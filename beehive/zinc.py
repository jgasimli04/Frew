"""Zinc-finger keyframe key generator -- Python reference (authoritative).

Places variable-rate anchors ("zinc keys") over the helix STATE ``s(n) = (A, I)``
and reconstructs the state trajectory between keys by zero-order hold. THIS
module generates the keys; Rust (``beecore/.../zinc.rs``) will only *consume*
them. Full spec: ``docs/blueprints/BEE_ZINC_KEYFRAME_BLUEPRINT.md``; ambient
balance evidence: ``docs/findings/ZINC_AMBIENT_FINDINGS.md``.

Two-rail anchor policy (v2, the Laplace ambient balance)
--------------------------------------------------------

Phase 1 showed a single absolute threshold over-anchors ambient passages: slow
state wander eventually crosses any fixed ``tau`` and fires keys where nothing
musical happens. v2 splits the rule into two rails:

* **Event rail (Laplace-designed).** The normalized state is passed through the
  first-order high-pass ``H(s) = s / (s + lam)`` -- discretized exactly under
  zero-order hold as ``e[n] = exp(-lam*dt) * e[n-1] + (S[n] - S[n-1])`` -- and a
  key fires when ``||e[n]|| > tau_event``. Variation slower than ``lam`` leaks
  away (attenuation ~ omega/lam) and never fires; transients pass at unit gain.
  ``lam`` is tied to the track's own angular tempo: ``lam = kappa * omega_bar``
  with ``omega_bar = 2*pi*bpm/(60*B)`` -- "ambient" means "slower than the bar,"
  a fact the helix already knows.
* **Hard rail (the provable bound).** A key always fires when the absolute hold
  error ``||S[n] - S[last_key]||`` exceeds ``tau_max``. Zero-order-hold
  reconstruction error is therefore <= ``tau_max`` at every frame, by
  construction -- the Phase-1 guarantee, re-based to the wider rail.

Design invariants:

* ``D(t)`` on the hard rail is deviation from the **last anchor**, never
  frame-to-frame (the mg.py prototype bug).
* ``(A, I)`` are per-channel z-scored before combining, so thresholds share one
  dimensionless unit (dB and semitones are not comparable raw).
* **Unused space is never triggered:** an ambient run emits no event key at all
  -- no grid, no zero-fill; the rare hard-rail key in a long drift is a real
  state change and keeps the bound honest.

Only the state ``(A, I)`` carries content in the helix: ``r == r0`` is constant
and ``theta = alpha(n)`` is a deterministic function of the frame index, so the
sole driftable, content-bearing quantity is the state (and ``z``, its running
integral, which each key re-anchors). We therefore anchor in state space.
"""

import math
from dataclasses import dataclass

import numpy as np

PHI = (1.0 + math.sqrt(5.0)) / 2.0
MAX_PERCEPTUAL_LATENCY_SEC = 0.020

ZINC_VERSION = 2


@dataclass
class Anchor:
    """One zinc key: an absolute state coordinate that resets the prediction."""

    frame: int      # frame index n where the key is pinned
    a: float        # absolute state A (loudness dB) at the key
    i: float        # absolute state I (interval, semitones) at the key
    r: float        # helix radius (== r0, constant) -- self-describing
    theta: float    # helix angle alpha(n) mod 2pi (derivable from n; kept for self-description)
    z: float        # helix climb h(n) at the key (re-anchors the running integral)


@dataclass
class ZincPolicy:
    """The two-rail anchor policy -- the rate-distortion knobs of the index.

    ``tau_event``: threshold on the high-passed state magnitude (event rail).
    ``tau_max``:   absolute hold-error bound (hard rail); the reconstruction
                   guarantee ``err <= tau_max`` holds at every frame.
    ``lam``:       event-rail high-pass cutoff, rad/s. 0 disables the leak
                   (the accumulator becomes a pure integrator of state steps).
    """

    tau_event: float
    tau_max: float
    lam: float
    version: int = ZINC_VERSION

    @classmethod
    def seeded(cls, record, *, kappa_lambda=16.0, event_mult=3.0, max_mult=6.0):
        """Default policy for a record: thresholds seeded from track volatility,
        leak tied to the track's own angular tempo (angular information as fact).

        Defaults fixed by the 2026-07-10 corpus sweep (ZINC_AMBIENT_FINDINGS):
        ``lam = 16*omega_bar`` (with this corpus's half-octave bpm estimates
        this lands the cutoff at ~4.2-4.7 Hz ~= 2x the true beat frequency --
        "ambient" is anything slower than half a beat), ``tau_event = 3*seed``,
        ``tau_max = 6*seed``. Caveat carried in the findings: ``lam`` inherits
        the bpm estimator's octave sensitivity; pass ``bpm=`` at encode time to
        pin it.
        """
        meta = record.meta
        hop_sec = meta["hop"] / meta["sr"]
        t0 = seed_tau(record.A, record.I, hop_sec)
        omega_bar = 2.0 * math.pi * float(meta["bpm"]) / (60.0 * float(meta.get("B", 4)))
        return cls(
            tau_event=event_mult * t0,
            tau_max=max_mult * t0,
            lam=kappa_lambda * omega_bar,
        )


