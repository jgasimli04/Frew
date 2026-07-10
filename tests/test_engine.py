"""Engine consistency + end-to-end tests.

The encode path is numpy-only for lightness, but it must agree with the verified
torch reference math (chroma + curvature/torsion). These tests pin that, then run
a full synthetic song through encode -> save/load -> helichain.

Run:  python3 -m pytest tests/test_engine.py -q
  or: python3 tests/test_engine.py
"""

import os
import sys
import tempfile

import numpy as np
import soundfile as sf
import torch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from beehive import chroma as tchroma
from beehive import helix as thelix
from beehive.audio import content_hash
from beehive.encode import _curvature_torsion, encode_song
from beehive.features import chroma_from_mag, chroma_weight_matrix
from beehive.helichain import Helichain
from beehive.record import HelixRecord


def test_numpy_chroma_matches_torch():
    rng = np.random.default_rng(0)
    sr, n_fft = 22050, 2048
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)[1:]            # drop DC (log2 undefined)
    mag = rng.random((5, len(freqs)))                       # 5 frames

    w_mat = chroma_weight_matrix(freqs, sigma=0.5, f_ref=440.0)
    np_chroma = chroma_from_mag(mag, w_mat)                 # (5, 12)

    f_t = torch.tensor(freqs, dtype=torch.float64)
    for i in range(mag.shape[0]):
        ref = tchroma.soft_chroma_projection(
            f_t, torch.tensor(mag[i], dtype=torch.float64), sigma=0.5, f_ref=440.0
        ).numpy()
        assert np.allclose(np_chroma[i], ref, atol=1e-4), (i, np_chroma[i] - ref)


def test_numpy_curvature_torsion_matches_torch():
    rng = np.random.default_rng(1)
    omega, r0 = 1.5, 0.8                                    # omega != 1 (where the typo hid)
    h1, h2, h3 = rng.random(7), rng.random(7), rng.random(7)
    k_np, t_np = _curvature_torsion(omega, r0, h1, h2, h3)
    k_t, t_t = thelix.curvature_torsion(
        omega, r0, torch.tensor(h1), torch.tensor(h2), torch.tensor(h3)
    )
    assert np.allclose(k_np, k_t.numpy(), atol=1e-9)
    assert np.allclose(t_np, t_t.numpy(), atol=1e-9)


def test_content_hash_slice():
    # A waveform with one bar repeated at two positions, a different bar between:
    # [bar | other | bar]. This is the loop-dedup scenario (BEE_FORMAT_BLUEPRINT.md
    # step 1) -- a repeated bar must hash-match, a different bar must not.
    rng = np.random.default_rng(2)
    bar = rng.standard_normal(1000).astype(np.float32)
    other = rng.standard_normal(1000).astype(np.float32)
    y = np.concatenate([bar, other, bar])

    # full range == today's whole-waveform behavior (no range given)
    assert content_hash(y, (0, len(y))) == content_hash(y)

    # the load-bearing contract: a range carved from the song hashes the same as
    # that same slice standing alone (this is what makes bar-level dedup sound)
    assert content_hash(y, (0, 1000)) == content_hash(y[:1000])

    # two identical slices (the repeated bar) hash equal
    assert content_hash(y, (0, 1000)) == content_hash(y, (2000, 3000))

    # two different slices (bar vs. other) hash differently
    assert content_hash(y, (0, 1000)) != content_hash(y, (1000, 2000))


def _write_synth(path, sr=22050, dur=3.0):
    t = np.linspace(0, dur, int(sr * dur), endpoint=False)
    # quiet 220 Hz first half, louder 440 Hz second half -> real A and I movement
    half = len(t) // 2
    y = np.zeros_like(t)
    y[:half] = 0.2 * np.sin(2 * np.pi * 220 * t[:half])
    y[half:] = 0.8 * np.sin(2 * np.pi * 440 * t[half:])
    sf.write(path, y.astype(np.float32), sr)


def test_encode_and_helichain_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "synth.wav")
        _write_synth(wav)

        rec = encode_song(wav, bpm=120.0)                  # fixed bpm: deterministic
        n = rec.n_frames
        assert n > 0
        for arr in (rec.A, rec.I, rec.F_mag, rec.h, rec.hue, rec.chroma):
            assert arr.shape[0] == n
        assert rec.chroma.shape[1] == 12
        assert (rec.F_mag >= 0).all()
        assert np.all(np.diff(rec.h) >= -1e-6)             # climb is non-decreasing
        assert np.all((rec.hue >= 0) & (rec.hue < 1.0 + 1e-6))

        stem = os.path.join(d, "rec")
        rec.save(stem)
        back = HelixRecord.load(stem)
        assert np.allclose(rec.x, back.x) and np.allclose(rec.chroma, back.chroma)

        chain = Helichain(os.path.join(d, "chain"))
        block1, created1 = chain.add_record(rec)
        block2, created2 = chain.add_record(rec)           # same content -> no-op
        assert created1 and not created2
        assert block1["block_hash"] == block2["block_hash"]
        ok, bad = chain.verify_chain()
        assert ok and bad is None


if __name__ == "__main__":
    test_numpy_chroma_matches_torch()
    test_numpy_curvature_torsion_matches_torch()
    test_content_hash_slice()
    test_encode_and_helichain_roundtrip()
    print("all engine tests passed")
