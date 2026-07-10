# Beehive Vocoder — Prototype Day Verdict (2026-06-20)

Build session against `BEEHIVE_BLUEPRINT.md`, Opus max effort. Everything below
is from real runs with PyTorch autograd (torch 2.12.1, MPS available) — not
finite differences, not memory. All experiments are seeded and reproducible.

**Definition of done (blueprint §6):** steps 1–3 with real autograd, the f0
non-convexity question answered with numbers, and a written yes/no verdict on the
step-4 synthetic sanity check. All three delivered below.

---

## TL;DR — the numbers and the yes/nos

| Question | Answer | Key number |
|---|---|---|
| Does formant-shape → chroma train cleanly with real autograd? | **YES** | loss 0.242 → ~1e-9, 92% non-increasing steps, no NaN |
| Is the f0 → chroma landscape non-convex/multimodal? | **YES** | 9 prominent local minima in [80, 600] Hz |
| Does a better *optimizer alone* solve f0? | **NO** | plain GD 0/24, Adam 2/24 inits hit true f0 |
| Do *restarts / grid warm-start* solve f0? | **YES** | best-of-24 and grid→Adam both → 220.00 Hz (±0 cents) |
| Recover source from the **full spectral** axis (dense, STFT-like)? | **f0 ✓, formants ✓** | f0 +0.0¢, formant centers 0 Hz error (in-model, noise-free) |
| Recover source from the **chroma** axis (the novel *compression*)? | **f0 ✓, formant shape ✗** | f0 +0.0¢ (needs restarts); formant center **102 Hz off** at chroma-loss 1.1e-8 |

**Prototype-day deliverable: COMPLETE.** All three §6 items are delivered — the
pipeline is differentiable end to end under real autograd, the f0 question is
answered with numbers, and the step-4 sanity check has a written, per-quantity
verdict.

**The representation result is SPLIT — and the split is the finding.** The axis
that came back fully invertible is the *full spectral render*: essentially a dense
magnitude spectrum, i.e. the STFT-like representation this project exists to
**beat**. The novel **chroma compression axis is where information is lost** — it
recovers f0 (given restarts) but is **many-to-one in timbre**: a different formant
shape produces the same chroma vector. For a "lighter than STFT" thesis that
locates the open problem precisely — the *compression* step, not the optimizer, is
what needs work next. This isn't a failure; it's the prototype showing you where
the hard part lives.

---

## 0. Bonus finding — a real typo in the spec's curvature formula

While porting the geometry I re-derived κ and τ **independently** in sympy
(`verify_geometry.py`) rather than transcribing the stated closed forms (the
project's verify-don't-guess norm — transcribing and testing formula==formula
would have blessed the bug). Result:

