# .bee Audio Format — Blueprint

**Target: Claude Code (Opus, max effort) — build session: next, after 2026-06-21 pivot**

This is a build spec, not theory exposition. It is a sibling to
`BEEHIVE_BLUEPRINT.md` (the helix/chroma prototype spec) and carries forward
the verdict in `VERDICT.md` (2026-06-20). Everything below is either proven in
a prior session (cited), or flagged explicitly as **OPEN** — an unresolved
design choice the next builder must make a real decision about, not paper over.
Don't treat silence as confidence, and don't invent a resolution to anything
marked OPEN.

Read `~/.claude/skills/beehive/SKILL.md` first for the full vocabulary and the
working norms (derive don't deliver, no invented terminology, no guessing,
peer-review backing for new claims). This blueprint assumes that context.

A plain-language note on what changed: until today, the helix/chroma data *was*
the whole representation — the project's ambition was that the compact 12-number
"chroma" axis would correlate uniquely with timbre and so could double as a
near-lossless compact code for the sound. The 2026-06-20 prototype showed that
correlation does not hold (see §1). Today the project stops asking the compact
axis to reconstruct audio at all, and instead defines `.bee` as a real audio
**file format** with two separate layers: a genuine audio payload that *can* be
reconstructed bit-for-bit, and the helix/force/chroma data riding alongside it
as a navigation and compression side-channel. The rest of this document
specifies that split.

---

## 1. What's already proven — carry it forward, don't re-derive it

**Core helix (locked-in math).** Position
`R(n) = (r0·cos(ωn), r0·sin(ωn), h(n))`, where `ω = 2π·bpm/(60·B)`
(B = beats per bar; one bar = one full 2π turn) and `h(n) = ∫₀ⁿ ‖F(m)‖ dm`.
State `s(n) = (A(n), I(n))` — amplitude (loudness, dB) and interval (spectral
centroid, semitones above a reference). Force `F(n) = ds/dn` is a vector; its
magnitude `‖F(n)‖` is "energy spent" and drives the climb. Static passages
(`F ≈ 0`) cost almost nothing; dynamic passages (large `‖F‖`) climb steeply.
`n` is a pluggable index — currently the hop/frame index in the real-audio
encoder (`beehive/encode.py`).

**Curvature/torsion (exact, sympy-verified, constant r0):**
```
κ(n) = ω·r0·√(ω⁴r0² + ω²h′² + h″²) / (ω²r0² + h′²)^(3/2)
τ(n) = ω·(ω²h′ + h‴) / (ω⁴r0² + ω²h′² + h″²)
```
`h′ = ‖F(n)‖`, `h″` its rate of change, `h‴` its jerk. (The under-root term is
`ω⁴r0²`; this corrects a one-character typo caught on 2026-06-20.)

**The representation finding (`VERDICT.md`, exp3) — this is *why* we pivoted.**
A synthetic tone was encoded and then the source was recovered from the
encoding, two ways:
- From the **full dense spectral axis** (a smoothed magnitude spectrum, i.e. the
  STFT-like representation this project exists to be lighter than): both the
  fundamental `f0` and the formant (timbre) shape come back exactly —
  `f0` to +0.0 cents, formant centers at 0 Hz error, fit loss 9.8e-21.
  **Invertible: yes** (in-model, noise-free — an identifiability check, not a
  robustness claim on real recordings).
- From the **compact chroma axis** (the 12-number vector actually kept on disk):
  `f0` comes back (given multi-restart search), but timbre does **not**. A
  *different* formant shape produced the *same* chroma vector — the recovered
  formant center was **102 Hz off** while the chroma itself matched to 1.1e-8.
  **Invertible: no — chroma is many-to-one in timbre.**

So as of today there is **no single axis that is both compact and invertible**.
The dense axis inverts but is the heavy thing we're trying to avoid; the compact
axis is light but loses timbre. That gap is the reason for the pivot in §2 —
not a bug to fix before proceeding.

**What's stored on disk today** (`beehive/record.py`): only `A` (loudness),
`I` (interval), `chroma` (12-dim), and `engagement` (reserved, currently zeros)
per frame. No waveform, no phase. The docstring is explicit: "a dense STFT is
what we refuse to keep." Nothing in the codebase synthesizes audio back from a
record — there is **no decoder of any kind today** (see §5).

