"""`bee` — the .bee format CLI (the surface a streaming platform calls).

The intended deployment (BEE_FORMAT_BLUEPRINT.md §2, P2P_MVP_BLUEPRINT.md): a
platform lets an artist upload a master; the platform runs `bee encode` to turn
it into a `.bee` (a lossless audio payload + the helix side-channel), serves the
`.bee`, and a client runs `bee decode` to get audio back, bit-for-bit.

    python3 -m beehive encode  AUDIO [-o OUT.bee] [--bpm N] [--hop H] [--n-fft N]
    python3 -m beehive decode  FILE.bee [-o OUT.wav]
    python3 -m beehive inspect FILE.bee

`encode_song.py` (repo root) remains the *helichain* entry point (analyse-once
ledger); this CLI is the *file-format* entry point. They share `beehive.encode`.
"""

import argparse
import os
import sys

from .beefile import bee_info, decode_bee_to_wav, write_bee
from .encode import encode_song


def _fmt_bytes(n):
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:,.0f} {unit}" if unit == "B" else f"{n:,.1f} {unit}"
        n /= 1024


def _ts(seconds):
    s = int(round(seconds))
    return f"{s // 60}:{s % 60:02d}"


def cmd_encode(args):
    if not os.path.exists(args.audio):
        sys.exit(f"no such file: {args.audio}")
    out = args.out or (os.path.splitext(args.audio)[0] + ".bee")
    print(f"encoding: {args.audio}")
    rec = encode_song(args.audio, bpm=args.bpm, hop=args.hop, n_fft=args.n_fft)
    manifest = write_bee(out, audio_path=args.audio, record=rec)

    am = manifest["audio"]
    src_sz, bee_sz = os.path.getsize(args.audio), os.path.getsize(out)
    sec = manifest["sections"]
    print(f"  wrote      {out}")
    print(f"  audio      {am['sample_rate']} Hz · {am['channels']} ch · {am['subtype']} "
          f"· {am['frames']} frames ({_ts(am['frames']/am['sample_rate'])}) · codec {am['codec']}")
    print(f"  helix      {manifest['sidechannel']['n_frames']} frames · "
          f"song_id {manifest['sidechannel']['song_id']}")
    print(f"  layer 1    {_fmt_bytes(sec['audio']['length'])}  (lossless audio payload)")
    print(f"  layer 2    {_fmt_bytes(sec['helix_arrays']['length'] + sec['helix_meta']['length'])}"
          f"  (helix side-channel — indexing only, not audio)")
    print(f"  size       source {_fmt_bytes(src_sz)}  ->  .bee {_fmt_bytes(bee_sz)} "
          f"({100*bee_sz/max(src_sz,1):.0f}% of source)")
    print(f"  lossless   bit-exact on decoded PCM (v0 placeholder coder; real "
          f"entropy coding is OPEN — blueprint §4a)")


def cmd_decode(args):
    out = args.out or (os.path.splitext(args.bee)[0] + ".wav")
    decode_bee_to_wav(args.bee, out)
    print(f"decoded: {args.bee} -> {out} ({_fmt_bytes(os.path.getsize(out))})")


def cmd_inspect(args):
    m = bee_info(args.bee)
    am, sc, sec = m["audio"], m["sidechannel"], m["sections"]
    print(f".bee format v{m['bee_format_version']}   created {m['created_at']}")
    print(f"  audio       {am['sample_rate']} Hz · {am['channels']} ch · {am['subtype']} "
          f"({am['dtype']}) · {am['frames']} frames ({_ts(am['frames']/am['sample_rate'])})")
    print(f"  codec       {am['codec']}   source_format {am.get('source_format')}")
    print(f"  sections    audio {_fmt_bytes(sec['audio']['length'])} · "
          f"helix_arrays {_fmt_bytes(sec['helix_arrays']['length'])} · "
          f"helix_meta {_fmt_bytes(sec['helix_meta']['length'])}")
    print(f"  sidechannel {sc['n_frames']} frames · fields {sc['stored_fields']} · "
          f"reconstructs_audio={sc['reconstructs_audio']}")
    print(f"  on disk     {_fmt_bytes(os.path.getsize(args.bee))}")
    print(f"  note        load latency is ns only if resident in RAM; µs from SSD; "
          f"ms over network (blueprint §3.4)")


def main(argv=None):
    p = argparse.ArgumentParser(prog="bee", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser("encode", help="audio file -> .bee")
    pe.add_argument("audio")
    pe.add_argument("-o", "--out", default=None)
    pe.add_argument("--bpm", type=float, default=None, help="override tempo estimate")
    pe.add_argument("--hop", type=int, default=1024)
    pe.add_argument("--n-fft", dest="n_fft", type=int, default=2048)
    pe.set_defaults(func=cmd_encode)

    pd = sub.add_parser("decode", help=".bee -> wav (lossless payload)")
    pd.add_argument("bee")
    pd.add_argument("-o", "--out", default=None)
    pd.set_defaults(func=cmd_decode)

    pi = sub.add_parser("inspect", help="print a .bee's manifest")
    pi.add_argument("bee")
    pi.set_defaults(func=cmd_inspect)

    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
