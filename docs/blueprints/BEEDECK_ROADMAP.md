# BeeDeck — roadmap for the .bee-native DJ + visual program

**Date: 2026-07-10. Status: task list LOCKED (user, this date); working title
"BeeDeck" (rename freely).** Sibling to `BEE_NATIVE_TRANSITION_BLUEPRINT.md`
(Swift shell + Rust algorithm home), `BEE_ZINC_KEYFRAME_BLUEPRINT.md` (the
index/keyframe layer), `BEE_LIGHT_BLUEPRINT.md` (light-by-default codec
decisions). Evidence norms unchanged: measure, don't claim.

## 1. Vision (user, 2026-07-10)

A macOS-native program at rekordbox/CDJ feature level (features from **public
information** — original implementation, no Pioneer code/assets): full DJ mixing
with FX, and an audio-visual stage. Decisions taken this date:

- **Library lives entirely in `.bee`** — "compression kicks in" at prepare time;
  the codec loop (L1 lossless payload + helix side-channel + zinc index) IS the
  library format. All sounds live in the helix realm; each sound is a unique
  key-generating equation; **θ is derivable as fact** (`θ = ω_n·n mod 2π` from
  manifest meta), so Rust re-derives angular data instead of storing it.
- **USB flow: Prepare → USB** (rekordbox-style). Pick tracks in the app →
  analyze + encode `.bee` onto the stick → decks launch and play from the stick.
- **Control: keyboard + trackpad** v1 (no CDJ/MIDI hardware; MIDI-learn later).
- **Visual stage:** background = a folder of **local video clips** (the
  "inspiration set"), generative overlay on top; track↔visual mapping is **pure
  signal correlation** (band energies, chroma hue, ‖F‖, θ phase) — no manual
  assignment step in v1.
- **5-band EQ** per deck (full-kill isolator), and its band signals feed the
  visuals ("bass leaving before the drop" → chromatic/shape response).

Constraints carried from locked blueprints:
- Swift/SwiftUI shell; realtime audio hazards off the Swift runtime (ObjC/C
  render path when decks need rate/pitch) — `BEE_NATIVE_TRANSITION_BLUEPRINT` §2.
- **Python authors zinc keys; Rust consumes them** (user steer 2026-07-10).
  Analyzer port to Rust is a separate gated track, not a prerequisite.
- Playback = lossless Layer-1 PCM path (`bee_pcm_bytes`); neural base is a
  future layer (`BEE_NEURAL_PLAYBACK_ROADMAP`), lossless-size axis is closed.

## 2. Task list

**T0 — Ambient-balanced zinc math (TODAY).** Laplace-domain two-rail anchor
policy + Fourier validation. Event rail = state through the high-pass
`H(s) = s/(s+λ)` (exact ZOH discretization), λ tied to the track's own bar
frequency ω_bar; hard rail = absolute hold error vs `τ_max` (keeps the provable
reconstruction bound). Fourier: per-track state spectra locate the ambient knee
and justify λ. **DoD:** on the 3-track corpus — ambient-decile anchor rate ≤ 1%,
index sparsity ≥ 10×, force-decile rate monotone, max recon error ≤ τ_max;
synthetic unit tests (constant/slow-sine → zero event anchors; step → one, at
the step); findings doc + blueprint §8(b) resolved.
Files: `beehive/zinc.py`, `scripts/zinc_report.py`, `tests/test_zinc.py`,
`docs/findings/ZINC_AMBIENT_FINDINGS.md`.

**T1 — Keys into the container + Rust consumer.** Python writes the
Python-authored key stream as a 4th section `zinc_index` (append to the section
tuple in `beehive/beefile.py::write_bee`; reading is already generic). Rust:
`SECTION_ZINC_INDEX` const, `zinc.rs` **consumer only** (read keys, re-derive θ
from meta as fact, reconstruct trajectory), roundtrip test, interop test
bit-exact vs `beehive.zinc.reconstruct_state`. Old readers unaffected (verified:
Rust fetches sections by name and ignores extras). **DoD:** `.bee` carries keys;
`cargo test` + interop green.