All of the above is **Python** today, and that is deliberate, not incidental:
the proven core is the reference implementation. Which language owns which part
of `.bee` going forward (Python reference / Rust production core / Swift
consumer) is settled in §4(c) — read it before assuming any of this gets
rewritten in another language.

**One reusable primitive already exists.** `beehive/audio.py` has
`content_hash(y)`: a SHA-256 over the float32 waveform samples (not the
container bytes), so the same audio in a different file format hashes the same.
It is used today at whole-song granularity to make "analyse each song once"
idempotent in the helichain. The pivot in §3 reuses this exact function at a
*finer* granularity (one bar instead of one whole song).

---

## 2. The pivot — stated precisely

**Drop the requirement that the compact axis (chroma) be invertible to audio.**
The original goal — chroma correlates uniquely with timbre, so it can serve as a
compact lossless-ish code — is abandoned because exp3 showed the correlation is
many-to-one (§1). Rather than block the project on solving timbre
identifiability under chroma (a genuinely hard, possibly-multi-session research
problem flagged in `VERDICT.md`), the representation responsibility is split:

- The **helix/force/chroma data stops being the thing that reconstructs audio.**
  It becomes *metadata* — a navigation and compression side-channel.
- A **separate, real audio payload** becomes the thing responsible for exact
  reconstruction. `.bee` is now a digital audio **file format**, not just the
  output of an analysis library.

Concretely, the side-channel earns its keep in two ways that are both standard,
well-understood ideas (not novel claims):
1. `‖F‖` (energy spent / how much the music is moving) drives **variable bit
   allocation** — more bits where the music moves, fewer where it's static.
   This is the same rate-distortion principle behind every variable-bitrate
   (VBR) codec: spend bits where they matter.
2. `chroma` becomes a **search/matching index** over chunks of audio — a way to
   find "which chunk looks like this" — *not* a signal that gets reconstructed.

Nothing in this pivot makes anything "lossless" yet. Whether `.bee` is lossless
depends entirely on the payload-encoding decision in §4(a), which is **not made**
in this document.

---

## 3. `.bee` container design — two layers

`.bee` is two layers stored together:

**Layer 1 — the audio payload (the thing that actually reconstructs).**
A sequence of audio chunks that, taken together, reconstruct the original PCM
(uncompressed digital audio samples). The *encoding of each chunk* is an OPEN
decision — see §4(a). What is settled is the **chunk unit**: one chunk = one
**loop** = one **bar** (see below).

**Layer 2 — the helix/chroma side-channel (navigation + compression control).**
Per chunk, the force/climb summary and the chroma vector. This layer does not
reconstruct audio; it decides chunk boundaries, governs bit allocation, and
indexes chunks for matching/dedup.

### 3.1 Why a chunk is one loop (one bar)

Every bar is already a closed 2π loop in the helix: with `r0` constant, the
`(x, y)` circle is *identical* on every bar — only `z` (the climb `h`) and the
underlying audio content differ from one bar to the next. So the natural unit to
cut the audio into is not an arbitrary time slice but **one loop = one bar**,
whose length in samples falls directly out of the existing `ω`/bpm math
(`ω = 2π·bpm/(60·B)`, one bar = one full turn). Cutting on bar boundaries is
what makes the dedup mechanism below meaningful, because a musically repeated
section recurs on bar boundaries.

### 3.2 The recall-entry idea (deduplication)

Because chunks are bars, two bars with **identical audio content** can be
detected and stored **once**. Reuse `content_hash` (§1) at loop granularity:
hash each bar's audio samples. Then:

- A **loop pool** holds each *unique* bar payload exactly once.
- A song becomes a sequence of **recall entries**, each roughly
  `(loop_hash, climb_height, chroma_vector, …)` — "play the loop with this hash,
  positioned at this climb height." The bar's audio is *not* repeated inline; the
  recall entry points into the pool.
- The pool is intended to be **shared across the whole helichain**, not just
  within one song — a drum loop or a chorus can recur across many different
  tracks, so a bar unique to one song may already exist in the pool from another.
  (Start single-song first — see §6/§7 — but the format should not preclude a
  shared pool.)

The reframe: a "song" stops being "3 minutes of unique audio" and becomes
"however many recall events it takes to walk through loops, most of which
already exist in the pool." This is **deduplication layered on top of the
force-driven VBR** of Layer 1 — two distinct compression mechanisms, not one.

