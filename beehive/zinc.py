"""Zinc-finger keyframe key generator -- Phase 1, Python reference (authoritative).

Places variable-rate anchors ("zinc keys") over the helix STATE ``s(n) = (A, I)``
by a *drift-from-last-anchor* rule, and reconstructs the state trajectory between
keys by zero-order hold. THIS module generates the keys; Rust
(``beecore/.../zinc.rs``) will only *consume* them. Full spec:
``docs/blueprints/BEE_ZINC_KEYFRAME_BLUEPRINT.md``.

Design invariants (all deliberate, all cited in the blueprint):

* ``D(t)`` is the deviation from the **last anchor**, not frame-to-frame -- the
  fix over the ``mg.py`` prototype (which predicted ``states[i-1]`` and so
  measured total variation). Because the decoder *holds the last key*, thresholding
  hold-error guarantees the reconstruction error is ``<= tau`` at every frame.
* ``(A, I)`` are per-channel z-scored before combining, so ``D(t)`` and ``tau``
  share one dimensionless unit (dB and semitones are not comparable raw).
* **Unused space is never triggered:** an ambient run emits no anchor at all --
  no key, no bytes, no event. There is no grid and no zero-fill.

Only the state ``(A, I)`` carries content in the helix: ``r == r0`` is constant and
``theta = alpha(n)`` is a deterministic function of the frame index, so the sole
driftable, content-bearing quantity is the state (and ``z``, its running integral,
which each key re-anchors). We therefore anchor in state space.
"""

import math
from dataclasses import dataclass

import numpy as np

PHI = (1.0 + math.sqrt(5.0)) / 2.0
MAX_PERCEPTUAL_LATENCY_SEC = 0.020


@dataclass
class Anchor:
    """One zinc key: an absolute state coordinate that resets the prediction."""

    frame: int      # frame index n where the key is pinned
    a: float        # absolute state A (loudness dB) at the key
    i: float        # absolute state I (interval, semitones) at the key
    r: float        # helix radius (== r0, constant) -- self-describing
    theta: float    # helix angle alpha(n) mod 2pi (derivable from n)
    z: float        # helix climb h(n) at the key (re-anchors the running integral)


def _normalized_state(A, I):
    """Per-channel z-scored state, shape ``(n, 2)``, plus the (mu, sigma) used."""
    A = np.asarray(A, dtype=np.float64)
    I = np.asarray(I, dtype=np.float64)
    muA, muI = float(A.mean()), float(I.mean())
    sA = float(A.std()) or 1.0
    sI = float(I.std()) or 1.0
    S = np.stack([(A - muA) / sA, (I - muI) / sI], axis=1)
    return S, (muA, sA, muI, sI)


def seed_tau(A, I, hop_sec):
    """The polymerase seed for ``tau``, dimensionally consistent in normalized state.

    ``tau = phi * std(||dS/dt||) * MAX_PERCEPTUAL_LATENCY_SEC`` -- units
    ``[state/sec] * [sec] = state``, the same unit as ``D(t)``. A *seed* only;
    Phase 5 sweeps ``tau`` as the rate-distortion knob (blueprint 2, 6).
    """
    S, _ = _normalized_state(A, I)
    v = np.linalg.norm(np.gradient(S, axis=0), axis=1) / hop_sec
    return max(PHI * float(v.std()) * MAX_PERCEPTUAL_LATENCY_SEC, 1e-6)


def place_anchors(record, tau):
    """Generate zinc keys over a ``HelixRecord``.

    Anchor whenever holding the last key would drift the normalized state past
    ``tau``. Frame 0 is always a key. Guarantee: for every frame ``m``,
    ``||S[m] - S[last_key]|| <= tau``.
    """
    A, I = np.asarray(record.A), np.asarray(record.I)
    S, _ = _normalized_state(A, I)
    n = len(A)
    alpha = np.asarray(record.alpha)
    z = np.asarray(record.z)
    r0 = float(record.meta.get("r0", 1.0))

    keys = []

    def emit(m):
        keys.append(
            Anchor(
                frame=int(m),
                a=float(A[m]),
                i=float(I[m]),
                r=r0,
                theta=float(alpha[m] % (2.0 * math.pi)),
                z=float(z[m]),
            )
        )

    emit(0)
    ref = 0
    for m in range(1, n):
        d = math.hypot(S[m, 0] - S[ref, 0], S[m, 1] - S[ref, 1])
        if d > tau:
            emit(m)
            ref = m
    return keys


def reconstruct_state(keys, n_frames):
    """Consumer-side reconstruction (what Rust will mirror): zero-order hold of
    ``(A, I)`` from each key until the next, snapping exactly at the keys."""
    A = np.empty(n_frames, dtype=np.float64)
    I = np.empty(n_frames, dtype=np.float64)
    for k, key in enumerate(keys):
        end = keys[k + 1].frame if k + 1 < len(keys) else n_frames
        A[key.frame:end] = key.a
        I[key.frame:end] = key.i
    return A, I
