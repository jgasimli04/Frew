# Claude Code prompt — Demo 1: the adaptive-time-step kernel (Rust)

Run inside `/Users/jgasimli/sonoFaig`. This is the first running demo of the
**time-based kernel feedback loop**: the kernel advances through audio in steps
whose length adapts to how fast the music is changing (`‖F‖`), not on a fixed
frame grid. Goal: show it produces the helix trajectory AND does measurably less
work than a fixed-step baseline, at bounded reconstruction error. Rust, not Python.

---

Build the first running demo of the loop-clocked, ADAPTIVE-time-step audio kernel — in RUST. Not Python.

This is the "time-based kernel feedback loop": the kernel advances through audio in steps whose length adapts to how fast the music is changing (‖F‖), instead of a fixed frame grid. Prove it (a) produces the helix trajectory and (b) does measurably less work than a fixed-step baseline on the same audio, at bounded reconstruction error.

READ FIRST (these define the model + notation — match them exactly, do not invent):
- SKILL_updated.md — the locked model and symbols.
- BEE_FORMAT_BLUEPRINT.md §1 — the proven helix/force/climb math.
- beehive/encode.py — the Python REFERENCE. Your Rust output must reproduce its A, I, h on the same input. Use its EXACT definitions of A (loudness dB), I (spectral centroid in semitones above its reference), and its derivative normalization (each derivative by running std, w_amp=w_int=1). Do not guess these — read them.
- STUDY_ROADMAP_ENGINE.md — phases + non-goals.

MODEL:
- Per analysis frame k (2048 Hann window, 512 hop, rustfft): state s(k) = (A(k), I(k)) per encode.py.
- Force F(k) = (A(k)-A(k-1), I(k)-I(k-1)); ‖F‖ = sqrt(dA²+dI²) after encode.py's normalization.
- Climb h accumulates ‖F‖. Angle α = ω·t, ω = 2π·bpm/(60·B), B=4 (CLI-overridable). Helix R = (r0·cosα, r0·sinα, h), r0=1.

THE KERNEL (the new part — the controller):
- Do NOT emit a point per frame. Walk frames accumulating ‖F‖; emit a kernel TICK only when accumulated ‖F‖ since the last tick reaches threshold ε_h → equal-energy ticks: long steps in static passages, short steps where the music moves. ε_h is the one knob (CLI arg).
- This is error-controlled step-size sampling (cf. adaptive Runge–Kutta / equal-arc-length). The accumulated-‖F‖ vs ε_h test IS the feedback controller.

STRUCTURE it like a real-time processor even though demo 1 is file-driven:
- A `Kernel` struct holding ALL running state, with `fn step(&mut self, frame: &[f32]) -> Option<Tick>`. Preallocate every buffer in `Kernel::new`. The hot path (`step`) must do ZERO heap allocation — document how that's guaranteed and assert it in a test (counting allocator).
- Demo 1 driver = a WAV reader feeding frames into `step`. (NEXT step, not now: swap the WAV driver for a cpal callback — the kernel must not change.)

DELIVER:
- One Rust crate: `cargo run --release -- <wav> --bpm <n> --eps <ε_h>`.
- Test input: recon/506206_Night_(Original Mix)/506206_Night_(Original Mix)_ORIGINAL_75s.wav
- Emit ticks.csv: n, t_seconds, alpha, x, y, h, f_norm, step_frames.
- Print: total frames M, adaptive ticks N, work reduction (1 − N/M), and max reconstruction error of the adaptive helix vs the full fixed-step helix (interpolate adaptive ticks back onto the frame grid; report max |Δh| and max XY error).

ACCEPTANCE (numbers, not vibes):
1. A, I, h from the Rust frame pass match encode.py within 1e-3 relative on the test WAV. You may run encode.py ONCE, read-only, to dump reference arrays. No engine logic in Python.
2. N < M materially on the 75s clip (real gap from static passages), max reconstruction error under a stated tolerance.
3. `cargo test` asserts (1), (2), and that `step` is allocation-free.

CONSTRAINTS: Rust only for all engine logic. Apple Silicon (M-series). Deps limited to hound + rustfft. No GUI.

NON-GOALS (do NOT build): cpal/CoreAudio callback, beat tracking (bpm is a CLI arg), dedup, SIMD, lossless/entropy codec. Just the kernel and the number.

---

## Why this is the right first demo

- It isolates **your logic** (the adaptive, energy-clocked kernel) from the
  real-time plumbing (CoreAudio/cpal), so the demo can't fail for reasons
  unrelated to the idea.
- The headline number — adaptive ticks `N` vs fixed frames `M` at bounded error —
  is the lightness thesis made checkable. That gap is the whole claim.
- The `Kernel::step` shape is already the real-time interface: demo 2 swaps the
  WAV driver for a cpal callback with no change to the kernel.
- `ε_h` (energy per tick) is the one knob — it is the step-size controller of the
  time-based kernel feedback loop, in one number.