**Precedent (state as precedent for the *idea*, not as proven for this exact
system):**
- Neural audio codecs already reconstruct audio from indices into a shared
  codebook far smaller than the corpus, at frame/token scale: SoundStream
  (Zeghidour et al., 2021), EnCodec (Défossez et al., 2022), DAC (Kumar et al.,
  2023). Same idea — reconstruct from references into a shared book of units —
  at a different (much finer) scale than a bar. To the best of available
  knowledge these are the right citations; exact architectural details should be
  checked against the papers before being asserted.
- MIR self-similarity / audio-structure work shows most recordings are mostly
  *repeated* sections: Foote, "Visualizing Music and Audio Using
  Self-Similarity," 1999. This empirically supports the claim that a real song
  is not 3 minutes of unique information — repetition is the norm, which is what
  makes bar-level dedup worth doing.

### 3.3 What a chunk/recall-entry header needs to carry

Concrete enough to build against, without pinning a byte layout (the payload
encoding itself is undecided, §4(a), so freezing bytes now would be premature):

- **loop hash** — `content_hash` of the bar's audio samples; the dedup key and
  the pointer into the loop pool.
- **climb height / force summary** — at minimum the bar's climb `h` (its `z`
  position); optionally a compact `‖F‖` summary for that bar (so a reader knows
  how dynamic the bar is, e.g. for VBR bit-allocation decisions). This is what
  distinguishes two recall entries that point at the *same* loop payload but sit
  at *different* heights.
- **chroma vector** — the 12-dim vector for the bar, carried for
  search/matching/indexing only (explicitly *not* used to reconstruct audio).
- **payload reference** — a pointer into the loop pool (for a deduped/repeated
  bar) **or** an inline payload (for a bar appearing for the first time). One
  flag distinguishes the two cases.
- **bar timing/index** — where this bar sits in the song (bar number / sample
  offset / length in samples), so the sequence reassembles in order.

### 3.4 A precision caveat to write into the format docs (don't overclaim)

"Nanosecond on-demand chunk loading" only holds for chunks **already resident in
RAM/cache**. From disk it is **microsecond**-scale (SSD page reads); over a
**network** it is **millisecond**-scale. State this plainly wherever load latency
is described, so nobody reads "nanosecond" as an unconditional property of the
format.

---

## 4. Open decisions this build must NOT silently resolve

These are blocking design choices for whoever picks this up. State both sides;
do not pick a winner here.

### (a) Payload encoding — raw PCM vs. real lossless predictive+entropy coding

- **Raw PCM in chunks.** Store each unique bar's samples verbatim. Pro:
  trivially correct and bit-exact by construction; nothing to build; an easy,
  obviously-lossless baseline. Con: no compression *within* a chunk — the only
  savings come from dedup (§3.2) and from not storing the dense STFT; a unique
  bar costs its full sample size.
- **Real lossless residual coding** (FLAC/ALAC/WavPack-style: linear prediction
  + exact integer residual + entropy coding). Pro: genuine within-chunk
  compression while staying bit-exact; this is what real lossless codecs do.
  Con: substantially more to build and to verify bit-exact; the place most likely
  to introduce reconstruction bugs.

**Unresolved because** this is the choice that determines whether `.bee` is
"lossless with real compression" or "lossless but only deduped" — and it trades
implementation risk against compression ratio. The §6 build sequence
*recommends starting with raw PCM as a baseline* to get a working round-trip
first, but **does not decide** that raw PCM is the final answer.

### (b) Dedup matching — exact hash vs. near-duplicate / similarity threshold

- **Exact, bit-identical loops (SHA-256 equality).** Two bars dedup only if
  their samples are byte-for-byte identical. Pro: nothing new to build —
  `content_hash` already exists and is exact; zero risk of a false match. Con:
  brittle — a human-played repeat differs by microtiming and dynamics every time
  and will **never** hash-match, so this only compresses loop-based/programmed
  audio (e.g. the electronic tracks currently in the helichain), not live or
  acoustic recordings.
- **Near-duplicate / similarity matching.** Treat two bars as "the same loop" if
  they are close under some similarity measure (within a threshold). Pro:
  generalizes to live/acoustic music, where nothing is ever bit-identical. Con:
  requires designing a closeness measure and a threshold — an **unsolved design
  problem** here; and once two non-identical bars are treated as one, you must
  decide what gets reconstructed (one canonical loop? a residual against it?),
  which interacts with §4(a).

