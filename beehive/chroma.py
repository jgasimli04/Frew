"""Chroma projection: collapse a harmonic spectrum onto the 12 pitch classes.

Octave equivalence folds frequencies onto a 12-point ring. The *soft* version
uses a periodic Gaussian kernel so the bin assignment is differentiable -- gradients
flow back into any learnable frequency (needed wherever f0/pitch is trained). The
*hard* version (nearest bin) is for visualisation only; it has zero gradient w.r.t.
frequency and breaks training of anything upstream of the bin assignment.

A resonance-shaped harmonic series does not collapse onto a single point: only
power-of-2 harmonics (2f0, 4f0, ...) land on the fundamental's pitch class, while
3f0, 5f0, ... land on other classes. The result is a *distribution* across the 12
bins -- a single point in the 12-dim chroma vector space, which the model treats as
timbral identity.
"""

import torch

N_BINS = 12


def _pitch_class(freqs, f_ref, n_bins):
    # Continuous position on the n_bins-per-octave scale (semitones above f_ref).
    return n_bins * torch.log2(freqs / f_ref)


def soft_chroma_projection(freqs, amps, sigma=0.5, f_ref=440.0, n_bins=N_BINS):
    """Differentiable soft chroma vector.

    For each frequency, distribute its amplitude across the 12 pitch classes by a
    periodic Gaussian weight (circular distance on the mod-12 ring), normalise that
    per-frequency distribution to sum to 1, scale by amplitude, then accumulate.

        midi_like   = 12 * log2(f / f_ref)
        weight[k]   = exp( -circ_dist(midi_like, k)^2 / (2 sigma^2) )
        chroma[k]   = sum_i amp_i * normalize(weight_i)[k]

    Parameters
    ----------
    freqs : tensor (N,) Hz, > 0.
    amps : tensor (N,) amplitudes.
    sigma : kernel width in semitones (~0.5 worked in testing; sweep it).
    f_ref : reference frequency for pitch class 0.

    Returns
    -------
    tensor (n_bins,) chroma vector.
    """
    midi_like = _pitch_class(freqs, f_ref, n_bins)               # (N,)
    k = torch.arange(n_bins, dtype=freqs.dtype, device=freqs.device)  # (12,)
    diff = midi_like.unsqueeze(-1) - k                           # (N, 12)
    raw = torch.remainder(diff, n_bins)                          # (N,12) in [0, 12)
    circ = torch.minimum(raw, n_bins - raw)                      # circular distance [0, 6]
    w = torch.exp(-(circ**2) / (2.0 * sigma**2))                 # (N, 12)
    w = w / w.sum(dim=-1, keepdim=True).clamp_min(1e-12)         # per-freq distribution
    return (amps.unsqueeze(-1) * w).sum(dim=0)                   # (12,)


def hard_chroma_projection(freqs, amps, f_ref=440.0, n_bins=N_BINS):
    """Nearest-bin chroma (visualisation only -- not differentiable in freqs)."""
    midi_like = _pitch_class(freqs, f_ref, n_bins)
    bins = torch.round(midi_like) % n_bins
    chroma = torch.zeros(n_bins, dtype=freqs.dtype, device=freqs.device)
    chroma.index_add_(0, bins.long(), amps)
    return chroma
