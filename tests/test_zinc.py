"""Unit tests for the zinc two-rail anchor policy (beehive/zinc.py).

Synthetic, deterministic: these encode the falsifiable claims of the ambient
balance -- ambient emits no event keys, transients fire exactly where they
happen, the hard rail bounds reconstruction error at every frame, and the v1
rule survives as the float-policy special case.
"""

import math
from types import SimpleNamespace

import numpy as np
import pytest

from beehive.zinc import (
    Anchor,
    ZincPolicy,
    place_anchors,
    reconstruct_state,
    select_anchor_frames,
)

HOP_SEC = 1024.0 / 44100.0            # the engine's frame period (~23.2 ms)
OMEGA_BAR = 2.0 * math.pi * 128.0 / (60.0 * 4.0)   # 128 bpm, 4 beats/bar


def _policy(tau_event=0.5, tau_max=2.0, lam=OMEGA_BAR):
    return ZincPolicy(tau_event=tau_event, tau_max=tau_max, lam=lam)


def _norm_recon_error(A, I, frames):
    """Max ZOH hold error on the z-scored state, given key frames."""
    A = np.asarray(A, float)
    I = np.asarray(I, float)
    sA = A.std() or 1.0
    sI = I.std() or 1.0
    Sx, Sy = (A - A.mean()) / sA, (I - I.mean()) / sI
    err = np.zeros(len(A))
    ref = 0
    for m in range(len(A)):
        if m in frames_set(frames):
            ref = m
        err[m] = math.hypot(Sx[m] - Sx[ref], Sy[m] - Sy[ref])
    return err.max()


def frames_set(frames):
    return frames if isinstance(frames, set) else set(frames)


def test_constant_state_emits_only_frame_zero():
    n = 2000
    A = np.full(n, -20.0)
    I = np.full(n, 5.0)
    frames, diag = select_anchor_frames(A, I, _policy(), HOP_SEC)
    assert frames == [0]
    assert diag["event_frames"] == [] and diag["hard_frames"] == []


def test_slow_sine_is_ambient_no_event_keys():
    # One state channel swinging over a 60 s period: far below the bar
    # frequency (~0.53 Hz), i.e. pure ambient wander. The Laplace high-pass
    # must let it leak away: zero event keys; only the hard rail may speak.
    n = 8000                                    # ~186 s
    t = np.arange(n) * HOP_SEC
    A = -30.0 + 10.0 * np.sin(2.0 * np.pi * t / 60.0)
    I = np.zeros(n)
    frames, diag = select_anchor_frames(A, I, _policy(), HOP_SEC)
    assert diag["event_frames"] == []
    # hard-rail keys are bounded by the path geometry: the z-scored swing is
    # ~2*sqrt(2) per period over ~3.1 periods, tau_max = 2.0
    assert len(frames) <= 12


def test_step_fires_exactly_at_the_step():
    n = 4000
    A = np.full(n, -40.0)
    A[2000:] = -10.0                            # one hard transient
    I = np.zeros(n)
    frames, diag = select_anchor_frames(A, I, _policy(), HOP_SEC)
    assert 2000 in frames                       # the key lands ON the event
    assert len(frames) <= 3                     # frame 0, the step, no chatter


def test_ambient_plus_transients_keys_cluster_at_transients():
    # Slow sine background + three sharp steps: every event key must sit within
    # 3 frames of a step -- "unused space is never triggered."
    rng = np.random.default_rng(7)
    n = 12000
    t = np.arange(n) * HOP_SEC
    A = -35.0 + 6.0 * np.sin(2.0 * np.pi * t / 45.0)
    steps = [3000, 6500, 9800]
    for s in steps:
        A[s:] += 12.0 * (1 if s != 6500 else -1)
    I = 0.02 * rng.standard_normal(n).cumsum() * 0.0  # keep I flat
    frames, diag = select_anchor_frames(A, I, _policy(), HOP_SEC)
    for f in diag["event_frames"]:
        assert min(abs(f - s) for s in steps) <= 3


def test_hard_rail_bounds_reconstruction_everywhere():
    rng = np.random.default_rng(11)
    n = 6000
    A = rng.standard_normal(n).cumsum() * 0.5   # random walk state
    I = rng.standard_normal(n).cumsum() * 0.3
    pol = _policy(tau_event=0.8, tau_max=1.5)
    frames, _ = select_anchor_frames(A, I, pol, HOP_SEC)
    assert _norm_recon_error(A, I, set(frames)) <= pol.tau_max + 1e-9


def test_event_rail_monotone_in_tau_event():
    rng = np.random.default_rng(3)
    n = 6000
    A = rng.standard_normal(n).cumsum() * 0.5
    I = rng.standard_normal(n).cumsum() * 0.3
    counts = []
    for te in (0.3, 0.6, 1.2):
        frames, _ = select_anchor_frames(
            A, I, _policy(tau_event=te, tau_max=math.inf), HOP_SEC)
        counts.append(len(frames))
    assert counts[0] >= counts[1] >= counts[2]


def test_float_policy_reproduces_v1_hard_rail():
    rng = np.random.default_rng(5)
    n = 3000
    A = rng.standard_normal(n).cumsum() * 0.4
    I = rng.standard_normal(n).cumsum() * 0.2
    rec = SimpleNamespace(
        A=A, I=I, alpha=np.zeros(n), z=np.zeros(n),
        meta={"r0": 1.0, "hop": 1024, "sr": 44100, "bpm": 128.0, "B": 4},
    )
    keys = place_anchors(rec, 0.9)              # v1: bare float tau
    # brute-force v1 rule on the z-scored state
    sA, sI = A.std() or 1.0, I.std() or 1.0
    Sx, Sy = (A - A.mean()) / sA, (I - I.mean()) / sI
    expect, ref = [0], 0
    for m in range(1, n):
        if math.hypot(Sx[m] - Sx[ref], Sy[m] - Sy[ref]) > 0.9:
            expect.append(m)
            ref = m
    assert [k.frame for k in keys] == expect


def test_reconstruct_state_snaps_at_keys():
    keys = [
        Anchor(frame=0, a=-30.0, i=2.0, r=1.0, theta=0.0, z=0.0),
        Anchor(frame=10, a=-10.0, i=4.0, r=1.0, theta=1.0, z=3.0),
    ]
    A, I = reconstruct_state(keys, 15)
    assert A[0] == -30.0 and A[9] == -30.0
    assert A[10] == -10.0 and A[14] == -10.0
    assert I[9] == 2.0 and I[10] == 4.0


def test_wire_format_roundtrip_is_24_bytes_le():
    """SECTION_ZINC_INDEX wire format: 24-byte LE records, roundtrip exact on
    f32-representable values, layout pinned byte-for-byte against a hand-packed
    record (the same pin as beecore's zinc_index_roundtrip test)."""
    from beehive.zinc import ANCHOR_BYTES, deserialize_anchors, serialize_anchors

    keys = [Anchor(frame=0, a=-30.0, i=12.0, r=1.0, theta=0.5, z=2.0),
            Anchor(frame=4093, a=-12.5, i=24.0, r=1.0, theta=0.25, z=173.5)]
    blob = serialize_anchors(keys)
    assert ANCHOR_BYTES == 24 and len(blob) == 48
    # hand-packed first record: <u32 frame, f32 r, theta, z, a, i> little-endian
    import struct
    assert blob[:24] == struct.pack("<Ifffff", 0, 1.0, 0.5, 2.0, -30.0, 12.0)
    assert deserialize_anchors(blob) == keys

    with pytest.raises(ValueError):
        deserialize_anchors(blob[:23])
