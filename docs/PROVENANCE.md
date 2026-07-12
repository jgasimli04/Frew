# Provenance — which math is original here, and which is conventional

**Date: 2026-07-11.** This document answers one question precisely: *where does
this repo run on its author's own mathematics and algorithms, and where does it
use conventional, textbook, or third-party techniques?* Every entry names the
files that implement it. "Original" below means: designed by the project's
author for this system, not taken from an existing audio/DJ/codec technique.
"Conventional" means: a standard, named technique used deliberately, as
infrastructure. Both labels are load-bearing — the point is that a reviewer can
tell them apart in one pass.

Measured claims cite `docs/findings/`; unmeasured parts say so.

---

## 1. The helix representation of a song — ORIGINAL (the core of the repo)

**The author's framework.** A song is parametrized as a 3-D helix

```
R(n) = ( r0·cos(ω·n),  r0·sin(ω·n),  h(n) )
```

- **Rotation is the musical clock:** ω = 2π·bpm/(60·B), so **one full turn =
  one bar**, and θ(n) = ω·n mod 2π is the bar phase. This clock — not an
  onset-detection beatgrid — is what the whole application stack runs on.
- **Climb is energy spent:** h(n) = ∫‖F‖, where F = ds/dn is the rate of
  change of the state s(n) = (A, I) — loudness (dB) and melodic interval
  (semitones), each normalized by its own per-track std so ‖F‖ is
  dimensionless (`beehive/encode.py` docstring makes this choice explicit).
- **Derivable geometry is never stored:** θ/α are recomputed from ω and the
  frame index as fact; storing them is a bug by project rule
  (`docs/blueprints/BEEDECK_ROADMAP.md` §1).
- The Frenet curvature/torsion closed forms for this helix are standard
  differential geometry (κ = |R′×R″|/|R′|³, τ = (R′×R″)·R‴/|R′×R″|²), but
  applied to the author's parametrization, with the corrected `ω⁴r0²` term
  derived and symbolically verified in-repo (`experiments/verify_geometry.py`).

Files: `beehive/helix.py` (torch reference), `beehive/encode.py` (numpy
pipeline, the authoritative encoder), `beehive/record.py` (what is stored),
`BeehiveMac/Sources/BeehiveKit/Geometry.swift`, `Engine.swift` (display-side
mirror), `kernel/` (the same math, adaptive-step).

**Conventional substrate underneath it:** STFT with Hann windows, magnitude
spectra, and 12-bin pitch-class chroma projection (`beehive/features.py`,
`beehive/chroma.py`) are standard MIR techniques. The repo's own
`docs/findings/VERDICT.md` measured chroma's many-to-one timbre limit
(2026-06-20) and pivoted the format to two layers because of it — the
conventional tool's limits were measured, not assumed.

## 2. The zinc keyframe index — ORIGINAL policy on standard control-theory parts

**The author's algorithm** (`beehive/zinc.py`, spec in
`docs/blueprints/BEE_ZINC_KEYFRAME_BLUEPRINT.md`): variable-rate anchors over
the helix state with a **two-rail firing policy**:

- **Event rail:** the normalized state runs through the first-order high-pass
  `H(s) = s/(s+λ)`; a key fires when the filtered deviation exceeds τ_event.
  The original move is **tying λ to the track's own bar frequency**,
  λ = κ·ω_bar — "ambient" is *defined* as "slower than the bar," a quantity
  the helix already knows per track. No fixed global threshold exists.
- **Hard rail:** a key always fires when absolute hold error vs. the last
  anchor exceeds τ_max, making zero-order-hold reconstruction error ≤ τ_max
  at every frame **by construction** — the provable bound.
- **Anchoring in state space** (A, I) rather than on a time grid: an ambient
  run emits no keys at all; there is no fixed-rate fallback grid.
- **Encode-time float64 authorship:** placement is measurably f32-sensitive
  (322 vs. 300 keys on the same track — `ZINC_AMBIENT_FINDINGS.md` §5), so
  keys are authored once on the live f64 state and the baked wire keys are
  the single authoritative set. Consumers never re-place.

Measured: ambient-decile anchor rate, ≥10× index sparsity, 21.4× sparsity and
2.8 KB/min on a real track — `docs/findings/ZINC_AMBIENT_FINDINGS.md`, roadmap
T0/T1 DONE notes.

**Conventional parts, named as such:** zero-order-hold discretization of a
first-order system (`e[n] = e^{-λΔt}·e[n−1] + ΔS`) is textbook control theory;
z-scoring is standard statistics. The *policy built from them* — two rails,
λ←ω_bar coupling, state-space-only anchoring — is the author's.

Consumer: `beecore/crates/bee-format/src/zinc.rs` reads and reconstructs only
(bit-exact vs. the Python reference, interop 42/42) — the "Python authors,
Rust consumes" split is an architectural invariant of this repo.

## 3. The `.bee` container — ORIGINAL concept, conventional wire mechanics

**Original:** the two-layer design itself — a bit-exact audio payload
(Layer 1) with the helix analysis state riding in the same file (Layer 2),
plus the zinc index as a third, additive section. The point of the format is
that **the analysis travels with the audio**, so every downstream feature
(SYNC, quantized loops, θ-synced FX, visuals) reads baked facts instead of
re-analyzing.

**Conventional, deliberately:** the wire format is ordinary engineering —
length-prefixed named sections, JSON manifest, CRC32 — and Layer 1's codecs
are **placeholders by explicit decision**: FLAC (via `claxon`/`flacenc`) for
integer PCM, raw+zlib (`miniz_oxide`) otherwise. The real predictive/entropy
coder is OPEN in `BEE_FORMAT_BLUEPRINT.md` §4(a) and has not been built; the
repo's own benchmark (`beecore/bench/RESULTS.md`) records that `.bee` does
not beat FLAC on file size — that axis is closed until new evidence.