def _normalized_state(A, I):
    """Per-channel z-scored state, shape ``(n, 2)``, plus the (muA, sA, muI, sI) used."""
    A = np.asarray(A, dtype=np.float64)
    I = np.asarray(I, dtype=np.float64)
    muA, muI = float(A.mean()), float(I.mean())
    sA = float(A.std()) or 1.0
    sI = float(I.std()) or 1.0
    S = np.stack([(A - muA) / sA, (I - muI) / sI], axis=1)
    return S, (muA, sA, muI, sI)


def seed_tau(A, I, hop_sec):
    """The polymerase seed for the thresholds, dimensionally consistent in
    normalized state: ``phi * std(||dS/dt||) * MAX_PERCEPTUAL_LATENCY_SEC``
    (units ``[state/sec] * [sec] = state``). A *seed* only -- the policy sweep
    owns the final numbers.
    """
    S, _ = _normalized_state(A, I)
    v = np.linalg.norm(np.gradient(S, axis=0), axis=1) / hop_sec
    return max(PHI * float(v.std()) * MAX_PERCEPTUAL_LATENCY_SEC, 1e-6)


def select_anchor_frames(A, I, policy, hop_sec):
    """The two-rail selection rule over raw state arrays. Pure; unit-tested.

    Returns ``(frames, diag)`` where ``frames`` is the sorted key frame list
    (frame 0 always included) and ``diag`` records which rail fired what:
    ``{"event_frames": [...], "hard_frames": [...], "params": (muA,sA,muI,sI)}``.
    """
    S, params = _normalized_state(A, I)
    n = S.shape[0]
    leak = math.exp(-policy.lam * hop_sec) if policy.lam > 0.0 else 1.0

    frames = [0]
    event_frames, hard_frames = [], []
    ref = 0
    ex = ey = 0.0
    for m in range(1, n):
        ex = leak * ex + (S[m, 0] - S[m - 1, 0])
        ey = leak * ey + (S[m, 1] - S[m - 1, 1])
        hold = math.hypot(S[m, 0] - S[ref, 0], S[m, 1] - S[ref, 1])
        if hold > policy.tau_max:
            frames.append(m)
            hard_frames.append(m)
        elif math.hypot(ex, ey) > policy.tau_event:
            frames.append(m)
            event_frames.append(m)
        else:
            continue
        ref = m
        ex = ey = 0.0  # a key re-pins the prediction; both rails restart
    return frames, {"event_frames": event_frames, "hard_frames": hard_frames,
                    "params": params}


def place_anchors(record, policy):
    """Generate zinc keys over a ``HelixRecord``.

    ``policy`` is a :class:`ZincPolicy`. A bare float is accepted for the v1
    rule (hard rail only at that ``tau``) so Phase-1 numbers stay reproducible.
    """
    if isinstance(policy, (int, float)):
        policy = ZincPolicy(tau_event=math.inf, tau_max=float(policy),
                            lam=0.0, version=1)

    A, I = np.asarray(record.A), np.asarray(record.I)
    meta = record.meta
    hop_sec = meta["hop"] / meta["sr"]
    frames, _ = select_anchor_frames(A, I, policy, hop_sec)

    alpha = np.asarray(record.alpha)
    z = np.asarray(record.z)
    r0 = float(meta.get("r0", 1.0))
    return [
        Anchor(
            frame=int(m),
            a=float(A[m]),
            i=float(I[m]),
            r=r0,
            theta=float(alpha[m] % (2.0 * math.pi)),
            z=float(z[m]),
        )
        for m in frames
    ]


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


def state_spectrum_bands(A, I, hop_sec, omega_bar, n_beats_per_bar=4):
    """Fourier validation helper: energy fraction of the normalized state below
    the bar frequency, between bar and beat, beat..10 Hz, and above 10 Hz.

    This is the measurement that justifies tying the event-rail leak ``lam`` to
    ``omega_bar``: the sub-bar band is the "ambient" wander the Laplace
    high-pass removes.
    """
    S, _ = _normalized_state(A, I)
    n = S.shape[0]
    win = np.hanning(n)
    spec = np.abs(np.fft.rfft(S * win[:, None], axis=0)) ** 2
    energy = spec.sum(axis=1)  # combine both state channels
    freqs = np.fft.rfftfreq(n, hop_sec)

    f_bar = omega_bar / (2.0 * math.pi)
    f_beat = n_beats_per_bar * f_bar
    edges = [0.0, f_bar, f_beat, 10.0, freqs[-1] + 1.0]
    total = float(energy[1:].sum()) or 1.0  # drop DC: z-scored state has none
    fracs = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (freqs >= lo) & (freqs < hi)
        m[0] = False
        fracs.append(float(energy[m].sum()) / total)
    return {"f_bar": f_bar, "f_beat": f_beat,
            "below_bar": fracs[0], "bar_to_beat": fracs[1],
            "beat_to_10hz": fracs[2], "above_10hz": fracs[3]}
