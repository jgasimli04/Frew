//! FEMTO/PRONOSTIA run-to-failure: point at a BearingX_Y directory of
//! acc_XXXXX.csv files (0.1 s @ 25.6 kHz every 10 s).
//!
//!     cargo run --release --bin run_femto -- <bearing_dir> [channel=0] [rpm=1800]

use bearing_helix_research::indicators::AlarmRule;
use bearing_helix_research::life::{evaluate_alarms, process_snapshot, ProcessConfig};
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("usage: run_femto <bearing_dir> [channel] [rpm]"));
    let channel: usize = args.next().map(|v| v.parse().unwrap()).unwrap_or(0);
    let rpm: f64 = args.next().map(|v| v.parse().unwrap()).unwrap_or(1800.0);
    let sr = 25600.0;

    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("bearing dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with("acc_"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no acc_*.csv in {dir:?}");
    eprintln!("{} snapshots, channel {channel}, {rpm} rpm", files.len());

    let mut mags: Vec<f64> = Vec::new();
    for p in files.iter().step_by((files.len() / 40).max(1)) {
        mags.extend(
            bearing_helix_research::io::read_femto_acc(p, channel).expect("read").iter().map(|v| v.abs()),
        );
    }
    mags.sort_by(|a, b| a.total_cmp(b));
    let scale = 0.95 * 32767.0 / mags[(mags.len() as f64 * 0.999) as usize].max(1e-9);

    // PRONOSTIA bearings: 13 balls, published orders for the NSK 6804-like geometry
    let watch_order = 3.05; // BPFO order per shaft rev (informed baseline)
    let pc = ProcessConfig {
        f_nominal_hz: rpm / 60.0,
        speed_tol_rel: 0.06,
        watch_order,
        with_zstd: true,
    };

    let mut series = Vec::new();
    for (i, p) in files.iter().enumerate() {
        let xf = bearing_helix_research::io::read_femto_acc(p, channel).expect("read");
        let x: Vec<i16> =
            xf.iter().map(|v| (v * scale).round().clamp(-32768.0, 32767.0) as i16).collect();
        let t_h = i as f64 * 10.0 / 3600.0; // one snapshot / 10 s
        series.push(process_snapshot(t_h, &x, sr, &pc));
        if i % 200 == 0 {
            eprintln!("  {i}/{}", files.len());
        }
    }

    let t_end = series.last().unwrap().t_h;
    println!("\n== FEMTO {dir:?} — run ends at {t_end:.2} h ==");
    for a in evaluate_alarms(&series, &AlarmRule::default(), Some(t_end)) {
        let informed = if a.informed { "  [knows the fault order]" } else { "" };
        match a.t_alarm_h {
            Some(t) => println!("   {:<28} alarm {t:7.2} h   lead-to-end {:6.2} h{informed}",
                a.name, t_end - t),
            None => println!("   {:<28} —{informed}", a.name),
        }
    }
}
