"""Convert every song in a folder to `.bee` (Layer 1 lossless audio + helix record).

    python3 scripts/convert_to_bee.py [FOLDER] [--force] [--bpm N]

For each audio file (aiff/aif/wav/flac/mp3/m4a):
  1. Get its HelixRecord: reuse the helichain record if the song was already
     analysed (analyse-once); otherwise run the encoder and append to the chain.
  2. Write `<song>.bee` next to the source (reference writer, beehive/beefile.py).
  3. Verify with the NATIVE core: `beecore` `bee decode` must reproduce the
     source's decoded PCM sha256-identically — the cross-implementation
     acceptance bar, applied to every file converted.

Idempotent: a song whose `.bee` already exists is skipped unless --force.
"""

import argparse
import glob
import hashlib
import os
import subprocess
import sys
import tempfile

import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root

from beehive import beefile
from beehive.encode import encode_song
from beehive.helichain import Helichain
from beehive.record import HelixRecord

REPO = pathlib.Path(__file__).resolve().parents[1]
BEE_BIN = REPO / "beecore" / "target" / "release" / "bee"
AUDIO_EXTS = {".aiff", ".aif", ".wav", ".flac", ".mp3", ".m4a"}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def record_for(src, bpm=None):
    """Reuse the analysed record if the helichain has it; else analyse + append."""
    hits = sorted(glob.glob(str(REPO / "helichain" / "records" / f"{src.stem}-*.npz")))
    if hits:
        return HelixRecord.load(hits[0][: -len(".npz")]), "helichain (reused)"
    record = encode_song(str(src), bpm=bpm)
    Helichain(root=str(REPO / "helichain")).add_record(record)
    return record, "analysed now (+appended to helichain)"


def verify_native(bee_path, truth_hash):
    """The acceptance bar: the Rust core must decode this .bee bit-exactly."""
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        out = tmp.name
    try:
        r = subprocess.run([str(BEE_BIN), "decode", str(bee_path), "--pcm-out", out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return False, f"native decode failed: {r.stderr.strip()}"
        with open(out, "rb") as f:
            return (sha(f.read()) == truth_hash), "pcm hash mismatch"
    finally:
        os.unlink(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder", nargs="?",
                    default=os.path.expanduser("~/Desktop/Music"))
    ap.add_argument("--force", action="store_true",
                    help="rewrite .bee files that already exist")
    ap.add_argument("--bpm", type=float, default=None,
                    help="tempo override for songs that still need analysing")
    args = ap.parse_args()

    if not BEE_BIN.exists():
        sys.exit(f"missing {BEE_BIN} — run: (cd beecore && cargo build --release)")

    folder = pathlib.Path(args.folder).expanduser()
    songs = sorted(p for p in folder.iterdir()
                   if p.suffix.lower() in AUDIO_EXTS)
    if not songs:
        sys.exit(f"no audio files in {folder}")

    failures = 0
    for src in songs:
        bee_path = src.with_suffix(".bee")
        if bee_path.exists() and not args.force:
            print(f"skip      {src.name}  (.bee exists)")
            continue

        data, _am = beefile._read_source_pcm(str(src))
        truth = sha(data.tobytes())
        record, provenance = record_for(src, bpm=args.bpm)

        manifest = beefile.write_bee(bee_path, audio_path=str(src), record=record)
        ok, why = verify_native(bee_path, truth)
        if not ok:
            failures += 1
            bee_path.unlink(missing_ok=True)  # never leave an unverified .bee
            print(f"FAILED    {src.name}  ({why}) — .bee removed")
            continue

        s_src, s_bee = src.stat().st_size, bee_path.stat().st_size
        print(f"converted {src.name}")
        print(f"          record: {provenance}")
        print(f"          {s_src:,} B -> {s_bee:,} B ({100 * s_bee / s_src:.1f}%),"
              f" codec {manifest['audio']['codec']},"
              f" verified bit-exact by the native core")

    if failures:
        sys.exit(f"{failures} conversion(s) failed verification")


if __name__ == "__main__":
    main()
