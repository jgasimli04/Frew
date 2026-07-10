"""exp4 — the OPEN measurement from LOOP_DEDUP_FINDINGS: pool + exact residual vs FLAC.

The "beehive offloads server storage" thesis says: store each recurring loop once
(a pool of canonical bars), and store every other bar as a *reference + residual*.
LOOP_DEDUP_FINDINGS Result 3 showed 50-80% of bars pool at <20% residual — but that
residual was PHASE-INVARIANT (magnitude spectra), and the lossless path pays the
phase-SENSITIVE sample residual instead, "which needs per-bar alignment and is
generally larger — that is an OPEN measurement, not done here." This is that
measurement, in actual coded bytes:

  A. whole-track FLAC                    (what .bee Layer 1 stores today)
  B. sum of per-bar FLAC                 (chunked baseline: cost of bar granularity)
  C. pool scheme: canonical bars FLAC'd + pooled bars as (rep, lag, gain) + exact
     residual FLAC'd (24-bit)            (the offload thesis, lossless by construction)

Per pooled bar: representative = its fingerprint match (greedy cosine pool at THR,
same fingerprint & code as analyze_loop_structure); alignment = best cross-
correlation lag within ±MAX_LAG; gain = per-channel least-squares alpha quantized
to 12-bit fixed point; residual = bar - round(alpha * shifted_rep), coded FLAC.
Reconstruction is exact by construction (residual + prediction = bar, integers).

NULL CONTROL (the caveat flagged in the findings): the same residual cost against a
RANDOM earlier canonical bar instead of the matched one. If matched ~= random, the
fingerprint match reflects genre homogeneity, not real repetition.

    python3 experiments/exp4_pool_residual.py
"""

import glob
import io
import json
import os
import sys

import numpy as np
import soundfile as sf

import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))      # sibling experiments

import analyze_loop_structure as als
from beehive.beefile import _read_source_pcm
from beehive.loops import bar_length_samples, segment_bars

THRESHOLDS = [0.98, 0.99]   # the pool thresholds Result 3 highlighted
MAX_LAG = 4096              # ~93 ms at 44.1k — microtiming alignment window
ALPHA_BITS = 12
ENTRY_BYTES = 12            # rep index u32 + lag i32 + 2 x alpha i16


def flac_len(x_int16, sr):
    buf = io.BytesIO()
    sf.write(buf, x_int16, sr, subtype="PCM_16", format="FLAC")
    return len(buf.getvalue())


def flac_len_residual(res_int32, sr):
    """Residuals exceed int16 range (up to bar + 2x rep); code as 24-bit FLAC."""
    buf = io.BytesIO()
    sf.write(buf, (res_int32 << 8).astype(np.int32), sr, subtype="PCM_24", format="FLAC")
    return len(buf.getvalue())


def best_lag(a, b, max_lag):
    """Lag maximizing cross-correlation of mono signals a,b (b shifted by +lag)."""
    n = len(a) + len(b)
    nfft = 1 << (n - 1).bit_length()
    xc = np.fft.irfft(np.fft.rfft(a, nfft) * np.conj(np.fft.rfft(b, nfft)), nfft)
    cand = np.concatenate([xc[: max_lag + 1], xc[-max_lag:]])
    k = int(np.argmax(cand))
    return k if k <= max_lag else k - (2 * max_lag + 1)


def shift_int(x, lag):
    """x shifted by +lag samples (zeros in), same length. x is (n, ch) int."""
    out = np.zeros_like(x)
    if lag >= 0:
        out[lag:] = x[: len(x) - lag] if lag < len(x) else 0
    else:
        out[:lag] = x[-lag:]
    return out


