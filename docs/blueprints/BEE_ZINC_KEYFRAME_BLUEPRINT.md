# .bee Zinc Keyframe Blueprint

**Date: 2026-07-10. Status: architecture proposal — one axis redefinition, one
math guardrail, a beecore module map, and a measured build sequence.**

Sibling to `BEE_LIGHT_BLUEPRINT.md` (the 2026-07-06 LOCKED decisions this
implements), `BEE_FORMAT_BLUEPRINT.md` (the v0 container it extends), and
`BEE_NATIVE_TRANSITION_BLUEPRINT.md` (Rust is the sole algorithm home).
Evidence base, all in-repo: `LOOP_DEDUP_FINDINGS.md`,
`POOL_RESIDUAL_FINDINGS.md` (exp4), `VERDICT.md` (exp3), `beecore/bench/RESULTS.md`.

This blueprint takes the *Zinc Keyframe mechanism* as given and says exactly
where it lives, what it wins, what it must **not** try to be, and how to build
it bit-exact against the Python reference — the same discipline that carried
Layer 1.

---

## 0. Vocabulary — the mechanism, stated directly in its own math

Earlier drafts introduced this mechanism through a zinc-finger-protein
analogy (predictive strand, major-groove insertion, polymerase drift, tandem
arrays). That analogy is retired below in favor of the math it stood in for —
the mechanism doesn't need biology to be precise, and carrying two
vocabularies for one system was itself a source of ambiguity. Kept here only
as a historical cross-reference for anyone who saw the earlier drafts:

| Former (retired) term | Resolved term used from here on |
|---|---|
| Predictive strand / protein fold `Ψ̂(t)` | **Predicted-state trajectory** `Ψ̂(t)` — the decoder's extrapolated state between anchors |
| Zinc anchor / keyframe | **Anchor state** — a full, absolute state coordinate that resets prediction error |
| Major-groove insertion / phase lock | **State reset (hard sync)** — decoder state is pinned to ground truth at that sample |
| Variable-rate tandem arrays | **Variable-rate anchor sequence** — anchors placed by content (drift), not a fixed grid |
| Polymerase drift `D(t) > τ` | **State-deviation metric** `D(t)` exceeding threshold `τ` — the anchor-placement rule |

So: **the mechanism is adaptive-threshold predictive coding with a
volatility-triggered anchor policy** — insert an anchor when the state
deviation `D(t)` exceeds `τ`, hold the predicted trajectory `Ψ̂(t)` otherwise.
Everything below uses this vocabulary. This is the concrete mechanism for the
**light-by-default base layer** locked on 2026-07-06 (`BEE_LIGHT_BLUEPRINT`
§2) — not a new format, not a fourth codec.

---

## 1. What "better than everyone" means here — pick the axis you can win

`.bee` competes on **two** axes. Only one of them is worth the word "everyone,"
and it is not file size. This is the most important decision in the document.

### 1a. PRIMARY axis — real-time topological indexing (uncontested)

Per `handoff.md` §4 and the paradigm's own closing sentence, the job is
**zero-latency semantic navigation and phase-locked AV triggering**, not the
smallest archive. No shipping audio format carries a topological index; here
`.bee` has no serious competitor. This is where the "better than everyone"
energy belongs and where "my work is no joke" becomes *measured*, not asserted.

- **Baseline:** an STFT + onset/beat-tracking pipeline (e.g. librosa
  `onset_detect` / `beat_track`) — the standard runtime path this project
  exists to be lighter than.
- **Metrics:** (i) **trigger latency** — wall-time from audio arrival to a
  phase-locked visual cue; target near-zero because the index is precomputed and
  `θ ≡ 0 (mod 2π)` is O(1). (ii) **beat-grid alignment error** — anchor phase vs.
  ground-truth downbeats, in ms. (iii) **index size** — the anchor stream in
  bytes/minute.
- **Claim to earn:** "`.bee` drives synchronized generative visuals at lower
  latency and tighter beat alignment than an STFT/onset pipeline, at a fraction
  of the runtime cost." Claimed only after measurement (repo norm).

### 1b. SECONDARY axis — bits at equal perceptual quality (winnable, perceptually only)

