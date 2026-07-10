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

## Still open in T5

Reverb, flanger, phaser, filter sweep, slicer patterns, master-bus FX; UI
shows no per-effect sub-parameter yet (one AMOUNT knob maps to
feedback/depth/drive).