Files: `beehive/beefile.py` (reference), `beecore/crates/bee-format/src/`
(`container.rs`, `codec.rs`, `manifest.rs`), `beecore/crates/bee-ffi/` (C ABI).

## 4. Bar math and loops — ORIGINAL use of the clock

One bar = one 2π turn = `B·60/bpm` seconds; `bar_length_samples` cuts audio on
the helix's own tempo math, and loop dedup hashes those bars
(`beehive/loops.py`). The dedup mechanism (content hashing) is conventional;
cutting on the θ grid is the author's. Measured honestly: exact bar dedup pays
**0%** on real mixes (`docs/findings/LOOP_DEDUP_FINDINGS.md`) — kept as a
correct-by-construction baseline, with near-duplicate matching explicitly OPEN.

## 5. The deck engine — ORIGINAL clock, conventional DSP components

`BeehiveMac/Sources/CBeeDeck/beedeck.c` + `BeehiveKit/DeckEngine.swift`:

- **ORIGINAL — everything timed runs on θ.** SYNC = match ω, then phase-lock
  θ between decks (Δbeat is displayed live from the θ grids). Quantize, hot
  cues, loops, and beat jump land on bar fractions of θ read from the `.bee`.
  The **grid** is never an onset-detected beatgrid; the only onset-based code
  in the repo is conventional **tempo estimation** (spectral flux +
  autocorrelation, `beehive/tempo.py` and `BeehiveKit/Tempo.swift`, both
  self-labeled as the textbook pipeline) used to *estimate ω* for raw files
  that don't carry one — overridable, and superseded the moment a `.bee`
  bakes ω in.
- **ORIGINAL — beat FX clock.** Every FX time parameter is a bar fraction of
  θ (1/16…4 bars). ROLL and REVERSE are *previous-θ-cycle capture replay* —
  they reuse the helix clock instead of any new timing code; DUCK is a pure
  gain g(φ) of the beat phase. Echo tap error measured 0.0 samples at native
  rate / 0.05 ms under varispeed (`docs/findings/BEEDECK_FX_FINDINGS.md`).
- **CONVENTIONAL — the DSP inside the boxes, named:** Linkwitz-Riley LR4
  crossovers (the isolator tree; band-sum flatness measured ±0.0045 dB,
  `BEEDECK_T3T4_FINDINGS.md`), biquads, feedback-delay echo, allpass-chain
  phaser, comb/allpass reverb, tanh waveshaper, constant-power crossfade
  (−3.01 dB centre, measured), vinyl-law varispeed resampling. These are
  textbook audio DSP, implemented fresh in C for this engine (no third-party
  DSP code), with behavior specs re-derived from public manuals as *behavior
  references only* (`BEEDECK_CDJ_FEATURE_SPEC.md` policy).

## 6. Visuals — ORIGINAL mappings on conventional rendering

- **ORIGINAL:** the overlay's geometry *is* the search geometry — rotation =
  α literally (one turn = one bar), twelve chroma petals as the pitch-class
  wheel, radius inflating with sub/low, the **bass-departure detector**
  (sustained sub+low collapse while highs persist → drop-build signal, same
  thresholds offline and live), beat shockwaves launched by θ quarter-bars,
  and the T10 rule *each EQ bus owns a scale stratum of the traced picture*
  with re-tracing locked to the beat. Mapping is pure signal correlation —
  no manual scene assignment (locked user decision, 2026-07-10).
- **CONVENTIONAL:** Apple Vision's `VNDetectContoursRequest` performs the
  neural contour inference (median 2.8 ms / trace measured via
  `beehive-cli --tracetest`); SwiftUI/Canvas/SceneKit do the drawing;
  5-band envelope analysis is standard filter-bank work.

Files: `BeehiveMac/Sources/BeehiveApp/StageView.swift`, `VideoTrace.swift`,
`HelixSceneView.swift`, `BeehiveKit/BandEnvelopes.swift`.

## 7. Adaptive-step kernel — ORIGINAL

`kernel/`: analysis steps sized by accumulated ‖F‖ (equal-energy ticks), not a
fixed frame grid — the helix climb as the sampling clock. Acceptance tests in
the crate; separate research track.

## 8. Helichain — conventional structure, author's records

`beehive/helichain.py` + `helichain/`: an append-only, hash-linked ledger
(conventional chain-of-hashes) whose *records* are the author's helix
analyses. Nothing novel claimed about the chaining itself.

## 9. Bearing-helix research — the same original fold, different domain

`bearing-helix-research/`: the author's rotation-clock framework applied to
rotating-machinery vibration (θ from shaft speed instead of bpm). Standard
vibration indicators used inside it (envelope analysis, kurtosis) are
conventional and named in that crate's own docs. Separate research track;
synthetic bench green, real-data validation open (its README states status).

## 10. Third-party code actually present

Rust crates: `serde`/`serde_json`, `miniz_oxide` (zlib), `claxon` (FLAC
decode), `flacenc` (FLAC encode), `crc32fast`. Python: `numpy`, `soundfile`
(libsndfile), `torch` (CPU tensor math), `pytest`. Apple frameworks in the
Mac app (AVFoundation, SwiftUI, SceneKit, Vision, Accelerate). That is the
complete list; there is no third-party DSP, DJ, or codec logic beyond these,
and no third-party assets ship in the repo.
