# `.bee` Neural Playback — roadmap (the "doesn't wait for the exact bits" layer)

**Status: forward-looking. Not built. Sits *on top of* the lossless floor, not
instead of it.** This document captures the dynamic-neural-decoding vision and
separates, per the project's standing rule, what is **established** (peer-reviewed)
from what is **conjecture** (analogy, still to test). It does not claim "the math
checks out" — one central piece is already contradicted by the project's own exp3
(`VERDICT.md`), and that is stated plainly below.

Read `BEE_FORMAT_BLUEPRINT.md` first. This is a sibling to it: the blueprint
defines the file format (a lossless audio payload + the helix/chroma
side-channel); this defines a *future playback path* that would reconstruct audio
from the side-channel using a neural decoder rather than from the exact payload
bits.

---

## 1. The vision, stated faithfully

The idea: playback should not require the decoder to receive and verify the exact
bitstream (`010101…`) before it produces sound. Instead, a neural network already
present on the device uses the `.bee` side-channel (the helix geometry, the force/
climb `‖F‖`, the chroma vector) as **conditioning** and *generates* the audio
dynamically — spending model capacity ("clarity") only where the music is moving,
which the side-channel already marks via `‖F‖`. The hoped-for result: tracks that
sound defined and crisp, with elements that "sit on top of each other" rather than
being summed into one mix — a different way of presenting stereo/space.

This is a real research direction. It is also partly contradicted by our own
findings. Both are true; below is which is which.

---

## 2. Established (peer-reviewed) — what genuinely supports the vision

- **Audio can be reconstructed from compact conditioning by a neural decoder.**
  This is exactly what neural audio codecs do: SoundStream (Zeghidour et al.,
  2021), EnCodec (Défossez et al., 2022), DAC (Kumar et al., 2023) reconstruct
  audio from quantized indices into a learned codebook far smaller than the raw
  signal. Neural vocoders (WaveNet, van den Oord et al., 2016; HiFi-GAN, Kong et
  al., 2020) reconstruct waveform from compact acoustic features
  (e.g. mel-spectrograms). *The blueprint already cites the codec family in §3.2.*
  (Architectural specifics should be checked against each paper before being
  asserted — same hedge the blueprint applies to these citations.)
- **"Doesn't wait for the exact bits" = generative, not error-checked, decoding.**
  A generative decoder produces plausible output from conditioning without needing
  a bit-exact bitstream. This is genuinely how the codecs above run at inference;
  it is **lossy** reconstruction, which is the key distinction in §3.
- **Modern devices ship the hardware for it.** On-device neural inference is
  standard: Apple Neural Engine via Core ML, Android NNAPI / NPUs. Running a small
  neural decoder client-side is realistic, not speculative.
- **Spending bits/capacity where the signal moves is principled.** This is
  rate–distortion / variable-bitrate allocation — the same idea the blueprint's
  §2 already grounds `‖F‖`-driven allocation in. The side-channel's `‖F‖` is a
  legitimate controller for *where* a decoder should spend effort.
- **"Elements on top of each other, not summed into one mix" has a real
  neighbour: object-/parametric-based audio.** Dolby Atmos and MPEG-H represent a
  scene as separate objects + spatial metadata rendered at playback, rather than a
  pre-summed stereo bus. Source separation (e.g. Open-Unmix, Hybrid Demucs) can
  decompose an existing mix into stems. So "keep elements separate and render them"
  is established practice — under the name object-based audio, not a new stereo.

## 3. Refuted in-project — the constraint the vision must respect

**The compact axis (chroma) does not invert to faithful audio.** exp3
(`VERDICT.md`) tested the nearest version of "reconstruct sound from the
side-channel": a *different* timbre produced the *same* 12-d chroma vector — the
recovered formant center was 102 Hz off while the chroma matched to 1.1e-8.
Chroma is **many-to-one in timbre**. This is *why* the project pivoted (blueprint
§2) and stopped asking the compact axis to reconstruct audio.

Consequence for this roadmap — the load-bearing engineering constraint:

- A neural decoder conditioned on **chroma alone cannot faithfully reconstruct**
  the original. It can only *generate something plausible* in the same pitch-class
  neighbourhood. That is **lossy/generative** playback, categorically different
  from the lossless floor the format already delivers.
- To get closer to faithful, the decoder must be conditioned on **more than
  chroma** — at minimum a representation that is not many-to-one in timbre
  (the dense spectral axis *is* invertible per exp3, but it is the heavy thing the
  project exists to avoid). Finding a conditioning set that is *both* compact *and*
  timbre-identifiable is an open research problem flagged in `VERDICT.md`, not a
  solved one.
