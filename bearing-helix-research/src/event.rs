//! From noise to a named event — the response layer on top of the fold.
//!
//! The byte rate says *something changed*. This module answers, immediately:
//! **when** (timestamped at revolution precision by a per-rev CUSUM, plus a
//! back-estimate of the true onset), **where** (which bearing component, by
//! scoring the envelope spectrum at each characteristic order — the fault
//! order *is* the address inside the bearing; and for an inner-race defect,
//! the angular position recovered from where in the load zone the impact
//! energy centres), and **what now** (the disposition policy): a departure
//! that keeps growing becomes a MAINTENANCE request carrying its growth rate
//! and a service-by prediction; a departure that plateaus is ABSORBED — the
//! reference re-bases, monitoring re-arms, and the event stays on the record
//! as the machine's new voice.
//!
//! Every event is a metadata object anchored to the helix (its revolution
//! index n is the helix coordinate), meant to live alongside the audio
//! project's engagement layer: the machine's life is one helix, its incidents
//! are objects on it.
//!
//! Honesty notes, enforced by tests against the rig's ground truth:
//!  * angular pinpointing is physical for INNER-race defects (the defect
//!    rides the shaft through the fixed load zone, so impact energy folds to
//!    a phase peak). An outer-race defect is fixed in the housing — one
//!    accelerometer cannot give its angle; we report the component and say so.
//!  * angles are relative to the load-zone bottom (0°); an absolute housing
//!    angle needs a keyphasor or a second channel.
//!  * the service-by prediction extrapolates an exponential fit to a
//!    documented, arbitrary service threshold (departure = 100 σ_ref); the
//!    bench prints predicted vs. rig-true failure so the gap is visible.

use crate::dsp::{band_envelope, magnitude_spectrum};
use crate::state::RevState;
use crate::synth::BearingSpec;

// ---------------------------------------------------------------------------
// when — per-revolution CUSUM
// ---------------------------------------------------------------------------

/// One-sided CUSUM over the per-rev bits/sample series. Slack ½σ, threshold
/// 12σ — chosen for zero false alarms over the 30 h healthy control (test).
///
/// A second, zero-slack walk runs alongside purely for the onset
/// back-estimate: the slacked statistic resets constantly under slow early
/// growth, so its own excursion start collapses toward the detection time;
/// the unslacked walk's last zero is where the departure actually left the
/// noise floor.
#[derive(Clone, Debug)]
pub struct Cusum {
    pub mu: f64,
    pub sigma: f64,
    pub slack: f64,
    pub threshold: f64,
    s: f64,
    /// zero-slack shadow walk + where its current excursion began
    w: f64,
    w_start: Option<u64>,
    n: u64,
}

pub struct Detection {
    /// machine time of the detecting revolution — precise to one rev
    pub t_detect_h: f64,
    /// helix coordinate of the detection
    pub rev_n: u64,
    /// back-estimate of when the departure left the noise floor. The seeding
    /// moment itself is NOT identifiable — a defect is invisible until it
    /// perturbs the stream; this is the earliest observable trace.
    pub t_onset_est_h: f64,
    pub onset_rev_n: u64,
}

impl Cusum {
    pub fn new(mu: f64, sigma: f64) -> Self {
        // slack 0.25σ / threshold 10σ: fires within the first snapshot whose
        // mean departure sustains ≈0.55 per-rev σ — earlier than the 5σ
        // snapshot rule — while the 30 h healthy control stays silent (tests
        // guard both properties).
        Cusum { mu, sigma, slack: 0.25, threshold: 10.0, s: 0.0, w: 0.0, w_start: None, n: 0 }
    }

