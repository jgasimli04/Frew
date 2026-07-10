# 00 — The Rotation Spine

The beehive framework leaves open "what `n` takes" — what the helix winds
around. Music answered bars (ω from bpm), the zinc chain answered optical
pulses (ω from the pulse clock). This project answers for machines:

**D1 (the machine's clock).** `n` is the shaft revolution index. A rotating
machine narrates itself once per revolution; the revolution is the natural
symbol. One helix turn = `TURN_REVS = 64` revolutions (`geometry.rs`) — a
"breath" long enough for the geometry to be well-sampled, short enough that a
shift is visible within a snapshot. The physical clock enters only as the
refined shaft frequency (`speed.rs`, ω to <2·10⁻⁴ relative, no tachometer —
test-enforced).

**D2 (state).** Per revolution, s(n) = (A, I):
`A = 20·log10(rev RMS / FS)` dB — the loudness axis;
`I = 12·log2(ZCR / 1 kHz)` semitones — a zero-crossing dominant-frequency
proxy on the interval axis. Both computed inside the codec loop (`fold.rs`)
where revolutions already exist. From here the locked formulas run unchanged:
F = ds/dn, h = Σ‖F‖, R(n), κ, τ (`geometry.rs`, ported from
`beehive/encode.py` and pinned to it by fixture parity at 1e-9).

## What the numbers did (synthetic rig, seeds fixed, 2026-07-07)

**The climb h(n) is an odometer, not an alarm.** After defect onset the climb
rate bends up by **1.15×** (profile A) / **1.08×** (profile B) — real but
weak, because ‖F‖ normalises each state derivative by its own whole-life std
(the source's resolution of the weighting thread): per-revolution estimator
noise sets the healthy climb, and wear must out-shout it. The climb *rate* as
an alarm under the shared rule **breaks** — the departure *level* of the byte
rate wins by hours. (The remote-session build reported the same shape:
odometer holds, climb-rate alarm fails.)

**The byte rate is the alarm.** The fold's steady-state bits/sample alarmed
**8.26 h** (A) / **5.95 h** (B) before ground-truth failure — before every
fault-agnostic baseline (best: kurtosis 4.26 h / crest 3.45 h) and marginally
before the envelope line that is *told* the fault order (8.10 h / 5.79 h).
Detection lands at ~0.9σ_noise impulse severity: individually invisible
impacts, caught as residual entropy. Zero false alarms on the 30 h healthy
control.

## Two deviations from the ported source, both deliberate

1. **Smoothing edges.** `_smooth` in the audio engine is `np.convolve(...,
   mode="same")`: zero padding droops the ends. In a streaming monitor the
   newest revolution is always an end. The port takes the mean over the
   clipped window instead; interior samples are bit-identical to numpy
   (fixture-tested both ways).
2. **No colour.** Chroma/hue have no vibration analogue yet; the (A, I) state
   carries everything. An order-spectrum → 12-band mapping is a plausible
   future colour axis, unbuilt.

## The event layer (event.rs) — what the numbers did

When the byte rate leaves noise, the monitor answers when / where / what-now
(bench, 2026-07-07, one event per life, healthy control silent):

- **When.** A per-rev CUSUM (slack 0.25σ, threshold 10σ) stamps detection at
  one-revolution precision (~30 ms) and accumulates across snapshot gaps; it
  arrives within about one snapshot of the coarse 5σ rule — its contribution
  is precision and gap-freedom, not extra earliness. A zero-slack shadow walk
  back-estimates when the departure left the noise floor (A: 11.5 h est vs
  12.0 true; B: 10.5 vs 10.0; S: 5.5 vs 8.0 — the walk's excursion fuzz is
  real, ~±2 h, worst on slow plateaus). The seeding moment itself is not
  identifiable: a defect is invisible until it perturbs the stream.
- **Where.** The fault order is the address inside the bearing: envelope
  scoring named outer/inner correctly at 18–24× margin on all three faulted
  lives. The inner-race angle (load-zone phase fold) recovered 217° vs true
  220° (B) and 129° vs 135° (S). An outer-race defect is fixed in the housing
  — one channel cannot give its angle, and the event says so instead of
  guessing.
- **What now.** Wait-until-distinguishable disposition: still-rising
  departures page (A, B → maintenance request with growth fit), stationary
  low departures are absorbed (S → reference re-based, monitoring re-armed,
  event kept as helix metadata — the machine's new voice). A fixed 2 h
  confirm window was tried first and produced a false Absorb the moment
  growth outran it; the wait-until-shape policy replaced it.
- **A prognosis limit, measured.** The byte rate is a log meter: superb near
  onset, compressive at high severity — so exponential service-by
  extrapolation on it leans LATE (A: predicted 26.1 h vs true failure 22.8;
  B: 24.3 vs 19.8). Late-stage prognosis should hand off to an energy-scale
  indicator (envelope line) once the departure is large. Recorded as a break,
  not patched away.

## A rig-design lesson worth keeping

The first rig grew the late-life noise floor as √wear. √ has infinite slope
at zero: severity going nonzero *stepped* the floor ~3% and the byte rate — a
log-of-σ meter — alarmed on the very onset snapshot. Physically wrong and
flattering to the format; replaced by a floor linear in wear. Any entropy
meter will happily detect your simulator's discontinuities: make the rig
smooth before believing the lead time.
