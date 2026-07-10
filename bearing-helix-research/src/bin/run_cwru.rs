//! CWRU seeded-fault corpus: not run-to-failure — each .mat is one condition.
//! The useful check is condition separation: healthy files should sit at the
//! byte-rate floor, faulted files above it, ranked by severity.
//!
//!     cargo run --release --bin run_cwru -- <file.mat>... [--rpm 1772] [--sr 12000]

use bearing_helix_research::life::{process_snapshot, ProcessConfig};
use bearing_helix_research::synth::SKF_6205;
use std::path::PathBuf;

fn main() {
    let mut rpm = 1772.0f64;
    let mut sr = 12000.0f64;
    let mut files: Vec<PathBuf> = Vec::new();
    let mut args = std::env::args().skip(1).peekable();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--rpm" => rpm = args.next().unwrap().parse().unwrap(),
            "--sr" => sr = args.next().unwrap().parse().unwrap(),
            _ => files.push(PathBuf::from(a)),
        }
    }
    assert!(!files.is_empty(), "usage: run_cwru <file.mat>... [--rpm 1772] [--sr 12000]");

    let pc = ProcessConfig {
        f_nominal_hz: rpm / 60.0,
        speed_tol_rel: 0.05,
        watch_order: SKF_6205.bpfi_ord, // default watch; override per experiment
        with_zstd: true,
    };

    println!("{:<28} {:>9} {:>9} {:>9} {:>8} {:>9}", "file", "bits_ll", "bits_bd", "zstd", "kurt", "env_line");
    for p in &files {
        let xf = bearing_helix_research::io::read_cwru(p, "DE_time").expect("DE_time");
        let peak = xf.iter().fold(0.0f64, |a, v| a.max(v.abs())).max(1e-9);
        let scale = 0.95 * 32767.0 / peak;
        let x: Vec<i16> =
            xf.iter().map(|v| (v * scale).round().clamp(-32768.0, 32767.0) as i16).collect();
        // one metrics row per file; a second's worth per segment keeps speed refinement local
        let m = process_snapshot(0.0, &x, sr, &pc);
        println!(
            "{:<28} {:>9.2} {:>9.2} {:>9.2} {:>8.2} {:>9.1}",
            p.file_name().unwrap().to_string_lossy(),
            m.bits_ll,
            m.bits_bd,
            m.bits_zstd,
            m.kurtosis,
            m.env_line_snr
        );
    }
}
