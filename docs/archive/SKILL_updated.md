# Beehive Vocoder — working framework

This is an ongoing research project, not a finished spec. The goal here is to let
any session pick up exactly where the last one left off: hold the model in mind,
use the project's own vocabulary, know what is settled versus open, and — above
all — work the way this collaborator wants to work.

Read the working norms below before replying. That part is what goes wrong
most easily, and matters most.

---

## What this project is

The north star is a lighter, faster audio library — an alternative to librosa
with better throughput. The bet is that librosa's standard representation (a
dense STFT: every frequency bin at every frame, computed and stored whether or
not anything is changing) carries a lot of dead weight, and that a song can be
represented far more compactly as a **3D helix**: a path that goes *around* at a
rate set by tempo while *climbing* at a rate set by how fast the music is
changing.

That climbing axis is the move a phase vocoder normally throws away. Keep it, and
static passages cost almost nothing to represent while busy passages carry the
detail. That is where the efficiency is supposed to come from.

---

## How to work on this

This collaborator is explicitly not using Claude in write-code-and-walk-away
mode. They are developing the theory and want it built with them. These norms
were learned directly, the hard way — treat them as binding, not optional style
notes:

- **Derive, don't deliver.** When they ask how something works, build it up
  step by step from where you both already are — don't hand down a finished
  result. They want to arrive at the answer together, not receive it.
- **One question at a time.** Stacking several questions at once overwhelms
  and reads as not listening. Ask the single most load-bearing question, get
  the answer, then ask the next.
- **Plain language over jargon — but never invent terminology.** Define the
  rare term you truly need using its standard mathematical name (curve,
  torsion, tangent, linking number, etc.), in whichever language is in use.
  Do not coin Azerbaijani neologisms for technical terms, and do not pad
  explanations with terms that aren't doing real work. When asked for
  proof-based writing, give definitions and equations only — no narrative
  scaffolding around them.
- **Demonstrate understanding — do not quiz them.** Prove you've internalized
  what they've taught you by restating their model back accurately and
  formalizing it, not by checking whether they know it.
- **Do NOT use multiple-choice / tappable options for open theoretical
  questions.** This was tried and explicitly rejected — it read as reductive
  ("idiocracy"-style) for genuinely unresolved math/conceptual territory.
  For this kind of question, derive a candidate answer in full open prose and
  let them confirm or correct it in their own words. Multiple-choice is still
  fine for pure logistics (file choice, task ordering, output format).
- **Never guess at facts that can be checked.** If a claim can be verified —
  a file's existence, a formula, a citation — verify it (search, compute
  symbolically, etc.) rather than hedging with "likely" or "probably."
- **They sometimes switch to Azerbaijani** to explain a subtle point. Read
  it, understand it, and carry on — don't ask them to translate. Reply in
  whichever language they're currently using.
- **Match their pace.** Short, clear, one idea at a time beats a dense wall
  every time, no matter how correct the wall is.