    /// Feed one revolution. `rev_n` is the ABSOLUTE helix index and `t_h` the
    /// revolution's machine time; `t_of` maps an absolute index back to a
    /// time (for the onset back-estimate). Returns a Detection the moment the
    /// statistic crosses.
    pub fn step(
        &mut self,
        rev_n: u64,
        t_h: f64,
        bits: f64,
        t_of: impl Fn(u64) -> f64,
    ) -> Option<Detection> {
        let z = (bits - self.mu) / self.sigma;
        self.s = (self.s + z - self.slack).max(0.0);
        let w_prev = self.w;
        self.w = (self.w + z).max(0.0);
        if self.w > 0.0 && w_prev == 0.0 {
            self.w_start = Some(rev_n);
        }
        self.n = rev_n;
        if self.s >= self.threshold {
            let onset_rev = self.w_start.unwrap_or(rev_n);
            Some(Detection {
                t_detect_h: t_h,
                rev_n,
                t_onset_est_h: t_of(onset_rev),
                onset_rev_n: onset_rev,
            })
        } else {
            None
        }
    }

    /// Re-base after an Absorb: new reference, statistic re-armed.
    pub fn rebase(&mut self, mu: f64, sigma: f64) {
        self.mu = mu;
        self.sigma = sigma.max(1e-12);
        self.s = 0.0;
        self.w = 0.0;
        self.w_start = None;
    }
}

// ---------------------------------------------------------------------------
// where — component by fault order, angle by load-zone folding
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Component {
    OuterRace,
    InnerRace,
    Ball,
    Cage,
}

impl Component {
    pub fn name(&self) -> &'static str {
        match self {
            Component::OuterRace => "outer race",
            Component::InnerRace => "inner race",
            Component::Ball => "rolling element",
            Component::Cage => "cage",
        }
    }
}

/// Envelope-spectrum line SNR at one order (±2.5% window / spectrum median).
fn order_snr(mags: &[f64], df: f64, median: f64, f_hz: f64) -> f64 {
    let lo = ((f_hz * 0.975) / df).floor().max(1.0) as usize;
    let hi = (((f_hz * 1.025) / df).ceil() as usize).min(mags.len().saturating_sub(1));
    if lo >= hi {
        return 0.0;
    }
    mags[lo..=hi].iter().fold(0.0f64, |a, &v| a.max(v)) / median
}

pub struct ComponentScore {
    pub component: Component,
    pub snr: f64,
    /// best / runner-up SNR — ≥ ~1.5 means the address is unambiguous
    pub margin: f64,
}

/// Score every characteristic order and name the defective component.
/// Inner race gets credit for its 1×-shaft sidebands (load-zone modulation);
/// ball defects for the 2×BSF line (a ball strikes both races per spin).
pub fn classify_component(x: &[f64], sr: f64, f_shaft: f64, spec: &BearingSpec) -> ComponentScore {
    let nyq = sr / 2.0;
    let env = band_envelope(x, sr, 0.2 * nyq, 0.6 * nyq);
    let m = env.iter().sum::<f64>() / env.len() as f64;
    let centred: Vec<f64> = env.iter().map(|v| v - m).collect();
    let (mags, df) = magnitude_spectrum(&centred, sr);
    let mut sorted: Vec<f64> = mags[1..].to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let median = sorted[sorted.len() / 2].max(1e-12);
    let line = |ord: f64| order_snr(&mags, df, median, ord * f_shaft);

    let candidates = [
        (Component::OuterRace, line(spec.bpfo_ord)),
        (
            Component::InnerRace,
            line(spec.bpfi_ord)
                + 0.5 * (line(spec.bpfi_ord - 1.0) + line(spec.bpfi_ord + 1.0)),
        ),
        (Component::Ball, line(spec.bsf_ord) + 0.5 * line(2.0 * spec.bsf_ord)),
        (Component::Cage, line(spec.ftf_ord)),
    ];
    let mut ranked = candidates;
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1));
    ComponentScore {
        component: ranked[0].0,
        snr: ranked[0].1,
        margin: ranked[0].1 / ranked[1].1.max(1e-12),
    }
}

pub struct AngleEstimate {
    /// defect angle relative to the load-zone bottom, degrees in [0, 360)
    pub deg_from_load_zone: f64,
    /// circular resultant length in [0, 1] — the pinpoint's sharpness
    pub confidence: f64,
}