- **Measured at bar scale (2026-06-22, `LOOP_DEDUP_FINDINGS.md`):** pooling bars
  by chroma matches bars that differ 22–400% in audio (exp3 in the wild); pooling
  by a **discriminative spectral fingerprint** pools 50–80% of bars at <20%
  phase-invariant residual. So the conditioning the generative decoder needs is a
  discriminative spectrum, **not** chroma — and at that residual it is squarely in
  the regime neural vocoders reconstruct from. This is the concrete bridge from
  "vision" to "buildable," with the chroma misconception corrected by data.

## 4. Conjecture (flag, don't build on) — needs evidence before it carries weight

- **"Songs come out more defined/crisp than the source."** Not supportable as
  stated: a decoder cannot add information the capture didn't keep (data-processing
  inequality). What *is* achievable and worth testing: a generative decoder can
  produce perceptually *clean* output (no quantization hiss), and `‖F‖`-driven
  allocation can place detail where it is perceived — "cleaner/!more flattering,"
  not "more than the original." Test against the original with listening studies
  (MUSHRA) + objective metrics (ViSQOL, PESQ); never claim "crisper than source"
  without that.
- **"New type of stereo / sounds blend without mixing."** Conjecture. Its honest
  grounding is object-based audio (§2): if the encoder kept *separate* elements
  (stems) + spatial metadata and the decoder rendered them per-device, you get
  "elements not summed into one bus" — but that is established object audio, and it
  requires the encoder to actually capture separate objects, which `.bee` does not
  do today (it stores one mixed payload + a side-channel). What would need to be
  true: a stems/objects layer in the container (see §5), backed by source
  separation or stems at upload. Until then this is a hypothesis, not a feature.

## 5. The gated build path (in order; each gate is a real precondition)

This respects the blueprint's existing gates — Rust and Swift do not start early,
and nothing here weakens the lossless floor.

1. **Floor (DONE).** `beehive/beefile.py`: lossless two-layer `.bee`, bit-exact
   round-trip, demonstrated on real tracks. Everything below rides on this.
2. **§4(a) decision + bar-level dedup (blueprint §6 steps 2–5).** Decide the
   payload coder; cut the payload into per-bar loops; measure dedup. Still Python.
3. **Stems/objects layer (only if §4 "new stereo" is pursued).** Extend the
   container with an optional separate-elements layer (stems + spatial metadata).
   This is the *real* prerequisite for "elements on top of each other," and it is
   object-based audio, scoped honestly.
4. **Neural decoder experiment (research, lossy).** Train/condition a small neural
   decoder on the side-channel (must include timbre-identifiable conditioning per
   §3, not chroma alone). Evaluate as a lossy codec (MUSHRA/ViSQOL) against EnCodec/
   DAC baselines. Report honestly; do not ship until it beats a baseline.
5. **On-device consumer (Swift/iOS) + Rust core.** Per blueprint §4(c): the lossless
   core (if §4a goes predictive) lands in Rust; Swift/iOS is the *consumer* that
   reads `.bee` and runs the Core ML decoder. iOS is a new target — today only the
   macOS `BeehiveMac` viewer exists. This is the last gate, not the first.

## 6. One-line honesty summary

`.bee` today is a **lossless** container with a helix side-channel. The neural
"derive-the-clarity-dynamically" playback is a **lossy, generative** future layer
that is reconcilable with the literature (neural codecs) **but not** with faithful
reconstruction from chroma (exp3), and whose "crisper than source / new stereo"
claims are conjecture pending the tests and the stems layer named above.

---

### References (verify specifics against the papers before asserting details)
- Zeghidour et al., *SoundStream: An End-to-End Neural Audio Codec*, 2021.
- Défossez et al., *High Fidelity Neural Audio Compression* (EnCodec), 2022.
- Kumar et al., *High-Fidelity Audio Compression with Improved RVQGAN* (DAC), 2023.
- van den Oord et al., *WaveNet*, 2016; Kong et al., *HiFi-GAN*, 2020.
- Foote, *Visualizing Music and Audio Using Self-Similarity*, 1999 (repetition).
- Object-based audio: Dolby Atmos; MPEG-H 3D Audio (ISO/IEC 23008-3).
- Source separation: Stöter et al., *Open-Unmix*, 2019; Défossez, *Hybrid Demucs*, 2021.
