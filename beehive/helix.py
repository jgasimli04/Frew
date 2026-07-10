"""The helix: rotation (tempo) plus climb (energy spent), and its Frenet
curvature/torsion invariants.

    R(n) = ( r0*cos(omega*n), r0*sin(omega*n), h(n) )

where omega = 2*pi*bpm / (60*B) and h(n) = integral of ||F(m)|| dm is the climb.

NOTE ON THE CURVATURE FORMULA
-----------------------------
The blueprint/SKILL stated curvature with `omega**2 * r0**2` under the square
root. That is a typo. The correct geometric term is `omega**4 * r0**2`, which is
the *same* quantity that (correctly) appears in the torsion denominator -- both
equal |R' x R''|^2 / (r0*omega)^2 and so must match. It is invisible at omega=1.
Re-derived independently from R(n) via the Frenet cross-product formulas and
confirmed symbolically in ../verify_geometry.py. We implement the corrected form.
"""

import torch


def helix_position(n, omega, r0, h):
    """Position R(n) on the helix.

    Parameters
    ----------
    n : tensor, the pluggable index (samples, beats, hops -- still open which).
    omega : angular velocity (2*pi*bpm / (60*B)).
    r0 : horizontal radius (constant in n for now; r(n) growth is open frontier).
    h : tensor of the same shape as n, the climb height h(n).

    Returns
    -------
    tensor of shape (*n.shape, 3): (x, y, z) = (r0*cos(omega*n), r0*sin(omega*n), h).
    """
    alpha = omega * n
    x = r0 * torch.cos(alpha)
    y = r0 * torch.sin(alpha)
    z = h
    return torch.stack([x, y, z], dim=-1)


def curvature_torsion(omega, r0, h1, h2, h3):
    """Frenet curvature kappa and torsion tau of the helix as closed forms.

    The helix is parametrised by n (not arc length); the formulas
    kappa = |R' x R''| / |R'|^3 and tau = (R' x R'') . R''' / |R' x R''|^2 are
    valid for any regular parametrisation, so these hold directly.

    Parameters
    ----------
    omega, r0 : helix constants.
    h1, h2, h3 : the climb derivatives h'(n)=||F(n)||, h''(n), h'''(n).
        Each may be a scalar or a tensor; standard broadcasting applies.

    Returns
    -------
    (kappa, tau) tensors.
    """
    # |R' x R''|^2 = r0^2 * omega^2 * (omega^4 * r0^2 + omega^2 * h1^2 + h2^2)
    common = torch.as_tensor(omega**4 * r0**2 + omega**2 * h1**2 + h2**2)
    cross_norm = r0 * omega * torch.sqrt(common)          # |R' x R''|
    speed_sq = omega**2 * r0**2 + h1**2                     # |R'|^2

    kappa = cross_norm / speed_sq**1.5                      # |R' x R''| / |R'|^3
    tau = omega * (omega**2 * h1 + h3) / common             # (R'xR'').R''' / |R'xR''|^2
    return kappa, tau
