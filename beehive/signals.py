"""Synthetic harmonic-series test signals (the proven-to-work starting point
before touching real audio).

A tone with fundamental f0 has partials at i*f0 (i = 1..H); their amplitudes are
the formant envelope sampled at those partials, optionally times a 1/i^rolloff
natural decay. This is the source-filter model made concrete: harmonic comb
(source) times spectral envelope (filter).
"""

import torch

from .formant import formant_envelope


def synth_harmonic_spectrum(f0, centers, widths, gains, n_harmonics=24, rolloff=0.0):
    """Return (freqs, amps) for a formant-shaped harmonic tone.

    Parameters
    ----------
    f0 : scalar tensor, fundamental frequency in Hz.
    centers, widths, gains : tensors (J,), formant parameters.
    n_harmonics : number of partials.
    rolloff : exponent of an optional 1/i^rolloff natural spectral decay.

    Returns
    -------
    freqs : tensor (H,) partial frequencies.
    amps : tensor (H,) partial amplitudes (>= 0).
    """
    i = torch.arange(1, n_harmonics + 1, dtype=f0.dtype, device=f0.device)
    freqs = i * f0
    amps = formant_envelope(freqs, centers, widths, gains)
    if rolloff:
        amps = amps / i**rolloff
    return freqs, amps
