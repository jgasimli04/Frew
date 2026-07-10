//! The deterministic physics rig — synthetic run-to-failure with real bearing
//! kinematics. Everything here is labelled synthetic wherever its numbers
//! surface; the rig exists so the pipeline can be *watched* end to end before
//! real datasets are downloaded (bench/fetch_data.sh).
//!
//! Kinematics: characteristic fault orders (per shaft revolution) of the two
//! bearings behind the public run-to-failure datasets.
//!
//!  * Rexnord ZA-2115 (NASA IMS test rig, 2000 rpm): published defect
//!    frequencies 236.4 / 296.9 / 139.9 / ~15 Hz → orders below. 16 rollers
//!    per row: BPFO + BPFI = Z holds (7.09 + 8.91 ≈ 16).
//!  * SKF 6205-2RS JEM (CWRU drive end): the standard published multipliers.
//!    9 balls: 3.5848 + 5.4152 = 9.0000.
//!
//! Physics per snapshot: shaft-synchronous harmonics (imbalance et al.) that
//! the TSA pool should absorb; a defect impulse train at the fault order with
//! per-impact slip jitter (real rolling elements slide — this is exactly why
//! fault impulses do NOT pool) each ringing a structural resonance; sensor
//! noise; i16 quantisation. Defect severity grows exponentially from onset;
//! failure is declared when severity crosses `fail_over_noise`·σ_noise.

#[derive(Clone, Copy, Debug)]
pub struct BearingSpec {
    pub name: &'static str,
    pub rollers: u32,
    pub bpfo_ord: f64,
    pub bpfi_ord: f64,
    pub bsf_ord: f64,
    pub ftf_ord: f64,
}

/// Rexnord ZA-2115 double-row bearing (NASA IMS rig), orders at 2000 rpm from
/// the published 236.4/296.9/139.9 Hz defect frequencies.
pub const ZA_2115: BearingSpec = BearingSpec {
    name: "Rexnord ZA-2115",
    rollers: 16,
    bpfo_ord: 7.092,
    bpfi_ord: 8.908,
    bsf_ord: 4.197,
    ftf_ord: 0.443,
};

