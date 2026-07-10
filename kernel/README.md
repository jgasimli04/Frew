# beehive-kernel — Demo 1: the adaptive-time-step kernel (Rust)

The first running demo of the **time-based kernel feedback loop**. The kernel
walks through audio in steps whose length adapts to how fast the music is
changing (`‖F‖`), not on a fixed frame grid. It (a) produces the helix trajectory
and (b) emits **materially fewer samples than a fixed-step baseline**, at bounded
reconstruction error.

```
cargo run --release -- <wav> --bpm <n> [--eps <ε_h>] [--b <beats>] [--r0 <r>] [--out ticks.csv]
cargo test --release            # acceptance #1, #2, #3
```

## The idea in one paragraph

A song is a 3-D helix (SKILL_updated.md): it *rotates* at a rate set by tempo and
*climbs* at a rate set by `‖F‖`, the rate of change of the state `s = (A, I)`.
Static passages barely climb; busy passages climb fast. Instead of one sample per
analysis frame, the kernel accumulates the climb energy and emits a **tick only
when the accumulated `‖F‖` since the last tick reaches `ε_h`** — *equal-energy
ticks*: long steps where the music is static, short steps where it moves. This is
error-controlled step-size sampling (cf. adaptive Runge–Kutta / equal-arc-length).
`ε_h` is the one knob — the step-size controller of the loop, in a single number.

## What matches the Python reference exactly

`beehive/encode.py` is the spec. The Rust frame pass reproduces it to ~1e-8
(relative-L2), far under the 1e-3 bar:

| quantity | definition (mirrored from `encode.py` / `features.py`) |
|---|---|
| `A(k)` | loudness dB on the **un-windowed** frame: `max(20·log10(rms+ε), −80)`, `rms=√(mean(x²)+ε)` |
| `I(k)` | `12·log2(centroid/440)` on the Hann-windowed magnitude, **energy-gated** (frames below 1% of the track's median frame energy hold the last valid interval; leading silence = 0) |
| `F` | `np.gradient` of A,I (central diff interior, one-sided ends), each component ÷ its own std over the track (`w_amp=w_int=1`) |
| `h` | `cumsum(‖F‖)` |

Two decisions worth stating:

* **Central difference, not `A(k)−A(k−1)`.** Acceptance #1 binds to `encode.py`,
  which uses `np.gradient` (central). A backward difference misses `h` by far more
  than 1e-3. The prompt's `A(k)−A(k−1)` is the informal description; the code is
  authoritative. (`step` finalizes frame *k−1* when it receives frame *k* — the
  central difference needs the following frame — and `flush()` finalizes the last
  frame with a one-sided difference.)
* **The Hann window is `np.hanning` (symmetric, denominator `n_fft−1`)**, applied
  for the spectrum; loudness uses the raw frame. FFT magnitudes are f32-quantized
  to mirror `stft_mag`, so the energy gate compares exactly.

## Two honest phases (and the real-time shape)

The I-gate (median frame energy) and the force normalizers (std of dA, dI) are
**whole-track statistics** — there is no single streaming pass that reproduces
`encode.py` exactly. So the demo is two phases, matching the roadmap's "Python
measures, the engine runs" split:

1. **`calibrate`** — a measurement pass producing `{energy_thresh, s_a, s_i}`.
2. **`Kernel::step(&mut self, frame) -> Option<Tick>`** — the real-time hot path.
   Given the calibrated constants it streams frames, reproduces A/I, finalizes the
   force one frame behind, accumulates `h`, and emits equal-energy ticks.

In Demo 2 the WAV driver is swapped for a cpal callback feeding `step` live; the
kernel does not change. The calibration constants would then come from a warm-up /
rolling estimate (out of scope here).

### `step` is allocation-free

Every buffer — the FFT plan, Hann window, bin frequencies, the complex FFT buffer
and its scratch — is built once in `Kernel::new`. The FFT runs via
`process_with_scratch` (the default `process` *would* allocate). Everything else is
scalar arithmetic over preallocated storage; `Tick`/`FrameState` are returned by
value. `tests/alloc.rs` proves **0 heap allocations** across a `step` with a
counting global allocator (its own test binary, so the allocator instruments
nothing else).

## The numbers (test clip: `506206_Night` ORIGINAL, 20 s, 44.1 kHz mono)

```
M = 1719 frames   ε_h = 5.0
N = 350 ticks     → 79.6% fewer emitted ticks (1 − N/M)
step (frames)     : min 1 · median 4 · max 15   ← genuinely content-adaptive
max |Δh|          : 5.23  ≤  ε_h + max‖F‖ = 12.15   (0.30% of h_total)
max XY error      : 0.037 ≤  r0·(1 − cos(Δα/2)) = 0.037   (chord/sagitta of widest arc)
```

The step spread (1 → 15) is the thesis: busy passages tick every frame, static
passages stretch out. The error tolerances are **closed-form and parameterized by
the knob** (halve `ε_h` → ~half the climb error, more ticks), not tuned constants:

* `max|Δh| ≤ ε_h + max‖F‖` — the carry remainder `r_i ∈ [0,‖F(n_i)‖)` makes each
  segment rise `< ε_h + max‖F‖`, and a monotone curve deviates from its chord by at
  most its rise.
* `max XY ≤ r0·(1 − cos(Δα/2))`, `Δα = ω·max_step_frames` — the sagitta of the
  widest tick arc.

`1 − N/M` is **representation** reduction (fewer emitted samples). The FFT still
runs every frame in both phases; turning repeated content into *compute* savings
(memoization) is Phase 4 — a non-goal here.

## Layout

```
src/lib.rs        Kernel, FeatureExtractor, calibrate, run, recon_error  (engine)
src/main.rs       CLI driver: WAV → calibrate → stream → ticks.csv + report
tests/acceptance.rs   #1 A/I/h match encode.py; #2 N<M + bounded recon
tests/alloc.rs        #3 step is allocation-free (counting allocator)
tests/fixtures/   reference_*.csv, dumped once from encode.py (read-only)
```

Engine dependencies are limited to `hound` + `rustfft` (per the roadmap). No
cpal/CoreAudio, beat tracking, dedup, SIMD, or codec — those are explicit
non-goals for Demo 1.