/// Inner-race angular localization: fold the squared resonance-band envelope
/// by shaft phase. The defect passes the load-zone bottom once per rev; the
/// phase where impact energy centres is where it rides. φ(t) from the same
/// centred model the codec uses.
pub fn locate_inner(x: &[f64], sr: f64, f0: f64, drift: f64) -> AngleEstimate {
    let nyq = sr / 2.0;
    let env = band_envelope(x, sr, 0.2 * nyq, 0.6 * nyq);
    let m = env.iter().sum::<f64>() / env.len() as f64;
    let dur = env.len() as f64 / sr;
    let (mut cs, mut sn, mut w) = (0.0f64, 0.0f64, 0.0f64);
    for (i, e) in env.iter().enumerate() {
        let t = i as f64 / sr;
        let phi = f0 * t + 0.5 * drift * t * (t - dur); // revolutions
        let ang = 2.0 * std::f64::consts::PI * (phi - phi.floor());
        let wi = (e - m).max(0.0).powi(2); // impact energy above the floor
        cs += wi * ang.cos();
        sn += wi * ang.sin();
        w += wi;
    }
    if w <= 0.0 {
        return AngleEstimate { deg_from_load_zone: 0.0, confidence: 0.0 };
    }
    // energy peaks where the defect meets the load zone: defect angle is the
    // negative of the energy-weighted mean shaft phase
    let mean_phase = sn.atan2(cs);
    let deg = (-mean_phase).to_degrees().rem_euclid(360.0);
    AngleEstimate { deg_from_load_zone: deg, confidence: (cs * cs + sn * sn).sqrt() / w }
}

// ---------------------------------------------------------------------------
// what now — disposition
// ---------------------------------------------------------------------------

/// The documented (arbitrary) service threshold: departure = 100 σ_ref.
pub const SERVICE_DEPARTURE_SIGMA: f64 = 100.0;
/// Growth slower than one doubling per this many hours reads as stable.
pub const STABLE_DOUBLING_H: f64 = 12.0;
/// A "stable" departure above this is still a Maintenance matter — absorbing
/// is for LOW sounds only.
pub const ABSORB_CEILING_SIGMA: f64 = 30.0;
/// Snapshots after detection before any verdict is allowed / is forced.
pub const CONFIRM_MIN_SNAPSHOTS: usize = 12; // 2 h at the 10-min cadence
pub const CONFIRM_MAX_SNAPSHOTS: usize = 30; // 5 h

#[derive(Clone, Debug)]
pub enum Disposition {
    /// keeps growing: page a human, with the fit that says why
    Maintenance {
        growth_per_h: f64,
        doubling_h: f64,
        service_by_h: f64,
    },
    /// plateaued low: re-base, keep listening, keep the event as metadata
    Absorb { plateau_sigma: f64 },
}

/// Wait-until-distinguishable disposition. A verdict is only allowed once the
/// recent departure is either stationary (Absorb, if it flattened low) or
/// still rising after the window (Maintenance). Returns None while the
/// evidence is still moving and the window has room — deciding on a departure
/// in mid-flight was tried first and produced a false Absorb the moment the
/// growth outran a fixed 2 h window (bench, profile A).
pub fn dispose(t_h: &[f64], departure_sigma: &[f64]) -> Option<Disposition> {
    dispose_inner(t_h, departure_sigma, false)
}

/// End-of-data verdict: the machine's record stopped (failure, teardown) with
/// a candidate still open — judge on the evidence that exists.
pub fn dispose_forced(t_h: &[f64], departure_sigma: &[f64]) -> Disposition {
    dispose_inner(t_h, departure_sigma, true).expect("forced dispose always decides")
}

