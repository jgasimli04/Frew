"""Zinc key-generator evidence run (beehive/zinc.py, two-rail v2).

Per corpus track:
  * Fourier validation: energy split of the normalized state spectrum around
    the track's own bar/beat frequencies -- the measurement behind tying the
    event-rail leak ``lam`` to ``omega_bar`` (the Laplace high-pass cutoff);
  * v1 reference rows (hard rail only, seed tau and 4x seed) -- Phase-1 numbers;
  * the v2 policy grid: kappa_lambda x tau_event x tau_max, reporting anchors,
    sparsity, ambient-decile rate, force tracking, error stats, rail split;
  * acceptance marking: ambient <= 1% AND sparsity >= 10x AND bound holds.

Run:  .venv/bin/python scripts/zinc_report.py
"""

import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from beehive.encode import encode_song
from beehive.zinc import (
    ZincPolicy,
    _normalized_state,
    place_anchors,
    reconstruct_state,
    seed_tau,
    select_anchor_frames,
    state_spectrum_bands,
)

HOME = os.path.expanduser("~")
CORPUS = [
    f"{HOME}/Desktop/Music/15928052_Liverpool Street In The Rain_(Original Mix).flac",
    f"{HOME}/Desktop/Music/17574893_Good Lies_(Original Mix).flac",
    f"{HOME}/Desktop/Music/506206_Night_(Original Mix).aiff",
]

GRID_KAPPA = (0.5, 1.0, 2.0)
GRID_EVENT = (1.0, 1.5, 2.0)      # x seed
GRID_MAX = (4.0, 6.0)             # x seed


def recon_error(record, frames, params):
    muA, sA, muI, sI = params
    keys = sorted(frames)
    A = np.asarray(record.A, float)
    I = np.asarray(record.I, float)
    Ar = np.empty_like(A)
    Ir = np.empty_like(I)
    for j, f in enumerate(keys):
        end = keys[j + 1] if j + 1 < len(keys) else len(A)
        Ar[f:end] = A[f]
        Ir[f:end] = I[f]
    return np.hypot((A - Ar) / sA, (I - Ir) / sI)


def decile_rates(record, frames, n_bins=10):
    F = np.asarray(record.F_mag, np.float64)
    mask = np.zeros(record.n_frames, dtype=bool)
    mask[list(frames)] = True
    order = np.argsort(F, kind="stable")
    return [float(mask[b].mean()) for b in np.array_split(order, n_bins)]


def run_policy(rec, pol, hop_sec):
    frames, diag = select_anchor_frames(rec.A, rec.I, pol, hop_sec)
    err = recon_error(rec, frames, diag["params"])
    dec = decile_rates(rec, frames)
    n = rec.n_frames
    k = len(frames)
    return {
        "anchors": k,
        "comp": n / max(1, k),
        "ambient": dec[0],
        "top": dec[-1],
        "monotone": all(dec[i] <= dec[i + 1] + 0.02 for i in range(len(dec) - 1)),
        "err_max": float(err.max()),
        "err_mean": float(err.mean()),
        "n_event": len(diag["event_frames"]),
        "n_hard": len(diag["hard_frames"]),
    }


def analyze(path):
    name = os.path.splitext(os.path.basename(path))[0]
    rec = encode_song(path)
    meta = rec.meta
    hop_sec = meta["hop"] / meta["sr"]
    n = rec.n_frames
    dur = n * hop_sec
    t0 = seed_tau(rec.A, rec.I, hop_sec)
    omega_bar = 2.0 * math.pi * float(meta["bpm"]) / (60.0 * float(meta.get("B", 4)))

    print(f"\n=== {name} ===")
    print(f"  {dur:.1f} s, {n} frames @ {hop_sec*1000:.1f} ms | bpm {meta['bpm']:.2f} "
          f"| seed tau {t0:.4f} | omega_bar {omega_bar:.3f} rad/s")

    spec = state_spectrum_bands(rec.A, rec.I, hop_sec, omega_bar)
    print(f"  state spectrum: below-bar {spec['below_bar']*100:5.1f}%  "
          f"bar..beat {spec['bar_to_beat']*100:5.1f}%  "
          f"beat..10Hz {spec['beat_to_10hz']*100:5.1f}%  "
          f">10Hz {spec['above_10hz']*100:5.1f}%   "
          f"(f_bar {spec['f_bar']:.3f} Hz, f_beat {spec['f_beat']:.2f} Hz)")

    print(f"  {'policy':28s} {'keys':>6} {'comp':>7} {'amb%':>6} {'top%':>6} "
          f"{'mono':>5} {'maxE':>6} {'meanE':>6} {'ev/hard':>11}")

    def show(label, pol, mark=False):
        r = run_policy(rec, pol, hop_sec)
        ok = (r["ambient"] <= 0.01 and r["comp"] >= 10.0
              and r["err_max"] <= pol.tau_max + 1e-9)
        flag = " <<" if (mark and ok) else ("  *" if ok else "")
        print(f"  {label:28s} {r['anchors']:>6} {r['comp']:>6.1f}x "
              f"{r['ambient']*100:>5.2f} {r['top']*100:>5.1f} "
              f"{str(r['monotone'])[:1]:>5} {r['err_max']:>6.3f} {r['err_mean']:>6.3f} "
              f"{r['n_event']:>5}/{r['n_hard']:<5}{flag}")
        return r, ok

    # v1 reference rows (hard rail only)
    show("v1 hard-only tau=seed", ZincPolicy(math.inf, t0, 0.0, version=1))
    show("v1 hard-only tau=4xseed", ZincPolicy(math.inf, 4.0 * t0, 0.0, version=1))

    # v2 grid
    results = {}
    for kap in GRID_KAPPA:
        for ev in GRID_EVENT:
            for mx in GRID_MAX:
                pol = ZincPolicy(ev * t0, mx * t0, kap * omega_bar)
                label = f"v2 k={kap:<3} te={ev:<3} tm={mx:<3}"
                results[(kap, ev, mx)], _ = show(label, pol)

    # the shipped default
    pol = ZincPolicy.seeded(rec)
    r_def, ok = show("v2 DEFAULT (seeded)", pol, mark=True)
    keys = place_anchors(rec, pol)
    kb_min = len(keys) * 12 / (dur / 60.0)
    kb_full = len(keys) * 24 / (dur / 60.0)
    print(f"  default index size: {kb_min:.0f} B/min (12B key) / {kb_full:.0f} B/min (24B key)")
    return name, r_def, ok


def main():
    rows = []
    for path in CORPUS:
        if not os.path.exists(path):
            print(f"!! missing: {path}")
            continue
        rows.append(analyze(path))

    print("\n=== summary: v2 DEFAULT (ZincPolicy.seeded) ===")
    print(f"{'track':40s} {'keys':>6} {'comp':>7} {'amb%':>6} {'ev/hard':>11} {'accept':>7}")
    for name, r, ok in rows:
        print(f"{name[:40]:40s} {r['anchors']:>6} {r['comp']:>6.1f}x "
              f"{r['ambient']*100:>5.2f} {r['n_event']:>5}/{r['n_hard']:<5} {str(ok):>7}")


if __name__ == "__main__":
    main()
