"""Loop-layer tests: ω/bpm-driven bar segmentation + exact dedup must be
correct and lossless (BEE_FORMAT_BLUEPRINT.md §6 steps 2-3).

Run:  python3 -m pytest tests/test_loops.py -q
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from beehive.loops import (
    bar_length_samples,
    dedup_report,
    dedup_song,
    reconstruct,
    segment_bars,
)


def test_bar_length_from_tempo():
    # one bar = B·60/bpm seconds; at 120 bpm, B=4, sr=1000 -> 2 s -> 2000 samples
    assert bar_length_samples({"bpm": 120.0, "B": 4, "sr": 1000}) == 2000


def test_segments_tile_exactly():
    segs = segment_bars(2050, 1000)            # 2050 = 2 full bars + 50 remainder
    assert segs == [(0, 1000), (1000, 2000), (2000, 2050)]
    # boundaries are contiguous, cover [0, n), no gap/overlap
    assert segs[0][0] == 0 and segs[-1][1] == 2050
    for (a, b), (c, d) in zip(segs, segs[1:]):
        assert b == c


def test_exact_dedup_and_lossless_reconstruct():
    rng = np.random.default_rng(0)
    spb = 4000
    barA = (rng.standard_normal((spb, 2)) * 0.1).astype("float32")
    barB = (rng.standard_normal((spb, 2)) * 0.1).astype("float32")
    tail = (rng.standard_normal((123, 2)) * 0.1).astype("float32")
    song = np.concatenate([barA, barB, barA, barA, barB, tail], axis=0)

    pool, recall, segs = dedup_song(song, spb)
    # 5 full bars (2 unique: A,B) + 1 remainder tail -> pool of 3
    assert len(recall) == 6
    assert len(pool) == 3
    assert [e["first"] for e in recall] == [True, True, False, False, False, True]
    # the remainder tail is never deduped
    assert recall[-1]["len"] == 123 and recall[-1]["first"] is True
    # lossless: walking the recall sequence rebuilds the exact samples
    assert np.array_equal(reconstruct(pool, recall), song)


def test_dedup_report_numbers():
    rng = np.random.default_rng(1)
    spb = 4000
    barA = (rng.standard_normal((spb, 2)) * 0.1).astype("float32")
    barB = (rng.standard_normal((spb, 2)) * 0.1).astype("float32")
    song = np.concatenate([barA, barB, barA, barA], axis=0)   # 4 bars, 2 unique
    rep = dedup_report(song, spb)
    assert rep["total_bars"] == 4
    assert rep["unique_bars"] == 2
    assert rep["duplicate_bars"] == 2
    assert abs(rep["dedup_ratio"] - 0.5) < 1e-9
    assert abs(rep["payload_saving"] - 0.5) < 1e-9


def test_distinct_bars_do_not_dedup():
    rng = np.random.default_rng(2)
    spb = 2000
    song = (rng.standard_normal((spb * 4, 2)) * 0.1).astype("float32")  # all distinct
    rep = dedup_report(song, spb)
    assert rep["duplicate_bars"] == 0
    assert rep["unique_bars"] == 4


if __name__ == "__main__":
    test_bar_length_from_tempo()
    test_segments_tile_exactly()
    test_exact_dedup_and_lossless_reconstruct()
    test_dedup_report_numbers()
    test_distinct_bars_do_not_dedup()
    print("all loop-layer tests passed")
