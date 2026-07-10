//! The one command that produces the headline numbers, deterministically:
//!
//!     cargo run --release --bin bench_synthetic
//!
//! Three synthetic lives (labelled synthetic everywhere they surface):
//!   A: Rexnord ZA-2115 kinematics, outer-race defect  (IMS-like rig)
//!   B: SKF 6205 kinematics, inner-race defect         (CWRU-geometry rig)
//!   H: healthy control (ZA-2115, no defect)           (false-alarm check)
//!
//! For each: every indicator through the SAME alarm rule → alarm time + lead
//! vs the rig's ground-truth failure; compression accounting on the healthy
//! reference stretch; the helix odometer bend. Series land in bench_out/ as
//! CSV + NPZ for the dashboard.

use bearing_helix_research::event::{Monitor, MonitorConfig};
use bearing_helix_research::indicators::AlarmRule;
use bearing_helix_research::life::{
    evaluate_alarms, odometer_bend, process_snapshot, ProcessConfig, SnapshotMetrics,
    BOUNDED_EPS_FS,
};
use bearing_helix_research::state::machine_dynamics;
use bearing_helix_research::synth::{snapshot, Fault, RigConfig, SKF_6205, ZA_2115};
use std::path::PathBuf;

fn profile_a() -> RigConfig {
    RigConfig {
        bearing: ZA_2115,
        fault: Fault::OuterRace,
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

fn profile_b() -> RigConfig {
    RigConfig {
        bearing: SKF_6205,
        fault: Fault::InnerRace,
        sr: 12000.0,
        rpm_nominal: 1772.0,
        snapshot_s: 1.0,
        snapshot_every_s: 600.0,
        onset_h: 10.0,
        growth_tau_h: 2.0,
        noise_fs: 0.010,
        resonance_hz: 3000.0,
        resonance_zeta: 0.05,
        seed_over_noise: 0.3,
        fail_over_noise: 40.0,
        defect_angle_deg: 220.0, // event.rs must recover this from the vibration
        plateau_over_noise: None,
        seed: 11,
    }
}

fn profile_h() -> RigConfig {
    RigConfig { fault: Fault::None, seed: 23, ..profile_a() }
}

/// The "low sound" case: a real inner-race defect that grows to 8σ_noise and
/// stabilizes — never fails. The right response is not a page but an Absorb:
/// re-base, keep listening, keep the event as metadata on the helix.
fn profile_s() -> RigConfig {
    RigConfig {
        fault: Fault::InnerRace,
        defect_angle_deg: 135.0,
        plateau_over_noise: Some(8.0),
        onset_h: 8.0,
        growth_tau_h: 1.5,
        seed: 31,
        ..profile_b()
    }
}

fn run_life(tag: &str, cfg: &RigConfig, until_h: f64) -> (Vec<SnapshotMetrics>, Monitor) {
    let pc = ProcessConfig {
        f_nominal_hz: cfg.f_shaft_nominal(),
        speed_tol_rel: 0.05,
        watch_order: cfg.fault_order(),
        with_zstd: true,
    };
    let mut mon = Monitor::new(MonitorConfig::default(), cfg.bearing);
    let n_snaps = (until_h * 3600.0 / cfg.snapshot_every_s).ceil() as u64;
    let mut out = Vec::with_capacity(n_snaps as usize);
    for s in 0..n_snaps {
        let (t_h, x) = snapshot(cfg, s);
        let m = process_snapshot(t_h, &x, cfg.sr, &pc);
        let xf: Vec<f64> = x.iter().map(|&v| v as f64).collect();
        mon.feed_snapshot(&m.rev_states, &xf, cfg.sr, m.f_hz, m.drift_hz_per_s);
        out.push(m);
        if s % 30 == 0 {
            eprintln!("  [{tag}] t={t_h:6.2} h  ({s}/{n_snaps})");
        }
    }
    mon.finish(); // end of record: file any open candidate
    (out, mon)
}

fn print_events(
    tag: &str,
    events: &[bearing_helix_research::event::DefectEvent],
    t_fail_true: Option<f64>,
    onset_true: Option<f64>,
    angle_true: Option<f64>,
) {
    use bearing_helix_research::event::Disposition;
    println!("\n== {tag} — defect events (per-rev CUSUM → locate → dispose) ==");
    if events.is_empty() {
        println!("   no events{}", if onset_true.is_none() { " (correct: nothing was seeded)" } else { "" });
        return;
    }
    for e in events {
        let onset = match onset_true {
            Some(o) => format!("{:.2} h (true {o:.1})", e.t_onset_est_h),
            None => format!("{:.2} h", e.t_onset_est_h),
        };
        println!(
            "   DETECT  t = {:.4} h at helix rev {} (one-rev precision ≈ 30 ms) · onset est {onset}",
            e.t_detect_h, e.detect_rev_n
        );
        let angle = match (e.angle_deg_from_load_zone, angle_true) {
            (Some(a), Some(tr)) => format!("{a:.0}° from load zone (true {tr:.0}°, conf {:.2})", e.angle_confidence),
            (Some(a), None) => format!("{a:.0}° from load zone (conf {:.2})", e.angle_confidence),
            (None, _) => "n/a for a single channel (defect fixed in housing)".to_string(),
        };
        println!("   WHERE   {} (margin {:.1}×) · angle {angle}", e.component, e.component_margin);
        match &e.disposition {
            Disposition::Maintenance { doubling_h, service_by_h, .. } => {
                let vs = match t_fail_true {
                    Some(f) => format!(" (rig truly fails {f:.2} h)"),
                    None => String::new(),
                };
                println!(
                    "   ROUTE   MAINTENANCE REQUEST — departure doubles every {doubling_h:.1} h; service by {service_by_h:.2} h{vs}"
                );
            }
            Disposition::Absorb { plateau_sigma } => {
                println!(
                    "   ROUTE   ABSORBED (self-stabilization) — stable at {plateau_sigma:.0}σ; reference re-based, monitoring re-armed, event kept as helix metadata"
                );
            }
        }
    }
}

fn print_alarm_table(tag: &str, series: &[SnapshotMetrics], t_fail: Option<f64>, rule: &AlarmRule) {
    println!("\n== {tag} — alarms under the shared rule (k={}σ, {} consecutive) ==",
        rule.k_sigma, rule.m_consecutive);
    match t_fail {
        Some(f) => println!("   ground-truth failure at {f:.2} h"),
        None => println!("   healthy control — any alarm below is FALSE"),
    }
    for a in evaluate_alarms(series, rule, t_fail) {
        let informed = if a.informed { "  [knows the fault order]" } else { "" };
        match (a.t_alarm_h, a.lead_h) {
            (Some(t), Some(l)) => {
                println!("   {:<28} alarm {t:7.2} h   lead {l:6.2} h{informed}", a.name)
            }
            (Some(t), None) => println!("   {:<28} alarm {t:7.2} h  (FALSE ALARM){informed}", a.name),
            (None, _) => println!("   {:<28} —{informed}", a.name),
        }
    }
}

fn compression_summary(tag: &str, series: &[SnapshotMetrics], healthy_up_to_h: f64) {
    let healthy: Vec<&SnapshotMetrics> =
        series.iter().filter(|m| m.t_h <= healthy_up_to_h).collect();
    let mean = |f: &dyn Fn(&SnapshotMetrics) -> f64| -> f64 {
        healthy.iter().map(|m| f(m)).sum::<f64>() / healthy.len().max(1) as f64
    };
    let ll = mean(&|m| m.bits_ll_stream);
    let bd = mean(&|m| m.bits_bd_stream);
    let zs = mean(&|m| m.bits_zstd);
    let worst_err = series.iter().fold(0.0f64, |a, m| a.max(m.max_err_fs));
    println!("\n== {tag} — bytes on the healthy stretch (≤ {healthy_up_to_h:.1} h) ==");
    println!("   raw                    16.00 bits/sample");
    println!("   zstd-19 on raw         {zs:5.2} bits/sample   ({:.2}x vs raw)", 16.0 / zs);
    println!("   fold lossless          {ll:5.2} bits/sample   ({:.2}x vs raw, {:+.1}% vs zstd)",
        16.0 / ll, (zs - ll) / zs * 100.0);
    println!("   fold bounded ±{:.2}% FS {bd:5.2} bits/sample   ({:.2}x vs raw, {:.2}x vs zstd)",
        BOUNDED_EPS_FS * 100.0, 16.0 / bd, zs / bd);
    println!("   bounded max |err|      {:.4}% FS (bound {:.2}% FS)",
        worst_err * 100.0, BOUNDED_EPS_FS * 100.0);
}

fn odometer_summary(tag: &str, series: &[SnapshotMetrics], onset_h: f64) {
    let states: Vec<_> = series.iter().flat_map(|m| m.rev_states.iter().copied()).collect();
    let dynamics = machine_dynamics(&states, 5);
    let (pre, post) = odometer_bend(&states, &dynamics.h, onset_h);
    println!("\n== {tag} — helix odometer (climb per revolution) ==");
    println!("   before onset {pre:.4}   after onset {post:.4}   bend {:.2}x", post / pre.max(1e-12));
}

fn emit(dir: &PathBuf, tag: &str, series: &[SnapshotMetrics]) {
    std::fs::create_dir_all(dir).expect("bench_out");
    let t: Vec<f64> = series.iter().map(|m| m.t_h).collect();
    let cols: Vec<(&str, Vec<f64>)> = vec![
        ("t_h", t),
        ("f_hz", series.iter().map(|m| m.f_hz).collect()),
        ("bits_bd", series.iter().map(|m| m.bits_bd).collect()),
        ("bits_ll", series.iter().map(|m| m.bits_ll).collect()),
        ("bits_bd_stream", series.iter().map(|m| m.bits_bd_stream).collect()),
        ("bits_ll_stream", series.iter().map(|m| m.bits_ll_stream).collect()),
        ("bits_zstd", series.iter().map(|m| m.bits_zstd).collect()),
        ("rms_fs", series.iter().map(|m| m.rms_fs).collect()),
        ("kurtosis", series.iter().map(|m| m.kurtosis).collect()),
        ("crest", series.iter().map(|m| m.crest).collect()),
        ("env_line", series.iter().map(|m| m.env_line_snr).collect()),
    ];
    let borrowed: Vec<(&str, &[f64])> = cols.iter().map(|(n, v)| (*n, v.as_slice())).collect();
    bearing_helix_research::io::write_csv(&dir.join(format!("{tag}.csv")), &borrowed).unwrap();
    bearing_helix_research::io::write_npz(&dir.join(format!("{tag}.npz")), &borrowed).unwrap();

    // odometer series at rev resolution
    let states: Vec<_> = series.iter().flat_map(|m| m.rev_states.iter().copied()).collect();
    let dynamics = machine_dynamics(&states, 5);
    let ocols: Vec<(&str, Vec<f64>)> = vec![
        ("t_h", states.iter().map(|s| s.t_h).collect()),
        ("a_db", states.iter().map(|s| s.a_db).collect()),
        ("i_semi", states.iter().map(|s| s.i_semi).collect()),
        ("h", dynamics.h.clone()),
        ("f_mag", dynamics.f_mag.clone()),
        ("tau", dynamics.tau.clone()),
    ];
    let oborrowed: Vec<(&str, &[f64])> = ocols.iter().map(|(n, v)| (*n, v.as_slice())).collect();
    bearing_helix_research::io::write_csv(&dir.join(format!("{tag}_odometer.csv")), &oborrowed).unwrap();
}

/// Two 0.2 s waveform excerpts from profile A — healthy (6 h) and past onset
/// (16 h, impacts ≈ 1.9σ_noise) — so the dashboard can show the machine, not
/// just the statistics.
fn emit_waveforms(dir: &PathBuf, cfg: &bearing_helix_research::synth::RigConfig) {
    std::fs::create_dir_all(dir).expect("bench_out");
    let (_, healthy) = snapshot(cfg, 36); // 6.0 h
    let (_, faulty) = snapshot(cfg, 96); // 16.0 h
    let n = 4096usize;
    let to_fs = |v: &i16| *v as f64 / bearing_helix_research::fold::FS_I16;
    let cols: Vec<(&str, Vec<f64>)> = vec![
        ("t_ms", (0..n).map(|i| i as f64 / cfg.sr * 1000.0).collect()),
        ("healthy_6h", healthy[..n].iter().map(to_fs).collect()),
        ("faulty_16h", faulty[..n].iter().map(to_fs).collect()),
    ];
    let borrowed: Vec<(&str, &[f64])> = cols.iter().map(|(nm, v)| (*nm, v.as_slice())).collect();
    bearing_helix_research::io::write_csv(&dir.join("waveform_a.csv"), &borrowed).unwrap();
}

fn main() {
    let out_dir = PathBuf::from("bench_out");
    let rule = AlarmRule::default();
    println!("bearing-helix-research synthetic bench — deterministic, seeds fixed");
    println!("(SYNTHETIC data from the physics rig; real-data runners: run_ims/run_cwru/run_femto)");

    let a = profile_a();
    let t_fail_a = a.t_fail_h();
    let until_a = t_fail_a.unwrap() + 1.0;
    eprintln!("profile A: {} outer race, onset {:.1} h, fail {:.2} h", a.bearing.name, a.onset_h, t_fail_a.unwrap());
    let (series_a, mon_a) = run_life("A", &a, until_a);

    let b = profile_b();
    let t_fail_b = b.t_fail_h();
    let until_b = t_fail_b.unwrap() + 1.0;
    eprintln!("profile B: {} inner race, onset {:.1} h, fail {:.2} h", b.bearing.name, b.onset_h, t_fail_b.unwrap());
    let (series_b, mon_b) = run_life("B", &b, until_b);

    let h = profile_h();
    eprintln!("profile H: healthy control, 30 h");
    let (series_h, mon_h) = run_life("H", &h, 30.0);

    let s = profile_s();
    eprintln!("profile S: {} stable inner defect (plateau 8σ, never fails), 20 h", s.bearing.name);
    let (_series_s, mon_s) = run_life("S", &s, 20.0);

    print_alarm_table("profile A (ZA-2115, outer race, synthetic)", &series_a, t_fail_a, &rule);
    print_alarm_table("profile B (SKF-6205, inner race, synthetic)", &series_b, t_fail_b, &rule);
    print_alarm_table("profile H (healthy control, synthetic)", &series_h, None, &rule);

    print_events("profile A (outer race, growing)", &mon_a.events, t_fail_a, Some(a.onset_h), None);
    print_events("profile B (inner race, growing)", &mon_b.events, t_fail_b, Some(b.onset_h), Some(b.defect_angle_deg));
    print_events("profile S (inner race, STABLE plateau — the low-sound case)", &mon_s.events, None, Some(s.onset_h), Some(s.defect_angle_deg));
    print_events("profile H (healthy)", &mon_h.events, None, None, None);

    // events.json: the sensory-metadata objects, one per event, helix-anchored
    {
        let all: Vec<(&str, &bearing_helix_research::event::DefectEvent)> =
            mon_a.events.iter().map(|e| ("A", e))
                .chain(mon_b.events.iter().map(|e| ("B", e)))
                .chain(mon_s.events.iter().map(|e| ("S", e)))
                .chain(mon_h.events.iter().map(|e| ("H", e)))
                .collect();
        let body: Vec<String> = all
            .iter()
            .map(|(tag, e)| format!("  {{\"profile\":\"{tag}\",\"event\":{}}}", e.to_json()))
            .collect();
        std::fs::create_dir_all(&out_dir).unwrap();
        std::fs::write(out_dir.join("events.json"), format!("[\n{}\n]\n", body.join(",\n"))).unwrap();
    }

    compression_summary("profile A", &series_a, a.onset_h.min(10.0));
    compression_summary("profile H", &series_h, 30.0);

    odometer_summary("profile A", &series_a, a.onset_h);
    odometer_summary("profile B", &series_b, b.onset_h);

    emit(&out_dir, "profile_a", &series_a);
    emit(&out_dir, "profile_b", &series_b);
    emit(&out_dir, "profile_h", &series_h);
    emit_waveforms(&out_dir, &a);
    println!("\nseries written to bench_out/*.csv and *.npz");

    // the one-line verdict the alarm table justifies
    let alarms_a = evaluate_alarms(&series_a, &rule, t_fail_a);
    let fmt_lead = alarms_a.iter().find(|x| x.name.contains("bounded")).and_then(|x| x.lead_h);
    let rms_lead = alarms_a.iter().find(|x| x.name == "RMS").and_then(|x| x.lead_h);
    if let (Some(f), Some(r)) = (fmt_lead, rms_lead) {
        println!("\nprofile A verdict: the format's own byte rate alarmed {:.1} h before failure ({:.1} h before RMS did).", f, f - r);
    }
}
