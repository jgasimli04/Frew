# Beehive Vocoder — Native macOS Visualization UI Blueprint
**Target: Claude Code on this Mac (needs Xcode) — not Cowork, not web.**

---

## Skill situation — checked, none exists

Searched both the standalone-skills catalog and the installable-plugins
registry for native Swift/macOS/Xcode development. Nothing general-purpose
exists. The only adjacent hit was `figma:figma-swiftui` (converts an existing
Figma design into SwiftUI code — not useful without a Figma mockup already
in hand). There is no skill to load for this; it's a normal Swift/SwiftUI
build, same as any other native macOS app.

The actual constraint is environment, not skill: Cowork's sandbox has no
Xcode, so it can write Swift source files but cannot compile, run, or
visually verify them. This whole task needs to run where Xcode lives — i.e.
Claude Code on this Mac, the same setup that already built and ran the
PyTorch prototype.

---

## What this UI needs to show

Five views, each corresponding to one piece of the Python prototype
(`~/sonoFaig/beehive/` and `exp1-3`). This is a *visualization/exploration*
tool, not a training tool — all the gradient-descent work already happened
in Python; the Swift app re-implements the forward-pass math only (no
autodiff needed) and lets the user move sliders and see results live.

1. **Helix view.** 3D render of `R(n) = (r0·cos(ωn), r0·sin(ωn), h(n))`.
   Sliders: ω (or bpm/B), r0, and a way to set a climb profile h(n) (start
   with a few presets — constant slope, step, sine — matching the "static
   vs dynamic passage" cases from the theory). Color the curve by curvature
   κ or torsion τ at each point (reuse the closed forms from `helix.py`).

2. **Formant envelope view.** 2D plot: the envelope curve plus harmonic
   stems at `f0, 2f0, 3f0...`, same content as `formant_pitch_invariance.png`
   but live. Sliders: f0, and per-formant center/width/gain (start with 2
   formants, matching the Python tests). This is the view that should make
   "formant peaks don't move, harmonics do" visually obvious when the user
   drags the f0 slider.

3. **Chroma projection view.** 12-slice radial bar chart, same content as
   `helix_chroma_projection.png`'s right panel, but live as formants/f0
   change. Swift Charts doesn't have a built-in polar/radial bar chart —
   draw this one with `Canvas` (12 wedges, angle = pitch class, radius =
   energy).

4. **f0 landscape view.** Line plot of loss vs. candidate f0 (reproduce
   `exp2`'s landscape characterization), with the 9 known local minima
   marked. This is the view that makes "why does gradient descent get
   stuck" visually obvious — the user should be able to see the valleys.

5. **Encode/decode comparison view.** Simple side-by-side readout: true
   (f0, formants) vs. recovered-from-full-spectrum vs.
   recovered-from-chroma-only, reproducing `exp3`'s table. This is the
   view that shows the many-to-one finding directly — true formant center
   vs. the wrong one chroma-alone converges to.

---

## Suggested architecture

- **SwiftUI app**, macOS-only target (set deployment target high enough for
  modern Swift Charts — macOS 14+ recommended).
- **Math core**: port the *pure functions only* (no training) from
  `helix.py`, `formant.py`, `chroma.py`, `signals.py` into a small Swift
  file, e.g. `BeehiveMath.swift` — plain `Double`/`[Double]` functions,
  direct translation of the closed forms, no dependency on PyTorch or any
  ML framework. These are forward-pass-only and don't need gradients in the
  UI.
- **3D helix**: SceneKit (mature, stable on macOS) rather than RealityKit
  (AR/iOS-oriented) or a from-scratch Metal renderer. A `SCNNode` path
  built from sampled `(x,y,z)` points is enough; don't over-engineer this.
- **2D charts** (formant envelope, f0 landscape): native Swift Charts
  (`Chart`, `LineMark`, `PointMark`).
- **Chroma wheel**: custom `Canvas` view, 12 wedges.
- **Controls**: standard SwiftUI `Slider`/`Stepper` bound to `@State`,
  recomputing the relevant math function on each change — no need for
  Combine pipelines or async work, everything here is cheap enough to run
  synchronously on every UI tick.

## Build sequence

1. New Xcode project, macOS App template, SwiftUI lifecycle.
2. Port the math core first (`BeehiveMath.swift`) and unit-test it against
   known values from the Python output (e.g. the static-climb sanity check:
   τ=0, κ=1/r0 — already verified in `verify_geometry.py`, reuse those
   numbers as the Swift test's expected values).
3. Build views in the order listed above (1-5) — each is independently
   useful, so ship incrementally rather than building all five before
   testing any.
4. Wire sliders last, once each view renders correctly with hardcoded
   example values matching the PNGs already in `sonoFaig/`.

## Explicitly out of scope for this UI

Training/gradient descent inside the app (that stays in Python — the app
visualizes results, it doesn't reproduce exp1/2/3's optimization loops),
real audio input/output, and anything from the theory's still-open items
(radius law, beehive packing, synthesis direction).
