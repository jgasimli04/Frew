"""Benchmark `.bee` v0 against standard audio formats on the real library.

For each source track (~/Desktop/Music): decode the PCM once (the truth), then
produce WAV / AIFF / FLAC (libsndfile) / ALAC (afconvert) / .bee (Python
reference) / .bee (Rust core), and measure:

  * size (bytes, and % of uncompressed WAV),
  * losslessness: decode back and compare against the truth PCM bit-for-bit,
  * encode / decode wall time.

Honest accounting for .bee: it is Layer-1 audio (FLAC or raw+zlib) PLUS the
helix side-channel and manifest, so the table also splits out that overhead.
The existing HelixRecords from the helichain are reused (real side-channels,
no re-analysis).

Run:  .venv/bin/python beecore/bench/bench_formats.py
"""

import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import time

import numpy as np
import soundfile as sf

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from beehive import beefile  # noqa: E402
from beehive.record import HelixRecord  # noqa: E402

MUSIC = pathlib.Path.home() / "Desktop" / "Music"
RECORDS = REPO / "helichain" / "records"
BEE_BIN = REPO / "beecore" / "target" / "release" / "bee"
TMP = pathlib.Path(__file__).resolve().parent / ".tmp"

AFCONVERT_FMT = {"PCM_16": "LEI16", "PCM_24": "LEI24", "PCM_32": "LEI32"}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def timed(fn):
    t0 = time.perf_counter()
    out = fn()
    return out, time.perf_counter() - t0


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, cmd))}\n{r.stderr}")
    return r


def record_for(src):
    stem = src.stem
    hits = list(RECORDS.glob(f"{stem}-*.npz"))
    if not hits:
        raise FileNotFoundError(f"no helichain record for {stem}")
    return HelixRecord.load(str(hits[0])[: -len(".npz")])


def verify_soundfile(path, truth_hash, dtype):
    data, _ = sf.read(path, dtype=dtype, always_2d=True)
    return sha(np.ascontiguousarray(data).tobytes()) == truth_hash


