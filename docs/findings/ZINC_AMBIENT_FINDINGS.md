# Zinc Ambient Balance — the Laplace two-rail policy (T0 findings)

**Date: 2026-07-10.** Key generator: `beehive/zinc.py` (v2). Reproduce:
`.venv/bin/python scripts/zinc_report.py`; unit tests `tests/test_zinc.py`
(8, synthetic, deterministic). Corpus: the three real library tracks, full
length. Follows `ZINC_PHASE1_FINDINGS.md` (which found the single-threshold
rule over-anchors ambient 5–25%); resolves `BEE_ZINC_KEYFRAME_BLUEPRINT.md`
§8(b). This is T0 of `BEEDECK_ROADMAP.md`.

## 1. The mechanism (user steer: "balance the ambient out — Laplace, and Fourier")

Two rails, split by timescale:

- **Event rail (Laplace).** The z-scored state `S(t)` passes through the
  first-order high-pass `H(s) = s/(s+λ)`, discretized exactly under ZOH:
  `e[n] = exp(−λΔ)·e[n−1] + (S[n] − S[n−1])`. A key fires when `‖e[n]‖ > τ_e`.
  Wander slower than λ is attenuated by ~ω/λ and never fires; transients pass at
  unit gain. λ is tied to the track's own angular tempo (θ as fact).
- **Hard rail (the guarantee).** A key always fires when the absolute hold error
  `‖S[n] − S[last key]‖ > τ_max` — so ZOH reconstruction error ≤ τ_max at
  **every** frame, by construction. The Phase-1 bound survives, re-based.

Both rails reset on any key ("a key re-pins the prediction").

## 2. Fourier validation — where the ambient actually lives

Energy split of the normalized state spectrum (Hann, full track), cut at each
track's own bar/beat frequencies:

| track | below bar | bar→beat | beat→10 Hz | >10 Hz |
|---|---|---|---|---|
| Liverpool | 14.5% | 3.0% | **79.1%** | 3.5% |
| Good Lies | **70.2%** | 7.0% | 21.1% | 1.7% |
| Night | 43.9% | 7.8% | 44.7% | 3.7% |

Good Lies is the ambient-heavy floor case — 70% of its state variation is slower
than a bar, which is exactly why every absolute-threshold rule kept firing in
its calm regions. The event/ambient boundary that worked lands at **≈4.2–4.7 Hz
on all three tracks ≈ 2× the true beat frequency**: "ambient" = variation slower
than roughly half a beat.

## 3. The frozen default (grid-swept, then fixed)

`ZincPolicy.seeded`: `λ = 16·ω_bar(meta)`, `τ_e = 3·seed`, `τ_max = 6·seed`
(seed = the Phase-1 volatility·20 ms·φ quantity). Corpus result:

| track | keys | sparsity | ambient decile | monotone | max err ≤ τ_max | event/hard | index (24 B keys) |
|---|---|---|---|---|---|---|---|
| Liverpool | 788 | **18.2×** | **0.21%** | yes | 2.816 ≤ 2.818 ✓ | 445/342 | 3.4 KB/min |
| Good Lies | 322 | **21.4×** | **0.72%** | yes | 2.398 ≤ 2.402 ✓ | 290/31 | 2.9 KB/min |
| Night | 895 | **17.9×** | **0.13%** | yes | 2.500 ≤ 2.505 ✓ | 757/137 | 3.5 KB/min |

T0 DoD met on all three: ambient ≤ 1%, sparsity ≥ 10×, force-decile rate
monotone, bound holds. Versus Phase 1's best honest point (v1 @ ×4 seed:
10.5–18.8× with ambient 0.4–2.9%), v2 is sparser **and** quieter in ambient on
every track — Good Lies goes 2.9% → 0.72% while gaining sparsity 18.8× → 21.4×.

Synthetic guarantees (unit-tested, `tests/test_zinc.py`): constant state → one
key; a 60 s-period sine → **zero** event keys; a step fires **on** the step
frame; with ambient+transient mixtures every event key lands within 3 frames of
a transient — "unused space is never triggered," now a passing test, not a
slogan.

## 4. Caveats — carried honestly

- **λ inherits the bpm octave error.** The estimator returned half-tempo on all
  three tracks (e.g. Liverpool 64.6 vs true 128), a known `tempo.py` caveat. The
  swept κ=16 already *contains* that bias — expressed against true bpm it is
  κ≈8 (2× beat). If the estimator is fixed or `bpm=` is passed, re-derive κ.
  OPEN mitigation: an absolute-frequency clamp on λ when bpm confidence is low.
- **Top-decile key rate drops** (79–87% at seed → 24–35% at default): at 18–21×
  sparsity only ~5% of frames carry keys at all; concentration stays monotone in
  ‖F‖ and event keys stay transient-locked (the AV-trigger property).
- Mean error rises with sparsity (0.11–0.17 → 0.84–0.95, still < τ_max): τ_e/τ_max
  remain the R/D knobs; per-track overrides ride in the policy, which will be
  serialized with the keys (T1).
