//! Acceptance tests — numbers, not vibes.
//!
//! 1. A, I, h from the Rust frame pass match `beehive/encode.py` within 1e-3
//!    (relative-L2, robust where I crosses zero).
//! 2. N < M materially on the clip, with bounded reconstruction error.
//! (3 — `step` is allocation-free — lives in `tests/alloc.rs`, its own binary so
//!  the counting global allocator instruments only that test.)

use beehive_kernel::{calibrate, debug_spectrum, read_wav_mono, recon_error, run, Params};
use std::collections::HashMap;

fn wav_path() -> String {
    format!(
        "{}/../recon/506206_Night_(Original Mix)/506206_Night_(Original Mix)_ORIGINAL_75s.wav",
        env!("CARGO_MANIFEST_DIR")
    )
}
fn fixture(name: &str) -> String {
    format!("{}/tests/fixtures/{}", env!("CARGO_MANIFEST_DIR"), name)
}

/// relative-L2: ‖a − b‖₂ / ‖b‖₂.
fn rel_l2(a: &[f64], b: &[f64]) -> f64 {
    assert_eq!(a.len(), b.len(), "length mismatch");
    let mut num = 0.0;
    let mut den = 0.0;
    for k in 0..a.len() {
        let d = a[k] - b[k];
        num += d * d;
        den += b[k] * b[k];
    }
    (num / den.max(1e-300)).sqrt()
}

struct Reference {
    a: Vec<f64>,
    i: Vec<f64>,
    f_mag: Vec<f64>,
    h: Vec<f64>,
}

fn load_reference_frames() -> Reference {
    let txt = std::fs::read_to_string(fixture("reference_frames.csv")).unwrap();
    let mut a = Vec::new();
    let mut i = Vec::new();
    let mut f_mag = Vec::new();
    let mut h = Vec::new();
    for line in txt.lines().skip(1) {
        if line.is_empty() {
            continue;
        }
        let c: Vec<&str> = line.split(',').collect();
        // k,A,I,dA,dI,F_mag,h
        a.push(c[1].parse().unwrap());
        i.push(c[2].parse().unwrap());
        f_mag.push(c[5].parse().unwrap());
        h.push(c[6].parse().unwrap());
    }
    Reference { a, i, f_mag, h }
}

fn load_meta() -> HashMap<String, f64> {
    let txt = std::fs::read_to_string(fixture("reference_meta.txt")).unwrap();
    let mut m = HashMap::new();
    for line in txt.lines() {
        if let Some((k, v)) = line.split_once('=') {
            if let Ok(x) = v.parse::<f64>() {
                m.insert(k.to_string(), x);
            }
        }
    }
    m
}

fn ref_params() -> Params {
    // bpm only sets alpha/x/y (not A/I/h); 120 matches the reference dump.
    Params::reference(44100, 120.0, 5.0)
}

#[test]
fn decode_matches_soundfile() {
    let (samples, sr) = read_wav_mono(&wav_path()).unwrap();
    assert_eq!(sr, 44100);
    let txt = std::fs::read_to_string(fixture("reference_decode.csv")).unwrap();
    let mut max_abs = 0.0f64;
    for line in txt.lines().skip(1) {
        if line.is_empty() {
            continue;
        }
        let c: Vec<&str> = line.split(',').collect();
        let idx: usize = c[0].parse().unwrap();
        let want: f64 = c[1].parse().unwrap();
        let got = samples[idx] as f64;
        max_abs = max_abs.max((got - want).abs());
    }
    eprintln!("decode: max abs sample error = {max_abs:.3e}");
    assert!(max_abs < 1e-6, "decode mismatch vs soundfile: {max_abs:e}");
}

#[test]
fn fft_matches_numpy_rfft() {
    let (samples, _) = read_wav_mono(&wav_path()).unwrap();
    let p = ref_params();
    let spec = debug_spectrum(&p, &samples[0..p.n_fft]);
    let txt = std::fs::read_to_string(fixture("reference_mag0.csv")).unwrap();
    let mut want = Vec::new();
    for line in txt.lines().skip(1) {
        if line.is_empty() {
            continue;
        }
        let c: Vec<&str> = line.split(',').collect();
        want.push(c[1].parse::<f64>().unwrap());
    }
    let rel = rel_l2(&spec, &want);
    eprintln!("fft frame-0 spectrum: relative-L2 = {rel:.3e}");
    assert!(rel < 1e-4, "rustfft vs numpy rfft (frame 0): {rel:e}");
}

#[test]
fn calibration_matches_reference() {
    let (samples, _sr) = read_wav_mono(&wav_path()).unwrap();
    let p = ref_params();
    let cal = calibrate(&samples, &p);
    let meta = load_meta();
    eprintln!(
        "calibration: s_a {} (ref {})  s_i {} (ref {})  M {} (ref {})",
        cal.s_a, meta["s_a"], cal.s_i, meta["s_i"], cal.m, meta["n_frames"]
    );
    assert_eq!(cal.m as f64, meta["n_frames"]);
    // 6-figure agreement; the residual is numpy's pairwise sum vs our sequential
    // sum over 1719 f64s (the task bar, acceptance #1, is met at ~1e-8 already).
    assert!((cal.s_a - meta["s_a"]).abs() / meta["s_a"] < 1e-6, "s_a");
    assert!((cal.s_i - meta["s_i"]).abs() / meta["s_i"] < 1e-6, "s_i");
    assert!((cal.h_total - meta["h_total"]).abs() / meta["h_total"] < 1e-6, "h_total");
    assert!((cal.mean_fmag - meta["mean_fmag"]).abs() / meta["mean_fmag"] < 1e-6, "mean_fmag");
}

