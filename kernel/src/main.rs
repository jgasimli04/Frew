//! Demo 1 driver: WAV in → calibrate → stream through the kernel → `ticks.csv`
//! plus the headline numbers (work reduction at bounded reconstruction error).
//!
//! Usage:
//!   cargo run --release -- <wav> --bpm <n> [--eps <ε_h>] [--b <beats>] [--r0 <r>] [--out <csv>]
//!
//! `--eps` is the one knob (climb energy per tick). If omitted it defaults to a
//! multiple of the calibrated mean ‖F‖ so the demo is non-degenerate, and the
//! value used is printed.

use beehive_kernel::{calibrate, read_wav_mono, recon_error, run, Params};
use std::io::Write;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cfg = match parse_args(&args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}\n\nusage: {} <wav> --bpm <n> [--eps <ε_h>] [--b <beats>] [--r0 <r>] [--out <csv>]", args.first().map(|s| s.as_str()).unwrap_or("kernel"));
            std::process::exit(2);
        }
    };

    let (samples, sr) = match read_wav_mono(&cfg.wav) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    // Build params; eps_h is filled after calibration if the user did not set it.
    let mut p = Params::reference(sr, cfg.bpm, cfg.eps.unwrap_or(0.0));
    if let Some(b) = cfg.b {
        p.b = b;
    }
    if let Some(r0) = cfg.r0 {
        p.r0 = r0;
    }

    let m = p.num_frames(samples.len());
    if m == 0 {
        eprintln!("error: signal shorter than one window ({} samples < {})", samples.len(), p.n_fft);
        std::process::exit(1);
    }

    let cal = calibrate(&samples, &p);
    let eps_used = match cfg.eps {
        Some(e) => e,
        None => {
            // 5×mean ‖F‖ → ~80% fewer ticks; clearly material, error still bounded.
            let e = 5.0 * cal.mean_fmag;
            p.eps_h = e;
            e
        }
    };
    p.eps_h = eps_used;

    let out = run(&samples, &p, &cal);
    let n = out.ticks.len();
    let err = recon_error(&out, &p);

    if let Err(e) = write_ticks(&cfg.out, &out) {
        eprintln!("error writing {}: {e}", cfg.out);
        std::process::exit(1);
    }

    // Adaptive-step distribution + worst-frame ‖F‖ → the stated closed-form tolerances.
    let mut steps: Vec<usize> = out.ticks.iter().skip(1).map(|t| t.step_frames).collect();
    steps.sort_unstable();
    let (min_s, med_s) = if steps.is_empty() {
        (0, 0)
    } else {
        (steps[0], steps[steps.len() / 2])
    };
    let max_fmag = out.frames.iter().map(|f| f.f_norm).fold(0.0_f64, f64::max);
    let dh_tol = eps_used + max_fmag; // proven: segment rise < ε_h+max‖F‖ ⇒ chord error ≤ that
    let xy_tol = p.r0 * (1.0 - (err.max_dalpha / 2.0).cos()); // sagitta of the widest tick arc

    let dur = samples.len() as f64 / sr as f64;
    println!("beehive-kernel · adaptive-time-step demo 1");
    println!("  input            : {}", cfg.wav);
    println!("  sample rate      : {sr} Hz   duration {dur:.2} s   ({} samples)", samples.len());
    println!("  analysis         : n_fft {} · hop {} · B {}", p.n_fft, p.hop, p.b);
    println!("  tempo            : bpm {:.2}   ω/frame {:.6} rad", p.bpm, p.omega_n());
    println!("  calibration      : energy_thresh {:.4}   s_a {:.6}   s_i {:.6}", cal.energy_thresh, cal.s_a, cal.s_i);
    println!("  climb            : h_total {:.4}   mean ‖F‖ {:.6}   max ‖F‖ {:.6}", cal.h_total, cal.mean_fmag, max_fmag);
    println!("  knob             : ε_h {eps_used:.6}{}", if cfg.eps.is_none() { "  (auto = 5·mean‖F‖)" } else { "" });
    println!();
    println!("  total frames   M : {m}");
    println!("  adaptive ticks N : {n}");
    println!("  representation   : {:.1}% fewer emitted ticks   (1 − N/M)", 100.0 * (1.0 - n as f64 / m as f64));
    println!("                     (the FFT still runs every frame; compute reuse is Phase 4, a non-goal here)");
    println!("  step (frames)    : min {min_s}  median {med_s}  max {}  ← equal-energy, content-adaptive", err.max_step_frames);
    println!();
    println!("  reconstruction error (adaptive helix vs full fixed-step helix):");
    println!("    max |Δh|       : {:.6}  ≤  ε_h+max‖F‖ = {dh_tol:.6}   ({:.3}% of h_total)", err.max_dh, 100.0 * err.max_dh / cal.h_total.max(1e-12));
    println!("    max XY error   : {:.6}  ≤  r0·(1−cos(Δα/2)) = {xy_tol:.6}", err.max_xy);
    println!("    widest arc     : {} frames  (Δα {:.4} rad)", err.max_step_frames, err.max_dalpha);
    println!();
    println!("  ε_h sweep — the knob ↔ ticks ↔ error tradeoff:");
    println!("    {:>10}  {:>6}  {:>10}  {:>10}  {:>10}", "ε_h", "N", "reduction", "max|Δh|", "maxXY");
    for mult in [2.0_f64, 5.0, 10.0, 20.0] {
        let mut ps = p;
        ps.eps_h = mult * cal.mean_fmag;
        let o = run(&samples, &ps, &cal);
        let e = recon_error(&o, &ps);
        println!(
            "    {:>10.4}  {:>6}  {:>9.1}%  {:>10.4}  {:>10.4}",
            ps.eps_h,
            o.ticks.len(),
            100.0 * (1.0 - o.ticks.len() as f64 / m as f64),
            e.max_dh,
            e.max_xy
        );
    }
    println!();
    println!("  wrote {} ticks → {}", n, cfg.out);
}

