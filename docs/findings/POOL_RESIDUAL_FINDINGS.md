# exp4 — pool + lossless residual vs FLAC: the offload thesis, measured

**Date: 2026-07-05. Evidence for BEE_FORMAT_BLUEPRINT.md §4(a)/(b) — the
measurement LOOP_DEDUP_FINDINGS.md explicitly left open ("the phase-sensitive
sample residual … is an OPEN measurement, not done here").**
Reproduce: `python3 experiments/exp4_pool_residual.py` (three helichain tracks).

## The question

The storage-offload thesis: a song = recall entries into a pool of canonical
bars; repeated bars stored as (reference, lag, gain) + exact residual. Does that
scheme, coded losslessly, beat plain FLAC in total bytes?

## Method

Bars segmented on the ω/bpm grid (`beehive/loops.py`); pooled by the same
discriminative spectral fingerprint and greedy cosine clustering as
LOOP_DEDUP_FINDINGS (thr 0.98 / 0.99). Each pooled bar coded as: best
cross-correlation lag (±4096 samples) + per-channel least-squares gain (12-bit
fixed point) against its representative, exact integer residual FLAC-coded
(24-bit). Reconstruction is exact by construction. **Null control** (the caveat
flagged in the earlier findings): identical residual coding against a *random*
earlier canonical bar instead of the matched one.

## Result — the lossless pool scheme LOSES on every track, at every threshold

| Track | pooled bars | pool scheme vs whole-track FLAC |
|---|---|---|
| Liverpool Street | 81% / 77% | **101.0% / 100.7%** |
| Good Lies | 83% / 63% | **101.0% / 100.7%** |
| Night | 67% / 46% | **101.5% / 100.7%** |

(thr 0.98 / 0.99. Per-bar chunking itself is free: Σ per-bar FLAC = +0.0% vs
whole-track — chunk granularity is not the problem.)

## Why — phase, quantified

The 9–17% residual in LOOP_DEDUP_FINDINGS was *phase-invariant* (magnitude
spectra). The exact time-domain residual after alignment and gain matching is
**83–99% of the bar's RMS** — subtracting the matched bar removes almost
nothing, because mastered repeats decorrelate in phase even when their spectra
nearly coincide. And the null control is damning: **matched-representative
residuals cost the same bytes as random-bar residuals to within 0.5%** (e.g.
Liverpool 24,274,587 vs 24,316,837 B). At the sample level, a fingerprint match
is no better a predictor than a random bar. The only partial exception is Night
(matched RMS 83% vs random 100%) — real structure exists there, but nowhere
near enough to pay for itself after entropy coding.

## What this settles and what it leaves open

1. **The lossless-residual branch of the §4(a)/(b) fork is dead on real
   mastered music.** Pool + exact residual is strictly worse than FLAC
   (100.7–101.5%). FLAC's intra-bar prediction already takes everything the
   time domain offers; inter-bar redundancy is not exploitable losslessly once
   phase diverges. Any "beehive offloads cloud storage" claim **cannot** be made
   for lossless audio on this evidence.
2. **The generative/lossy branch remains the only live path for loop reuse.**
   The 9–17% phase-invariant residual is real signal similarity; it is exactly
   the regime where neural vocoders (HiFi-GAN; EnCodec/DAC family) reconstruct
   from spectral evidence. But that is a *perceptual* codec claim, not a
   lossless one, and it competes with the neural-codec literature, not with
   FLAC. (BEE_NEURAL_PLAYBACK_ROADMAP.md is the relevant vision doc.)
3. Caveat on scope: three loop-based electronic masters, fixed-grid bars, one
   alignment/gain model per bar. Finer prediction (multi-tap, per-band, or
   within-track-only pools on unmastered stems) was not tested — stems before
   mastering are the one setting where lossless reuse might still exist, but
   that is a different product (DAW/label tooling), not consumer files.