#[test]
fn a_i_h_match_encode_py() {
    let (samples, _) = read_wav_mono(&wav_path()).unwrap();
    let p = ref_params();
    let cal = calibrate(&samples, &p);
    let out = run(&samples, &p, &cal);

    let r = load_reference_frames();
    assert_eq!(out.frames.len(), r.a.len(), "frame count");

    let mut a = Vec::with_capacity(out.frames.len());
    let mut i = Vec::with_capacity(out.frames.len());
    let mut f = Vec::with_capacity(out.frames.len());
    let mut h = Vec::with_capacity(out.frames.len());
    for (k, fs) in out.frames.iter().enumerate() {
        assert_eq!(fs.n, k, "frame order");
        a.push(fs.a);
        i.push(fs.i);
        f.push(fs.f_norm);
        h.push(fs.h);
    }

    let ra = rel_l2(&a, &r.a);
    let ri = rel_l2(&i, &r.i);
    let rf = rel_l2(&f, &r.f_mag);
    let rh = rel_l2(&h, &r.h);
    eprintln!("A: {ra:.3e}   I: {ri:.3e}   ‖F‖: {rf:.3e}   h: {rh:.3e}  (relative-L2)");

    assert!(ra < 1e-3, "A relative-L2 {ra:e}");
    assert!(ri < 1e-3, "I relative-L2 {ri:e}");
    assert!(rf < 1e-3, "‖F‖ relative-L2 {rf:e}");
    assert!(rh < 1e-3, "h relative-L2 {rh:e}");
}

#[test]
fn work_reduction_and_bounded_recon() {
    let (samples, _) = read_wav_mono(&wav_path()).unwrap();
    let mut p = ref_params();
    let cal = calibrate(&samples, &p);
    // The knob: 5×mean ‖F‖ — the demo default.
    p.eps_h = 5.0 * cal.mean_fmag;

    let out = run(&samples, &p, &cal);
    let m = p.num_frames(samples.len());
    let n = out.ticks.len();
    let err = recon_error(&out, &p);
    let reduction = 1.0 - n as f64 / m as f64;

    // The adaptive step distribution (skip the frame-0 anchor's 0-length step).
    let mut steps: Vec<usize> = out.ticks.iter().skip(1).map(|t| t.step_frames).collect();
    steps.sort_unstable();
    let (min_s, med_s, max_s) = (steps[0], steps[steps.len() / 2], *steps.last().unwrap());
    let max_fmag = out.frames.iter().map(|f| f.f_norm).fold(0.0_f64, f64::max);

    // Closed-form tolerances, parameterized by the knob ε_h:
    //   climb : max|Δh| ≤ ε_h + max‖F‖   (carry remainder ∈ [0,‖F‖) ⇒ segment rise < ε_h+max‖F‖,
    //           and a monotone curve deviates from its chord by ≤ its rise)
    //   xy    : ≤ r0·(1 − cos(Δα_max/2)) (chord/sagitta of the widest tick arc)
    let dh_tol = p.eps_h + max_fmag;
    let xy_tol = p.r0 * (1.0 - (err.max_dalpha / 2.0).cos());
    eprintln!(
        "M {m}  N {n}  reduction {:.1}%  steps[min/med/max] {min_s}/{med_s}/{max_s}",
        100.0 * reduction
    );
    eprintln!(
        "  max|Δh| {:.4} ≤ ε_h+max‖F‖ {:.4}  ({:.3}% of h_total)   maxXY {:.4} ≤ sagitta {:.4}",
        err.max_dh, dh_tol, 100.0 * err.max_dh / cal.h_total, err.max_xy, xy_tol
    );

    // (2a) materially fewer ticks than frames.
    assert!(n < m, "N must be < M");
    assert!(reduction > 0.5, "work reduction not material: {:.3}", reduction);
    // (2b) the steps actually adapt to content — not a fixed-rate downsampler.
    assert!(min_s < max_s, "step length must vary with content");
    assert!(max_s >= 2 * min_s.max(1), "static passages should give clearly longer steps");
    // (2c) reconstruction error under the stated closed-form tolerances.
    assert!(err.max_dh <= dh_tol + 1e-9, "max|Δh| {} exceeds ε_h+max‖F‖ {}", err.max_dh, dh_tol);
    assert!(err.max_xy <= xy_tol + 1e-9, "maxXY {} exceeds sagitta {}", err.max_xy, xy_tol);
    // ticks bracket the whole grid (anchors at frame 0 and M-1).
    assert_eq!(out.ticks.first().unwrap().n, 0);
    assert_eq!(out.ticks.last().unwrap().n, m - 1);
}