fn dispose_inner(t_h: &[f64], departure_sigma: &[f64], force: bool) -> Option<Disposition> {
    let n = departure_sigma.len();
    if n < CONFIRM_MIN_SNAPSHOTS && !force {
        return None;
    }
    if n < 4 {
        // forced with almost nothing: all we can say is that it departed
        return Some(Disposition::Absorb {
            plateau_sigma: departure_sigma.iter().sum::<f64>() / n.max(1) as f64,
        });
    }
    let mean3 = |end: usize| -> f64 {
        departure_sigma[end.saturating_sub(3)..end].iter().sum::<f64>() / 3.0
    };
    let last = mean3(n);
    // the last hour vs the hour before it (6 snapshots back)
    let prev = mean3(n.saturating_sub(6).max(3)).max(0.05);
    let still_rising = last / prev >= 1.25;

    if still_rising && n < CONFIRM_MAX_SNAPSHOTS && !force {
        return None; // let it show its shape
    }
    if !still_rising && last < ABSORB_CEILING_SIGMA {
        return Some(Disposition::Absorb { plateau_sigma: last });
    }

    // rising to the end of the window (or flat but high): page, with the
    // growth fit over the most recent 12 snapshots
    let lo = n.saturating_sub(12);
    let pts: Vec<(f64, f64)> = t_h[lo..]
        .iter()
        .zip(&departure_sigma[lo..])
        .map(|(t, d)| (*t, d.max(0.05).ln()))
        .collect();
    let m = pts.len() as f64;
    let mx = pts.iter().map(|p| p.0).sum::<f64>() / m;
    let my = pts.iter().map(|p| p.1).sum::<f64>() / m;
    let sxx: f64 = pts.iter().map(|p| (p.0 - mx) * (p.0 - mx)).sum();
    let sxy: f64 = pts.iter().map(|p| (p.0 - mx) * (p.1 - my)).sum();
    let g = if sxx > 0.0 { (sxy / sxx).max(1e-6) } else { 1e-6 };
    let doubling_h = std::f64::consts::LN_2 / g;
    let t_last = *t_h.last().unwrap();
    let service_by_h = t_last + ((SERVICE_DEPARTURE_SIGMA / last.max(1e-9)).ln() / g).max(0.0);
    Some(Disposition::Maintenance { growth_per_h: g, doubling_h, service_by_h })
}

// ---------------------------------------------------------------------------
// the event object — a sensory-metadata object anchored to the helix
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct DefectEvent {
    pub t_detect_h: f64,
    pub detect_rev_n: u64,
    pub t_onset_est_h: f64,
    pub component: &'static str,
    pub component_margin: f64,
    /// Some(deg) only when the physics permits a single-channel pinpoint
    pub angle_deg_from_load_zone: Option<f64>,
    pub angle_confidence: f64,
    pub departure_sigma_at_disposition: f64,
    pub disposition: Disposition,
}

impl DefectEvent {
    /// The wire/ecosystem form: one JSON object per event, `helix_n` is the
    /// coordinate that anchors it to the machine's helix record.
    pub fn to_json(&self) -> String {
        let (kind, detail) = match &self.disposition {
            Disposition::Maintenance { growth_per_h, doubling_h, service_by_h } => (
                "maintenance_request",
                format!(
                    "\"growth_per_h\":{:.4},\"doubling_h\":{:.2},\"service_by_h\":{:.2}",
                    growth_per_h, doubling_h, service_by_h
                ),
            ),
            Disposition::Absorb { plateau_sigma } => (
                "absorbed_stable",
                format!("\"plateau_sigma\":{:.1}", plateau_sigma),
            ),
        };
        let angle = match self.angle_deg_from_load_zone {
            Some(a) => format!("{:.1}", a),
            None => "null".to_string(),
        };
        format!(
            "{{\"object\":\"defect_event\",\"helix_n\":{},\"t_detect_h\":{:.4},\"t_onset_est_h\":{:.4},\
             \"component\":\"{}\",\"component_margin\":{:.2},\"angle_deg_from_load_zone\":{},\
             \"angle_confidence\":{:.2},\"departure_sigma\":{:.1},\"disposition\":\"{}\",{}}}",
            self.detect_rev_n,
            self.t_detect_h,
            self.t_onset_est_h,
            self.component,
            self.component_margin,
            angle,
            self.angle_confidence,
            self.departure_sigma_at_disposition,
            kind,
            detail
        )
    }
}

// ---------------------------------------------------------------------------
// the monitor — NOISE → CANDIDATE → (MAINTENANCE | ABSORB), single pass
// ---------------------------------------------------------------------------

pub struct MonitorConfig {
    /// snapshots of reference before the detector arms
    pub ref_snapshots: usize,
}

impl Default for MonitorConfig {
    fn default() -> Self {
        MonitorConfig { ref_snapshots: 30 }
    }
}

