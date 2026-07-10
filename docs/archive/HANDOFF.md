# HANDOFF — `.bee` floor + loop-dedup logic, for creator review

**From:** the build side (Claude Code, Opus, 2026-06-22 session).
**To:** the creator — for a routine check-up of the logic.
**Supersedes:** `HANDOFF_beefile.md` (its task — the bit-exact round-trip — is done).
**How to read this:** every claim is paired with how it was verified and what to
distrust. §6 is the audit target: the assumptions that could be wrong.

---

## 0. Reproduce before trusting

```
python3 -m pytest tests/ -q                 # 16 pass (engine 4, beefile 7, loops 5)
python3 analyze_loop_structure.py           # the dedup evidence (numbers in §3)
python3 -m beehive encode <song> -o x.bee ; python3 -m beehive inspect x.bee
```
Real-track bit-exact check (the lossless claim): encode a FLAC, `read_bee`, compare
`sha256` of decoded PCM in vs out — done in-session on *Good Lies* (2:40), matched.

---

## 1. What was built — claim ↔ verification

| Artifact | Claim | Verified by | Status |
|---|---|---|---|
| `beehive/beefile.py` | `.bee` = lossless audio payload + helix side-channel; bit-exact on decoded PCM | `tests/test_beefile.py` (PCM16/24, mono/stereo, float→raw_zlib, real FLAC sha256) | works |
| `beehive/cli.py` (`python -m beehive`) | encode/decode/inspect surface for platforms | runs on real tracks | works |
| `beehive/loops.py` | ω/bpm bar segmentation + exact dedup + bit-exact reconstruct | `tests/test_loops.py` (constructed track dedups 60%, rebuilds byte-exact) | works |
| `analyze_loop_structure.py` | measures whether the side-channel finds real repetition | numbers below, reproducible | evidence |
| `LOOP_DEDUP_FINDINGS.md`, `BEE_NEURAL_PLAYBACK_ROADMAP.md` | written findings + grounded vision | — | docs |

Deliberately **not** built (gated / would be dishonest now): real entropy coder
(§4a OPEN), near-dup matcher baked into the format (§4b OPEN), Rust core, **iOS
app** (only macOS `BeehiveMac` exists; §4c gate unmet), neural decoder (refuted
from chroma — see §5).

---

## 2. The logic, exposed

### 2.1 Lossless contract (the load-bearing definition)
"Lossless" = **bit-exact on the decoded PCM array libsndfile returns**, *not* on the
source container bytes. Source read at its native subtype (NOT `load_audio`, which
mono-averages to float32 = lossy). 24-bit is decoded to `int32` (left-justified) and
re-encoded via FLAC `PCM_24` consistently, so the round-trip is exact at the array
level. Float/exotic subtypes fall back to raw samples + zlib. **Caveat logged in
code:** raw_zlib stores native byte order; the reader raises on a cross-endian
mismatch rather than silently misreading (all current targets are little-endian).

### 2.2 Bar = one helix turn (equations)
```
ω = 2π·bpm/(60·B)          ω_frame = ω·hop/sr          α(n) = ω_frame·n
T_bar = B·60/bpm           spb = round(T_bar·sr)        [FIXED integer]
```
`spb` is a **fixed** integer (not per-bar rounding) on purpose: two equal-content
bars can only hash-equal if they are the same length. Segmentation tiles `[0,N)` as
`[k·spb,(k+1)·spb)`; the final bar is the remainder and is never deduped.
Reconstruction = concatenate pool entries in recall order ⇒ lossless **by
construction** (no transform on the samples).

### 2.3 Dedup + matching metrics
- **Exact dedup key:** SHA-256 of a bar's *native* sample bytes (not the float32
  analysis cast, which loses precision for int24/int32).
- **Clustering (analysis only):** greedy cosine — a bar joins the first cluster
  whose representative it matches `≥ thr`, else opens a new one.
- **Residual (analysis only):** `median ||a−b|| / ||b||` over matched bars, on the
  per-bar mean log-magnitude **spectrum** (phase-invariant). For unit vectors
  `||a−b||² = 2(1−cos)` — see the coupling caveat in §6.

---

## 3. Results (numbers, reproducible)

**Exact byte-dedup:** 0% on all three tracks, at est / ×2 / ×0.5 bpm. (Control: a
constructed copy-pasted-bar track dedups 60% and rebuilds byte-exact — engine is
correct; mastered mixes simply have no byte-identical bars.)

**Near-dup pooling (pool % @ phase-invariant residual):**

| thr | Liverpool chroma | Liverpool spectrum | Good Lies chroma | Good Lies spectrum | Night chroma | Night spectrum |
|---|---|---|---|---|---|---|
| 0.98 | 96% @ 41% | **81% @ 9%** | 96% @ 22% | **83% @ 17%** | 92% @ 38% | **67% @ 17%** |
| 0.99 | 90% @ 35% | **77% @ 9%** | 96% @ 22% | **63% @ 13%** | 86% @ 29% | **46% @ 12%** |

---

## 4. Claims → grounds (the inference chain)

