# .bee Light — the refocus blueprint

**Date: 2026-07-06. Status: two decisions LOCKED (user, this date), one gate OPEN.**
Sibling to `BEE_FORMAT_BLUEPRINT.md` (the v0 container it amends) and
`BEE_NEURAL_PLAYBACK_ROADMAP.md` (the vision doc this promotes from "future
layer" to "the base layer"). Evidence base: `LOOP_DEDUP_FINDINGS.md`,
`POOL_RESIDUAL_FINDINGS.md` (exp4), `VERDICT.md`.

---

## 1. Why the refocus

The north star was always: *you have a heavy FLAC; `.bee` is the same or better
quality, lighter on disk, and literally lighter to stream because the stream
logic is tuned to the format.* The v0 build drifted from that — today's `.bee`
stores FLAC inside the container plus the helix record, so it weighs what FLAC
weighs (measured on ~/Desktop/Music: 87.5–97.5% of source).

Every **lossless** route to "meaningfully lighter" has since been measured dead
on real mastered music, by this project's own experiments:

- exact byte-dedup of bars: **0%** on all three tracks (LOOP_DEDUP Result 1);
- pool + exact residual: **100.7–101.5% of whole-track FLAC** — strictly worse
  (exp4, POOL_RESIDUAL_FINDINGS);
- the lossless-codec field itself is saturated (best-in-class beats FLAC by
  single-digit percent).

What **is** alive, measured: 50–80% of bars are spectrally reusable at <20%
phase-invariant residual (LOOP_DEDUP Result 3) — the perceptual/generative
regime. The sources run 726–1412 kbps; perceptual transparency lives around
160–256 kbps and neural codecs far below that. "Same or better quality than
FLAC, but lighter" is winnable **perceptually**, and only perceptually.

## 2. Decision 1 (LOCKED): light by default, exact optional

A `.bee` is:

- **Base layer (always present, always what streams):** a perceptual encoding,
  target: indistinguishable from source (provable by ABX / MUSHRA / ViSQOL —
  claimed only after measurement, per project norms).
- **Residual section (optional, archive profile):** a lossless correction that
  tops decode(base) + residual up to **bit-exact** source PCM. Carrying it costs
  roughly FLAC weight; the point is that the *default* `.bee` doesn't carry it.
- **Helix side-channel (unchanged):** A, I, chroma, ‖F‖ per frame — navigation,
  bit-allocation control, and indexing. Never reconstructs audio (exp3).

Streaming ships the base layer in **bar-aligned chunks** (one chunk = one 2π
loop, `beehive/loops.py` segmentation); the residual streams only on explicit
demand. ‖F‖ drives both bit allocation and prefetch depth. This is the "stream
logic tuned to the format" made concrete.

**Consequence:** the bit-exact contract moves from "what `.bee` is" to "what
the archive profile of `.bee` guarantees." beecore's bit-exact decode survives
as the residual/archive path, not as the identity of the format.

## 3. Decision 2 (LOCKED): the base layer engine is the neural route

Chosen over (a) vendoring a proven DSP codec now and (b) building a bee-native
transform coder from scratch. The base layer is a neural codec of the
EnCodec/DAC family (RVQ token streams), per BEE_NEURAL_PLAYBACK_ROADMAP §2 —
the peer-reviewed, established part of that doc. The container stays
codec-agnostic (the manifest names the codec per file), so the engine can be
upgraded without a format break.

Known constraints carried in from the roadmap, restated so nobody re-learns
them:

- Conditioning/pooling must key on **discriminative spectra, not chroma**
  (chroma is many-to-one in timbre — exp3, LOOP_DEDUP Result 2).
- "Crisper than source" is conjecture; never claim it without listening tests.
- A lossless residual against a *neural* base requires **deterministic decode**
  of the base on the platform computing/applying the residual. Float
  nondeterminism across CPU/GPU/ANE is a real, known hazard: v1 scopes the
  bit-exact residual contract to a pinned CPU decode; cross-platform
  determinism is its own later gate.

## 4. The OPEN gate: quality on real tracks, measured first

Nothing container-shaped gets rebuilt until this gate is passed:

> **exp5 (`experiments/exp5_neural_base.py`):** encode the three helichain
> tracks through a pretrained DAC-family model at 44.1 kHz, decode, and report
> (1) real token-stream sizes vs FLAC, (2) objective spectral distances,
> (3) reconstruction files for listening. The user's ears are the gate.

Pass → build sequence §5. Fail at full codebook depth → the neural engine is
not ready as-is; fall back to the proven-codec base (decision 2 revisited with
evidence, not vibes).

## 5. Build sequence after the gate (small, verifiable steps)

1. **Base-layer section in the container** (`beehive/beefile.py`): new section
   `base` (codec id + token payload, bar-aligned framing), FLAC payload becomes
   the optional `residual`/archive section. Light profile = default in
   `scripts/convert_to_bee.py`; `--archive` keeps bit-exact.
2. **Bar-aligned token chunking**: group base tokens by the ω/bpm bar grid so a
   chunk = one loop; recall-entry headers per BEE_FORMAT_BLUEPRINT §3.3.
3. **Residual profile**: exact residual = source PCM − pinned-CPU decode(base),
   entropy-coded; acceptance bar = sha256-identical PCM, same as v0.
4. **Stream logic**: a measured demo — bytes-to-first-sound and bytes-per-
   minute vs FLAC-over-HTTP, using bar chunks + ‖F‖-driven prefetch.
5. **Native playback** (last gate, per roadmap §5): ONNX/Core ML export of the
   decoder for beecore/BeehiveMac; not before the format settles.

## 6. Out of scope (unchanged from prior blueprints)

Training our own codec from scratch; cross-song shared pools; near-duplicate
dedup thresholds (§4b stays open); stems/objects layer; radius law, ‖F‖
weighting, beehive packing (theory frontier).