def bench_track(src, results):
    print(f"\n=== {src.name} ===")
    info = sf.info(str(src))
    data, am = beefile._read_source_pcm(str(src))
    truth = sha(data.tobytes())
    dtype = am["dtype"]
    print(f"  {info.samplerate} Hz, {am['channels']} ch, {am['subtype']}, "
          f"{am['frames']:,} frames ({am['frames']/info.samplerate/60:.1f} min), "
          f"raw PCM {data.nbytes:,} B")

    d = TMP / src.stem[:24].strip().replace(" ", "_")
    d.mkdir(parents=True, exist_ok=True)
    rows = []

    def add(fmt, path, t_enc, t_dec, lossless, note=""):
        size = path.stat().st_size if path else None
        rows.append(dict(fmt=fmt, size=size, enc=t_enc, dec=t_dec,
                         lossless=lossless, note=note))

    # --- source file itself (context row) -----------------------------------
    add(f"source ({src.suffix[1:]})", src, None, None, True, "as purchased")

    # --- WAV (uncompressed baseline) ----------------------------------------
    wav = d / "ref.wav"
    _, t_enc = timed(lambda: sf.write(wav, data, am["sample_rate"], subtype=am["subtype"]))
    (_, t_dec) = timed(lambda: sf.read(wav, dtype=dtype, always_2d=True))
    add("WAV (PCM)", wav, t_enc, t_dec, verify_soundfile(wav, truth, dtype))

    # --- AIFF (uncompressed) --------------------------------------------------
    aiff = d / "ref.aiff"
    _, t_enc = timed(lambda: sf.write(aiff, data, am["sample_rate"], subtype=am["subtype"]))
    (_, t_dec) = timed(lambda: sf.read(aiff, dtype=dtype, always_2d=True))
    add("AIFF (PCM)", aiff, t_enc, t_dec, verify_soundfile(aiff, truth, dtype))

    # --- FLAC (libsndfile, same encoder the .bee reference uses) -------------
    fl = d / "ref.flac"
    _, t_enc = timed(lambda: sf.write(fl, data, am["sample_rate"],
                                      subtype=am["subtype"], format="FLAC"))
    (_, t_dec) = timed(lambda: sf.read(fl, dtype=dtype, always_2d=True))
    add("FLAC (libsndfile)", fl, t_enc, t_dec, verify_soundfile(fl, truth, dtype))

    # --- ALAC (afconvert, Apple Lossless) -------------------------------------
    alac = d / "ref_alac.m4a"
    fmt = AFCONVERT_FMT.get(am["subtype"])
    if fmt:
        _, t_enc = timed(lambda: run(["afconvert", "-f", "m4af", "-d", "alac",
                                      str(wav), str(alac)]))
        back = d / "alac_back.wav"
        _, t_dec = timed(lambda: run(["afconvert", "-f", "WAVE", "-d", fmt,
                                      str(alac), str(back)]))
        ok = verify_soundfile(back, truth, dtype)
        add("ALAC (afconvert)", alac, t_enc, t_dec, ok)
    else:
        print(f"  (skipping ALAC: no afconvert mapping for {am['subtype']})")

    # --- .bee — Python reference ----------------------------------------------
    record = record_for(src)
    bee_py = d / "track_py.bee"
    manifest, t_enc = timed(lambda: beefile.write_bee(bee_py, audio_path=str(src),
                                                      record=record))
    (rec2_pcm, t_dec) = timed(lambda: beefile.read_bee(bee_py))
    ok = (sha(np.ascontiguousarray(rec2_pcm[1]).tobytes()) == truth)
    sec = manifest["sections"]
    l1 = sec["audio"]["length"]
    l2 = sec["helix_arrays"]["length"] + sec["helix_meta"]["length"]
    hdr = bee_py.stat().st_size - l1 - l2
    add(".bee (Python ref)", bee_py, t_enc, t_dec, ok,
        f"L1 {l1:,} + L2 {l2:,} + manifest {hdr:,}")

    # --- .bee — Rust core ------------------------------------------------------
    (d / "pcm.bin").write_bytes(data.tobytes())
    am_in = {k: am[k] for k in ("sample_rate", "channels", "subtype", "frames",
                                "dtype", "byte_order", "source_format")}
    (d / "am.json").write_text(json.dumps(am_in))
    arrays_bytes, meta_bytes = beefile._serialize_sidechannel(record)
    (d / "h.npz").write_bytes(arrays_bytes)
    (d / "hm.json").write_bytes(meta_bytes)

    bee_rs = d / "track_rs.bee"
    _, t_enc = timed(lambda: run([str(BEE_BIN), "encode",
                                  "--pcm", str(d / "pcm.bin"),
                                  "--audio-meta", str(d / "am.json"),
                                  "--helix-npz", str(d / "h.npz"),
                                  "--helix-meta", str(d / "hm.json"),
                                  "--out", str(bee_rs)]))
    out_pcm = d / "rs_out.bin"
    _, t_dec = timed(lambda: run([str(BEE_BIN), "decode", str(bee_rs),
                                  "--pcm-out", str(out_pcm)]))
    ok = sha(out_pcm.read_bytes()) == truth
    add(".bee (Rust core)", bee_rs, t_enc, t_dec, ok)

    # cross-check: Rust-written .bee decodes losslessly in Python too
    _, rs_pcm = beefile.read_bee(bee_rs)
    assert sha(np.ascontiguousarray(rs_pcm).tobytes()) == truth, "cross-impl mismatch!"

    wav_size = wav.stat().st_size
    print(f"\n  {'format':<20} {'size':>13} {'%WAV':>6} {'lossless':>9} "
          f"{'enc s':>7} {'dec s':>7}  note")
    for r in rows:
        pct = f"{100 * r['size'] / wav_size:5.1f}" if r["size"] else "  n/a"
        enc = f"{r['enc']:7.2f}" if r["enc"] is not None else "    n/a"
        dec = f"{r['dec']:7.2f}" if r["dec"] is not None else "    n/a"
        loss = "yes" if r["lossless"] else "NO!"
        print(f"  {r['fmt']:<20} {r['size']:>13,} {pct:>6} {loss:>9} "
              f"{enc} {dec}  {r['note']}")
    results[src.name] = rows

    # keep the artifacts small: drop the big intermediates, keep the .bee files
    for junk in ("pcm.bin", "rs_out.bin", "ref.wav", "ref.aiff", "alac_back.wav"):
        (d / junk).unlink(missing_ok=True)


def main():
    if not BEE_BIN.exists():
        sys.exit(f"missing {BEE_BIN}; run cargo build --release in beecore/")
    if TMP.exists():
        shutil.rmtree(TMP)
    TMP.mkdir(parents=True)

    sources = sorted([*MUSIC.glob("*.flac"), *MUSIC.glob("*.aiff"), *MUSIC.glob("*.wav")])
    if not sources:
        sys.exit(f"no sources found in {MUSIC}")

    results = {}
    for src in sources:
        bench_track(src, results)
    print("\nall lossless checks passed" if all(
        r["lossless"] for rows in results.values() for r in rows) else
        "\nSOME LOSSLESS CHECKS FAILED")


if __name__ == "__main__":
    main()