struct Config {
    wav: String,
    bpm: f64,
    eps: Option<f64>,
    b: Option<f64>,
    r0: Option<f64>,
    out: String,
}

fn parse_args(args: &[String]) -> Result<Config, String> {
    let mut wav: Option<String> = None;
    let mut bpm: Option<f64> = None;
    let mut eps: Option<f64> = None;
    let mut b: Option<f64> = None;
    let mut r0: Option<f64> = None;
    let mut out = "ticks.csv".to_string();

    let mut i = 1;
    while i < args.len() {
        let a = &args[i];
        let mut take = |name: &str| -> Result<String, String> {
            i += 1;
            args.get(i).cloned().ok_or_else(|| format!("{name} needs a value"))
        };
        match a.as_str() {
            "--bpm" => bpm = Some(take("--bpm")?.parse().map_err(|_| "--bpm not a number")?),
            "--eps" => eps = Some(take("--eps")?.parse().map_err(|_| "--eps not a number")?),
            "--b" | "--B" => b = Some(take("--b")?.parse().map_err(|_| "--b not a number")?),
            "--r0" => r0 = Some(take("--r0")?.parse().map_err(|_| "--r0 not a number")?),
            "--out" => out = take("--out")?,
            s if s.starts_with("--") => return Err(format!("unknown flag {s}")),
            s => {
                if wav.is_some() {
                    return Err(format!("unexpected argument {s}"));
                }
                wav = Some(s.to_string());
            }
        }
        i += 1;
    }

    Ok(Config {
        wav: wav.ok_or("missing <wav> argument")?,
        bpm: bpm.ok_or("missing --bpm")?,
        eps,
        b,
        r0,
        out,
    })
}

fn write_ticks(path: &str, out: &beehive_kernel::RunOutput) -> std::io::Result<()> {
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    writeln!(f, "n,t_seconds,alpha,x,y,h,f_norm,step_frames")?;
    for t in &out.ticks {
        writeln!(
            f,
            "{},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{}",
            t.n, t.t_seconds, t.alpha, t.x, t.y, t.h, t.f_norm, t.step_frames
        )?;
    }
    Ok(())
}