**Unresolved because** exact matching is free but narrow; near-duplicate
matching is general but unbuilt and risks correctness. The three songs currently
in the helichain are loop-based electronic tracks ("Original Mix"), where exact
dedup is plausible — so the §6 sequence starts with exact-hash only, but this is
explicitly the **next open decision**, not a final answer.

### (c) Implementation language strategy — who builds what, in what language

This is a direct extension of the open §4(a) payload-encoding decision: it does
**not** pick a side of §4(a), it only assigns *which language* owns each part of
`.bee` once a side is eventually chosen. The split is three-way:

- **Python owns the reference / spec implementation.** This is not a default —
  it is because every piece of the invention that is actually *proven* lives in
  `beehive/`, tested, in numbers that can be checked: the helix math, force /
  climb, `content_hash`, exp1–3 (`VERDICT.md`), and the §6 build sequence already
  underway. The reference definition of the format must be the single source of
  truth, and switching language now — while §4(a) and §4(b) are still open —
  would mean re-verifying all of that proven work against a moving target for no
  gain. Python stays the source of truth for the format definition, the research,
  and the dedup-rate analysis **permanently**.
- **Rust owns the eventual production lossless core** — specifically the real
  predictive + entropy coder, *if and only if* §4(a) is decided in that direction
  (the FLAC/ALAC/WavPack-style side) rather than raw PCM. This is not arbitrary.
  To the best of available knowledge, new bit-exact audio codecs are in practice
  being written in Rust — Symphonia and Claxon are pure-Rust lossless / media
  decoders (Claxon is a FLAC decoder; Symphonia is a broader pure-Rust media
  decoding framework) — so the precedent for doing exactly this kind of bit-level
  audio work in Rust is real; exact scope and current capabilities of each should
  be checked against their repositories before being asserted, the same way §3.2
  hedges the SoundStream/EnCodec/DAC and Foote-1999 citations. The reason to
  reach for Rust *here specifically* is that the lossless core is the bit-level
  work — LPC prediction, exact integer residuals, entropy coding — where
  correctness bugs are easy to introduce and hard to catch, and Rust gives
  C-level performance with memory-safety guarantees over precisely that work. It
  can later bind into Python via PyO3 and into the Swift app via the C ABI / FFI,
  so adopting it does **not** force a second rewrite of the proven math.
- **Swift stays the consumer.** The existing `BeehiveMac` viewer app reads and
  plays `.bee` once there is something to read; it does **not** reimplement the
  codec in either direction. Reconstruction is the payload core's job, exposed to
  Swift over FFI.

**Sequencing constraint (important — Rust does NOT start now).** Rust enters
only after *both* of these are true, in this order:
1. **§4(a) is actually decided** — really decided, not merely discussed here.
   There is no reason to write a real entropy coder before the chunk / payload
   shape it operates on is fixed, and §4(a) deliberately leaves that shape open.
2. **The §6 step 5 raw-PCM baseline exists and works** — a tested, bit-exact
   round-trip in Python (raw PCM is the simplest, already-recommended starting
   option for §4(a)). Writing low-level Rust before that baseline exists risks
   building exacting bit-level code against a format that is still moving.

Until both conditions hold, every part of `.bee` is Python (see §6, §7).

---

## 5. Inherited open frontier from the original theory (still applies)

These predate today's pivot and remain open. Note them in code comments as
`# TODO: open theory question, see SKILL.md` where relevant; do not resolve them.

- **The radius law — how/whether `r(n)` grows.** "Completion" = the outermost
  full turn, reached once, at the end, at the largest radius. But *how* the
  radius grows (or whether it grows at all) is unresolved; `r0` is constant in
  the code today. The fact that the `(x, y)` circle repeats per bar (§3.1) holds
  precisely *because* `r0` is currently constant — if the radius law later makes
  `r` grow, the "identical circle every bar" assumption that the dedup unit rests
  on must be revisited.
- **Weighting inside `‖F‖`.** `A` (dB) and `I` (semitones) are different units;
  the encoder normalizes each derivative by its own std and applies optional
  weights `w_amp`, `w_int` (default 1). The weighting is the knob still to be
  decided.
- **Beehive hexagonal packing.** How multiple helices (stems? notes? bands?)
  pack into one honeycomb structure is still open.
