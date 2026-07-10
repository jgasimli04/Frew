"""Foundation engine CLI: encode a song into the helichain and keep it on standby.

    python3 encode_song.py [AUDIO_PATH] [--bpm N] [--chain DIR]

With no path it defaults to the AIFF in ~/Downloads. Encodes the song once, stores
the helix record, appends a block to the helichain (idempotent: a song already in
the chain is not re-analysed), and prints a summary + the size of this compact
representation against the dense STFT it replaces.
"""

import argparse
import glob
import numpy as np
import os


def _ts(seconds):
    """Float seconds -> 'm:ss' string."""
    s = int(round(seconds))
    return f"{s // 60}:{s % 60:02d}"

import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root, for `beehive`

from beehive.encode import encode_song
from beehive.helichain import Helichain


def _default_audio():
    """First audio file found in the usual spots (newest library dir first)."""
    pats = ["*.aif*", "*.flac", "*.wav", "*.mp3"]
    for base in ("~/Desktop/Music", "~/Downloads"):
        for pat in pats:
            hits = sorted(glob.glob(os.path.join(os.path.expanduser(base), pat)))
            if hits:
                return hits[0]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("audio", nargs="?", default=_default_audio(), help="audio file")
    ap.add_argument("--bpm", type=float, default=None, help="override tempo estimate")
    ap.add_argument("--chain", default=os.path.expanduser("~/sonoFaig/helichain"),
                    help="helichain directory")
    ap.add_argument("--hop", type=int, default=1024)
    ap.add_argument("--n-fft", type=int, default=2048)
    args = ap.parse_args()

    if not args.audio or not os.path.exists(args.audio):
        ap.error("no audio file found (pass a path, or drop an .aiff in ~/Downloads)")

    print(f"encoding: {args.audio}")
    rec = encode_song(args.audio, bpm=args.bpm, hop=args.hop, n_fft=args.n_fft)
    m = rec.meta
    print(f"  song_id     {m['song_id']}")
    print(f"  duration    {_ts(m['duration_s'])}   sr {m['sr']} Hz   frames {m['n_frames']}")
    print(f"  tempo       {m['bpm']:.1f} bpm ({m['bpm_source']}"
          + (f", conf {m['bpm_confidence']:.2f}" if m['bpm_confidence'] is not None else "")
          + f")   omega {m['omega_rad_per_s']:.3f} rad/s")
    print(f"  climb h(N)  {float(rec.h[-1]):.1f}   (total energy spent; outer radius r0={m['r0']})")

    # top dynamic moments (audible frames only, skip silence transitions)
    mask = rec.A > -40
    F = np.where(mask, rec.F_mag, 0)
    top5_idx = np.argsort(F)[-5:][::-1]
    top5_ts = sorted([_ts(int(i) * m["hop"] / m["sr"]) for i in top5_idx])
    print(f"  peak moments  {' · '.join(top5_ts)}")

    chain = Helichain(args.chain)
    block, created = chain.add_record(rec)
    status = "added block" if created else "already in chain (analysed once)"
    print(f"  helichain   {status} #{block['index']}  "
          f"hash {block['block_hash'][:12]}...  -> {args.chain}")
    ok, bad = chain.verify_chain()
    print(f"  chain check {'OK' if ok else f'BROKEN at #{bad}'}  ({len(chain.blocks())} block(s))")

    cr = rec.compression_report()
    npz = os.path.join(args.chain, block["record_file"])
    on_disk = os.path.getsize(npz) if os.path.exists(npz) else 0
    print(f"  size        stored {cr['stored_bytes']/1024:.0f} KiB logical "
          f"({on_disk/1024:.0f} KiB on disk, compressed)  vs  dense STFT "
          f"{cr['stft_bytes']/1024:.0f} KiB")
    print(f"  lighter by  {cr['ratio_state_vs_stft']:.0f}x (A,I geometry substrate), "
          f"{cr['ratio_stored_vs_stft']:.0f}x (+timbre)  [column count, not adaptive offload]")


if __name__ == "__main__":
    main()