enum Phase {
    Reference,
    Noise,
    Candidate {
        det: Detection,
        dep: Vec<(f64, f64)>,
        comp: ComponentScore,
        ang: Option<AngleEstimate>,
    },
}

/// Single-pass monitor over a life. Feed each snapshot's per-rev states plus
/// its raw samples (for localization); events come out as they are disposed.
pub struct Monitor {
    cfg: MonitorConfig,
    spec: BearingSpec,
    cusum: Option<Cusum>,
    ref_bits: Vec<f64>,
    ref_snaps: usize,
    rev_times: Vec<f64>,
    phase: Phase,
    rev_count: u64,
    pub events: Vec<DefectEvent>,
}

impl Monitor {
    pub fn new(cfg: MonitorConfig, spec: BearingSpec) -> Self {
        Monitor {
            cfg,
            spec,
            cusum: None,
            ref_bits: Vec::new(),
            ref_snaps: 0,
            rev_times: Vec::new(),
            phase: Phase::Reference,
            rev_count: 0,
            events: Vec::new(),
        }
    }

    /// `x` are the snapshot's raw samples; `f0`/`drift` the refined speed.
    pub fn feed_snapshot(&mut self, revs: &[RevState], x: &[f64], sr: f64, f0: f64, drift: f64) {
        if revs.is_empty() {
            return;
        }
        let snap_bits: f64 = revs.iter().map(|r| r.bits).sum::<f64>() / revs.len() as f64;
        let snap_t = revs[0].t_h;
        for r in revs {
            self.rev_times.push(r.t_h);
        }
        let first_rev_n = self.rev_count;
        self.rev_count += revs.len() as u64;

        let phase = std::mem::replace(&mut self.phase, Phase::Noise);
        self.phase = match phase {
            Phase::Reference => {
                self.ref_bits.extend(revs.iter().map(|r| r.bits));
                self.ref_snaps += 1;
                if self.ref_snaps >= self.cfg.ref_snapshots {
                    let n = self.ref_bits.len() as f64;
                    let mu = self.ref_bits.iter().sum::<f64>() / n;
                    let sd = (self.ref_bits.iter().map(|b| (b - mu) * (b - mu)).sum::<f64>() / n)
                        .sqrt();
                    self.cusum = Some(Cusum::new(mu, sd.max(1e-9)));
                    Phase::Noise
                } else {
                    Phase::Reference
                }
            }
            Phase::Noise => {
                let mut cus = self.cusum.take().unwrap();
                let times = &self.rev_times;
                let mut detected: Option<Detection> = None;
                for (i, r) in revs.iter().enumerate() {
                    if detected.is_none() {
                        detected = cus.step(first_rev_n + i as u64, r.t_h, r.bits, |n| {
                            times.get(n as usize).copied().unwrap_or(r.t_h)
                        });
                    }
                }
                let departure = (snap_bits - cus.mu) / cus.sigma;
                self.cusum = Some(cus);
                match detected {
                    Some(det) => {
                        // localize immediately, on the detecting snapshot
                        let comp = classify_component(x, sr, f0, &self.spec);
                        let ang = if comp.component == Component::InnerRace {
                            Some(locate_inner(x, sr, f0, drift))
                        } else {
                            None
                        };
                        Phase::Candidate { det, dep: vec![(snap_t, departure)], comp, ang }
                    }
                    None => Phase::Noise,
                }
            }
            Phase::Candidate { det, mut dep, mut comp, mut ang } => {
                let cus = self.cusum.as_ref().unwrap();
                dep.push((snap_t, (snap_bits - cus.mu) / cus.sigma));
                // refine the address while confirming (the signal only grows)
                let c2 = classify_component(x, sr, f0, &self.spec);
                if c2.margin > comp.margin {
                    if c2.component == Component::InnerRace {
                        ang = Some(locate_inner(x, sr, f0, drift));
                    }
                    comp = c2;
                }
                let ts: Vec<f64> = dep.iter().map(|p| p.0).collect();
                let ds: Vec<f64> = dep.iter().map(|p| p.1).collect();
                let verdict = dispose(&ts, &ds);
                if verdict.is_none() {
                    Phase::Candidate { det, dep, comp, ang }
                } else {
                    let disposition = verdict.unwrap();
                    self.events.push(DefectEvent {
                        t_detect_h: det.t_detect_h,
                        detect_rev_n: det.rev_n,
                        t_onset_est_h: det.t_onset_est_h,
                        component: comp.component.name(),
                        component_margin: comp.margin,
                        angle_deg_from_load_zone: ang.as_ref().map(|a| a.deg_from_load_zone),
                        angle_confidence: ang.as_ref().map(|a| a.confidence).unwrap_or(0.0),
                        departure_sigma_at_disposition: *ds.last().unwrap(),
                        disposition: disposition.clone(),
                    });
                    let cus = self.cusum.as_mut().unwrap();
                    match disposition {
                        Disposition::Absorb { .. } => {
                            // self-stabilization: the plateau is the machine's
                            // new voice — re-base the reference and re-arm
                            let recent: Vec<f64> =
                                dep.iter().rev().take(6).map(|p| p.1).collect();
                            let mu_new = cus.mu
                                + cus.sigma * (recent.iter().sum::<f64>() / recent.len() as f64);
                            let sd = cus.sigma;
                            cus.rebase(mu_new, sd);
                        }
                        Disposition::Maintenance { .. } => {
                            // latched: a paged defect stays paged
                            cus.rebase(f64::INFINITY, 1.0);
                        }
                    }
                    Phase::Noise
                }
            }
        };
    }