- **Synthesis back to audio.** Still completely unbuilt. **Important for this
  pivot:** nothing here builds a decoder. The audio that gets reconstructed comes
  from **Layer 1's payload** via whatever raw-PCM-or-FLAC-style choice is made in
  §4(a) — *not* from the helix/chroma layer. The helix layer indexes and
  allocates; it does not synthesize. So "`.bee` can reconstruct audio" is true
  only once §4(a) is decided and that decoder is built — and even then it is the
  payload codec doing it, not the helix.

---

## 6. Build sequence for the next session

Work in this order; each step must be runnable and testable before the next.
Same philosophy as `BEEHIVE_BLUEPRINT.md` §3 — small, verifiable steps, simplest
viable option first.

1. **Generalize `content_hash` to hash a slice.** Today it hashes a whole
   waveform. Add the ability to hash an arbitrary sample range (one bar's worth)
   without changing the existing whole-song behavior. Test: hashing the full
   range still equals today's `content_hash(y)`; two identical slices hash equal;
   two different slices hash differently.

2. **Build loop segmentation off the existing bar/`ω` math.** From a record's
   `bpm`/`ω`/`hop`/`sr`, compute bar boundaries in samples (one bar = one 2π
   turn) and cut the decoded waveform into per-bar slices. Test: the slices
   concatenate back to the original samples exactly (no gaps/overlap, no dropped
   tail); bar count matches `duration / bar_length` within rounding.

3. **Build a minimal recall-entry sequence for ONE song against itself.** Hash
   each bar (step 1), build the sequence of recall entries (§3.3 fields), with a
   single-song loop pool holding each unique bar once. **No cross-song pool yet.**
   This is the metadata layer only — it does not need to *reconstruct audio* yet;
   it needs to round-trip the **non-payload state** losslessly: from the recall
   sequence + pool you can recover the per-bar `(loop_hash, climb_height, chroma)`
   for every bar in original order, identical to what you'd get reading the song
   straight through. Test: that round-trip is exact, frame-for-frame / bar-for-bar.

4. **Report dedup rates on the three real helichain tracks.** For each of the
   three songs already in `helichain/chain.jsonl`, count how many bars are
   exact-hash duplicates of an *earlier bar in the same song*. This is the first
   real evidence of whether bar-level exact dedup actually buys anything on real
   (loop-based electronic) audio. Numbers, written down.

5. **Only then: a minimal payload encoder, simplest option first.** Implement
   Layer 1 with **raw PCM chunks** (the easier side of §4(a)) so that `.bee` can
   actually reconstruct audio for one song: unique bars stored verbatim in the
   pool, repeated bars stored as references, reassembled in order. Test:
   decoded-from-`.bee` samples equal the original samples bit-for-bit (this is the
   first point at which any "lossless" claim is even testable — and only for the
   raw-PCM baseline). Real predictive+entropy coding (the other side of §4(a)) is
   **not** in this step. **This step stays Python**, and so does everything in
   steps 1–5: it *is* the §4(a) raw-PCM baseline, and per §4(c) the entire
   sequence above is the reference implementation.

> **Language handoff (per §4(c)).** A Rust step is added to this sequence
> **only after** §4(a) is actually decided *and* step 5's raw-PCM round-trip is
> tested and bit-exact in Python — and only if §4(a) is decided toward real
> predictive + entropy coding. That future step would be "port (only) the
> residual / entropy coder core to a Rust crate, bound back into Python via
> PyO3, with the same bit-exact round-trip test as step 5 as the acceptance
> bar." It does **not** belong in this sequence yet, because step 5 does not
> exist yet and §4(a) is still open. Do not start it early.

---

## 7. Explicitly out of scope for the next session

Keep scope from creeping. Deferred, with reasons tied to the §6 sequence:

- **Real lossless entropy/residual coding** (the FLAC/ALAC/WavPack side of
  §4(a)). Deferred because §6 step 5 uses raw PCM to get a *correct, bit-exact*
  round-trip first; adding linear-prediction + entropy coding before there's a
  working baseline just multiplies the places a reconstruction bug can hide.
- **Cross-song / helichain-wide global loop pool.** Deferred because §6 step 3
  is explicitly single-song-against-itself; a shared pool adds pool-management,
  collision, and provenance questions that are pointless to solve before
  single-song dedup is shown to work and measured (step 4).
- **Near-duplicate / similarity matching** (the §4(b) "general" side). Deferred
  because it is an unsolved design problem (no closeness measure exists yet), and
  the three current helichain tracks are loop-based electronic where **exact**
  hashing is plausible. Start exact-hash only; revisit once §4(b) is actually
  decided.
- **Any helix-layer audio synthesis / decoder.** Deferred (in fact, out of scope
  permanently for the helix layer): reconstruction is the payload codec's job
  (§5), not the helix's.
- **A Rust implementation of anything, full stop** (per §4(c)). Out of scope
  until **both** conditions hold: (1) §4(a) is actually decided — not just
  discussed — *and* decided toward real predictive + entropy coding rather than
  raw PCM; **and** (2) §6 step 5's raw-PCM baseline has a working, tested,
  bit-exact round-trip in Python. Not "later" in the abstract — those two named
  gates. Until then, no Rust crate, no PyO3 binding, no FFI work; all of `.bee`
  is Python.
- **Beehive packing, radius law, `‖F‖` weighting** (§5 inherited items).
  Untouched; these are not on the path to a working bar-dedup round-trip.

---

## 8. Reference files already in the project

- `~/.claude/skills/beehive/SKILL.md` — full model, vocabulary, working norms.
- `~/.claude/skills/beehive/handout.md` — extended theory (partially grounded,
  partially still analogy).
- `~/.claude/skills/beehive/derivation.md` — original step-by-step build.
- `/Users/jgasimli/sonoFaig/docs/blueprints/BEEHIVE_BLUEPRINT.md` — the prior (helix/chroma
  prototype) build spec this file is a sibling to.

- `/Users/jgasimli/sonoFaig/docs/blueprints/P2P_MVP_BLUEPRINT.md` — the distribution-layer
  (P2P + native iOS) MVP spec; **SPECULATIVE — BLOCKED** on §6 step 5 here (no
  real `.bee` payload exists to sync/share yet), and depends on §4(b) for the
  full cross-user vision.
- `/Users/jgasimli/sonoFaig/docs/findings/VERDICT.md` — the 2026-06-20 prototype-day findings
  (the chroma-many-to-one / full-spectral-invertible split that drove the pivot).
- `/Users/jgasimli/sonoFaig/beehive/audio.py` — `load_audio` and
  `content_hash` (the function the dedup pivot reuses at loop granularity).
- `/Users/jgasimli/sonoFaig/beehive/encode.py` — the encode pipeline (decode →
  frames → state → force → climb → helix → chroma → HelixRecord); confirms no
  synthesis-back-to-audio path exists.
- `/Users/jgasimli/sonoFaig/beehive/record.py` — what's stored on disk today
  (only `A`, `I`, `chroma`, `engagement`; no waveform, no phase).
- `/Users/jgasimli/sonoFaig/helichain/chain.jsonl` — the hash-chain ledger;
  three real loop-based electronic tracks live in it today (the test set for §6
  step 4).
- **`BeehiveMac`** — the existing Swift viewer app; per §4(c) it is the `.bee`
  *consumer* (reads/plays the format), not a place the codec gets reimplemented.

See **§4(c)** for the implementation-language split (Python reference / Rust
production core / Swift consumer) and the sequencing gate that keeps Rust out
until §4(a) is decided and the §6 step-5 baseline is bit-exact in Python.

---

## 9. Definition of done for the next session

Not "a working `.bee` codec" — that's multi-session. Done for the next session
means a real, checkable deliverable:

> For **one** song from the helichain, its bars are hashed at loop granularity
> and a recall-entry sequence (with a single-song loop pool) is generated that
> **round-trips the per-bar metadata losslessly** — from the sequence + pool you
> recover every bar's `(loop_hash, climb_height, chroma)` in original order,
> bit-identical to reading the song straight through (§6 steps 1–3). Plus a
> **written report**, with numbers, of how many bars in each of the **three**
> helichain tracks are exact-hash duplicates of an earlier bar **in the same
> track** (§6 step 4).

Optionally, if time permits, §6 step 5: the raw-PCM payload reconstructs one
song's samples bit-for-bit — but the metadata round-trip + the dedup-rate report
are the load-bearing deliverable. Numbers and an exact round-trip, not a vibe.

Both §4 open decisions — **(a) payload encoding** and **(b) dedup matching** —
must still be open at the end of this session: the build deliberately picks the
*baseline* side of each (raw PCM; exact hashing) to make progress, and that
choice is **not** a commitment to either as the final design.