- The stated **torsion τ is correct.**
- The stated **curvature κ had a typo**: the term under the square root read
  `ω²r₀²` but must be **`ω⁴r₀²`** (it is the same geometric quantity
  `|R′×R″|²/(r₀ω)²` that appears, correctly, in τ's denominator — so the two
  had to match and didn't). Invisible at ω=1, which is how it survived an
  earlier "sympy-verified" pass.

sympy confirms: derived κ ≠ stated κ, derived κ = corrected κ. The torch
implementation (using `ω⁴r₀²`) matches sympy to 1e-9 at ω=1.5, and the static
sanity check gives τ=0, κ=1/r₀ as it must. **Both `SKILL.md` and
`BEEHIVE_BLUEPRINT.md` now carry the corrected formula** (verified by grep);
`beehive/helix.py` was correct from the start.

> Note: the `SKILL.md` edit was made by an external subagent I did not spawn
> (the harness flagged it as a self-modification-of-agent-config concern). I
> verified the change directly — it is the correct one-character fix
> (`ω²r₀² → ω⁴r₀²` under the root only) and matches the sympy derivation. Likely
> user-triggered, but flagging it since it touched your agent config.

```
correct:  κ(n) = ω·r₀·√(ω⁴r₀² + ω²h′² + h″²) / (ω²r₀² + h′²)^(3/2)
          τ(n) = ω·(ω²h′ + h‴) / (ω⁴r₀² + ω²h′² + h″²)
```

(The `(ω²r₀² + h′²)` in κ's denominator is the speed term `|R′|²` and is
correctly `ω²r₀²` — only the under-root term was wrong.)

---

## 1. Scaffold (blueprint §3.1) — done

`beehive/` package, all PyTorch-differentiable:

- `helix.py` — `helix_position`, `curvature_torsion` (corrected closed forms).
- `formant.py` — `formant_envelope` (sum of Gaussian resonances, linear Hz).
- `chroma.py` — `soft_chroma_projection` (differentiable, periodic Gaussian
  kernel) and `hard_chroma_projection` (visualization only, no f0 gradient).
- `signals.py` — `synth_harmonic_spectrum` (source–filter harmonic tone).
- `verify_geometry.py` — the independent sympy κ/τ derivation above.

## 2. Differentiability regression: formant shape → chroma (blueprint §3.2)

`exp1_formant_chroma.py`. 6 learnable params (2 formants × center/width/gain),
f0 fixed, Adam, 300 steps.

- loss **0.242 → ~1e-9** (100% reduction), **92%** of steps non-increasing.
- grad norm 1.8e-1 → 7.5e-6, **no NaN/inf**.
- **PASS** — converges cleanly with exact gradients, even harder than the prior
  finite-diff run (0.458 → 0.138). Don't read into the exact final value; a
  different optimizer + exact gradients give a different trajectory (per the
  pass criterion: large smooth drop, sane grads).
- **Note carried forward:** chroma loss hit ~0 while the recovered formant-1
  center was 729 vs true 600 Hz — first sign that **formant → chroma is
  many-to-one**. Confirmed in exp3.

## 3. f0 non-convexity, properly powered (blueprint §3.3) — the open question

`exp2_f0_landscape.py`. True f0 = 220 Hz, fixed formants, soft chroma (σ=0.5),
search [80, 600] Hz. Apples-to-apples: one shared seeded set of 24 inits, fixed
600-step budget, success = within 50 cents of true f0, reported as fraction
converged. Everything optimizes θ = log f0 (natural scale — fair to plain GD too).

**Landscape:** 9 prominent local minima at
`[81, 94, 110, 134, 142, 163, 220, 324, 435] Hz`; global min exactly at 220 Hz;
loss range 0.0 – 1.45. **Confirmed multimodal** (reproduces the prior finite-diff
finding with exact autograd).

**Convergence (best learning rate per method):**

| Method | exact (<50¢ of true) | octave-folded |
|---|---|---|
| A. plain GD (SGD) | **0 / 24** | 5 / 24 |
| B. Adam | **2 / 24** | 7 / 24 |
| C. Adam + restarts (best-of-24) | **solves it** → 220.00 Hz (+0.0¢) | yes |
| D. coarse grid warm-start + Adam | **solves it** → 221→220.00 Hz (−0.0¢) | yes |

**Answer:** a single gradient-descent run does **not** solve f0 here. What solves
it is **multiple restarts or a coarse grid warm-start**. The octave-folded column
(5–7/24) shows many inits land on octave/related-pitch-class errors — the
structural multimodality (harmonics crossing chroma bins as f0 sweeps), exactly as
the broader pitch-tracking literature predicts. This is the honest result, not a
tuned one.

*Caveat on A vs B:* because all methods share the same 24 inits, the 0/24-vs-2/24
gap is mostly **which basin each init happens to sit in**, not "Adam-the-optimizer
beats GD." The load-bearing takeaway is C/D — restarts/warm-start escape the basin
problem; the optimizer choice within a single run is secondary.

## 4. Synthetic encode/decode sanity check (blueprint §3.4)

`exp3_encode_decode.py`. Encode a known tone (f0 = 196 Hz, formants
[550, 1800] Hz), then recover (f0, formants) from the encoding using the method
exp2 proved is required — **multi-restart** (60 grid starts, best by loss) + Adam.
Two encodings compared:

**(1) Full spectral representation** (smoothed magnitude spectrum, what the
pipeline holds before the chroma collapse):
- f0 → **196.00 Hz (+0.0 cents)**, formant centers → **[550.0, 1800.0] (0 Hz
  error)**, loss **9.8e-21**. **Invertible: YES** (both f0 and formant shape).
- This is an **in-model, noise-free** inverse — the same generator fitting its own
  output — so it's an *identifiability + optimizability* check, not a robustness
  claim. 9.8e-21 means "uniquely recoverable in principle," not "near-perfect on
  real signals." (And note: this axis is basically a dense magnitude spectrum.)
- (Single-start decoding first landed on 588 Hz = 3×f0 — a harmonic-ambiguity
  trap — which is exactly why multi-restart, exp2's lesson, is required.)

**(2) Chroma-only** (the 12-dim timbral-identity vector):
- chroma matched to **1.1e-8** (essentially perfect) — yet recovered formant-1
  center **652 vs 550 Hz (102 Hz off)**. **Invertible: NO.**
- A *different* timbre yields the *same* chroma vector → **many-to-one**,
  confirming exp1's hint.

**Verdict (per-quantity, not a blanket yes/no):**

| | f0 | formant shape |
|---|---|---|
| Full spectral axis (dense, STFT-like) | ✓ recovered | ✓ recovered |
| Chroma axis (novel compression) | ✓ recovered (with restarts) | ✗ **102 Hz off** at chroma-loss 1e-8 |

The sanity check is **informative and complete**: the underlying signal *is*
identifiable, and we've localized exactly what the chroma compression loses —
**timbre (formant shape), not pitch**. A different formant shape yields the same
chroma vector, so chroma cannot be inverted back to a unique timbre.

**Tension to resolve (flagging, not smoothing over):** SKILL.md calls the chroma
vector "timbral identity." exp3 tests the *inverse* and finds it **many-to-one** —
chroma does *not* uniquely pin timbre. This does not necessarily break the
*forward* claim the model actually relies on (same timbre **→** same chroma point,
for matching/fusion), which exp3 did not test. But "same chroma **←** unique
timbre" is false as shown. Per the project's established-vs-conjecture norm: treat
chroma as a **same-timbre matching descriptor** (forward direction, still to be
verified) and **not** as an invertible timbre code. To *recover* timbre you need
the full spectral axis, or chroma paired with one absolute-scale anchor.

---

## What this established vs. what's still open

**Established this session (with numbers):**
- The full helix/formant/chroma pipeline is differentiable end to end under real
  autograd; gradients are exact and sane.
- formant → chroma trains cleanly (and is many-to-one).
- f0 → chroma is multimodal; restarts/warm-start are required, single-run
  gradient descent is not enough.
- The dense spectral axis is invertible to source f0 + timbre (in-model). The
  novel chroma compression recovers **f0** but is **many-to-one in timbre** —
  the compression, not the optimizer, is where information is lost.
- Corrected a real curvature-formula typo in the spec (κ).

**Out of scope today (blueprint §4, unchanged):** the radius law (`r(n)` growth),
beehive hexagonal packing, synthesis-back-to-audio, torsion-vs-linking-number
(whether "twist" needs a genuine second curve, per Călugăreanu–White–Fuller).

**Recommended next steps (multi-session):**
1. Adopt multi-restart / grid warm-start as the standard f0 front-end; treat σ
   as a swept hyperparameter (only 0.5 tested).
2. **Fix timbre identifiability under chroma** — this is the open problem this
   session surfaced. Chroma loses formant shape (many-to-one). Either enrich the
   timbral axis (the literature already says it must be a vector ≥3 dims, not a
   scalar) or accept chroma as match-only and carry timbre on a separate axis.
3. **Verify the *forward* chroma claim** that the model actually leans on —
   "same timbre → same chroma point" — which exp3 did not test (it tested the
   inverse). That claim, if it holds, is what the mycelium/fusion mechanism needs.
4. Decide the pitch axis explicitly: keep the full spectral axis (or chroma + one
   absolute anchor) wherever absolute pitch must be recoverable.
5. Only then attempt blueprint §3.5 — the real-audio head-to-head against a
   mel-spectrogram baseline of equal bottleneck size.

## Reproduce

```bash
cd ~/sonoFaig
python3 verify_geometry.py        # κ/τ derivation + typo check
python3 exp1_formant_chroma.py    # formant → chroma regression
python3 exp2_f0_landscape.py      # f0 non-convexity, 4 methods
python3 exp3_encode_decode.py     # encode/decode sanity check
```