**T2 — AV Stage v0 (STARTED TODAY).** In `BeehiveMac/BeehiveApp`: a Stage window
that plays the loaded `.bee` while compositing (a) the inspiration-set video
layer — clips from a user-picked folder, bar-synced advance with crossfade,
muted, rate gently slaved to bpm; (b) a generative overlay driven purely by
signal correlation: 5-band envelopes (offline, at the helix frame grid), chroma
hue/sat/val, ‖F‖, helix angle α, and a bass-departure detector (sub+low collapse
while highs persist → deflate/desaturate response — the user's "bass leaving
before the drop"). **DoD:** `swift build` green; stage runs with any clip folder;
overlay visibly phase-locked (rotation = α, pulse = bands).
Files: `BeehiveMac/Sources/BeehiveKit/BandEnvelopes.swift` (new),
`BeehiveMac/Sources/BeehiveApp/StageView.swift` (new), `AppModel.swift` +
`main.swift` (wire-in).

**T3 — Decks & CDJ core.** Two decks: PCM min/max waveform (overview + zoom)
colored by helix hue, beatgrid lines at θ≡0 with downbeat emphasis, hot cues ×8
+ memory cues, quantize, auto/manual loops on the bar math
(`beehive/loops.py` = `bar_length_samples`/`segment_bars`), beat jump, SYNC =
match ω then phase-lock θ, tempo slider ±6/10/16/WIDE, master tempo (key lock),
slip mode; full keyboard map. Realtime path: move per-deck playback to a render
callback (ObjC/C per transition blueprint) or `AVAudioUnitVarispeed`/
`TimePitch` interim — decide by measuring glitch behavior under rate change.
**DoD:** beatmatch two real tracks by keyboard only; loop/cue latency
imperceptible (< 10 ms trigger-to-audio).

**T4 — Mixer.** Per deck: trim, **5-band full-kill isolator EQ** (Linkwitz-Riley
LR4 biquad crossovers at 60 / 250 / 2000 / 8000 Hz), one-knob HP/LP filter,
channel fader; crossfader with curve select; cue/headphone bus (second output
device) ; meters. The EQ band taps become the live visual signal source,
replacing T2's offline envelopes — the "EQ sends the signal to the visuals"
promise, literally. **DoD:** full bass kill is −∞ (true kill), band sum flat
within ±0.5 dB when all at 0; visuals respond to EQ moves in < 50 ms.

**T5 — Beat FX (θ-synced).** Echo, delay, reverb, flanger, phaser, filter sweep,
roll/slicer; all time parameters quantized to bar fractions derived from ω
(1/16 … 4 bars), beat-aligned via θ. **DoD:** echo tail lands on the grid at any
tempo; FX bypass is click-free.
*2026-07-10 — first wave SHIPPED (RMX-IGNITE manual used as the behavior
reference, math re-derived on the θ grid — see
`docs/findings/BEEDECK_FX_FINDINGS.md` for the measured numbers):* per-deck FX
slot on the isolator band buses (LOW/MID/HI/ALL routing over the 5-band LR4
split) with ECHO (beat-fraction delay, tape-glide time), DUCK (pure g(φ)
envelope), ROLL and REVERSE (previous-θ-cycle capture replay — zero new clock
code), DRIVE (waveshaper), and a momentary ECHO-OUT release punch. DoD checks
live in `beehive-cli --decktest` (tests 7–13). Still open from the list:
reverb, flanger, phaser, filter sweep, slicer patterns, FX on the master bus.

**T6 — Prepare → USB.** Track picker → per track: Python analysis (authors helix
record + zinc keys) → `.bee` written onto the mounted stick + a library index
(start with helichain-style `chain.jsonl`; move to SQLite when browse needs it)
→ verify by native Rust decode hash (pattern exists in
`scripts/convert_to_bee.py`). App browses and plays straight from the stick.
**DoD:** a stick prepared in-app cold-loads on another Mac running BeeDeck and
plays; every `.bee` on it passes native-decode verification.

**T7 — Visual correlation v1.** Analyze the inspiration clips themselves
(brightness / motion energy / dominant color over time) and correlate to the
audio signal profile (band envelopes + chroma + ‖F‖) when choosing the next
clip and the overlay treatment — the "AI edits the visuals" hook, kept
deterministic and local. **DoD:** A/B: correlated selection visibly beats
random rotation on the same set (logged rubric, honest listening/watching
notes).

**T8 — Polish.** Musical key detection (Krumhansl-style over the stored per-frame
chroma — substrate already in every record), key display + key-shift, MIDI-learn
layer, set recording to disk, 4-deck layout.

**Eng track (parallel, gated):** analyzer port to Rust (`bee-engine`) per
`BEE_NATIVE_TRANSITION_BLUEPRINT` Phase 6, bit-exact vs Python fixtures. Until it
lands, Python remains the sole author of records/keys (locked steer); the app
shells out to the venv for prepare flows.

## 3. Verification norms

Every milestone ships with: the runnable check named in its DoD, `pytest` +
`cargo test` + `swift build` green, and — where a claim is made (latency, kill
depth, correlation quality) — a measured number in a findings doc, not an
adjective. No lossless-size claims anywhere (axis closed by
`LOOP_DEDUP`/`POOL_RESIDUAL`/`bench/RESULTS.md`).
