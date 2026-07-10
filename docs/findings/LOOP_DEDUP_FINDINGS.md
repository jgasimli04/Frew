# Loop-dedup findings — the side-channel is indexing on the wrong feature

**Date: 2026-06-22. Evidence for BEE_FORMAT_BLUEPRINT.md §4(b) and §6 step 4.**
Reproduce: `python3 analyze_loop_structure.py` (numbers below are from the three
helichain tracks). Engine + tests: `beehive/loops.py`, `tests/test_loops.py`.

## What was measured

Each track is cut into bars (one bar = one 2π helix turn = `B·60/bpm·sr` samples),
then bars are pooled three ways. "pool %" = fraction of bars that could be reused
from an earlier representative; "residual" = phase-invariant spectral difference
between a matched bar and its representative (the audio cost of reusing it).

## Result 1 — exact byte-dedup is 0% on mastered audio

| Track | bars | exact byte-identical dups |
|---|---|---|
| Liverpool Street | 90 | **0 (0.0%)** |
| Good Lies | 83 | **0 (0.0%)** |
| Night | 109 | **0 (0.0%)** |

Checked at the estimated tempo and at ×2 / ×0.5 alignment. The engine is correct
(a constructed copy-pasted-bar track dedups 60% and reconstructs bit-exact —
`tests/test_loops.py`); mastered **full mixes simply contain no byte-identical
bars**, because evolving layers and reverb tails overlay every repeat. So the
"free" exact-hash path (the §4b starting point) buys nothing on real music.

## Result 2 — chroma (what the side-channel stores today) is the wrong index

| Track | chroma pool @ resid | reading |
|---|---|---|
| Liverpool | 90% @ **35%** | matches bars that differ ~⅓ of their energy |
| Good Lies | 96% @ **22%** | over-pools |
| Night | 90% @ **38%** (347% at thr 0.90) | severe over-matching |

This is exp3 (`VERDICT.md`) confirmed at bar scale: chroma is **many-to-one in
timbre**, so chroma proximity ≠ audio proximity. Pooling by chroma would be badly
lossy. Chroma earns its keep for colour/visualisation, **not** as a reuse index.

## Result 3 — a discriminative, phase-invariant spectrum finds REAL repetition

Per-bar mean log-magnitude spectrum (does not fold octaves like chroma does):

| Track | spectrum pool @ resid (thr 0.98–0.99) |
|---|---|
| Liverpool | **77–81% pool @ 9% residual** |
| Good Lies | 83% pool @ 17% · 63% @ 13% |
| Night | 67% pool @ 17% · 46% @ 12% |

50–80% of bars are spectrally reusable at <20% phase-invariant residual — the
exploitable structure exact-hash and chroma both miss.

**Caveat (not yet proven — see `HANDOFF.md` §6a):** "reusable" here is suggestive,
not established. A high spectral pool % may reflect genre *homogeneity* (every bar
of one track shares synths/key/mastering) rather than true repetition — and the
pool % falls smoothly with threshold (Good Lies 83%→63%→2.4%) with no "N real loops"
plateau, which is what homogeneity, not discrete repeats, looks like. Needs a null
baseline (matched pairs vs randomly paired / cross-track bars) to confirm.

## Conclusion — the load-bearing decision this unlocks

1. **Change the reuse index from chroma to a discriminative spectral fingerprint.**
   Chroma stays for colour; reuse/dedup must key on a feature that is not
   many-to-one. (This does not yet pick a *threshold* — §4b stays open — but it
   does rule chroma out as the matcher, with numbers.)
2. **Then pick the reconstruction side — this is the real fork:**
   - **Lossless-residual:** store representative bar + an *exact* sample residual.
     Caveat: the <20% figure is **phase-invariant**; the exact (phase-sensitive)
     residual needs per-bar alignment and may be larger — measure actual residual
     compressibility before committing.
   - **Lossy/generative (the "NN derives clarity" vision):** store the spectral
     fingerprint + a representative; a neural vocoder generates phase and detail.
     The small phase-invariant residual is exactly the regime neural vocoders
     (HiFi-GAN; the EnCodec/DAC codec family) operate in — so the vision is
     **viable, conditioned on the discriminative spectrum, not chroma.**

Neither side is decided here (per §4 it must stay open); this supplies the
evidence. What is settled: the lossless FLAC floor (`beehive/beefile.py`) is the
fallback under both, and the segmentation/dedup engine (`beehive/loops.py`) is the
substrate for both.
