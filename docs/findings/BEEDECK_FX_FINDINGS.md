# BeeDeck Beat FX — measured findings (T5 first wave)

**Date: 2026-07-10.** Verification per the roadmap norm: numbers, not
adjectives. All figures from `beehive-cli --decktest` (tests 7–13), which
renders offline through the exact C code the audio thread runs
(`Sources/CBeeDeck/beedeck.c`), sr 44100, 120 bpm grid (beat = 22050 samples).

## What was built

One θ-synced FX slot per deck, inserted on the isolator band buses — the
existing 5-band LR4 crossover doubles as the FX router (band targets
LOW = sub+low, MID, HI = himid+hi, ALL). Behavior reference: the AlphaTheta
RMX-IGNITE manual (public doc, feature behavior only — all math re-derived on
BeeDeck's own grid; no vendor code). The FX cycle is `beat_src × beats`
source samples, so every effect reads its phase φ from the playhead each
frame: loops, seeks, hot cues and varispeed cannot de-sync the FX from what's
audible, by construction.

| Effect | Mechanism | New DSP? |
|---|---|---|
| ECHO | feedback delay, time = cycle, tape-style glide (~80 ms) on time changes | delay ring |
| DUCK | in-place gain `1 − depth·((1+cos 2πφ)/2)²` | none — pure φ |
| ROLL | replays the last complete θ-cycle from the capture ring (slip-style: transport keeps advancing) | none — capture ring + φ |
| REVERSE | plays the previous θ-cycle backwards, re-captured every cycle | none — same ring |
| DRIVE | `tanh` waveshaper, amount-blended | waveshaper |
| ECHO-OUT (release) | momentary punch: dry mutes, beat-spaced repeats decay (fb 0.62), tail rings out after key-up | release ring |

## Measured results (DoD)

**Roadmap T5 DoD: "echo tail lands on the grid at any tempo; FX bypass is
click-free." Both hold:**

- **Echo grid landing, native rate:** 9 taps from one impulse, spacing target
  22050.0 → **worst error 0.0 samples (0.00 ms)**.
- **Echo grid landing, varispeed ×1.06:** 7 taps, spacing target 20801.9
  output samples → **worst error 2.1 samples (0.05 ms)** (residual = the
  80 ms tape-glide settling; sub-0.1 ms is far below audibility).
- **Engage/bypass click:** all five effects toggled on/off on a 440 Hz sine —
  worst sample step **0.0566 = 1.81× the clean sine's own slope** (loop-wrap
  declick baseline on the same rig is 1.25×; threshold 2.5×). The dry path is
  never interrupted; wet paths ride a ~3 ms smoothed gain.

Effect-specific:

- **DUCK (φ envelope):** −33.3 dB in a ±25 ms window on the beat,
  **−0.00 dB off-beat** — the envelope is the beat phase, nothing else.
- **REVERSE:** 4/4 settled cycles of a rising per-beat saw play high→low.
- **ROLL:** held rms 0.566 (the captured loud cycle) while the live input had
  dropped to 0.071; releasing falls back to the live input.
- **RELEASE echo-out:** repeat windows −9.5 / −13.6 / −17.8 / −22.0 dB —
  **monotonic, −12.5 dB across 3 taps** (fb 0.62 ⇒ −4.15 dB/tap, as designed);
  dry returns within **+0.54 dB** of the pre-hold level.
- **DRIVE:** crest factor 1.027 at full amount (clean sine 1.414, square 1.0).

Cost: the full pre-existing suite still passes unchanged (band-sum flatness
worst **+0.0045 dB**, true-zero kills, −72 dB bass-kill leakage), and the
60 s single-deck render runs at **97× realtime** with the FX section in the
loop.

## Design notes / limits (honest)

- **Type-switch while engaged hard-cuts the old wet path** (dry stays
  continuous). Deliberate: instant grabs are the point of ROLL/REVERSE;
  cutting a long echo tail on a type swap is standard hardware behavior. The
  smoothed path is engage/bypass, which is what the DoD requires.
- **ROLL's internal wrap is a hard cut** (no crossfade at the slice
  boundary) — part of the roll sound; revisit only if real material
  complains.
- **Band envelopes (the stage's visual feed) are tapped pre-FX**, so the
  visuals see the EQ but not the FX. Post-FX metering needs a per-band FX
  topology — out of scope for a bus-routed slot.
- **Tracks without a grid** (non-`.bee`): FX free-runs on a 0.5 s
  pseudo-beat scaled by the beats knob; everything works, nothing is
  beat-aligned — the `.bee`-first library remains the point.
- Release repeats are capped at the 2 s release ring (fine down to 30 bpm at
  the default ≤ 1-beat fractions).

## Second wave (same day): SWEEP · FLANGER · PHASER · SLICER · REVERB

The catalog completed to ten effects. The φ-driven ones again needed no clock
of their own — SWEEP and PHASER redesign their biquads once per render block
from φ; FLANGER's LFO *is* φ; SLICER re-sequences the previous cycle straight
off the same capture ring ROLL/REVERSE use. REVERB is the one true new
primitive (Schroeder: 4 combs + 2 allpasses, amount = RT60 0.4–2.2 s).

Measured (decktest 14–18, same run as above):

- **SWEEP** (resonant LP, cutoff 200 Hz→20 kHz riding φ, amount = Q):
  6 kHz tone **−42.8 dB at φ=0, +0.1 dB at φ=0.5**.
- **FLANGER** (0.5–8.5 ms delay riding φ, feedback ≤0.55): 1 kHz level swings
  **10.1 dB** across the θ cycle.
- **PHASER** (4-stage allpass, 300 Hz–3 kHz, feedback ≤0.7): **11.0 dB** swing.
- **SLICER** (previous θ-cycle, 8 slices, amount picks 1 of 4 patterns):
  staircase input re-sequenced — **8/8 output slices** match pattern
  `[0,0,2,2,4,4,6,6]` within 1.5 dB.
- **REVERB** (amount 1 → RT60 ≈ 2.2 s): 50 ms burst → tail **−34.0 dB** 0.6 s
  later, **−58.1 dB** at +1.5 s (monotonic), and the pre-burst floor is exact
  silence (−inf).
- **Engage/bypass across all ten types: unchanged worst step 1.81×** a clean
  sine's slope — the click-free DoD holds for the full catalog.
- Block-rate LFO note: SWEEP/PHASER coefficients update per render block
  (≤512 frames ≈ 11.6 ms) — standard practice; no zipper audible in the click
  test.

## Still open in T5

Master-bus FX (everything is per-deck) and per-effect sub-parameters (one
AMOUNT knob maps to feedback / depth / drive / resonance / pattern / RT60).
