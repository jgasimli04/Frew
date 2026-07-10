//! Shaft-speed refinement from the vibration signal alone — no tachometer.
//!
//! The fold codec segments the stream into revolutions at *fractional* sample
//! boundaries, so everything downstream lives or dies on ω. Method:
//!
//!  1. coarse: harmonic-consensus peak search on the magnitude spectrum in a
//!     ±tol band around the nominal speed (the 1× imbalance line and its
//!     harmonics are always present on a real machine);
//!  2. fine: single-frequency complex correlations over two half-windows; the
//!     phase advance between them pins the frequency to a small fraction of a
//!     bin (iterated over harmonics 1, 2, 4 — each pass tightens the wrap
//!     ambiguity window for the next);
//!  3. drift: the same fine estimator on the first and last thirds gives a
//!     linear within-snapshot drift term.
//!
//! The acceptance test (`speed_refinement_beats_2e4`) requires relative error
//! < 2e-4 on the synthetic rig with speed wander enabled.

use crate::dsp::{hann, magnitude_spectrum, prev_pow2};
use std::f64::consts::PI;

#[derive(Clone, Copy, Debug)]
pub struct SpeedEstimate {
    /// shaft frequency at the snapshot centre, Hz
    pub f_hz: f64,
    /// linear drift across the snapshot, Hz/s
    pub drift_hz_per_s: f64,
}

/// Hann-windowed complex correlation of `x[off..off+m]` against e^{-i2πft}.
fn tone_corr(x: &[f64], sr: f64, f: f64, off: usize, m: usize) -> (f64, f64) {
    let w = hann(m);
    let (mut re, mut im) = (0.0f64, 0.0f64);
    for k in 0..m {
        let t = (off + k) as f64 / sr;
        let ph = 2.0 * PI * f * t;
        let v = x[off + k] * w[k];
        re += v * ph.cos();
        im -= v * ph.sin();
    }
    (re, im)
}

/// Fine frequency estimate near `f0` using the phase advance of harmonic `k`
/// between two half-windows separated by `d` samples. Returns the implied
/// fundamental and the harmonic's amplitude (for consensus weighting).
fn phase_refine(x: &[f64], sr: f64, f0: f64, k: u32, off: usize, m: usize, d: usize) -> (f64, f64) {
    let fk = f0 * k as f64;
    let (r1, i1) = tone_corr(x, sr, fk, off, m);
    let (r2, i2) = tone_corr(x, sr, fk, off + d, m);
    // phase of c2 * conj(c1)
    let dphi = (i2 * r1 - i1 * r2).atan2(r2 * r1 + i2 * i1);
    let df = dphi / (2.0 * PI * d as f64 / sr); // frequency offset at harmonic k
    let amp = (r1 * r1 + i1 * i1).sqrt().min((r2 * r2 + i2 * i2).sqrt());
    (f0 + df / k as f64, amp)
}

/// Weighted consensus across harmonics. A phase estimate at harmonic k has
/// frequency variance ∝ 1/(k²·amplitude²), so strong low harmonics and weak
/// high ones both contribute what they actually know. Estimates that land
/// outside their own wrap window are discarded.
fn harmonic_consensus(x: &[f64], sr: f64, f0: f64, m: usize, d: usize) -> f64 {
    let (mut num, mut den) = (0.0f64, 0.0f64);
    for k in 1..=5u32 {
        let (fk, amp) = phase_refine(x, sr, f0, k, 0, m, d);
        let wrap = sr / (2.0 * d as f64 * k as f64); // fundamental-domain window
        if (fk - f0).abs() > 0.9 * wrap {
            continue;
        }
        let w = (k * k) as f64 * amp * amp;
        num += w * fk;
        den += w;
    }
    if den > 0.0 {
        num / den
    } else {
        f0
    }
}

/// Refine the shaft speed within ±`tol_rel` of `f_nominal`.
pub fn refine_speed(x: &[f64], sr: f64, f_nominal: f64, tol_rel: f64) -> SpeedEstimate {
    let n = prev_pow2(x.len().min(1 << 15));
    let (mags, df_bin) = magnitude_spectrum(&x[..n], sr);

    // 1. coarse: harmonic consensus over candidate fundamentals on the bin grid
    let lo = ((f_nominal * (1.0 - tol_rel)) / df_bin).floor().max(1.0) as usize;
    let hi = ((f_nominal * (1.0 + tol_rel)) / df_bin).ceil() as usize;
    let mut best = (lo, f64::MIN);
    for b in lo..=hi.min(mags.len() - 1) {
        let mut score = 0.0;
        for k in 1..=4usize {
            let kb = k * b;
            if kb + 1 < mags.len() {
                // small local max absorbs off-grid harmonics
                score += mags[kb - 1].max(mags[kb]).max(mags[kb + 1]) / k as f64;
            }
        }
        if score > best.1 {
            best = (b, score);
        }
    }
    let mut f = best.0 as f64 * df_bin;

    // 2. fine: converge the wrap window at the fundamental, then take the
    // variance-weighted consensus across harmonics 1..5 (twice — the second
    // pass runs with everything inside a tight window).
    let m = n / 2;
    let d = n / 2;
    f = phase_refine(&x[..n], sr, f, 1, 0, m, d).0;
    f = harmonic_consensus(&x[..n], sr, f, m, d);
    f = harmonic_consensus(&x[..n], sr, f, m, d);

    // 3. drift from first/last third, same consensus estimator
    let t3 = n / 3;
    let f_a = harmonic_consensus(&x[..t3 + t3 / 2], sr, f, t3, t3 / 2);
    let off = n - t3 - t3 / 2;
    let f_b = harmonic_consensus(&x[off..n], sr, f, t3, t3 / 2);
    let dt = off as f64 / sr; // separation of the two estimation windows
    let drift = if dt > 0.0 { (f_b - f_a) / dt } else { 0.0 };

    SpeedEstimate { f_hz: f, drift_hz_per_s: drift }
}
