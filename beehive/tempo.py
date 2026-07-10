"""Tempo estimation: turn a real signal into bpm, hence omega.

omega = 2*pi*bpm / (60*B) is undefined without a tempo, and a real file does not
hand you one. We estimate it ourselves (not via librosa -- beating librosa is the
point) with the textbook pipeline:

  1. spectral flux: half-wave-rectified sum of positive magnitude changes between
     frames -> an onset-strength envelope (peaks where new energy appears);
  2. autocorrelate the envelope; a periodic beat shows up as a peak at the lag of
     one beat;
  3. convert the best lag (within a plausible bpm band) back to bpm.

This is a deliberately light estimator, not a beat tracker; bpm is reported as an
estimate and can be overridden when encoding.
"""

import numpy as np

EPS = 1e-10


def onset_envelope(mag):
    """Spectral-flux onset strength, one value per frame."""
    diff = np.diff(mag.astype(np.float64), axis=0)            # (n_frames-1, n_bins)
    flux = np.maximum(diff, 0.0).sum(axis=1)                  # half-wave rectify
    flux = np.concatenate([[0.0], flux])                     # align to n_frames
    flux -= flux.mean()
    return flux


def estimate_bpm(mag, sr, hop, bpm_min=60.0, bpm_max=200.0):
    """Estimate tempo in bpm from the magnitude spectrogram.

    Returns (bpm, confidence) where confidence is the normalised autocorrelation
    height at the chosen lag (0..1-ish), a rough trust signal.
    """
    env = onset_envelope(mag)
    if env.std() < EPS:
        return float("nan"), 0.0

    ac = np.correlate(env, env, mode="full")[len(env) - 1:]   # autocorr, lags >= 0
    ac[0] = 0.0                                               # ignore zero lag
    fps = sr / hop                                            # frames per second
    lag_min = max(1, int(round(60.0 * fps / bpm_max)))
    lag_max = min(len(ac) - 1, int(round(60.0 * fps / bpm_min)))
    if lag_max <= lag_min:
        return float("nan"), 0.0

    band = ac[lag_min:lag_max + 1]
    best = lag_min + int(np.argmax(band))
    bpm = 60.0 * fps / best
    conf = float(ac[best] / (ac.max() + EPS))
    return float(bpm), conf
