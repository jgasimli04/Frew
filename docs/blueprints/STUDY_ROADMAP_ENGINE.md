# Engine Study Roadmap — loop-clocked real-time core

Goal: build the **loop-clocked audio engine** — the runtime version of `.bee`'s
already-solved "no fixed-block uniform compute." Storage solved it with loop
chunks + `‖F‖`-driven VBR + dedup; the engine ports the *same principle from bits
to compute*: spend work ∝ `‖F‖`, and reuse (memoize) repeated loops instead of
recomputing.

**Why low-level (not Python):** the engine is a *real-time audio* problem. The
audio callback must be lock-free, allocation-free, and deterministic — Python's
GIL, GC pauses, and heap allocation are all disqualifying in the callback. And
librosa *is* Python/NumPy, so a "faster than librosa" runtime can't itself be
Python. Python stays where you **measure** (analysis, dedup rates, the math
reference in `beehive/`); low-level (Rust recommended) is where you **run**.

Study in dependency order. **Do not start a phase until the previous one runs.**
Each phase ends in a buildable milestone — that is the anchor.

---

## Phase 0 — the real-time contract (study first, before any engine code)

The hard prerequisite. The callback gets a buffer and must fill it before a
deadline, every time, with **no** `malloc`, locks, syscalls, file/network I/O, or
GC on the audio thread.

- **Read:** Ross Bencina — *Real-time audio programming 101: time waits for
  nothing* (rossbencina.com). The canonical statement of the callback contract.
- **Read/watch:** Timur Doumler — CppCon talks on real-time audio and lock-free
  programming (*"Want fast C++? Know your hardware"*, his lock-free queue talks).
- **Learn one primitive:** a single-producer/single-consumer (SPSC) lock-free
  ring buffer — how the audio thread hands data to a worker thread without
  locking. Rust: `ringbuf` crate docs.

**Milestone:** none yet — this phase is mental model. You should be able to say
exactly why a `Vec::push` (which may reallocate) is illegal in the callback.

---

## Phase 1 — get sound through low-level code

Smallest real engine: audio in → audio out, in the systems language, with zero
allocation in the hot path.

- **Lang:** Rust. Enough ownership/borrowing to not fight the compiler; the key
  real-time pattern is **preallocate everything** (`Vec::with_capacity` up front,
  never grow in the callback) and avoid dynamic dispatch (`Box<dyn …>`) in the
  hot loop.
- **Lib:** `cpal` (cross-platform audio I/O; FFIs cleanly to Swift and Python
  later). Mac-native alternative if you want it: CoreAudio / AUHAL.

**Milestone:** a zero-allocation passthrough callback — input copied to output,
glitch-free for several minutes at a small buffer size.

---

## Phase 2 — the force inputs, ported and cross-checked

Compute the state `s(n) = (A, I)` and the force in the engine, validated against
the Python reference.

- **Math (only these chapters):** Julius O. Smith III — *Mathematics of the DFT*
  and *Spectral Audio Signal Processing* (free online, CCRMA,
  ccrma.stanford.edu/~jos/). Cover: the DFT, the STFT (window + hop), magnitude
  spectrum, **spectral centroid**.
- **Math you already implicitly use:** `F = ds/dn` is a finite difference
  (numerical differentiation); `h(n) = ∫₀ⁿ‖F‖` is a cumulative sum. Know the
  discrete forms and their error behavior.
- **Lib:** FFT via `rustfft` (portable) **or** Apple Accelerate / `vDSP`
  (Mac-tuned). See the fork below.
- **Discipline:** every value (`A`, `I`, `‖F‖`, `h`) must match
  `beehive/encode.py` on the same input within tolerance. The Python code is the
  spec; the engine must reproduce it before it earns the right to be faster.

**Milestone:** per-frame `A`, `I`, `F`, `h` from a live or file input, numerically
equal to the Python encoder.

---

## Phase 3 — the loop clock (the novel core: "content owns the clock")

This is the part that makes it *not VST*. The processing unit is one loop = one
bar, its length set by tempo (`ω = 2π·bpm/(60·B)`), not by a host block size.

- **Study:** real-time tempo/beat tracking.
  - `aubio` (C library) — real-time onset, pitch, tempo. The reference real-time
    MIR toolkit.
  - Adam Stark — `BTrack` (C++), a real-time beat tracker (github.com/adamstark).
  - Algorithm background: Daniel Ellis — *Beat Tracking by Dynamic Programming*
    (2007); beat-synchronous chroma in Ellis & Poliner (2007). This is the
    peer-reviewed basis for segmenting on musical units instead of fixed frames.
- **Math:** tempo estimation = autocorrelation / comb-filter on an onset-strength
  envelope; beat placement = dynamic programming. Bar boundary → `ω` → loop
  length in samples.

**Milestone:** the engine emits a loop boundary on each bar and carries the climb
`h` across boundaries as the only handoff state.

---

## Phase 4 — fast, and reuse (where the lightness becomes real)

- **SIMD (Apple Silicon = ARM NEON):** vectorize the per-loop reductions. Use
  Accelerate / `vDSP` (NEON under the hood, easiest on your M-series) or Rust
  `std::simd` / the `pulp` crate. Profile first; only vectorize the hot loop.
- **Dedup → memoization (the runtime payoff):** cache a processed loop's output
  keyed by `content_hash` (already in `beehive/audio.py`). A repeated loop = a
  cache hit = **zero recompute**. This is `.bee`'s storage dedup, applied to
  compute.
- **FFI out:** bind the Rust core to Swift (`BeehiveMac`) via C ABI + `cbindgen`
  or `uniffi`; bind to Python (measurement/research) via `PyO3`. One core, two
  consumers, no rewrite.

**Milestone:** a busy passage and a static/repetitive passage show a measurable
compute gap — static/repeated loops cost near zero. That number *is* the thesis.

---

## The one real fork (decide, don't agonize)

**FFT / vector backend:**
- `rustfft` + `std::simd` — pure-Rust, **portable**, core stays platform-neutral.
- Accelerate / `vDSP` — **Mac-tuned**, faster on M-series now, but ties the core
  to Apple.

Pick portable if the core must run everywhere; pick `vDSP` if Mac performance is
the priority for the first build. This does not block Phases 0–1; decide by
Phase 2.

---

## Skip for now (rabbit holes, deferred per the blueprint)

- **Frenet–Serret curvature/torsion** — analysis-side geometry, not on the path
  to a running engine.
- **Near-duplicate / similarity dedup** — unsolved design problem; exact
  `content_hash` is enough for loop-based material first.
- **FLAC/ALAC-style predictive + entropy coding** — the heavy lossless core;
  the blueprint gates it behind a working raw-PCM baseline. Not engine-MVP.

---

## Reference anchors already in this repo

- `beehive/encode.py` — the spec the engine must reproduce (Phase 2 check).
- `beehive/audio.py` — `content_hash`, the dedup/memoization key (Phase 4).
- `BEE_FORMAT_BLUEPRINT.md` — the storage-side solution this engine mirrors.
- `SKILL_updated.md` — the locked model + working norms.