/// SKF 6205-2RS JEM (CWRU drive-end bearing), standard published multipliers.
pub const SKF_6205: BearingSpec = BearingSpec {
    name: "SKF 6205-2RS JEM",
    rollers: 9,
    bpfo_ord: 3.5848,
    bpfi_ord: 5.4152,
    bsf_ord: 2.3575,
    ftf_ord: 0.39828,
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fault {
    None,
    OuterRace,
    InnerRace,
}

#[derive(Clone, Copy, Debug)]
pub struct RigConfig {
    pub bearing: BearingSpec,
    pub fault: Fault,
    pub sr: f64,
    pub rpm_nominal: f64,
    pub snapshot_s: f64,
    pub snapshot_every_s: f64,
    /// defect onset, hours of machine life
    pub onset_h: f64,
    /// severity e-folding time, hours
    pub growth_tau_h: f64,
    /// sensor noise sigma, fraction of full scale
    pub noise_fs: f64,
    /// structural resonance the impacts ring
    pub resonance_hz: f64,
    pub resonance_zeta: f64,
    /// severity at onset, in units of noise sigma (buried at birth)
    pub seed_over_noise: f64,
    /// severity at declared failure, in units of noise sigma
    pub fail_over_noise: f64,
    /// inner-race only: the defect's angle on the shaft, degrees from the
    /// load-zone bottom — what event::locate_inner must recover
    pub defect_angle_deg: f64,
    /// Some(level): severity stops growing at level·σ_noise — a stable,
    /// non-failing defect (the "absorb as the machine's new voice" case)
    pub plateau_over_noise: Option<f64>,
    pub seed: u64,
}

impl RigConfig {
    pub fn f_shaft_nominal(&self) -> f64 {
        self.rpm_nominal / 60.0
    }
    /// severity (impulse peak amplitude, FS fraction) at machine time t
    pub fn severity(&self, t_h: f64) -> f64 {
        if self.fault == Fault::None || t_h < self.onset_h {
            return 0.0;
        }
        let s0 = self.seed_over_noise * self.noise_fs;
        let s = s0 * ((t_h - self.onset_h) / self.growth_tau_h).exp();
        match self.plateau_over_noise {
            Some(p) => s.min(p * self.noise_fs),
            None => s,
        }
    }
    /// ground-truth failure time: severity crossing fail_over_noise·σ.
    /// A plateaued defect below the failure level never fails.
    pub fn t_fail_h(&self) -> Option<f64> {
        if self.fault == Fault::None {
            return None;
        }
        if let Some(p) = self.plateau_over_noise {
            if p < self.fail_over_noise {
                return None;
            }
        }
        Some(self.onset_h + self.growth_tau_h * (self.fail_over_noise / self.seed_over_noise).ln())
    }
    pub fn fault_order(&self) -> f64 {
        match self.fault {
            Fault::None => self.bearing.bpfo_ord, // what the informed baseline watches
            Fault::OuterRace => self.bearing.bpfo_ord,
            Fault::InnerRace => self.bearing.bpfi_ord,
        }
    }
}

// --- deterministic RNG: splitmix64 streams, one per (seed, snapshot, purpose) --

#[derive(Clone, Copy)]
pub struct Rng(u64);

impl Rng {
    pub fn stream(seed: u64, snapshot: u64, purpose: u64) -> Rng {
        // mix the coordinates so streams are independent and reproducible
        let mut s = seed ^ snapshot.wrapping_mul(0x9E3779B97F4A7C15) ^ purpose.wrapping_mul(0xD1B54A32D192ED03);
        // warm up
        let mut r = Rng(s);
        for _ in 0..3 {
            s = r.next_u64();
        }
        r.0 = s;
        r
    }
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    pub fn uniform(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
    /// Box–Muller, deterministic
    pub fn gaussian(&mut self) -> f64 {
        let u1 = self.uniform().max(1e-300);
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

/// One machine snapshot: `snapshot_s` seconds of i16 vibration at time t_h.
pub fn snapshot(cfg: &RigConfig, snap_idx: u64) -> (f64, Vec<i16>) {
    let t_h = snap_idx as f64 * cfg.snapshot_every_s / 3600.0;
    let n = (cfg.snapshot_s * cfg.sr).round() as usize;
    let fs = crate::fold::FS_I16;

    // slow speed wander (deterministic in absolute time) + within-snapshot drift
    let f0 = cfg.f_shaft_nominal()
        * (1.0
            + 0.0020 * (2.0 * std::f64::consts::PI * t_h / 3.1).sin()
            + 0.0011 * (2.0 * std::f64::consts::PI * t_h / 0.73 + 1.0).sin());
    let drift = cfg.f_shaft_nominal() * 0.0004 * (2.0 * std::f64::consts::PI * t_h / 1.7).cos(); // Hz/s

    let sev = cfg.severity(t_h);
    let sev_fail = cfg.fail_over_noise * cfg.noise_fs;
    let wear = (sev / sev_fail).min(1.0); // 0..1 through the degradation

    // synchronous part: harmonic set (imbalance, misalignment, looseness) under
    // slow load variation — ±15% amplitude wobble over hours. Constant-load
    // machines don't exist; this is what makes energy statistics (RMS, kurtosis)
    // honest baselines instead of laboratory fictions. Deterministic in t_h.
    let mut ph_rng = Rng::stream(cfg.seed, 0, 1);
    let base_amp = [0.020, 0.009, 0.004, 0.0025, 0.0012];
    let load_period_h = [1.9, 1.3, 2.7, 0.9, 2.1];
    let harm_phase: Vec<f64> =
        (0..base_amp.len()).map(|_| ph_rng.uniform() * 2.0 * std::f64::consts::PI).collect();
    let mut load_rng = Rng::stream(cfg.seed, 0, 4);
    let load_phase: Vec<f64> =
        (0..base_amp.len()).map(|_| load_rng.uniform() * 2.0 * std::f64::consts::PI).collect();
    let harm_amp: Vec<f64> = base_amp
        .iter()
        .zip(load_period_h.iter().zip(&load_phase))
        .map(|(&a, (&p, &ph))| {
            a * (1.0 + 0.15 * (2.0 * std::f64::consts::PI * t_h / p + ph).sin())
        })
        .collect();

    let mut noise = Rng::stream(cfg.seed, snap_idx + 1, 2);
    let mut imp_rng = Rng::stream(cfg.seed, snap_idx + 1, 3);

    // impact train: fault-order arrivals with per-impact slip jitter
    let dur = n as f64 / cfg.sr;
    let mut impacts: Vec<(f64, f64)> = Vec::new(); // (time_s, amplitude_fs)
    if sev > 0.0 {
        let ord = cfg.fault_order();
        let mut t = imp_rng.uniform() / (ord * f0); // random phase start
        while t < dur {
            let load = match cfg.fault {
                Fault::InnerRace => {
                    // the defect rides the shaft through the fixed load zone:
                    // strongest impacts when shaft phase + defect angle ≡ 0
                    let phi = f0 * t + cfg.defect_angle_deg / 360.0;
                    let c = (2.0 * std::f64::consts::PI * phi).cos();
                    (0.35 + 0.65 * 0.5 * (1.0 + c)).powi(2)
                }
                _ => 1.0,
            };
            let amp = sev * load * (0.7 + 0.6 * imp_rng.uniform());
            impacts.push((t, amp));
            let slip = 1.0 + 0.012 * imp_rng.gaussian(); // ~1.2% slip jitter
            t += slip.max(0.2) / (ord * (f0 + drift * (t - dur / 2.0)));
        }
    }

    // render: synchronous + impacts ringing the resonance + noise
    let tau_r = 1.0 / (2.0 * std::f64::consts::PI * cfg.resonance_hz * cfg.resonance_zeta);
    let ring_len = (6.0 * tau_r * cfg.sr) as usize + 1;
    // late-life broadband floor rise — LINEAR in wear so it is smooth from
    // zero. (A √wear law was tried first; its infinite slope at onset steps
    // the noise floor and gifts any entropy meter an instant, unphysical
    // detection. Recorded in theory/00.)
    let sigma_eff = cfg.noise_fs * (1.0 + 0.35 * wear);

    let mut x = vec![0.0f64; n];
    for i in 0..n {
        let t = i as f64 / cfg.sr;
        let phi = f0 * t + 0.5 * drift * t * (t - dur); // revolutions
        let mut v = 0.0;
        for (k, (&a, &p)) in harm_amp.iter().zip(&harm_phase).enumerate() {
            v += a * (2.0 * std::f64::consts::PI * (k as f64 + 1.0) * phi + p).cos();
        }
        x[i] = v + sigma_eff * noise.gaussian();
    }
    for &(t_imp, amp) in &impacts {
        let i0 = (t_imp * cfg.sr) as usize;
        for j in 0..ring_len {
            let i = i0 + j;
            if i >= n {
                break;
            }
            let dt = j as f64 / cfg.sr;
            x[i] += amp
                * (-dt / tau_r).exp()
                * (2.0 * std::f64::consts::PI * cfg.resonance_hz * dt).sin();
        }
    }

    let samples = x
        .iter()
        .map(|v| (v * fs).round().clamp(i16::MIN as f64, i16::MAX as f64) as i16)
        .collect();
    (t_h, samples)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::speed::refine_speed;

    fn ims_like(fault: Fault) -> RigConfig {
        RigConfig {
            bearing: ZA_2115,
            fault,
            sr: 20480.0,
            rpm_nominal: 2000.0,
            snapshot_s: 1.0,
            snapshot_every_s: 600.0,
            onset_h: 12.0,
            growth_tau_h: 2.2,
            noise_fs: 0.008,
            resonance_hz: 4200.0,
            resonance_zeta: 0.045,
            seed_over_noise: 0.3,
            fail_over_noise: 40.0,
            defect_angle_deg: 0.0,
            plateau_over_noise: None,
            seed: 7,
        }
    }

    #[test]
    fn fault_orders_satisfy_the_roller_identity() {
        // BPFO + BPFI = Z (rolling-element count) — geometry, not opinion.
        for b in [ZA_2115, SKF_6205] {
            assert!(
                (b.bpfo_ord + b.bpfi_ord - b.rollers as f64).abs() < 0.02,
                "{}: {} + {} != {}",
                b.name,
                b.bpfo_ord,
                b.bpfi_ord,
                b.rollers
            );
        }
    }

    #[test]
    fn snapshots_are_deterministic() {
        let cfg = ims_like(Fault::OuterRace);
        let (t1, a) = snapshot(&cfg, 90);
        let (t2, b) = snapshot(&cfg, 90);
        assert_eq!(t1, t2);
        assert_eq!(a, b, "same seed + snapshot index must reproduce bit-exactly");
    }

    #[test]
    fn speed_refinement_beats_2e4() {
        // acceptance: <2e-4 relative error against the rig's true centre
        // frequency, wander and drift enabled, no tachometer.
        let cfg = ims_like(Fault::None);
        for snap in [0u64, 33, 61] {
            let (t_h, x) = snapshot(&cfg, snap);
            let xf: Vec<f64> = x.iter().map(|&v| v as f64).collect();
            let est = refine_speed(&xf, cfg.sr, cfg.f_shaft_nominal(), 0.05);
            let f_true = cfg.f_shaft_nominal()
                * (1.0
                    + 0.0020 * (2.0 * std::f64::consts::PI * t_h / 3.1).sin()
                    + 0.0011 * (2.0 * std::f64::consts::PI * t_h / 0.73 + 1.0).sin());
            let rel = (est.f_hz - f_true).abs() / f_true;
            assert!(rel < 2e-4, "snapshot {snap}: relative speed error {rel:.2e}");
        }
    }
}
