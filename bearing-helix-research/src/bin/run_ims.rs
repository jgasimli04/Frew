//! NASA IMS run-to-failure: point this at a test directory of timestamped
//! ASCII snapshot files (bench/fetch_data.sh).
//!
//!     cargo run --release --bin run_ims -- <dir> [channel=0] [rpm=2000] [sr=20480]
//!
//! Data are floats, so snapshots are scaled to i16 by the corpus-wide 99.9th
//! percentile (printed). Alarm table + CSV/NPZ land next to bench_out/.

use bearing_helix_research::indicators::AlarmRule;
use bearing_helix_research::life::{evaluate_alarms, process_snapshot, ProcessConfig};
use bearing_helix_research::synth::ZA_2115;
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("usage: run_ims <dir> [channel] [rpm] [sr]"));
    let channel: usize = args.next().map(|v| v.parse().unwrap()).unwrap_or(0);
    let rpm: f64 = args.next().map(|v| v.parse().unwrap()).unwrap_or(2000.0);
    let sr: f64 = args.next().map(|v| v.parse().unwrap()).unwrap_or(20480.0);

    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("data dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file() && !p.file_name().unwrap().to_string_lossy().starts_with('.'))
        .collect();
    files.sort(); // IMS names are timestamps: lexical == chronological
    assert!(!files.is_empty(), "no snapshot files in {dir:?}");
    eprintln!("{} snapshots, channel {channel}, {rpm} rpm, {sr} Hz", files.len());

    // pass 1: scale (99.9th percentile of |x| over a subsample of files)
    let mut mags: Vec<f64> = Vec::new();
    for p in files.iter().step_by((files.len() / 40).max(1)) {
        let x = bearing_helix_research::io::read_ims(p, channel).expect("read");
        mags.extend(x.iter().map(|v| v.abs()));
    }
    mags.sort_by(|a, b| a.total_cmp(b));
    let scale = 0.95 * 32767.0 / mags[(mags.len() as f64 * 0.999) as usize].max(1e-9);
    eprintln!("i16 scale: {scale:.1} counts per unit");

    let pc = ProcessConfig {
        f_nominal_hz: rpm / 60.0,
        speed_tol_rel: 0.05,
        watch_order: ZA_2115.bpfo_ord, // the informed baseline watches BPFO
        with_zstd: true,
    };
    let mut series = Vec::new();
    for (i, p) in files.iter().enumerate() {
        let xf = bearing_helix_research::io::read_ims(p, channel).expect("read");
        let x: Vec<i16> =
            xf.iter().map(|v| (v * scale).round().clamp(-32768.0, 32767.0) as i16).collect();
        let t_h = i as f64 * (10.0 / 60.0); // IMS cadence: one snapshot / 10 min
        series.push(process_snapshot(t_h, &x, sr, &pc));
        if i % 100 == 0 {
            eprintln!("  {i}/{} t={t_h:.1} h", files.len());
        }
    }

    let t_end = series.last().unwrap().t_h;
    println!("\n== IMS {dir:?} — run ends at {t_end:.1} h (failure at/near end of test) ==");
    for a in evaluate_alarms(&series, &AlarmRule::default(), Some(t_end)) {
        let informed = if a.informed { "  [knows the fault order]" } else { "" };
        match a.t_alarm_h {
            Some(t) => println!("   {:<28} alarm {t:7.2} h   lead-to-end {:6.2} h{informed}",
                a.name, t_end - t),
            None => println!("   {:<28} —{informed}", a.name),
        }
    }

    let out = PathBuf::from("bench_out");
    std::fs::create_dir_all(&out).unwrap();
    let cols: Vec<(&str, Vec<f64>)> = vec![
        ("t_h", series.iter().map(|m| m.t_h).collect()),
        ("bits_bd", series.iter().map(|m| m.bits_bd).collect()),
        ("bits_ll", series.iter().map(|m| m.bits_ll).collect()),
        ("bits_zstd", series.iter().map(|m| m.bits_zstd).collect()),
        ("rms_fs", series.iter().map(|m| m.rms_fs).collect()),
        ("kurtosis", series.iter().map(|m| m.kurtosis).collect()),
        ("env_line", series.iter().map(|m| m.env_line_snr).collect()),
    ];
    let borrowed: Vec<(&str, &[f64])> = cols.iter().map(|(n, v)| (*n, v.as_slice())).collect();
    bearing_helix_research::io::write_csv(&out.join("ims.csv"), &borrowed).unwrap();
    bearing_helix_research::io::write_npz(&out.join("ims.npz"), &borrowed).unwrap();
    println!("\nseries written to bench_out/ims.csv|npz");
}