`BEE_LIGHT_BLUEPRINT` §1 already established: "same or better quality than FLAC
but lighter" is winnable **perceptually and only perceptually.** The
adaptive-threshold rate policy is the lever — spend ~0 bits on ambient stretches, dense
anchor arrays only on transients — riding on the neural base layer (Decision 2).

- **Baseline:** Opus and an EnCodec/DAC-family neural codec at matched bitrate.
- **Metric:** **ViSQOL / MUSHRA at a fixed bitrate**, or bitrate at fixed
  perceptual score. Never "crisper than source" without a listening test.

### 1c. NOT an axis — lossless file size (already measured dead, do not re-fight)

State this plainly so the build never drifts back into it:

- Exact byte-dedup of bars: **0%** on all three real tracks (`LOOP_DEDUP` R1).
- Pool + exact residual: **100.7–101.5% of whole-track FLAC** — strictly worse
  (exp4, `POOL_RESIDUAL_FINDINGS`).
- `beecore/bench/RESULTS.md`: `.bee` = same-encoder FLAC **±2%**; the lossless
  field is saturated (best-in-class beats FLAC by single digits).

The bit-exact path (Layer 1: `content_hash` bar dedup, `exp_5.py`) is **not**
where the win is. It survives as the **optional archive/residual profile**
(`BEE_LIGHT_BLUEPRINT` §2), proving decode(base)+residual = source. It is not
the identity of `.bee` and it is not the compression story. `exp_5.py` /
`import sys.py` did their one job — proving recall→reconstruct is bit-exact — and
now retire into that residual path. This is the experimental ground being
ditched.

---

## 2. Guardrail on the math — one correction, stated as a ceiling

The paradigm has one false link that, left in, makes the compression claim
unfalsifiable. Fix it once:

> The drift that costs bits is **signal entropy** — the audio doing something the
> predictor cannot know in advance — **not** "floating-point truncation."
> Float drift is negligible and nearly free to correct. Keyframes cost **real
> bits**. "File size scales exclusively on structural volatility" is therefore a
> bit-**allocation policy**, not an escape from entropy: you are choosing one
> point on the rate–distortion curve, not getting zero error *and* maximum
> compression simultaneously.

Consequence for the spec: `τ` is **the** rate–distortion knob. Small `τ` →
dense anchors → higher fidelity, more bytes. Large `τ` → sparse anchors → lighter,
more prediction error carried by the base layer. The compression number is
whatever the curve gives at the chosen `τ`, **measured**, per repo norms. No
theoretical "maximum ratio" is claimed.

---

## 3. Where the adaptive-threshold index lives — one layer, driving one base, being the index

Do not spawn a fourth codec. Three representations already exist: beecore's v0
FLAC/zlib container, the LOCKED neural-RVQ base + optional lossless residual, and
this predictive index. Unify:

> **The Zinc index is the adaptive-keyframe / rate-control layer that both (a) *is*
> the navigation index and (b) drives bit allocation for whichever base codec the
> manifest names. It never reconstructs audio by itself.**

- **PRIMARY target (v1): the helix STATE index.** The predicted/anchored
  quantity is the state trajectory `(A, I)` → `(r, θ, z)` from
  `beehive/encode.py`. Anchors + extrapolation between them = the compact index
  that drives conditioning, prefetch depth, `‖F‖` bit-allocation, and — the
  headline — **phase-locked AV triggers**. This is small, exact-enough for
  navigation, and contradicts nothing.

- **HARD NON-GOAL:** an adaptive-threshold predictor that reconstructs **audio** from
  `(r, θ, z)`. exp3/`VERDICT` proved the compact axis does not invert to timbre;
  LOCKED Decision 2 puts audio reconstruction in the neural base + residual. A
  keyframe predictor over 2 scalars per frame cannot carry 44.1 kHz. Off the
  table.

- **RESEARCH BET (not v1, flag only):** variable-rate **sparsification of the
  neural token stream** — emitting dense RVQ frames only where `D(t) > τ`. This
  is the real perceptual-bitrate win (axis 1b), but it is a research question
  against EnCodec/DAC, not a first deliverable. Gate it behind axis-1a shipping.

---

## 4. The algorithm, concretely (the reference oracle in `beehive/`, then Rust)

