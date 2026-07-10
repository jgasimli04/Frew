"""Cross-implementation acceptance for the `.bee` v0 core.

The contract (blueprint §4c): Python `beehive/beefile.py` is the reference
implementation; the Rust crate `bee-format` is the portable production core.
A `.bee` written by either implementation must decode in the other to
  * bit-identical PCM arrays (Layer 1 lossless contract), and
  * a bit-identical Layer-2 side-channel (A, I, chroma, engagement + meta).

Run:  .venv/bin/python beecore/interop/test_interop.py
(from the sonoFaig repo root; builds nothing — expects
 beecore/target/release/bee to exist: `cargo build --release`)
"""

import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

import numpy as np
import soundfile as sf

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from beehive import beefile  # noqa: E402
from beehive.encode import encode_song  # noqa: E402
from beehive.record import STORED_FIELDS  # noqa: E402

BEE_BIN = REPO / "beecore" / "target" / "release" / "bee"
TMP = pathlib.Path(__file__).resolve().parent / ".tmp"

PASS, FAIL = [], []


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append(name)
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


def sha(b):
    return hashlib.sha256(b).hexdigest()


def rust(*args):
    r = subprocess.run([str(BEE_BIN), *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"bee {' '.join(args)} failed:\n{r.stderr}")
    return r.stdout


def make_sources(d):
    """Deterministic test sources covering both codec paths."""
    rng = np.random.default_rng(20260705)
    sr = 22_050
    t = np.arange(4 * sr) / sr

    # 16-bit stereo: tone + noise bursts (flac path, the common case)
    left = 0.5 * np.sin(2 * np.pi * 220.0 * t)
    right = 0.3 * np.sin(2 * np.pi * 330.0 * t) + 0.1 * rng.standard_normal(len(t))
    beat = (np.sin(2 * np.pi * 2.0 * t) > 0).astype(float)
    pcm16 = d / "src_pcm16_stereo.wav"
    sf.write(pcm16, np.stack([left * beat, right * beat], axis=1), sr, subtype="PCM_16")

    # 24-bit mono: sweep (flac path, the 24-bit left-justify convention)
    sweep = 0.6 * np.sin(2 * np.pi * (110.0 + 400.0 * t[: 3 * sr] / 3) * t[: 3 * sr])
    pcm24 = d / "src_pcm24_mono.wav"
    sf.write(pcm24, sweep, sr, subtype="PCM_24")

    # float32 stereo (raw_zlib path)
    fl = d / "src_float32_stereo.wav"
    noise = 0.2 * rng.standard_normal((2 * sr, 2)).astype(np.float32)
    sf.write(fl, noise + np.float32(0.4) * np.sin(2 * np.pi * 175.0 * t[: 2 * sr])[:, None].astype(np.float32), sr, subtype="FLOAT")

    return [("pcm16_stereo", pcm16, "flac"), ("pcm24_mono", pcm24, "flac"),
            ("float32_stereo", fl, "raw_zlib")]


def run_case(d, name, wav, expect_codec):
    print(f"case {name} ({wav.name}, expect codec={expect_codec})")
    data, am = beefile._read_source_pcm(wav)
    truth = sha(data.tobytes())
    record = encode_song(str(wav), bpm=120.0)
    f32 = {k: np.asarray(getattr(record, k), dtype=np.float32) for k in STORED_FIELDS}

    # --- reference writes, core reads --------------------------------------
    py_bee = d / f"{name}_py.bee"
    manifest = beefile.write_bee(py_bee, audio_path=str(wav), record=record)
    check(f"{name}: reference codec", manifest["audio"]["codec"] == expect_codec,
          manifest["audio"]["codec"])

    out_pcm = d / f"{name}_rust_read.bin"
    rust("decode", str(py_bee), "--pcm-out", str(out_pcm),
         "--audio-meta-out", str(d / f"{name}_rust_am.json"))
    check(f"{name}: Rust decodes Python-written .bee bit-exact",
          sha(out_pcm.read_bytes()) == truth)

    npz_out, hm_out = d / f"{name}_helix.npz", d / f"{name}_helix.json"
    rust("extract-helix", str(py_bee), "--npz-out", str(npz_out), "--meta-out", str(hm_out))
    with np.load(npz_out) as z:
        side_ok = all(np.array_equal(z[k], f32[k]) and z[k].dtype == np.float32
                      for k in STORED_FIELDS)
    check(f"{name}: Rust reads Layer-2 arrays bit-exact", side_ok)
    check(f"{name}: Rust reads Layer-2 meta verbatim",
          json.loads(hm_out.read_text()) == record.meta)

    # --- core writes, reference reads ---------------------------------------
    (d / f"{name}_pcm.bin").write_bytes(data.tobytes())
    am_in = {k: am[k] for k in
             ("sample_rate", "channels", "subtype", "frames", "dtype",
              "byte_order", "source_format")}
    (d / f"{name}_am.json").write_text(json.dumps(am_in))
    arrays_bytes, meta_bytes = beefile._serialize_sidechannel(record)
    (d / f"{name}_h.npz").write_bytes(arrays_bytes)
    (d / f"{name}_hm.json").write_bytes(meta_bytes)

    rust_bee = d / f"{name}_rust.bee"
    rust("encode", "--pcm", str(d / f"{name}_pcm.bin"),
         "--audio-meta", str(d / f"{name}_am.json"),
         "--helix-npz", str(d / f"{name}_h.npz"),
         "--helix-meta", str(d / f"{name}_hm.json"),
         "--out", str(rust_bee))

    record2, pcm2 = beefile.read_bee(rust_bee)
    check(f"{name}: Python decodes Rust-written .bee bit-exact",
          np.array_equal(pcm2, data) and pcm2.dtype == data.dtype
          and sha(np.ascontiguousarray(pcm2).tobytes()) == truth)
    side2_ok = all(np.array_equal(np.asarray(getattr(record2, k)), f32[k])
                   for k in STORED_FIELDS)
    check(f"{name}: Python reloads Layer-2 from Rust .bee bit-exact", side2_ok)
    check(f"{name}: Layer-2 meta survives Rust round-trip", record2.meta == record.meta)

    info = json.loads(rust("info", str(rust_bee)))
    check(f"{name}: Rust manifest codec", info["audio"]["codec"] == expect_codec,
          info["audio"]["codec"])

    src, pyb, rsb = wav.stat().st_size, py_bee.stat().st_size, rust_bee.stat().st_size
    print(f"  sizes: source WAV {src:,} B | .bee (python) {pyb:,} B | .bee (rust) {rsb:,} B")


def main():
    if not BEE_BIN.exists():
        sys.exit(f"missing {BEE_BIN}; run: cargo build --release (in beecore/)")
    if TMP.exists():
        shutil.rmtree(TMP)
    TMP.mkdir(parents=True)

    for name, wav, codec in make_sources(TMP):
        run_case(TMP, name, wav, codec)

    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        sys.exit(1)


if __name__ == "__main__":
    main()
