"""geometry_to_audio: resynthesize a waveform from the stored helix geometry.

This is the decoder the format was missing. The previous `.bee` marked the
geometry `reconstructs_audio=False` and shipped a FLAC payload *alongside* it.
Here the geometry IS the source of sound. It inverts the three stored per-frame
quantities directly:

  A[n]        loudness (dB)            -> per-frame RMS (overall gain)
  I[n]        spectral centroid (st)   -> brightness (octave tilt of the partials)
  chroma[n]   12-d pitch-class energy  -> which pitch classes sound

Method: an additive oscillator bank. Partials sit at every pitch-class frequency
across the audible octaves, f = f_ref * 2**(o + k/12). For each frame the partial
amplitudes start from chroma (folded back out across octaves), are tilted so the
re-synthesized spectral centroid matches I[n], then scaled so the frame RMS
matches A[n]. Amplitudes are interpolated between frame centers and summed with
continuous-phase sinusoids.

Honest ceiling (state it, do not hide it): A/I/chroma carry no phase, no fine
spectrum, no transients, and (mono analysis) no stereo. So this tracks loudness,
brightness, and harmony but is a vocoder-style *sketch* of the source, not a
faithful copy. It measures the geometry as defined today -- not the ceiling of a
neural decoder conditioned on it, which is the separate, larger build.
"""

import numpy as np

EPS = 1e-12


def _partial_frequencies(f_ref, sr, o_lo=-5, o_hi=6):
    """Every pitch-class frequency across the audible octaves.

    Returns (freqs, pitch_class, octave) flat arrays for partials kept inside
    (20 Hz, 0.95*Nyquist). freq = f_ref * 2**(octave + pitch_class/12).
    """
    o = np.arange(o_lo, o_hi + 1)
    k = np.arange(12)
    freqs = (f_ref * 2.0 ** (o[:, None] + k[None, :] / 12.0)).ravel()
    pc = np.repeat(k[None, :], len(o), axis=0).ravel()
    octv = np.repeat(o[:, None], 12, axis=1).ravel().astype(np.float64)
    keep = (freqs > 20.0) & (freqs < 0.95 * sr / 2.0)
    return freqs[keep], pc[keep], octv[keep]


def _match_centroid_tilt(chroma_exp, freqs, octv, target_hz, iters=40):
    """Per-frame octave tilt beta s.t. centroid(a) == target, a = chroma*2**(beta*octv).

    Vectorized bisection over all frames at once. The synthesized centroid is
    monotonic increasing in beta (more weight on high octaves -> brighter), so
    bisection converges; targets outside the partial range pin beta at a bound.
    chroma_exp: (F, P), target_hz: (F,). Returns beta: (F,).
    """
    F = chroma_exp.shape[0]
    lo = np.full(F, -6.0)
    hi = np.full(F, 6.0)
    f = freqs[None, :]
    o = octv[None, :]
    for _ in range(iters):
        beta = 0.5 * (lo + hi)
        a = chroma_exp * np.exp2(beta[:, None] * o)
        cen = (a * f).sum(1) / (a.sum(1) + EPS)
        too_low = cen < target_hz
        lo = np.where(too_low, beta, lo)
        hi = np.where(too_low, hi, beta)
    return 0.5 * (lo + hi)


def geometry_to_audio(record, *, start_s=0.0, dur_s=None):
    """Decode a HelixRecord's geometry (A, I, chroma + meta) back to a waveform.

    start_s/dur_s render just a span (cheaper to audition); default = whole song.
    Returns (waveform float32, sr).
    """
    meta = record.meta
    sr = int(meta["sr"])
    hop = int(meta["hop"])
    win = int(meta["win"])
    f_ref = float(meta["f_ref"])
    floor_db = float(meta["floor_db"])
    n_samples = int(meta["n_samples"])

    A = np.asarray(record.A, np.float64)
    I = np.asarray(record.I, np.float64)
    chroma = np.asarray(record.chroma, np.float64)

    freqs, pc, octv = _partial_frequencies(f_ref, sr)
    chroma_exp = chroma[:, pc]                                  # (F, P)

    # I[n] (semitones above f_ref) -> target centroid in Hz; set the octave tilt.
    target_hz = f_ref * np.exp2(I / 12.0)
    beta = _match_centroid_tilt(chroma_exp, freqs, octv, target_hz)
    a = chroma_exp * np.exp2(beta[:, None] * octv[None, :])     # (F, P) pre-gain

    # scale each frame so the partial sum's RMS == 10**(A/20); silence -> 0.
    cur_rms = np.sqrt((a ** 2).sum(1) / 2.0) + EPS
    tgt_rms = np.where(A <= floor_db + 1e-6, 0.0, 10.0 ** (A / 20.0))
    a *= (tgt_rms / cur_rms)[:, None]

    # additive synthesis over the requested span, continuous-phase sinusoids.
    s0 = int(start_s * sr)
    s1 = n_samples if dur_s is None else min(n_samples, s0 + int(dur_s * sr))
    t = np.arange(s0, s1) / sr
    center_t = (np.arange(len(A)) * hop + win / 2.0) / sr
    rng = np.random.default_rng(0)
    phase0 = rng.uniform(0.0, 2.0 * np.pi, len(freqs))

    out = np.zeros(t.shape, np.float64)
    for p in range(len(freqs)):
        env = np.interp(t, center_t, a[:, p], left=0.0, right=0.0)
        out += env * np.sin(2.0 * np.pi * freqs[p] * t + phase0[p])
    return out.astype(np.float32), sr
