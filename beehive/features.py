"""Per-frame features: the state s(n) = (amplitude, interval) and timbral colour.

`n` is the hop/frame index (the first concrete choice for the pluggable slot).
Each frame yields:

  A(n)  -- amplitude, as loudness in dB (the "mostly loudness" axis of the force).
  I(n)  -- interval, the spectral centroid on a log-frequency (semitone) scale,
           so dI/dn is literally "how the pitch spacing is moving" (derivation
           step 5: the force's direction is loudness vs. spacing).
  chroma(n) -- the 12-dim timbral-identity vector, used downstream for colour.

The chroma here is a vectorised numpy mirror of the verified torch
`chroma.soft_chroma_projection`: because the bin frequencies are fixed across
frames, the per-frequency soft assignment collapses to one constant weight matrix
W (bins x 12), and the whole song's chroma is a single matmul mag @ W. A unit
test asserts this matches the torch reference frame-for-frame.
"""

import numpy as np

EPS = 1e-10


def frame_signal(y, win, hop):
    """Split a 1-D signal into overlapping frames (n_frames, win), no padding.

    Frame n covers samples [n*hop, n*hop+win); this fixes the meaning of the
    pluggable index n as the hop/frame number.
    """
    if len(y) < win:
        raise ValueError(f"signal shorter ({len(y)}) than one window ({win})")
    view = np.lib.stride_tricks.sliding_window_view(y, win)   # (len-win+1, win)
    return view[::hop]                                        # (n_frames, win)


def stft_mag(frames, n_fft, window):
    """Magnitude spectrum per frame and the bin centre frequencies."""
    spec = np.fft.rfft(frames * window, n=n_fft, axis=1)
    return np.abs(spec).astype(np.float32)                   # (n_frames, n_bins)


def loudness_db(frames, floor_db=-80.0):
    """A(n): per-frame loudness in dB, floored for silent frames."""
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1) + EPS)
    return np.maximum(20.0 * np.log10(rms + EPS), floor_db).astype(np.float32)


def interval_semitones(mag, freqs, f_ref=440.0, energy_floor_ratio=1e-2):
    """I(n): spectral centroid expressed in semitones above f_ref.

    Centroid = energy-weighted mean frequency; log2 turns it into an interval
    (spacing) scale so equal pitch moves are equal distances.

    Near-silent frames must be energy-gated, not just guarded against zero: a
    frame with a sliver of low-frequency rumble yields a wild centroid (e.g. 7 Hz
    -> -71 semitones), and because ||F|| normalises dI by its own std over the
    track, a few such silence-boundary spikes both dominate ||F|| and suppress
    genuine interval movement everywhere else. So frames whose energy is below
    `energy_floor_ratio` of the track's median frame energy hold the last valid
    interval (no spurious movement across silence); leading silence is f_ref (0).
    """
    m = mag.astype(np.float64)
    total = m.sum(axis=1)
    pos = total[total > 0]
    thresh = energy_floor_ratio * (np.median(pos) if pos.size else 0.0)
    valid = total > thresh

    centroid = np.full(total.shape, f_ref)
    centroid[valid] = (m[valid] * freqs).sum(axis=1) / total[valid]
    inter = 12.0 * np.log2(np.maximum(centroid, EPS) / f_ref)

    # hold-last over gated frames: forward-fill from the most recent valid frame.
    idx = np.where(valid, np.arange(len(valid)), -1)
    fill = np.maximum.accumulate(idx)
    held = np.where(fill >= 0, inter[np.clip(fill, 0, None)], 0.0)
    return held.astype(np.float32)


def chroma_weight_matrix(freqs, sigma=0.5, f_ref=440.0, n_bins=12):
    """Constant (n_bins-summed) soft-assignment matrix W of shape (n_bins, n_freqs).

    Mirrors chroma.soft_chroma_projection: for each frequency, a periodic Gaussian
    over circular distance on the mod-12 ring, normalised to sum to 1 across the 12
    classes. DC / non-positive bins are zeroed (log2 undefined). Because freqs are
    fixed per song, chroma(frame) = W @ mag[frame].
    """
    freqs = np.asarray(freqs, dtype=np.float64)
    valid = freqs > 0.0
    midi = np.zeros_like(freqs)
    midi[valid] = n_bins * np.log2(freqs[valid] / f_ref)         # (n_freqs,)
    k = np.arange(n_bins)                                        # (n_bins,)
    diff = midi[:, None] - k                                     # (n_freqs, n_bins)
    raw = np.mod(diff, n_bins)
    circ = np.minimum(raw, n_bins - raw)                        # circular dist [0,6]
    w = np.exp(-(circ ** 2) / (2.0 * sigma ** 2))              # (n_freqs, n_bins)
    w /= np.clip(w.sum(axis=1, keepdims=True), EPS, None)        # per-freq distribution
    w[~valid] = 0.0
    return w.T.astype(np.float32)                               # (n_bins, n_freqs)


def chroma_from_mag(mag, w_matrix):
    """All-frames chroma in one matmul: (n_frames, n_bins)."""
    return (mag.astype(np.float64) @ w_matrix.T.astype(np.float64)).astype(np.float32)