def residual_against(bar, rep, sr):
    """Exact integer residual of bar vs aligned, gain-matched rep.

    Returns (residual bytes when FLAC'd, time-domain RMS ratio residual/bar)."""
    mono_bar = bar.astype(np.float64).mean(axis=1)
    mono_rep = rep.astype(np.float64).mean(axis=1)
    lag = best_lag(mono_bar, mono_rep, MAX_LAG)
    shifted = shift_int(rep.astype(np.int64), lag)

    pred = np.zeros_like(shifted)
    scale = 1 << ALPHA_BITS
    for c in range(bar.shape[1]):
        s = shifted[:, c].astype(np.float64)
        denom = float(s @ s)
        alpha = float(bar[:, c].astype(np.float64) @ s) / denom if denom > 0 else 0.0
        aq = int(round(np.clip(alpha, -2.0, 2.0) * scale))
        pred[:, c] = (aq * shifted[:, c] + (scale >> 1)) >> ALPHA_BITS

    res = (bar.astype(np.int64) - pred).astype(np.int32)
    rms_bar = float(np.sqrt((bar.astype(np.float64) ** 2).mean())) or 1.0
    rms_res = float(np.sqrt((res.astype(np.float64) ** 2).mean()))
    return flac_len_residual(res, sr), rms_res / rms_bar


def run_track(jf, rng):
    meta = json.load(open(jf))
    sp = meta["source_path"]
    if not os.path.exists(sp):
        print(f"{meta['song_id']}: source missing\n")
        return
    pcm, am = _read_source_pcm(sp)
    if am["dtype"] != "int16":
        print(f"{meta['song_id']}: skipping non-int16 source ({am['dtype']})\n")
        return
    sr = am["sample_rate"]
    spb = bar_length_samples(meta)
    segs = segment_bars(pcm.shape[0], spb)
    spectra = als.bar_spectra(sp, meta["sr"], meta["hop"], meta["n_fft"], segs)

    size_whole = flac_len(pcm, sr)
    bar_flac = [flac_len(pcm[s:e], sr) for (s, e) in segs]
    size_chunked = sum(bar_flac)

    print(f"{meta['song_id'][:52]}")
    print(f"  {len(segs)} bars @ {spb} samples · whole-track FLAC {size_whole:,} B · "
          f"per-bar FLAC {size_chunked:,} B (+{100*(size_chunked/size_whole-1):.1f}% chunking cost)")

    for thr in THRESHOLDS:
        labels = als.greedy_pool(spectra, thr)
        canon_bytes = pooled_bytes = null_bytes = 0
        n_pooled = 0
        rms_matched, rms_null = [], []
        canonical_idx = []

        for k, (s, e) in enumerate(segs):
            bar = pcm[s:e]
            full = (e - s) == spb
            if labels[k] == k or not full:
                canon_bytes += bar_flac[k]
                canonical_idx.append(k)
                continue
            n_pooled += 1
            rs, re_ = segs[labels[k]]
            nbytes, rr = residual_against(bar, pcm[rs:re_], sr)
            pooled_bytes += nbytes + ENTRY_BYTES
            rms_matched.append(rr)
            # null control: random earlier canonical bar as the "match"
            js = [j for j in canonical_idx if (segs[j][1] - segs[j][0]) == spb]
            if js:
                j = js[rng.integers(len(js))]
                nb2, rr2 = residual_against(bar, pcm[segs[j][0]:segs[j][1]], sr)
                null_bytes += nb2 + ENTRY_BYTES
                rms_null.append(rr2)

        total = canon_bytes + pooled_bytes
        vs_whole = 100 * total / size_whole
        vs_chunk = 100 * total / size_chunked
        md = lambda v: f"{100*np.median(v):.0f}%" if v else "n/a"
        print(f"  thr {thr:.2f}: pooled {n_pooled}/{len(segs)} bars "
              f"({100*n_pooled/len(segs):.0f}%)")
        print(f"    pool scheme total {total:,} B = {vs_whole:.1f}% of whole-FLAC, "
              f"{vs_chunk:.1f}% of chunked-FLAC")
        print(f"    residual RMS (time-domain, aligned+gain): matched {md(rms_matched)}"
              f" vs random-rep {md(rms_null)}"
              f"   residual bytes: matched {pooled_bytes:,} vs random {null_bytes:,}")
    print()


def main():
    rng = np.random.default_rng(20260705)
    hc = os.path.expanduser("~/sonoFaig/helichain")
    for jf in sorted(glob.glob(os.path.join(hc, "records", "*.json"))):
        run_track(jf, rng)
    print("Reading: the offload thesis wins only if 'pool scheme total' < 100% of "
          "whole-FLAC. 'matched vs random-rep' close together = fingerprint match is "
          "genre homogeneity, not real reusable repetition (the flagged caveat).")


if __name__ == "__main__":
    main()
