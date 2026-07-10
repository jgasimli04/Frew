# Beehive Vocoder — Prototype Blueprint
**Target: Claude Code (Opus, max effort) — build session: 2026-06-20**

This is a build spec, not theory exposition. Everything below has either been
derived symbolically (sympy, exact) or empirically tested (numpy, real
numbers) in a prior session. Where something is untested or uncertain, it's
flagged explicitly — don't treat silence as confidence.

Read `~/.claude/skills/beehive/SKILL.md` first for full vocabulary and the
working norms (derive don't deliver, no invented terminology, no guessing,
peer-review backing for new claims). This blueprint assumes that context.

---

## 1. What's already proven — build on this, don't re-derive it

**Core helix.** Position `R(n) = (r0·cos(ωn), r0·sin(ωn), h(n))`, where
`ω = 2π·bpm/(60·B)` and `h(n) = ∫₀ⁿ ‖F(m)‖ dm`, `F(n) = ds/dn`,
`s(n) = (A(n), I(n))` (amplitude, interval).

**Curvature/torsion (exact, sympy-verified, constant r0):**
```
κ(n) = ω·r0·√(ω⁴r0² + ω²h'² + h''²) / (ω²r0² + h'²)^(3/2)
τ(n) = ω·(ω²h' + h''') / (ω⁴r0² + ω²h'² + h''²)
```
`h'=‖F(n)‖`, `h''` its rate of change, `h'''` its jerk. Sanity-checked: fully
static input (`h'=h''=h'''=0`) gives `τ=0`, matching a flat circle. This part
is smooth in its inputs — no known differentiability issue.

**Timbre/resonance grounding (peer-reviewed, see SKILL.md for citations).**
Source-filter model: pitch (fundamental) and resonance (formant envelope) are
separable. Formant structure is pitch-invariant — verified visually in
`formant_pitch_invariance.png`. Octave equivalence only collapses power-of-2
harmonics onto the fundamental's chroma bin; the rest land on other pitch
classes, so a resonance-shaped harmonic series produces a **distribution**
across the 12 chroma bins, not a single point — verified in
`helix_chroma_projection.png`.

**Trainability test results (this session, numpy finite-diff, no GPU
framework available in that sandbox):**
- Formant shape params (2 Gaussian formants: center/width/gain each) →
  chroma vector: **trains cleanly**. 300 steps of gradient descent, loss
  0.458 → 0.138 (69.8% reduction), smooth convergence.
- Fundamental frequency `f0` → chroma bin assignment: **loss landscape is
  non-convex and multimodal** regardless of hard or soft binning (sharp
  basins around alignment points, loss swings ~0.27 to ~1.8). Plain gradient
  descent gets stuck in plateaus (hard binning) or wanders without
  converging (soft binning). This is a real, specific finding — not a guess.

---

## 2. What needs to change before this is a real trainable system

1. **Use a real autodiff framework, not finite differences.** The dev
   sandbox this was tested in had network egress blocked (`pip install
   torch` failed with a proxy 403) — that's an environment limitation, not a
   property of the model. Claude Code should have normal pip/internet
   access locally. Install PyTorch first; implement the helix/formant/chroma
   pipeline as `nn.Module`s so gradients are exact, not finite-diff
   approximations.

2. **Replace hard chroma binning with the soft (Gaussian-kernel) version
   everywhere f0 or pitch is learnable.** Hard `round() % 12` binning is fine
   for *visualization* (already used in `helix_chroma_projection.png`) but
   breaks gradient flow into anything upstream of the bin assignment. The
   soft-binning formula already implemented and tested:
   ```
   midi_like = 12 * log2(f / f_ref)
   weight[k] = exp(-periodic_distance(midi_like, k)² / (2σ²))   for k in 0..11
   chroma_vector = normalize(weight) · amplitude
   ```
   reuse this; `σ ≈ 0.5` semitones worked in testing but treat as a
   hyperparameter to sweep.

3. **Don't use vanilla gradient descent on anything involving f0/pitch.**
   The landscape is multimodal. Use Adam (adaptive, momentum-based) at
   minimum; budget for multiple random restarts or a coarse grid-search
   warm-start before fine-tuning by gradient. This is a known hard problem
   (pitch/f0 estimation landscapes are notoriously non-convex in the
   broader pitch-tracking literature) — don't expect a single GD run to
   solve it cleanly even with a good optimizer.

---

## 3. Build sequence for today

Work in this order; each step should be runnable and testable before moving
to the next. Use synthetic harmonic-series test signals first (already
proven to work in the prior session) before touching real audio.

1. **Project scaffold.** New Python package (e.g. `beehive/`), PyTorch as
   the core dependency. Port the numpy formulas above into `nn.Module` or
   plain differentiable functions: `helix_position(n, omega, r0, h)`,
   `curvature_torsion(omega, r0, h)`, `formant_envelope(f, centers, widths,
   gains)`, `soft_chroma_projection(freqs, amps, sigma)`.

2. **Differentiability regression test.** Re-run the formant-shape training
   experiment from this session (target chroma vector, 2-formant model) but
   with real autograd instead of finite differences. Confirm it still
   converges (it should — finite-diff already showed it does) and check
   gradient magnitudes are sane (no NaN/inf, no vanishing).

3. **f0/pitch trainability experiment, properly powered.** Reproduce the
   non-convex-landscape finding with Adam + multiple restarts instead of
   plain GD. Report whether a better optimizer actually solves what plain
   GD couldn't — this is the open question from this session, not yet
   answered.

4. **Synthetic end-to-end encode/decode sanity check.** Take a synthetic
   harmonic signal (known f0, known formants), encode through the full
   helix+chroma pipeline, and verify the representation is invertible
   enough to identify the source f0 and formant shape from the encoding
   (a minimal "is this representation actually informative" test).

5. **Only if 1-4 succeed: real audio test.** Pull a small set of real
   instrument/vowel recordings (or synthesize with a physical modeling
   library), run the same pipeline, and compare reconstruction or
   classification accuracy against a baseline mel-spectrogram encoder of
   equal bottleneck size. This is the actual head-to-head against librosa's
   approach — don't attempt it before the synthetic checks pass.

---

## 4. Explicitly out of scope for today

These are open frontier items from the theory (see SKILL.md "What's still
open") and should not block prototype day: the radius law (`r(n)` growth),
the beehive hexagonal packing of multiple helices, the synthesis-back-to-
audio direction, and the torsion-vs-linking-number question (whether "twist"
needs a second curve, per Călugăreanu–White–Fuller). Note them in code
comments as `# TODO: open theory question, see SKILL.md` where relevant, but
do not attempt to resolve them today.

---

## 5. Reference files already in the project

- `~/.claude/skills/beehive/SKILL.md` — full model, vocabulary, working norms
- `~/.claude/skills/beehive/handout.md` — extended theory (mycelium,
  gravitational force, arcX — partially grounded, partially still analogy)
- `~/.claude/skills/beehive/derivation.md` — original step-by-step build
- `/Users/jgasimli/sonoFaig/formant_pitch_invariance.png` — visual proof of
  pitch-invariant formant structure
- `/Users/jgasimli/sonoFaig/helix_chroma_projection.png` — visual of the
  helix + chroma-bin energy distribution

---

## 6. Definition of done for "prototype day"

Not "a trained model that beats librosa" — that's a multi-session goal. Done
for today means: steps 1-3 above completed with real autograd, the f0
non-convexity question answered (does Adam + restarts fix it, yes or no,
with numbers), and a clear, written verdict on whether step 4's synthetic
sanity check passes. That verdict is the actual deliverable — a number and a
yes/no, not a vibe.