Promote the *logic* already prototyped in `mg.py` and the `encode.py` edit into a
clean reference, then port to Rust. Four pieces:

1. **Predicted-state trajectory — `Ψ̂(t)`.** v1: zero-order hold from the last anchor
   (predict = last anchored state). v2: first-order extrapolation along the helix
   tangent (`κ, τ` are already exact in `encode.py`). Keep v1 for the first
   bit-exact port; it is the simplest falsifiable baseline.

2. **Drift metric — `D(t)`.** Deviation of ground-truth state from the
   prediction **relative to the last anchor**, *not* frame-to-frame. This is the
   correction flagged in the `mg.py` prototype: `apply_polymerase_proofreading`
   currently predicts `states[i-1]` (previous frame), which measures total
   variation, not hold-error. The decoder holds the last **anchor**, so
   `D(t) = ‖s(t) − Ψ̂(t | last_anchor)‖`. Decide this before the Rust port —
   cheap now, expensive after it is in Rust and the reference has to match.

3. **Threshold — `τ`.** Starting heuristic from the drift-threshold work:
   `τ = φ · (track_volatility · MAX_PERCEPTUAL_LATENCY_SEC)` with a `1e-6` floor
   (`PHI`, `MAX_PERCEPTUAL_LATENCY_SEC = 0.020` in `encode.py`). Treat this as a
   *seed*, not a truth: `τ` is the rate–distortion knob of §2 and gets swept and
   fixed by measurement on the corpus. Note the units caveat — `track_volatility`
   mixes dB/s and semitone/s in quadrature; normalize per-channel before combining
   so `τ` means one thing.

4. **Anchor + snap.** When `D(t) > τ`: emit an **anchor** = absolute
   `(r, θ, z)` (+ raw `(A, I)`), reset `D → 0`, resume prediction from the anchor.
   Anchors cluster densely in transients, vanish in ambient passages — the
   variable-rate anchor sequence.

**Invariant — unused space is never triggered.** Un-anchored regions are pure
*absence*: no key is written, no bytes are occupied, no runtime event fires.
There is no fixed grid, no reserved slot, no zero-fill, no poll. The consumer
acts **only at anchor frames** — that absence is precisely why the AV-trigger
latency claim (§1a) holds and why ambient passages cost ~0.

**Who generates, who uses — Python authors the keys, Rust consumes them.** The
anchor-placement selector (`D(t)`/τ, §4.1–4.3) runs **encode-time in the Python
reference** and its output *is* the authoritative key set. Those keys are baked
into the `.bee` (`SECTION_ZINC_INDEX`) verbatim, exactly as `encode.py` already
authors the helix npz that `container.rs` stores byte-for-byte. **Rust does not
re-derive placement.** Rust's job is the runtime **consumer**: read the
Python-generated keys, reconstruct the trajectory, fire the phase-locked
triggers — the zero-latency path. `beehive/encode.py` therefore stays the key
generator *and* the reference oracle; the `proofreading_tau` metadata edit is
fine as reference metadata. Bit-exactness is checked on the **consumer**
reproducing the Python reference's reconstruction from the same keys.

---

## 5. beecore module map (real files)

The v0 container already carries named sections
(`container.rs`: `SECTION_AUDIO`, `SECTION_HELIX_ARRAYS`, `SECTION_HELIX_META`;
manifest `sections: BTreeMap<String, Section{offset,length}>`). The index is an
**additive** section — no break to existing readers.

- **`manifest.rs`** — add `pub const SECTION_ZINC_INDEX: &str = "zinc_index";`
  and an optional `zinc: Option<ZincMeta>` (chosen `τ`, anchor count, predictor
  version, state-channel definition). Keep `bee_format_version` bump additive; old
  readers ignore an unknown section.
- **`container.rs`** — write/read the anchor blob as one more section; extend
  `Sidechannel` unpacking to surface anchors. No change to header layout (magic /
  ver / manifest_len / blob).
- **New `src/zinc.rs` — the consumer only.** `struct Anchor { frame: u32,
  r,θ,z: f32, a,i: f32 }`; `fn read_anchors(section) -> Vec<Anchor>` (parse the
  Python-authored keys); `fn reconstruct_trajectory(&[Anchor], n_frames) -> State`
  (predict + snap between keys). **No `place_anchors` in Rust** — placement is
  Python's job (§4). Rust reads, reconstructs, triggers.
