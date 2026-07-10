//! The baselines the byte rate must beat — and the one shared alarm rule.
//!
//! Standard condition-monitoring indicators, each cited in briefing/PRIOR_ART:
//! RMS and kurtosis (the fault-agnostic workhorses), crest factor, and the
//! envelope-spectrum line at a *known* fault order (the informed baseline —
//! it is told which line to watch, the byte rate is not).
//!
//! Fairness rule: every indicator, including the format's bits/sample, is fed
//! to the SAME alarm rule with the SAME reference window. No per-indicator
//! tuning anywhere.

use crate::dsp::{band_envelope, magnitude_spectrum};

pub fn rms(x: &[f64]) -> f64 {
    (x.iter().map(|v| v * v).sum::<f64>() / x.len().max(1) as f64).sqrt()
}

/// Raw normalised 4th moment, m4/m2² (Gaussian ≈ 3).
pub fn kurtosis(x: &[f64]) -> f64 {
    let n = x.len().max(1) as f64;
    let m = x.iter().sum::<f64>() / n;
    let m2 = x.iter().map(|v| (v - m) * (v - m)).sum::<f64>() / n;
    let m4 = x.iter().map(|v| (v - m).powi(4)).sum::<f64>() / n;
    if m2 == 0.0 {
        0.0
    } else {
        m4 / (m2 * m2)
    }
}

pub fn crest(x: &[f64]) -> f64 {
    let peak = x.iter().fold(0.0f64, |a, v| a.max(v.abs()));
    let r = rms(x);
    if r == 0.0 {
        0.0
    } else {
        peak / r
    }
}

/// Envelope-spectrum line SNR at `order`×shaft. High-frequency band-pass
/// (structural-resonance band, [0.2, 0.6]·Nyquist), analytic envelope, then
/// the envelope spectrum's peak within ±2.5% of the target order, normalised
/// by the spectrum's median — the classic informed detector.
pub fn envelope_line_snr(x: &[f64], sr: f64, f_shaft_hz: f64, order: f64) -> f64 {
    let nyq = sr / 2.0;
    let env = band_envelope(x, sr, 0.2 * nyq, 0.6 * nyq);
    let m = env.iter().sum::<f64>() / env.len() as f64;
    let centred: Vec<f64> = env.iter().map(|v| v - m).collect();
    let (mags, df) = magnitude_spectrum(&centred, sr);

    let f_target = order * f_shaft_hz;
    let lo = ((f_target * 0.975) / df).floor().max(1.0) as usize;
    let hi = (((f_target * 1.025) / df).ceil() as usize).min(mags.len() - 1);
    if lo >= hi {
        return 0.0;
    }
    let peak = mags[lo..=hi].iter().fold(0.0f64, |a, &v| a.max(v));

    let mut sorted: Vec<f64> = mags[1..].to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let median = sorted[sorted.len() / 2].max(1e-12);
    peak / median
}

// ---------------------------------------------------------------------------
// the shared alarm rule
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
pub struct AlarmRule {
    /// threshold: reference mean + k·(reference std)
    pub k_sigma: f64,
    /// consecutive snapshots above threshold required
    pub m_consecutive: usize,
    /// reference window: the first `ref_fraction` of the observed span,
    /// capped at `ref_cap_h` hours
    pub ref_fraction: f64,
    pub ref_cap_h: f64,
}

impl Default for AlarmRule {
    fn default() -> Self {
        AlarmRule { k_sigma: 5.0, m_consecutive: 3, ref_fraction: 0.25, ref_cap_h: 5.0 }
    }
}

/// First alarm time under the shared rule, or None. One-sided (upward):
/// every indicator here rises with damage.
pub fn first_alarm(t_h: &[f64], v: &[f64], rule: &AlarmRule) -> Option<f64> {
    assert_eq!(t_h.len(), v.len());
    if t_h.len() < 4 {
        return None;
    }
    let t_end = *t_h.last().unwrap();
    let t_ref = (rule.ref_fraction * t_end).min(rule.ref_cap_h);
    let reference: Vec<f64> =
        t_h.iter().zip(v).filter(|(t, _)| **t <= t_ref).map(|(_, v)| *v).collect();
    if reference.len() < 4 {
        return None;
    }
    let n = reference.len() as f64;
    let mu = reference.iter().sum::<f64>() / n;
    let sd = (reference.iter().map(|x| (x - mu) * (x - mu)).sum::<f64>() / n).sqrt();
    let thresh = mu + rule.k_sigma * sd.max(1e-12 * mu.abs().max(1e-12));

    let mut streak = 0usize;
    for (i, (&t, &val)) in t_h.iter().zip(v).enumerate() {
        if t <= t_ref {
            continue;
        }
        if val > thresh {
            streak += 1;
            if streak >= rule.m_consecutive {
                return Some(t_h[i + 1 - rule.m_consecutive]);
            }
        } else {
            streak = 0;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lcg(state: &mut u64) -> f64 {
        *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((*state >> 11) as f64 / (1u64 << 53) as f64) - 0.5
    }

    #[test]
    fn kurtosis_of_uniform_noise_and_of_a_sine_are_textbook() {
        let mut s = 42u64;
        let noise: Vec<f64> = (0..200_000).map(|_| lcg(&mut s)).collect();
        let k_noise = kurtosis(&noise); // uniform => 1.8
        assert!((k_noise - 1.8).abs() < 0.05, "uniform kurtosis {k_noise}");
        let sine: Vec<f64> =
            (0..65536).map(|i| (2.0 * std::f64::consts::PI * i as f64 / 64.0).sin()).collect();
        assert!((kurtosis(&sine) - 1.5).abs() < 0.01, "sine kurtosis");
        assert!((rms(&sine) - 1.0 / 2.0f64.sqrt()).abs() < 1e-3, "sine rms A/√2");
    }

    #[test]
    fn alarm_rule_fires_on_a_step_and_stays_silent_on_flat() {
        let t: Vec<f64> = (0..200).map(|i| i as f64 * 0.1).collect(); // 20 h
        let flat: Vec<f64> = (0..200).map(|i| 1.0 + 0.01 * ((i * 7919 % 13) as f64 - 6.0)).collect();
        let rule = AlarmRule::default();
        assert_eq!(first_alarm(&t, &flat, &rule), None, "no alarm on a flat series");

        let mut stepped = flat.clone();
        for v in stepped.iter_mut().skip(150) {
            *v += 1.0; // step at t = 15 h
        }
        let a = first_alarm(&t, &stepped, &rule).expect("must alarm on a step");
        assert!((a - 15.0).abs() < 0.35, "alarm at {a}, expected ~15 h");
    }
}
