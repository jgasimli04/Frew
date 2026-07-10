"""Phase 1 evidence for the zinc-finger key generator (beehive/zinc.py).

Encodes each corpus track, generates zinc keys at the seed tau, and reports:
  * anchor count / density / state-compression ratio;
  * reconstruction error in tau-units (must be <= tau -- the design guarantee);
  * anchor rate per ||F|| decile (anchors must track force; the ambient decile
    must be ~0 -- "unused space is never triggered");
  * index size (bytes/min) -- the axis-1a metric;
  * a mini tau-sweep, previewing the rate-distortion knob (blueprint 6, Phase 5).

Run:  .venv/bin/python scripts/zinc_report.py
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from beehive.encode import encode_song
from beehive.zinc import (
    _normalized_state,
    place_anchors,
    reconstruct_state,
    seed_tau,
)

HOME = os.path.expanduser("~")
CORPUS = [
    f"{HOME}/Desktop/Music/15928052_Liverpool Street In The Rain_(Original Mix).flac",
    f"{HOME}/Desktop/Music/17574893_Good Lies_(Original Mix).flac",
    f"{HOME}/Desktop/Music/506206_Night_(Original Mix).aiff",
]


def recon_error(record, keys, params):
    """Per-frame reconstruction error in the same normalized units as tau."""
    muA, sA, muI, sI = params
    Ar, Ir = reconstruct_state(keys, record.n_frames)
    dA = (np.asarray(record.A) - Ar) / sA
    dI = (np.asarray(record.I) - Ir) / sI
    return np.hypot(dA, dI)


def force_decile_anchor_rate(record, keys, n_bins=10):
    """Anchor rate within each ||F|| decile (low force -> high force)."""
    F = np.asarray(record.F_mag, dtype=np.float64)
    mask = np.zeros(record.n_frames, dtype=bool)
    mask[[k.frame for k in keys]] = True
    order = np.argsort(F, kind="stable")
    buckets = np.array_split(order, n_bins)
    return [float(mask[b].mean()) for b in buckets]


def analyze(path):
    name = os.path.splitext(os.path.basename(path))[0]
    rec = encode_song(path)
    n = rec.n_frames
    hop_sec = rec.meta["hop"] / rec.meta["sr"]
    dur = n * hop_sec

    _, params = _normalized_state(rec.A, rec.I)
    tau = seed_tau(rec.A, rec.I, hop_sec)
    keys = place_anchors(rec, tau)
    err = recon_error(rec, keys, params)
    deciles = force_decile_anchor_rate(rec, keys)

    n_keys = len(keys)
    print(f"\n=== {name} ===")
    print(f"  duration            {dur:8.1f} s   ({n} frames @ {hop_sec*1000:.1f} ms)")
    print(f"  seed tau            {tau:8.4f}  (normalized-state units)")
    print(f"  anchors             {n_keys:8d}   ({n_keys/dur:.2f} /s)")
    print(f"  state compression   {n/max(1,n_keys):8.1f}x  (frames per key)")
    print(f"  recon error  max    {err.max():8.4f}   mean {err.mean():.4f}   "
          f"<= tau: {err.max() <= tau + 1e-9}")
    # index size: minimal key = frame(u32)+a+i (12B); full = +r,theta,z (24B)
    for label, kb in (("minimal 12B", 12), ("full 24B", 24)):
        print(f"  index size {label:>11}  {n_keys*kb/ (dur/60):8.0f} B/min")
    print(f"  ||F|| decile anchor-rate (low->high force):")
    print("    " + "  ".join(f"{d*100:4.1f}%" for d in deciles))
    print(f"    ambient (bottom decile): {deciles[0]*100:.2f}%   "
          f"top decile: {deciles[-1]*100:.1f}%")

    print(f"  tau sweep (x seed -> anchors, compression):")
    for mult in (0.5, 1.0, 2.0, 4.0, 8.0):
        ks = place_anchors(rec, tau * mult)
        print(f"    x{mult:<4} tau={tau*mult:7.4f}  "
              f"anchors={len(ks):6d}  {n/max(1,len(ks)):6.1f}x")
    return name, n, n_keys, tau, float(err.max()), deciles[0]


def main():
    rows = []
    for path in CORPUS:
        if not os.path.exists(path):
            print(f"!! missing: {path}")
            continue
        rows.append(analyze(path))

    print("\n=== summary ===")
    print(f"{'track':40s} {'frames':>8} {'keys':>7} {'comp':>7} "
          f"{'maxErr<=tau':>11} {'ambient%':>9}")
    for name, n, k, tau, mx, amb in rows:
        print(f"{name[:40]:40s} {n:>8} {k:>7} {n/max(1,k):>6.1f}x "
              f"{str(mx <= tau + 1e-9):>11} {amb*100:>8.2f}%")


if __name__ == "__main__":
    main()
