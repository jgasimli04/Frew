# exp5 — the neural base layer, measured on the three real tracks

**Date: 2026-07-06. Evidence for BEE_LIGHT_BLUEPRINT.md §4 (the quality gate).
Status: sizes MEASURED · quality PENDING THE USER'S EARS — no claim made.**
Reproduce: `.venv/bin/python experiments/exp5_neural_base.py` (weights cached
under `~/.cache/descript/dac/`; saved tokens in `experiments/recon/*.dac` are
reused, so reruns skip encoding).

## The question

Decision 2 of the refocus picked the neural route (DAC/EnCodec family) as the
`.bee` base-layer engine. Before any container work: what does a pretrained
DAC 44kHz model actually deliver on the three helichain tracks — real token
sizes, and reconstructions good enough to pass the user's ears?

## Method

DAC 44kHz **16kbps** model (Kumar et al. 2023; 18 RVQ codebooks × 1024
entries, hop 512), full codebook depth, stereo coded as two independent mono
streams (how `compress()` folds channels), MPS. Sizes are **packed** token
bits (10 bits/code), not the inflated uint16 `.dac` artifact. Listening pairs
(recon vs source) both normalized to −16 LUFS, PCM_24 — see "decode headroom"
below for why that matters.

## Result 1 — size: 22–30× lighter than the FLAC-weight .bee, ~32 kbps stereo

| track | min | src MB | .bee v0 MB | tokens MB | kbps | vs src | mel | msSTFT |
|---|---|---|---|---|---|---|---|---|
| Liverpool Street | 5.54 | 30.2 (flac) | 29.4 | **1.33** | 32.1 | 23× | 0.490 | 1.428 |
| Good Lies | 2.67 | 21.8 (flac) | 19.2 | **0.65** | 32.4 | 34× | 0.496 | 1.958 |
| Night | 6.19 | 65.5 (aiff) | 39.5 | **1.49** | 32.0 | 44× | 0.531 | 1.523 |

(vs the FLAC-weight `.bee` v0: 22× / 30× / 27×. mel/msSTFT are relative
reference numbers on the level-matched pairs — **not** transparency claims.)

Speed on M-series MPS: encode 10–19× realtime, decode ~6× realtime (55–61 s
for 5.5–6.2 min tracks) — decode is the heavier direction, relevant for the
native-playback gate later.

## Result 2 — decode headroom is a real format concern (bug caught, fixed)

A naive decode — restore original loudness, write 16-bit — **hard-clipped
3.9–5.9% of samples** on these tracks: at equal integrated loudness, DAC's
reconstruction overshoots the source's peak structure (recon peaks 0.58–0.76
vs source 0.37–0.49 at −16 LUFS), and mastered material leaves no headroom.
Pin for the container: **the `.bee` decode path must define an output
headroom / true-peak policy**; blind loudness restore into a fixed-point sink
is a correctness bug, not a taste choice.

## Result 3 — the gate itself: PENDING

Listening pairs in `experiments/recon/` (both sides −16 LUFS, PCM_24, A/B at
one volume):

- `<track>.dac-16kbps.wav` vs `<track>.source.wav` × 3

What to listen for, given how this model codes: stereo image stability (L/R
are quantized independently — image smear/wander is the most likely tell),
transient sharpness (hi-hats, claps), sub-bass punch, reverb-tail texture.

**Pass** → container build per BEE_LIGHT_BLUEPRINT §5 (base section in
`beefile.py`, bar-aligned token chunks, optional lossless residual, streaming
demo). **Fail at full depth** → the pretrained engine is insufficient as-is;
revisit decision 2 with this evidence (options: 8kbps-vs-16kbps A/B, mid/side
coding, or the proven-codec base).

## Scope caveats

Three loop-based electronic masters; one pretrained model (no fine-tuning);
dual-mono stereo; full 18-codebook depth only (the RVQ coarse-to-fine ladder —
fewer codebooks = lower quality tier — is measured only as arithmetic here,
not decoded); informal listening, not ABX/MUSHRA — formal tests gate any
*public* quality claim, per project norms. Token streams are raw RVQ indices;
further entropy coding of tokens (typically shaves ~10–20% in the literature)
is unmeasured here.
