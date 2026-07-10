//! Minimal self-contained DSP: radix-2 FFT, Hann window, band-limited
//! envelope via the analytic signal. No dependencies — the crate's rule is
//! that the format and its instruments are fully inspectable.

use std::f64::consts::PI;

/// In-place radix-2 decimation-in-time FFT. `re.len()` must be a power of two.
pub fn fft_in_place(re: &mut [f64], im: &mut [f64], inverse: bool) {
    let n = re.len();
    assert_eq!(n, im.len());
    assert!(n.is_power_of_two(), "fft length must be a power of two");
    // bit reversal
    let mut j = 0usize;
    for i in 0..n {
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
        let mut m = n >> 1;
        while m >= 1 && j & m != 0 {
            j ^= m;
            m >>= 1;
        }
        j |= m;
    }
    let sign = if inverse { 1.0 } else { -1.0 };
    let mut len = 2;
    while len <= n {
        let ang = sign * 2.0 * PI / len as f64;
        let (wr, wi) = (ang.cos(), ang.sin());
        let mut i = 0;
        while i < n {
            let (mut cr, mut ci) = (1.0f64, 0.0f64);
            for k in 0..len / 2 {
                let (ar, ai) = (re[i + k], im[i + k]);
                let (br, bi) = (re[i + k + len / 2], im[i + k + len / 2]);
                let (tr, ti) = (br * cr - bi * ci, br * ci + bi * cr);
                re[i + k] = ar + tr;
                im[i + k] = ai + ti;
                re[i + k + len / 2] = ar - tr;
                im[i + k + len / 2] = ai - ti;
                let ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
            i += len;
        }
        len <<= 1;
    }
    if inverse {
        let inv = 1.0 / n as f64;
        for v in re.iter_mut() {
            *v *= inv;
        }
        for v in im.iter_mut() {
            *v *= inv;
        }
    }
}

pub fn hann(n: usize) -> Vec<f64> {
    (0..n).map(|i| 0.5 - 0.5 * (2.0 * PI * i as f64 / n as f64).cos()).collect()
}

pub fn prev_pow2(n: usize) -> usize {
    let mut p = 1usize;
    while p * 2 <= n {
        p *= 2;
    }
    p
}

/// Hann-windowed magnitude spectrum of the first `prev_pow2(len)` samples.
/// Returns (magnitudes for bins 0..n/2, bin width in Hz).
pub fn magnitude_spectrum(x: &[f64], sr: f64) -> (Vec<f64>, f64) {
    let n = prev_pow2(x.len());
    let w = hann(n);
    let mut re: Vec<f64> = x[..n].iter().zip(&w).map(|(v, w)| v * w).collect();
    let mut im = vec![0.0; n];
    fft_in_place(&mut re, &mut im, false);
    let mags = (0..n / 2).map(|i| (re[i] * re[i] + im[i] * im[i]).sqrt()).collect();
    (mags, sr / n as f64)
}

/// Band-limited envelope: keep positive-frequency bins in [lo_hz, hi_hz],
/// double them (analytic signal), zero the rest, inverse FFT, magnitude.
/// The classic demodulation step of envelope analysis.
pub fn band_envelope(x: &[f64], sr: f64, lo_hz: f64, hi_hz: f64) -> Vec<f64> {
    let n = prev_pow2(x.len());
    let mut re = x[..n].to_vec();
    let mut im = vec![0.0; n];
    fft_in_place(&mut re, &mut im, false);
    let df = sr / n as f64;
    for i in 0..n {
        let f = if i <= n / 2 { i as f64 * df } else { -1.0 };
        let keep = f >= lo_hz && f <= hi_hz;
        let g = if keep { 2.0 } else { 0.0 }; // analytic: double positives
        re[i] *= g;
        im[i] *= g;
    }
    fft_in_place(&mut re, &mut im, true);
    re.iter().zip(&im).map(|(r, i)| (r * r + i * i).sqrt()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fft_finds_a_pure_tone() {
        let sr = 1024.0;
        let f = 96.0;
        let x: Vec<f64> = (0..1024).map(|i| (2.0 * PI * f * i as f64 / sr).sin()).collect();
        let (mags, df) = magnitude_spectrum(&x, sr);
        let peak = mags.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).unwrap().0;
        assert!((peak as f64 * df - f).abs() < df, "peak at {} Hz", peak as f64 * df);
    }

    #[test]
    fn envelope_recovers_amplitude_modulation() {
        // 3 kHz carrier amplitude-modulated at 40 Hz: the envelope spectrum
        // must show 40 Hz, though the raw spectrum has no 40 Hz line.
        let sr = 16384.0;
        let n = 16384;
        let x: Vec<f64> = (0..n)
            .map(|i| {
                let t = i as f64 / sr;
                (1.0 + 0.8 * (2.0 * PI * 40.0 * t).cos()) * (2.0 * PI * 3000.0 * t).sin()
            })
            .collect();
        let env = band_envelope(&x, sr, 2000.0, 4000.0);
        let m = env.iter().sum::<f64>() / env.len() as f64;
        let centred: Vec<f64> = env.iter().map(|v| v - m).collect();
        let (mags, df) = magnitude_spectrum(&centred, sr);
        let peak = mags[1..].iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).unwrap().0 + 1;
        assert!((peak as f64 * df - 40.0).abs() < 2.0 * df);
    }
}
