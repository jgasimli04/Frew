"""`.bee` v0 round-trip tests (BEE_FORMAT_BLUEPRINT.md §6 step 5).

The load-bearing contract: a song packed into a `.bee` and read back is
**bit-exact on the decoded PCM** — sha256(pcm_in) == sha256(pcm_out) — across
channel layouts and both v0 payload codecs (FLAC for 16/24-bit integer PCM,
raw+zlib otherwise). Layer 2 (the helix side-channel) must also round-trip: the
stored state comes back identical and the geometry re-derives to the same record.

Run:  python3 -m pytest tests/test_beefile.py -q
"""

import hashlib
import os
import sys
import tempfile

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from beehive.beefile import (
    _read_source_pcm,
    bee_info,
    decode_bee_to_wav,
    read_bee,
    write_bee,
)
from beehive.encode import encode_song


def _sha(arr):
    return hashlib.sha256(np.ascontiguousarray(arr).tobytes()).hexdigest()


def _write_song(path, *, sr=22050, dur=3.0, channels=1, subtype="PCM_16"):
    """A short synthetic 'song' with real A/I movement: quiet 220 Hz then loud 440 Hz.
    Stereo puts a different tone in each ear so channels are not identical."""
    t = np.linspace(0, dur, int(sr * dur), endpoint=False)
    half = len(t) // 2
    base = np.zeros_like(t)
    base[:half] = 0.2 * np.sin(2 * np.pi * 220 * t[:half])
    base[half:] = 0.8 * np.sin(2 * np.pi * 440 * t[half:])
    if channels == 1:
        y = base
    else:
        right = 0.5 * np.sin(2 * np.pi * 330 * t)
        y = np.stack([base, right], axis=1)
    sf.write(path, y.astype(np.float32), sr, subtype=subtype)


def _roundtrip_case(d, name, *, channels, subtype, expected_codec):
    src = os.path.join(d, f"{name}.wav")
    bee = os.path.join(d, f"{name}.bee")
    _write_song(src, channels=channels, subtype=subtype)

    rec = encode_song(src, bpm=120.0)               # fixed bpm -> deterministic
    manifest = write_bee(bee, audio_path=src, record=rec)
    assert manifest["audio"]["codec"] == expected_codec
    assert manifest["audio"]["channels"] == channels

    pcm_in, _ = _read_source_pcm(src)               # the canonical decoded PCM
    rec_back, pcm_out = read_bee(bee)

    # the contract: bit-exact decoded PCM
    assert pcm_out.shape == pcm_in.shape
    assert pcm_out.dtype == pcm_in.dtype
    assert _sha(pcm_in) == _sha(pcm_out), f"{name}: PCM not bit-exact"
    return rec, rec_back


def test_bee_roundtrip_pcm16_stereo():
    with tempfile.TemporaryDirectory() as d:
        _roundtrip_case(d, "s16", channels=2, subtype="PCM_16", expected_codec="flac")


def test_bee_roundtrip_pcm24_stereo():
    with tempfile.TemporaryDirectory() as d:
        _roundtrip_case(d, "s24", channels=2, subtype="PCM_24", expected_codec="flac")


def test_bee_roundtrip_pcm16_mono():
    with tempfile.TemporaryDirectory() as d:
        _roundtrip_case(d, "m16", channels=1, subtype="PCM_16", expected_codec="flac")


def test_bee_roundtrip_float_mono_uses_raw_zlib():
    # FLOAT is outside FLAC's range -> exercises the raw+zlib fallback path.
    with tempfile.TemporaryDirectory() as d:
        _roundtrip_case(d, "f32", channels=1, subtype="FLOAT", expected_codec="raw_zlib")


def test_bee_sidechannel_roundtrips():
    with tempfile.TemporaryDirectory() as d:
        rec, back = _roundtrip_case(d, "side", channels=2, subtype="PCM_16",
                                    expected_codec="flac")
        # Layer 2: stored state is identical, geometry re-derives to the same record
        assert np.array_equal(rec.A, back.A)
        assert np.array_equal(rec.I, back.I)
        assert np.array_equal(rec.chroma, back.chroma)
        assert np.allclose(rec.x, back.x) and np.allclose(rec.z, back.z)
        assert np.allclose(rec.F_mag, back.F_mag)
        assert back.meta["song_id"] == rec.meta["song_id"]
        assert back.meta["bpm"] == rec.meta["bpm"]


def test_bee_decode_to_wav_is_lossless():
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "song.wav")
        bee = os.path.join(d, "song.bee")
        out = os.path.join(d, "out.wav")
        _write_song(src, channels=2, subtype="PCM_16")
        rec = encode_song(src, bpm=120.0)
        write_bee(bee, audio_path=src, record=rec)

        decode_bee_to_wav(bee, out)
        pcm_in, _ = _read_source_pcm(src)
        pcm_out, _ = _read_source_pcm(out)
        assert _sha(pcm_in) == _sha(pcm_out)


def test_bee_rejects_non_bee_file():
    import pytest
    with tempfile.TemporaryDirectory() as d:
        junk = os.path.join(d, "not.bee")
        with open(junk, "wb") as f:
            f.write(b"this is not a bee file")
        with pytest.raises(ValueError):
            bee_info(junk)


if __name__ == "__main__":
    test_bee_roundtrip_pcm16_stereo()
    test_bee_roundtrip_pcm24_stereo()
    test_bee_roundtrip_pcm16_mono()
    test_bee_roundtrip_float_mono_uses_raw_zlib()
    test_bee_sidechannel_roundtrips()
    test_bee_decode_to_wav_is_lossless()
    test_bee_rejects_non_bee_file()
    print("all .bee round-trip tests passed")
