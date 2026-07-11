# BeeDeck T3/T4 — decks, mixer, isolator: measured findings

**Date: 2026-07-10.** Code: `BeehiveMac/Sources/CBeeDeck/` (the C DSP core),
`BeehiveKit/DeckEngine.swift` (shell wiring), `BeehiveApp/DecksView.swift`
(two-deck UI + keyboard map). Reproduce: `cd BeehiveMac && swift build &&
.build/debug/beehive-cli --decktest` (offline, no audio device) and
`--deckload <file.bee>` (end-to-end `.bee` → Rust decode → C core → render).
Spec: `docs/blueprints/BEEDECK_ROADMAP.md` T3/T4.

## Architecture (per the locked blueprints)

- **All realtime DSP is C** (`CBeeDeck`): transport, cubic-Hermite varispeed,
  the isolator, filter, faders, crossfader, metering. Swift hosts one
  `AVAudioSourceNode` whose render block calls `bd_mixer_render` — no Swift
  runtime on the audio thread, no locks, no allocation (transition blueprint §2).
- **Parameters cross on C11 atomics**, single writer per field; every gain is
  one-pole smoothed (~3 ms) against zipper noise; kill targets snap to an
  exact 0 below −140 dB.
- **`.bee` is the deck format**: Layer-1 PCM through the Rust core is the
  audio; Layer-2 meta carries the θ-anchored beatgrid (bpm, B) — beatgrid
  lines, quantize, loops and SYNC all derive from the helix grid, no separate
  analysis pass. Plain audio files load with the grid off (sync disabled) —
  the library loop stays `.bee`-first.

## The isolator: LR4 crossover tree with phase compensation

Splits at 60 / 250 / 2000 / 8000 Hz. Each split is Linkwitz-Riley LR4 (squared
Q=1/√2 Butterworth biquads); `LP4+HP4 = 2nd-order allpass` is an algebraic
identity that survives the bilinear transform, so each split sums flat. Bands
that skip downstream splits carry matching allpass compensators (3/2/1 for
sub/low/mid) so all five branches arrive phase-aligned.

## Measured (offline, through the render path — `--decktest`)

| check | measured | DoD |
|---|---|---|
| all-open band-sum flatness | worst **±0.0045 dB** @ 25 Hz | ±0.5 dB |
| kill totality | all-band kill → rms **exactly 0** (true −∞) | kill = −∞ |
| bass-kill leakage (45 Hz, sub+low killed) | **−72 dB** (adjacent-band LR4 slopes) | inaudible |
| mid content under bass kill (1 kHz) | dev **0.034 dB** | < 0.5 dB |
| loop wrap declick | max step ×**1.25** of a clean sine's slope | click-free |
| seek/hot-cue declick | same crossfade, PASS | click-free |
| varispeed rate accuracy | error < **1e-4** (exact to print precision) | — |
| varispeed pitch (440 Hz @ ×1.06) | **466.0 Hz** (target 466.4) | vinyl law |
| crossfader centre (constant-power) | **−3.01 dB** | −3 dB |
| throughput | **123× realtime** (one deck, full strip, debug build) | ≥ realtime |

End-to-end: `--deckload` on a real library `.bee` — native Rust decode, θ grid
(bpm 64.6 → beat 40 960 samples), full record for the stage, signal through
the C core, and the 44.1→48 kHz device-rate correction lands within 0.2%.

## Honest deferrals (T3/T4 scope cuts, all noted in code)

- **Key lock (master tempo)** — varispeed is vinyl-style (pitch·tempo
  coupled). A time-stretch stage is a separate, later insert.
- **Cue/headphone bus** — needs a second output device (aggregate); the
  mixer's cue path is not built yet.
- **Trigger-to-audio latency** rides the HAL buffer: requested 256 frames
  (~5.3 ms @48 kHz — inside the <10 ms DoD), but the device may refuse;
  not yet measured against hardware.
- **Waveform zoom** renders from the 2048-bucket overview pyramid —
  overview-grade, not sample-grade; fine at 8 s width, will want a finer
  pyramid for sub-second zoom.
- **bpm octave caveat carries over** from the encoder (`ZINC_AMBIENT_FINDINGS`):
  Liverpool's grid is 64.6 (half of true 128) — SYNC still works because both
  decks use the same estimator, but beat-jump distances are musically 2 beats
  when the estimate is half-tempo.

## The T4→T2 hand-off, live

Per-band post-EQ peak envelopes are published from the render thread
(atomics) and become the stage's signal source whenever a deck is on air —
`StageView` renders the *playing deck's own helix* (its α as rotation, its
chroma petals) with the live band levels and a live bass-departure detector.
Kill the bass on deck A and the stage deflates in the same frame the audio
thins: the EQ literally sends the signal to the visuals.