- **`src/bin/bee.rs`** — a `bee index` subcommand: emit/inspect the anchor
  stream, print anchor count + bytes/minute (axis-1a metric) and beat-alignment.
- **`bench/`** — extend `bench_formats.py` with the axis-1a measurement
  (trigger latency + beat-alignment vs an STFT/onset baseline) and record it in
  `RESULTS.md` alongside the size table.

---

## 6. Build sequence — each phase ends in a measured, bit-exact deliverable

1. **Key generator (Python, authoritative).** Clean Python `place_anchors` /
   `reconstruct_trajectory` over `encode.py`'s `(A, I) → (r, θ, z)` state, with
   the §4.2 `D(t)`-vs-anchor fix. This *is* the key set that ships. **DoD:** on
   the three real tracks, reconstruction error between anchors is bounded by `τ`;
   anchor count tracks `‖F‖`; ambient passages emit no anchors. Numbers logged.
2. **Container section.** The Python-authored anchor stream written as
   `SECTION_ZINC_INDEX` (additive, verbatim — like the helix npz); round-trip
   test in `tests/roundtrip.rs`. **DoD:** a `.bee` carries the keys; old readers
   still decode PCM.
3. **Rust consumer, bit-exact.** `zinc.rs` *reads* the Python keys and
   reconstructs the trajectory bit-for-bit against the Python reference through
   the interop harness (mirror `beecore/interop/test_interop.py`). No placement in
   Rust. **DoD:** Rust reconstruction == Python reconstruction from the same keys,
   on the corpus.
4. **Axis-1a measurement (the headline).** Trigger latency + beat-alignment +
   index size vs the STFT/onset baseline; write to `RESULTS.md`. **DoD:** a table
   that substantiates or refutes the latency/alignment claim of §1a.
5. **`τ` sweep.** Rate–distortion curve of index-error vs bytes over the corpus;
   pick and freeze a default `τ`. **DoD:** one chosen `τ` with the curve behind it.
6. **(Research, gated) token sparsification** — axis-1b, only after 1–5 ship.

---

## 7. Definition of done

- A `.bee` carries a `zinc_index` section: a variable-rate anchor stream whose
  density tracks `‖F‖`, reconstructing the state trajectory to within `τ`.
- Rust is bit-exact against the Python reference (Layer-1 discipline).
- `RESULTS.md` reports the **axis-1a** numbers (latency, beat-alignment, index
  bytes/min) vs a named STFT/onset baseline — the claim that `.bee` does its
  actual job better than the standard runtime path, measured.
- No lossless-size claim is made; no audio is reconstructed from `(r, θ, z)`.

---

## 8. OPEN — decisions the builder must make, not paper over

- **(a)** Predictor order — zero-order hold (v1) vs helix-tangent extrapolation.
  Start v1; only escalate if the `τ` sweep shows hold wastes anchors.
- **(b)** ~~`D(t)` norm and per-channel normalization of `(A, I)` before
  combining (units, §4.3).~~ **RESOLVED 2026-07-10** (`ZINC_AMBIENT_FINDINGS.md`):
  per-channel z-score, then a **two-rail rule** — event rail = state through the
  Laplace high-pass `H(s)=s/(s+λ)` (exact ZOH discretization, λ tied to the
  track's angular tempo, default `16·ω_bar(meta)` ≈ 2× true beat) fired at
  `τ_e = 3·seed`; hard rail = absolute hold error at `τ_max = 6·seed`, keeping
  the provable bound. Corpus: 18–21× sparsity, ambient decile ≤ 0.72%, bound
  holds. λ's bpm-octave sensitivity stays OPEN (clamp candidate).
- **(c)** Anchor coordinate precision — full f32 `(r,θ,z,a,i)` vs quantized. Affects
  index size (axis-1a metric); decide by measurement.
- **(d)** Whether anchors align to bar boundaries (`beehive/loops.py`, one 2π loop
  = one chunk) or float freely. Bar-alignment helps streaming prefetch; free
  placement minimizes anchors. Measure both.