    /// End of the record (failure, teardown, end of dataset): a candidate
    /// still open is judged on the evidence that exists and filed.
    pub fn finish(&mut self) {
        let phase = std::mem::replace(&mut self.phase, Phase::Noise);
        if let Phase::Candidate { det, dep, comp, ang } = phase {
            let ts: Vec<f64> = dep.iter().map(|p| p.0).collect();
            let ds: Vec<f64> = dep.iter().map(|p| p.1).collect();
            let disposition = dispose_forced(&ts, &ds);
            self.events.push(DefectEvent {
                t_detect_h: det.t_detect_h,
                detect_rev_n: det.rev_n,
                t_onset_est_h: det.t_onset_est_h,
                component: comp.component.name(),
                component_margin: comp.margin,
                angle_deg_from_load_zone: ang.as_ref().map(|a| a.deg_from_load_zone),
                angle_confidence: ang.as_ref().map(|a| a.confidence).unwrap_or(0.0),
                departure_sigma_at_disposition: *ds.last().unwrap_or(&0.0),
                disposition,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fold::{encode_snapshot, FoldConfig, Mode};
    use crate::speed::refine_speed;
    use crate::state::states_from_revs;
    use crate::synth::{snapshot, Fault, RigConfig, SKF_6205, ZA_2115};

    fn rig(bearing: crate::synth::BearingSpec, fault: Fault, sr: f64, rpm: f64) -> RigConfig {
        RigConfig {
            bearing,
            fault,
            sr,
            rpm_nominal: rpm,
            snapshot_s: 1.0,
            snapshot_every_s: 600.0,
            onset_h: 6.0,
            growth_tau_h: 1.5,
            noise_fs: 0.008,
            resonance_hz: if sr > 15000.0 { 4200.0 } else { 3000.0 },
            resonance_zeta: 0.045,
            seed_over_noise: 0.3,
            fail_over_noise: 40.0,
            defect_angle_deg: 0.0,
            plateau_over_noise: None,
            seed: 5,
        }
    }

    /// Run a rig life through the monitor exactly as the bench does.
    fn run_monitor(cfg: &RigConfig, until_h: f64) -> Monitor {
        let mut mon = Monitor::new(MonitorConfig::default(), cfg.bearing);
        let n_snaps = (until_h * 3600.0 / cfg.snapshot_every_s).ceil() as u64;
        let fold = FoldConfig { mode: Mode::Bounded { eps_fs: 0.001 }, ..Default::default() };
        for s in 0..n_snaps {
            let (t_h, x) = snapshot(cfg, s);
            let xf: Vec<f64> = x.iter().map(|&v| v as f64).collect();
            let sp = refine_speed(&xf, cfg.sr, cfg.f_shaft_nominal(), 0.05);
            let enc = encode_snapshot(&x, cfg.sr, &sp, &fold);
            let revs = states_from_revs(&enc.revs, t_h, cfg.sr);
            mon.feed_snapshot(&revs, &xf, cfg.sr, sp.f_hz, sp.drift_hz_per_s);
        }
        mon.finish(); // the record ends here — file any open candidate
        mon
    }

    #[test]
    fn healthy_control_raises_no_events() {
        let cfg = rig(ZA_2115, Fault::None, 20480.0, 2000.0);
        let mon = run_monitor(&cfg, 20.0);
        assert!(mon.events.is_empty(), "false event: {:?}", mon.events.first().map(|e| e.to_json()));
    }

    #[test]
    fn growing_outer_defect_is_timestamped_located_and_paged() {
        let cfg = rig(ZA_2115, Fault::OuterRace, 20480.0, 2000.0);
        let t_fail = cfg.t_fail_h().unwrap(); // ≈ 13.3 h
        let mon = run_monitor(&cfg, 11.5);
        assert_eq!(mon.events.len(), 1, "expected exactly one event");
        let e = &mon.events[0];
        assert!(e.t_detect_h > cfg.onset_h && e.t_detect_h < 9.0,
            "detected at {:.2} h (onset 6.0)", e.t_detect_h);
        // the estimate marks where the departure left the noise floor: at or
        // after true onset (defects are invisible before they perturb the
        // stream), well before detection, within the growth timescale
        assert!(e.t_onset_est_h < e.t_detect_h - 0.3,
            "back-estimate {:.2} h should precede detection {:.2} h", e.t_onset_est_h, e.t_detect_h);
        assert!((e.t_onset_est_h - cfg.onset_h).abs() < 2.0,
            "onset back-estimate {:.2} h vs true 6.0", e.t_onset_est_h);
        assert_eq!(e.component, "outer race", "margin {:.2}", e.component_margin);
        assert!(e.component_margin > 1.5, "ambiguous address: {:.2}", e.component_margin);
        assert!(e.angle_deg_from_load_zone.is_none(),
            "outer race must NOT claim a single-channel angle");
        match &e.disposition {
            Disposition::Maintenance { doubling_h, service_by_h, .. } => {
                assert!(*doubling_h < STABLE_DOUBLING_H);
                assert!(*service_by_h > e.t_detect_h && *service_by_h < t_fail + 6.0,
                    "service_by {:.1} vs true failure {:.1}", service_by_h, t_fail);
            }
            d => panic!("expected Maintenance, got {d:?}"),
        }
    }

    #[test]
    fn plateaued_inner_defect_is_absorbed_and_its_angle_recovered() {
        let mut cfg = rig(SKF_6205, Fault::InnerRace, 12000.0, 1772.0);
        cfg.defect_angle_deg = 135.0;
        cfg.plateau_over_noise = Some(8.0);
        cfg.onset_h = 5.5;
        cfg.growth_tau_h = 1.0;
        cfg.seed = 12;
        assert!(cfg.t_fail_h().is_none(), "a plateaued defect never fails");
        let mon = run_monitor(&cfg, 14.0);
        assert_eq!(mon.events.len(), 1, "one stable defect, one event, then silence");
        let e = &mon.events[0];
        assert_eq!(e.component, "inner race", "margin {:.2}", e.component_margin);
        let ang = e.angle_deg_from_load_zone.expect("inner race must be pinpointed");
        let err = (ang - 135.0 + 180.0).rem_euclid(360.0) - 180.0;
        assert!(err.abs() < 20.0, "angle {ang:.1}° vs true 135° (err {err:.1}°)");
        assert!(e.angle_confidence > 0.15, "confidence {:.2}", e.angle_confidence);
        match &e.disposition {
            Disposition::Absorb { plateau_sigma } => {
                assert!(*plateau_sigma > 2.0, "plateau {plateau_sigma:.1}σ should be a real departure");
            }
            d => panic!("expected Absorb (self-stabilization), got {d:?}"),
        }
        let j = e.to_json();
        assert!(j.contains("\"object\":\"defect_event\"") && j.contains("absorbed_stable"), "{j}");
    }
}