- **No hypothesis goes forward without checking it against peer-reviewed
  literature first** (per this project's standing rule). Flag clearly which
  parts of any claim are established vs. still analogy/conjecture.

---

## The core model (what's locked in)

### 1. Tempo sets the rotation

A bar's real duration is `T_bar = B · (60 / bpm)`, where `B` is beats per bar.
One bar is one full turn (2π). So the angular velocity is

```
ω = 2π / T_bar = (2π · bpm) / (60 · B)
```

and the angle at index `n` is `α(n) = ω · n`.

Everything is **relative** — scaled by tempo and bar length, never tied to
absolute clock time.

### 2. Euler mapping — the compression trick

```
z = r · e^{iθ} = r·cos θ + i·r·sin θ
```

The real part is the horizontal x, the imaginary part the horizontal y. This is
already how a phase vocoder represents one frequency bin: a magnitude `r`
riding a rotating phase `θ`.

### 3. The helix — rotation plus climb

```
R(n) = ( r₀·cos α(n),  r₀·sin α(n),  h(n) )      α(n) = ω·n
```

**Definitions of every symbol:**

- `R(n)` — position vector, function of `n`, value in ℝ³.
- `n` — the pluggable index (see §5).
- `r₀` — constant, non-negative real number; horizontal radius. The subscript
  `0` marks it as constant in `n`, distinct from a general `r(n)` that could
  vary (e.g. under "gravitational spread," still open — see §The frontier).
- `cos(·), sin(·)` — standard trigonometric functions, argument in radians.
- `ω` — angular velocity, constant: `ω = 2π·bpm / (60·B)`.
- `α(n) = ω·n` — the angle at index `n`, in radians.
- `h(n)` — height function, `h(n) = ∫₀ⁿ ‖F(m)‖ dm` (see §4).
- `x(n), y(n), z(n)` — the three coordinate components of `R(n)`.

The climb is **not** `sin θ` — it is the separate, third quantity `h(n)`
stacked on top of the (x,y) circle.

### 4. The force — what drives the climb

```
s(n) = ( A(n), I(n) )              state: amplitude, interval
F(n) = ds/dn = ( dA/dn, dI/dn )     force: rate of change of state
‖F(n)‖ = √( (dA/dn)² + (dI/dn)² )   magnitude: energy spent
h(n) = ∫₀ⁿ ‖F(m)‖ dm                height: running total of energy spent
```

Static passage → `F ≈ 0` → tight, bunched coils. Dynamic passage → large `‖F‖`
→ stretched coils.

### 5. n — the pluggable index

`n` counts nothing on its own — a slot for note index, sample number, beat, or
hop/frame. *What goes into `n` first is still open.*

### 6. Completion and the composite shape

A completed song reaches a full 360° at the **largest radius**, once, at the
end. A song is also a **composite**: multiple elements at different angular
positions/radii. Packing them is the beehive question — still open.

---

## Geometry of the helix: curvature and torsion (new, derived this session)

The helix `R(n) = (r₀cos(ωn), r₀sin(ωn), h(n))` is a 3D space curve and has two
standard, intrinsic differential-geometry invariants, computed via the
Frenet–Serret apparatus: `T(s) = dR/ds` (unit tangent), `N(s)` (normal),
`B(s) = T×N` (binormal), with `dB/ds = -τN` defining torsion `τ`.

For constant `r₀` and arbitrary `h(n)`, computed symbolically (verified, not
guessed):

```
κ(n) = ω·r₀·√(ω²r₀² + ω²h'² + h''²) / (ω²r₀² + h'²)^(3/2)

τ(n) = ω·(ω²h' + h''') / (ω⁴r₀² + ω²h'² + h''²)
```

where `h' = ‖F(n)‖`, `h''` its rate of change, `h'''` its jerk. Sanity check:
`h'=h''=h'''=0` (fully static) gives `τ=0` — a flat circle has no torsion, as
expected.

**Reading:** `τ` measures how tightly the curve's two "strands" — the
horizontal rotation and the vertical climb — are wound together per unit arc
length. This is an intrinsic property of the *single* curve `R(n)`; no extra
axis or attached vector is needed for it to exist.

**Open distinction — torsion vs. linking number.** If the "twist" intuition
refers to a *single* curve's intrinsic torsion, `τ(n)` above is the answer.
If it refers to *two separate* curves wound around each other (e.g. two
distinct harmonic elements), the correct object is instead the **linking
number**:

```
Lk(C₁,C₂) = (1/4π) ∮_{C₁}∮_{C₂} (r₁−r₂)·(dr₁×dr₂)/|r₁−r₂|³
```

an integer topological invariant, governed by the Călugăreanu–White–Fuller
theorem (1959/1969/1971): `Lk = Tw + Wr` (twist + writhe), the exact framework
used for DNA supercoiling. **This is unresolved**: the model currently only
defines one curve, `R(n)`; a second curve `C₂` has not yet been specified.

---

## Timbre and resonance (new, derived this session)

**What's established (peer-reviewed):**

- Timbre is a multidimensional perceptual space (Grey 1977; McAdams), typically
  3 axes: spectral centroid (brightness), spectral flux, attack
  characteristics (high-frequency energy in onset).
- The source–filter model (Fant; standard in speech/instrument acoustics):
  pitch (fundamental, "source") and resonance/formant structure ("filter") are
  separable. Cepstral analysis (MFCCs) is built specifically to separate them:
  fast-varying spectral structure = pitch, slow-varying spectral envelope =
  timbre/formants.
- Formant structure (the resonator's amplification pattern across frequency)
  is **pitch-invariant** — verified visually in
  `formant_pitch_invariance.png`: a fixed envelope shapes different harmonic
  series at different fundamentals; the envelope peaks don't move, the
  harmonics do.
- Octave equivalence (chroma, pitch class) collapses only power-of-2
  harmonics (`2f₀, 4f₀, 8f₀...`) onto the fundamental's chroma bin; other
  harmonics (`3f₀, 5f₀...`) land on *different* pitch classes. So a
  resonance-shaped harmonic series doesn't collapse onto one chroma point —
  it produces a **distribution across multiple chroma bins**, visualized in
  `helix_chroma_projection.png`.
- Resolved ambiguity: "lands at the same location" does **not** mean one of
  12 discrete bins — it means a single point in the 12-dimensional chroma
  *vector* space. Two same-timbre moments share that 12-dim point even though
  their energy is spread across several individual bins.

**Why this matters for the model:** if a third-axis encoding of "timbral
identity" is needed, the literature says it must be a vector (≥3 dims for
timbre generally, or the 12-dim chroma-projection specifically) — not a
scalar height. Collapsing to a scalar would also break the mycelium/
anastomosis fusion mechanism (§4 of the extended theory handout), which needs
full-vector comparison to detect matching identity, not just a magnitude.

**Recommended resolution:** keep `h(n)` (the climb axis) tied to `‖F(n)‖` as
originally defined — that grounding is intact. Attach timbral identity as a
separate per-`n` vector (e.g. the 12-dim chroma-projection), not folded into
the geometric z-coordinate. This keeps the two physical quantities (energy
spent vs. timbral identity) from being conflated into one axis.

---

## What's still open (the frontier)

- **What `n` takes first** — the concrete starting index for a real run.
- **The radius law** — `completion = largest radius` is a concept, not a
  formula yet. Pure helix, widening cone, or both?
- **Weighting inside `‖F‖`** — how amplitude and interval are normalized
  against each other.
- **The beehive** — packing multiple helices into a honeycomb; what it buys.
- **Synthesis direction** — getting audio back out of the representation.
- **The librosa map** — which concrete functions this replaces.
- **Torsion vs. linking number** — is "twist" the single-curve `τ(n)` derived
  above, or does it require a genuine second curve and `Lk = Tw + Wr`? If the
  latter, what is the second curve?
- **Mechanism vs. analogy still needing literature backing:** mycelium/
  anastomosis growth dynamics applied to audio correlation; gravitational
  "spread" framing of the force; arcX as a correlation-recovery mechanism.
  (Timbre-as-chroma-projection and formant pitch-invariance are now grounded —
  see above.)

---

## Why this could beat librosa

- librosa's STFT is dense: full bins × full frames, regardless of content.
- This representation stores a compact state and its derivative — static
  passages cost almost nothing new.
- Net aim: faster processing, more efficient throughput, a lighter library.

---

## Glossary

- **Helix / spiral** — the song's path: rotation (tempo) plus climb (energy).
- **Loop** — one bar = one full 2π turn.
- **Force / energy spent** — `F(n) = ds/dn`; drives the climb.
- **Climb** — the third axis; height accumulated from force. *Not* `sin θ`.
- **State `s(n)`** — `(amplitude, interval)` at index `n`.
- **`n`** — the pluggable index; counts nothing by itself.
- **Completion** — the outermost full turn, reached once, at the end.
- **Beehive** — the (open) honeycomb packing of multiple helices.
- **ω** — angular velocity, `(2π·bpm)/(60·B)`.
- **Curvature `κ`, torsion `τ`** — Frenet–Serret invariants of a single 3D
  curve; `τ` measures how tightly rotation and climb are wound together.
- **Linking number `Lk`** — topological invariant of *two* curves; governed
  by `Lk = Tw + Wr` (Călugăreanu–White–Fuller).
- **Formant** — a resonator's amplification peak in the spectral envelope;
  pitch-invariant.
- **Source–filter model** — pitch (source) and resonance/timbre (filter) as
  separable components of a produced sound.
- **Timbral identity** — now defined as a point in a multi-dimensional (e.g.
  12-bin chroma) space, not a single scalar.

---

## Deeper derivation

See `references/derivation.md` for the original step-by-step build, and
`references/handout.md` for the mycelium/gravitational-force/arcX extension
(partially grounded — see Timbre and resonance section above for what's now
confirmed vs. still open).
