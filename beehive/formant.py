"""Formant envelope: the resonator's amplification pattern across frequency.

Source-filter model -- the envelope (filter) is fixed in Hz and shapes whatever
harmonic series (source) passes through it, which is why formant structure is
pitch-invariant (a fixed envelope amplifies different harmonics for different
fundamentals; the peaks don't move, the harmonics do). Modelled here as a sum of
Gaussian resonances in linear frequency.
"""

import torch


def formant_envelope(freqs, centers, widths, gains):
    """Spectral envelope value at each frequency.

        env(f) = sum_j gain_j * exp( -(f - center_j)^2 / (2 * width_j^2) )

    Parameters
    ----------
    freqs : tensor (N,) of frequencies in Hz.
    centers, widths, gains : tensors (J,), one entry per formant. Differentiable
        -- these are the learnable timbre-shape parameters.

    Returns
    -------
    tensor (N,) of envelope amplitudes.
    """
    f = freqs.unsqueeze(-1)                                   # (N, 1)
    contrib = gains * torch.exp(-(f - centers) ** 2 / (2.0 * widths**2))  # (N, J)
    return contrib.sum(dim=-1)                                # (N,)
