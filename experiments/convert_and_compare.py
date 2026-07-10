"""Convert lossless audio -> the helix geometry (as a single-file format) -> audio.

The point of this script is the *measurement* the project was missing: take a
lossless track, store ONLY the helix geometry (A, I, chroma) as the file, decode
that geometry back to sound, and report the trade -- how much smaller, and how
much quality is kept -- with the numbers and an audio file you can listen to.

It does not render a verdict. It builds the instrument and prints what it reads.

Run:
    .venv/bin/python convert_and_compare.py "/Users/jgasimli/Desktop/Music/<song>"
    [--start 60] [--dur 25]
"""

import argparse
import json
import os

import numpy as np
import soundfile as sf

import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root, for `beehive`

from beehive.audio import load_audio
from beehive.encode import encode_song
from beehive.synth import geometry_to_audio


def save_geometry(record, path):
    """Single-file .beegeo container: compressed A, I, chroma + the meta JSON.

    This is 'the geometry as a file format' -- one self-contained file, no audio
    payload riding alongside. float32 + npz/zlib is the v0 size; integer
    quantization would shrink it further (noted, not done here -- keep it lean).
    """
    meta_bytes = np.frombuffer(json.dumps(record.meta).encode("utf-8"), dtype=np.uint8)
    np.savez_compressed(
        path,
        A=record.A.astype(np.float32),
        I=record.I.astype(np.float32),
        chroma=record.chroma.astype(np.float32),
        meta=meta_bytes,
    )


def log_spectral_distance(ref, est, n_fft=2048, hop=512):
    """Mean per-frame RMS distance between log-magnitude spectra, in dB.

    This is the honest fidelity number: it compares the decoded audio to the
    ORIGINAL, in the spectral domain where the geometry threw information away.
    (Loudness/centroid/chroma 'tracking' would be circular -- the decoder hits
    those by construction -- so they are not used as the quality score.)
    """
    def logmag(y):
        if len(y) < n_fft:
            y = np.pad(y, (0, n_fft - len(y)))
        w = np.hanning(n_fft).astype(np.float64)
        idx = range(0, len(y) - n_fft + 1, hop)
        S = np.stack([np.abs(np.fft.rfft(y[i:i + n_fft] * w)) for i in idx])
        return 20.0 * np.log10(S + 1e-6)

    n = min(len(ref), len(est))
    LR, LE = logmag(ref[:n]), logmag(est[:n])
    m = min(len(LR), len(LE))
    return float(np.sqrt(((LR[:m] - LE[:m]) ** 2).mean()))


def human(nbytes):
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024 or unit == "GB":
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--start", type=float, default=60.0, help="excerpt start (s)")
    ap.add_argument("--dur", type=float, default=25.0, help="excerpt length (s)")
    ap.add_argument("--bpm", type=float, default=None, help="override tempo estimate")
    args = ap.parse_args()

    src = os.path.expanduser(args.source)
    stem = os.path.splitext(os.path.basename(src))[0]
    # recon/ lives next to this script (experiments/recon), independent of cwd
    outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recon", stem)
    os.makedirs(outdir, exist_ok=True)

    print(f"\n=== {stem} ===")
    print("encoding lossless audio -> helix geometry ...")
    record = encode_song(src, bpm=args.bpm)

    geo_path = os.path.join(outdir, stem + ".beegeo.npz")
    save_geometry(record, geo_path)

    src_bytes = os.path.getsize(src)
    geo_bytes = os.path.getsize(geo_path)
    dur = float(record.meta["duration_s"])
    nF = record.n_frames

    print("\n-- SIZE (the geometry as the whole file) --")
    print(f"  source (lossless) : {human(src_bytes):>10}   ({record.meta['sr']} Hz, "
          f"{dur:.0f}s)")
    print(f"  geometry (.beegeo): {human(geo_bytes):>10}   ({nF} frames x 14 floats)")
    print(f"  size ratio        : {src_bytes / geo_bytes:>9.1f}x smaller")
    print(f"  geometry bitrate  : {geo_bytes * 8 / dur / 1000:>9.1f} kbps "
          f"(vs ~{src_bytes * 8 / dur / 1000:.0f} kbps lossless)")

    # --- decode an excerpt and compare to the ORIGINAL excerpt ---
    print(f"\ndecoding geometry -> audio (excerpt {args.start:.0f}-"
          f"{args.start + args.dur:.0f}s) ...")
    recon, sr = geometry_to_audio(record, start_s=args.start, dur_s=args.dur)
    peak = np.max(np.abs(recon)) or 1.0
    recon_norm = recon / peak * 0.95

    y, _ = load_audio(src, mono=True)
    s0 = int(args.start * sr)
    orig = y[s0:s0 + len(recon)]

    lsd = log_spectral_distance(orig.astype(np.float64), recon.astype(np.float64))

    recon_wav = os.path.join(outdir, f"{stem}_DECODED_{int(args.start)}s.wav")
    orig_wav = os.path.join(outdir, f"{stem}_ORIGINAL_{int(args.start)}s.wav")
    sf.write(recon_wav, recon_norm, sr)
    sf.write(orig_wav, orig, sr)

    print("\n-- QUALITY (decoded vs ORIGINAL, the honest direction) --")
    print(f"  log-spectral distance : {lsd:6.2f} dB  (0 = identical; lower is closer)")
    print(f"  not captured by A/I/chroma: phase, fine spectrum, transients, stereo")
    print(f"  real size yardstick is a LOSSY codec (Opus/AAC) at the quality you")
    print(f"  actually hear -- not the lossless source. (Not benchmarked here.)")

    print("\n-- LISTEN (A/B the same 25s) --")
    print(f"  original: {orig_wav}")
    print(f"  decoded : {recon_wav}")
    print()


if __name__ == "__main__":
    main()