- **C1 — exact dedup is useless on mastered audio.** Ground: 0% across tracks +
  passing control. *Strong.*
- **C2 — chroma is the wrong reuse index.** Ground: chroma pools 90–96% of bars but
  those bars differ 22–41% (Night up to 347%) in the *independent* spectral metric =
  exp3's many-to-one, at bar scale. *Strong — clustering space (chroma) and residual
  space (spectrum) are independent here.*
- **C3 — a discriminative spectrum finds real repetition.** Ground: 50–80% pool at
  <20% residual. *Weak — the word to distrust is "real": this may be genre
  homogeneity, not repetition (§6a). Suggestive, not proven.*
- **C4 — the NN-playback vision is viable conditioned on the spectrum (not chroma).**
  Ground: a <20% phase-invariant residual is the regime neural vocoders operate in.
  *Analogy to the literature, NOT a demonstration — no decoder was built or run; and
  it rests on C3, so it inherits C3's weakness. Conjecture, flagged.*

---

## 5. Established / refuted / conjecture / open

- **Established (in-project, tested):** the lossless floor; bar segmentation; exact
  dedup correctness; exact dedup = 0% on the corpus; chroma over-pools (C1, C2).
- **Refuted:** chroma reconstructs/identifies audio (exp3, re-confirmed at bar
  scale). Chroma stays for colour, not for reuse.
- **Conjecture (needs evidence):** C3 absolute residuals (decouple the metric);
  C4 (build/run a decoder); "crisper than source" and "new stereo" (roadmap §4).
- **Open (your call):** §4a payload coder; §4b reuse threshold; the reconstruction
  fork (lossless-residual vs lossy-generative); radius law; ‖F‖ weighting.

---

## 6. Where the logic could be wrong — please check these

a. **C3 does not prove repetition — strongest caveat. Two confounds:**
   (i) *Baseline homogeneity.* Every bar of one electronic track shares a global
   spectral envelope (same synths, key, mastering), so a high pool % at cosine ≥0.98
   is the *expected* result of homogeneity whether or not any bars repeat. The
   numbers show exactly this — there is **no clustering plateau**: Good Lies' spectral
   pool runs 83%→63%→2.4% across thr 0.98→0.99→0.999, a smooth continuum, not the
   flat "N real loops" band that discrete repeats would hold across a threshold
   range. So "real" in C3 is unproven; this may be "bars are globally similar," not
   "bar 50 is a reusable copy of bar 3."
   (ii) *Metric coupling.* Clustering and the residual use the *same* spectral space,
   so a high threshold mechanically bounds the residual (`||a−b||²=2(1−cos)` for the
   normalized part); "low residual at high thr" is partly by construction. The
   chroma-vs-spectrum *comparison* is still fair (same metric, same thr), but the
   absolute spectral residual is **not** independent confirmation that matched bars
   are the same loop. **Decoupling check (not run — see §7).**

b. **Alignment assumptions.** `spb` uses the **estimated** bpm (known half/double
   bias — Liverpool 64.6 may be 129; Night 69.8 may be 140), and bars are assumed to
   start at sample 0 (no downbeat phase offset). Wrong bpm/phase ⇒ bars don't align
   to musical loops ⇒ pooling **understates** true repetition. Current numbers are a
   lower bound under this assumption.

c. **The fingerprint averages over a whole bar.** A bar's mean spectrum discards
   within-bar time order, so two bars with the same average but different internal
   arrangement match falsely (overstates pool %). Same blindness chroma has, weaker.
   Also, the residual is on `log1p(mag)`, which compresses loud bins and lets quiet
   bins dominate the norm — so it *under-reads* true audio difference.

d. **The fingerprint is computed on the mono mix** (`load_audio`), while the payload
   is native stereo — so the matcher ignores inter-channel content for stereo tracks.

e. **Corpus = 3 loop-based electronic tracks.** Conclusions likely do not generalize
   to acoustic/live material (where even spectral repetition is rarer).

f. **Lossless contract is "bit-exact on decoded PCM,"** not on the original
   container; for a lossy source it is lossless of the decoded samples. Confirm this
   is the definition you intend for a format artists upload masters into.

---

## 7. The decision waiting on you, and the next build

Settled by data: change the reuse index **chroma → discriminative spectrum**. Open
fork (don't want to resolve it for you):
- **Lossless-residual:** representative bar + exact residual (archival). Needs the
  §6(a) phase-sensitive residual measured first — it may be large.
- **Lossy/generative (your vision):** spectral fingerprint + representative, neural
  vocoder fills phase/detail. Viable per C4 *if* C4 is demonstrated.

**Both** branches need the same next functional piece: the discriminative-spectrum
fingerprint as the side-channel's reuse index (currently chroma). Recommended next
build = that fingerprint + the §6(a) decoupling check — a **null baseline**
(matched-pair similarity vs randomly paired / cross-track bars; real repetition sits
clearly above the null, homogeneity does not) plus the phase-sensitive sample
residual and musical-position sanity — which turns C3 from suggestive into proven
(or refutes it). Then the fork is an informed choice.
