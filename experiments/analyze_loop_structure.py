"""Loop-structure evidence for the §4(b) decision — numbers, not vibes.

Exact byte-dedup finds 0 repeats on mastered mixes (test: tracks overlay evolving
layers, so no two bars are byte-identical). The open question (BEE_FORMAT_BLUEPRINT
§4b) is whether the *side-channel* finds the musical repetition that bytes miss —
i.e. whether chroma is a usable near-duplicate index — and, critically, whether a
chroma "match" corresponds to actually-similar audio or to exp3's many-to-one
blur (different sound, same chroma).

For each track it pools bars two ways and compares, per cosine-similarity
threshold:
  - by CHROMA (what the side-channel stores today), and
  - by a discriminative, phase-invariant SPECTRAL fingerprint (mean log-magnitude
    spectrum per bar; unlike chroma it does not fold octaves together).
For each it reports:
  - pool %   -> potential dedup = 1 - clusters/total if matched bars were reused;
  - residual -> median ||spec_bar - spec_rep|| / ||spec_rep||, the *phase-invariant*
    audio difference between a matched bar and its representative.

The residual is deliberately phase-invariant (magnitude only): that is the cost
the GENERATIVE path faces (a neural vocoder regenerates phase). The LOSSLESS path
faces the phase-SENSITIVE sample residual instead, which needs per-bar alignment
and is generally larger — that is an OPEN measurement, not done here. This script
does NOT pick a threshold or a side of §4(b); it supplies the evidence to.

    python3 analyze_loop_structure.py
"""

import glob
import json
import os

import numpy as np

import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root, for `beehive`

from beehive.audio import load_audio
from beehive.beefile import _read_source_pcm
from beehive.features import frame_signal, stft_mag
from beehive.loops import bar_length_samples, dedup_report, segment_bars

THRESHOLDS = [0.90, 0.95, 0.98, 0.99, 0.999]


def bar_chroma(chroma, hop, segs):
    """Mean chroma vector per bar (averaging the frames spanning the bar's samples)."""
    out = []
    for (start, end) in segs:
        f0 = start // hop
        f1 = max(f0 + 1, end // hop)
        out.append(chroma[f0:min(f1, len(chroma))].mean(axis=0))
    return np.asarray(out)


def bar_spectra(path, sr_meta, hop, n_fft, segs):
    """Per-bar mean log-magnitude spectrum — a discriminative, phase-invariant
    fingerprint (unlike chroma, it does not fold octaves together). Returned
    L2-normalized so cosine similarity is meaningful, plus the raw means for a
    spectral (phase-invariant) residual."""
    y, sr = load_audio(path, mono=True)
    window = np.hanning(n_fft).astype(np.float32)
    mag = stft_mag(frame_signal(y, n_fft, hop), n_fft, window)   # (frames, bins)
    logmag = np.log1p(mag)
    out = []
    for (start, end) in segs:
        f0 = start // hop
        f1 = max(f0 + 1, end // hop)
        out.append(logmag[f0:min(f1, len(logmag))].mean(axis=0))
    return np.asarray(out)


def spectral_residual(spectra, labels, segs, spb):
    """Median phase-invariant residual: ||spec_bar - spec_rep|| / ||spec_rep||."""
    res = []
    for k, (start, end) in enumerate(segs):
        if labels[k] == k or (end - start) != spb:
            continue
        a, b = spectra[k], spectra[labels[k]]
        denom = np.linalg.norm(b) or 1.0
        res.append(np.linalg.norm(a - b) / denom)
    return float(np.median(res)) if res else None


def greedy_pool(vecs, thr):
    """Greedy cosine clustering: a bar joins the first cluster whose representative
    it matches >= thr, else opens a new cluster. Returns labels + rep index per bar."""
    reps, rep_idx, labels = [], [], []
    for j, v in enumerate(vecs):
        n = np.linalg.norm(v)
        u = v / n if n > 0 else v
        best, bi = -1.0, -1
        for i, r in enumerate(reps):
            s = float(u @ r)
            if s > best:
                best, bi = s, i
        if best >= thr:
            labels.append(rep_idx[bi])
        else:
            reps.append(u)
            rep_idx.append(j)
            labels.append(j)
    return labels


def main():
    hc = os.path.expanduser("~/sonoFaig/helichain")
    for jf in sorted(glob.glob(os.path.join(hc, "records", "*.json"))):
        meta = json.load(open(jf))
        sp = meta["source_path"]
        if not os.path.exists(sp):
            print(f"{meta['song_id']}: source missing\n")
            continue
        npz = jf[:-5] + ".npz"
        chroma = np.load(npz)["chroma"]
        hop = meta["hop"]

        pcm, am = _read_source_pcm(sp)
        spb = bar_length_samples(meta)
        segs = segment_bars(pcm.shape[0], spb)
        rep = dedup_report(pcm, spb)
        bars = bar_chroma(chroma, hop, segs)
        spectra = bar_spectra(sp, meta["sr"], hop, meta["n_fft"], segs)

        print(f"{meta['song_id'][:52]}")
        print(f"  {am['subtype']} {am['channels']}ch · bpm {meta['bpm']:.1f} · "
              f"{rep['total_bars']} bars · exact-dup {rep['duplicate_bars']} "
              f"({rep['dedup_ratio']*100:.1f}%)")
        print(f"  {'thr':>5}   chroma(many-to-one)        spectrum(discriminative,phase-inv)")
        for thr in THRESHOLDS:
            cl = greedy_pool(bars, thr)
            sl = greedy_pool(spectra, thr)
            cmr = spectral_residual(spectra, cl, segs, spb)   # audio cost of chroma reuse
            smr = spectral_residual(spectra, sl, segs, spb)   # audio cost of spectral reuse
            cmr_s = "n/a" if cmr is None else f"{cmr*100:3.0f}%"
            smr_s = "n/a" if smr is None else f"{smr*100:3.0f}%"
            print(f"  {thr:5.3f}   pool {(1-len(set(cl))/len(cl))*100:4.1f}% resid {cmr_s:>4}"
                  f"      pool {(1-len(set(sl))/len(sl))*100:4.1f}% resid {smr_s:>4}")
        print()
    print("Reading: 'pool %' = potential dedup if matched bars were reused; 'resid' = "
          "phase-invariant audio difference between a matched bar and its representative.\n"
          "Low pool% OR high resid => no free lunch: chroma over-matches (exp3), and if "
          "even the discriminative spectrum finds no low-resid matches, these mastered "
          "mixes have no reusable bars. This is the §4(b) evidence.")


if __name__ == "__main__":
    main()
