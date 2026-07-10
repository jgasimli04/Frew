# Sonofai — Distribution Layer (P2P + iOS) MVP Blueprint

**Target: Claude Code (Opus, max effort) — but NOT YET. Read §3 first.**

> ## ⚠️ STATUS: SPECULATIVE — BLOCKED on the unfinished `.bee` core
> Nothing in this document can be built today. It is **planning/prep only**. The
> entire MVP depends on a real `.bee` payload existing — and that payload does
> **not** exist yet (`BEE_FORMAT_BLUEPRINT.md` §6 steps 2–5 are unbuilt; only
> step 1, `content_hash` slicing, has landed). At minimum, **§6 step 5** in
> `BEE_FORMAT_BLUEPRINT.md` — the raw-PCM round-trip — must exist and be
> bit-exact in Python before there is any real file for one device to send and
> another to play. Until then this is a target to hand to a future build
> session, not a build session itself. This gate is restated in full in §3, and
> it is deliberately framed as prominently as the Rust sequencing gate in
> `BEE_FORMAT_BLUEPRINT.md` §4(c).

This is a sibling spec to `BEE_FORMAT_BLUEPRINT.md`. It carries forward that
document's conventions: everything below is either grounded in something that
already exists in the codebase (cited), grounded in real external precedent
(cited, and hedged "to the best of available knowledge" the same way
`BEE_FORMAT_BLUEPRINT.md` §3.2 and §4(c) hedge theirs), or flagged explicitly as
**OPEN** — a design choice the future builder must actually decide, not paper
over. Don't treat silence as confidence, and don't invent a resolution to
anything marked OPEN.

The tone here leans a little more narrative than the format blueprint, because
the idea is newer and a reader may be meeting it for the first time. It is still
meant to be concrete enough to hand to a build session as a real target once §3's
gate clears.

---

## 1. What this is — and what it isn't

The Sonofai project wants `.bee` files to *reach listeners*. Today there is no
distribution story at all: a `.bee` file (once it exists) just sits on whatever
machine made it. This document is about the layer that moves it.

There are **two very different milestones** here, and conflating them is the main
way this gets confused. State them apart and keep them apart:

### 1a. The long-term vision — cost-efficient streaming via peer resharing

The ambition is a **peer-to-peer sharing network**: once a `.bee` file exists on
one device, other devices and other users can fetch it **from peers** rather than
from a central server. The point is cost — if listeners serve each other the
content-addressed chunks, the streaming bill does not scale linearly with
listeners the way a pure central-server model does. This is the full vision:
strangers, many devices, content moving peer-to-peer across the network.

This milestone is **far off** and depends on open `.bee` decisions (see §3, §5).
It is described in §5 so the near-term work doesn't accidentally foreclose it —
**not** because it is the thing being built next.

### 1b. The near-term, actually-testable MVP — same-account, two-device sync

The thing worth building *first*, and the only thing this document treats as a
real near-term target, is deliberately tiny:

- **One** user account.
- **Two** devices that both belong to that one user — a Mac and an iPhone.
- Upload a `.bee` file from one device; confirm it **plays on the other**
  "without further work."

That's it. **No third parties. No strangers. No resharing to other people's
devices.** This is a sync/handoff test between two devices under a single
account — which means it has *none* of the legal, trust, or cross-user-dedup
complexity of §1a. That narrowness is the whole point: it is small enough to
actually finish and verify, and (as §3 explains) it can proceed in parallel with
the still-open `.bee` core decisions in a way the full §1a vision cannot.

**These are different milestones with different scope.** When this document says
"the MVP," it means §1b. When it says "the full P2P vision," it means §1a.

---

## 2. The binding analogy — an explanation of §4(b), not new content

The user offered a biology analogy for the matching mechanism — cannabinoid
receptor binding, lock-and-key vs. induced-fit. It is worth recording, but it is
important to be precise about what it is: **a vivid way to explain a decision that
`.bee` already has open, not a new mechanism and not a source of new algorithmic
detail.**

`BEE_FORMAT_BLUEPRINT.md` §4(b) is the open decision about *how two bars are
judged "the same loop"* for dedup. It has two sides:

- **Exact-hash matching (SHA-256 equality)** — two bars dedup only if their
  samples are byte-for-byte identical. This is **lock-and-key**: only a perfect
  complement binds. A perfect fit or nothing.
- **Near-duplicate / similarity matching** — two bars count as "the same loop" if
  they are close under some similarity measure, within a threshold. This is
  **induced-fit**: binding happens within some tolerance, not only on an exact
  match.

That is the entire connection. The analogy maps cleanly onto the two sides of
§4(b) and stops there. **There is no further literal link to molecular
geometry** — do not extend it, and do not treat cannabinoid biology as a source
of any algorithmic specifics. Use it to *explain* §4(b) to someone new, then move
on. This document does **not** resolve §4(b) (see §3).

---

## 3. The gate — what this MVP depends on from the unfinished `.bee` core

This section is the load-bearing caveat. It is stated as prominently as the Rust
sequencing gate in `BEE_FORMAT_BLUEPRINT.md` §4(c), and for the same reason:
starting downstream work before its upstream dependency exists means building
against something that isn't there.

**The whole MVP is SPECULATIVE and BLOCKED.** Concretely:

1. **There is no real `.bee` payload yet to upload, sync, or play.**
   `BEE_FORMAT_BLUEPRINT.md` §6 steps 2–5 are not done — only step 1
   (`content_hash` slicing, in `beehive/audio.py`) has landed. Nothing in the
   codebase reconstructs audio from a record (`BEE_FORMAT_BLUEPRINT.md` §5: "no
   decoder of any kind today"). At **minimum, §6 step 5** — the raw-PCM
   round-trip, the first point at which decoded-from-`.bee` samples can be
   checked bit-for-bit against the original — must exist and pass before there is
   a real file for any device to receive and play. **Until that file exists, the
   MVP cannot even begin**; there is nothing to transfer.

2. **`§4(a)` and `§4(b)` remain open — and this document does not resolve
   either.** Do not let the MVP's design quietly assume an answer to either:
   - **Do not assume near-duplicate matching exists.** It is the unbuilt side of
     §4(b).
   - **The narrow MVP (§1b) does not need §4(b) resolved at all.** It transfers
     *one known file* between two devices under one account. There is no
     cross-content dedup, no "is this bar the same as that bar," no matching
     across users — so it does not depend on §4(b) in either direction. **This is
     exactly why the narrow MVP can proceed in parallel** with the open core
     decisions: it only needs a file to exist (§6 step 5) and a way to move it.
   - **The full P2P vision (§1a) is different.** Cross-user dedup — recognizing
     that a chunk one user has is "the same" chunk another user wants — *is*
     §4(b). So §1a genuinely depends on §4(b) being resolved first (see §5). The
     two milestones differ precisely on this point.

3. **This file is planning/prep only.** It exists so that the moment §6 step 5
   lands, there is a ready, concrete target. It is not a license to start now.
   (Note: a separate `RUST_CODEBASE_BLUEPRINT.md` was proposed in another
   session but **does not exist in the repo as of this writing** — so this gate's
   framing is matched to `BEE_FORMAT_BLUEPRINT.md` §4(c), the existing gate in
   the project, rather than to that file.)

---

## 4. MVP architecture (for the narrow §1b test)

This is the architecture for the **same-account, two-device** test only. Keep it
as small as the test.

### 4.1 Native apps on both ends

- **macOS app.** Mirror the existing `BeehiveMac` viewer — the project already
  has a native macOS Swift app that is the `.bee` *consumer*
  (`BEE_FORMAT_BLUEPRINT.md` §4(c), §8). The Mac side of this MVP is the *sender*:
  it has the `.bee` file and hands it off.
- **iOS app.** A **native Swift / SwiftUI** app. The user was explicit:
  "anything else for iOS application should be native only" — meaning **no
  cross-platform framework** (no React Native, Flutter, etc.). The iOS app is
  native, mirroring the native macOS app. Its MVP job is the *receiver*: accept a
  `.bee` file and play it.

### 4.2 A shared Swift package for client logic

Both apps need the same client-side logic (reading a `.bee` file, the transfer
client, playback wiring). Duplicating it in two codebases is the obvious trap. A
real, citable Apple pattern avoids it:

- **A shared Swift package** used by both the macOS and iOS apps, with each app's
  **UI staying platform-native** (AppKit/SwiftUI on Mac, SwiftUI on iOS). To the
  best of available knowledge, a shared Swift package is Apple's standard way to
  share code across its own platforms while keeping per-platform UI distinct.
  Exact package structure and current tooling should be checked against Apple's
  Swift Package Manager documentation before implementation, the same hedge style
  used elsewhere in this project's docs.

This keeps the "what is a `.bee` file / how do I receive it / how do I play it"
logic in one place, and leaves only genuinely platform-specific UI in each app.

### 4.3 The device-to-device handoff — OPEN: two named options, pick neither here

How the file actually moves from Mac to iPhone is an **OPEN decision**. There are
two real, current Apple frameworks, and this document deliberately **does not
pick** between them — it names both so the future builder makes a real choice:

- **`MultipeerConnectivity`** — Apple's framework for nearby-device peer-to-peer
  data transfer over Wi-Fi / Bluetooth, **no server involved**. Fits the "two
  devices, no central infrastructure" shape directly, and is conceptually closer
  to the eventual §1a P2P story. Constraint to weigh: it is oriented to *nearby*
  devices.
- **`CloudKit` / iCloud sync** — account-based sync **through Apple's servers**.
  Fits the "same account, both my devices" framing directly and does not require
  the devices to be near each other. Constraint to weigh: it routes through
  Apple's servers (so it is sync, not literally peer-to-peer).

Both are **real, named, current Apple frameworks.** State plainly: their **exact
current capabilities, APIs, size limits, and entitlements must be checked against
Apple's developer documentation before implementation** — the same hedge this
project applies to all external citations. The choice between them is a genuine
trade-off (local-no-server vs. account-sync-via-server) and is left **OPEN** on
purpose.

---

## 5. The longer-term P2P vision (§1a) — and why it is gated further than §1b

This section records the full vision so the near-term work doesn't foreclose it.
It is **not** a near-term target.

### 5.1 The shape: content-addressed sharing over the existing loop pool

The `.bee` design already produces exactly the property a peer-sharing network
needs. `BEE_FORMAT_BLUEPRINT.md` §3.2 defines a **loop pool** of unique bar
payloads, each keyed by `content_hash` (`beehive/audio.py`) — a SHA-256 over the
audio samples, identical regardless of container. **Content-addressed chunks are
already what `.bee` is.** A peer network that shares those chunks by hash is a
*natural fit* for that design, **not a new requirement imposed on it** — note it
that way.

**Precedent (stated as precedent for the *idea*, hedged to the best of available
knowledge):**

- **BitTorrent** — peers exchange pieces identified by hash; a swarm serves
  content to itself rather than from one origin.
- **IPFS** — content-addressed storage where hash-identified blocks are shared
  across a peer network.

Both are general precedent that content-addressed, hash-identified chunks can be
shared peer-to-peer at scale. The `.bee` loop pool's `content_hash` keying is the
property that makes this kind of sharing possible. Exact protocol details of
BitTorrent/IPFS should be checked against their specifications before being
asserted — the same way `BEE_FORMAT_BLUEPRINT.md` §3.2 hedges its
SoundStream/EnCodec/DAC and Foote-1999 citations.

### 5.2 Why §1a is gated harder than §1b

The full vision depends on **two** things the narrow MVP does not:

1. **§4(b) must be resolved.** Cross-user dedup — recognizing that a chunk one
   peer holds is "the same" as one another peer wants — **is** the §4(b) matching
   decision (exact-hash vs. near-duplicate; the lock-and-key vs. induced-fit of
   §2). Sharing across strangers' libraries is where that decision actually
   bites. The narrow MVP sidesteps it entirely by moving one known file; the full
   vision cannot.
2. **A real payload must exist (§4(a) / §6 step 5).** There is nothing to share
   peer-to-peer until there is a real, reconstructable payload — same dependency
   as §3, but more so, because §1a shares chunks *across* the network rather than
   moving one whole file once.

### 5.3 Consent caveat (stated once, briefly — a planning note, not a blocker)

Re-sharing an artist's uploaded track across **other users'** devices without
consent is the same mechanics that drove the **Napster** litigation. This matters
for the **full §1a vision** — and only for it. The narrow §1b MVP has **no
third-party sharing at all** (it is two devices under one account), so this
caveat does **not** apply to the MVP and is **not** a blocker for it. Noted once,
for §1a planning; moving on.

---

## 6. Build sequence for the narrow MVP (§1b)

Ordered, small, testable steps — same philosophy as `BEE_FORMAT_BLUEPRINT.md` §6.
**Step 0 is the gate; do not start step 1 until step 0 is true.**

0. **(GATE) A real `.bee` test file exists.** `BEE_FORMAT_BLUEPRINT.md` §6 step 5
   (the raw-PCM round-trip) is done and bit-exact in Python, so there is an
   actual `.bee` file that reconstructs to known audio. **Nothing below can start
   until this holds.** Test: the file exists and round-trips to its original
   samples bit-for-bit (that test lives in `BEE_FORMAT_BLUEPRINT.md` §6 step 5,
   not here).

1. **Minimal native iOS shell that can open and play a `.bee` file already on the
   device.** No transfer yet — side-load the test file from step 0 and prove the
   iOS app can read it (via the shared Swift package, §4.2) and play it. Test:
   the test `.bee` file, placed on the iPhone by hand, plays correctly in the iOS
   app. (Proving playback in isolation removes it as a variable before transfer
   is added.)

2. **macOS-side send.** In the `BeehiveMac`-mirroring Mac app, add the ability to
   take a local `.bee` file and initiate a handoff. Test: the Mac app can select
   the test file and trigger a send action (the send *target* is wired in step 3).

3. **Wire up the chosen transfer mechanism.** Make the §4.3 OPEN decision —
   `MultipeerConnectivity` **or** `CloudKit`/iCloud — and implement *that one*
   end-to-end: Mac sends, iPhone receives, against the same user account. Test:
   the test `.bee` file initiated from the Mac arrives, intact (verify by
   `content_hash` / byte equality), on the iPhone.

4. **The actual MVP scenario, end to end.** Upload the test `.bee` file from the
   Mac app; confirm it appears on the iPhone app and plays — **with no manual
   transfer step beyond the initial upload.** Test: see §9 (this step *is* the
   definition of done).

Keep each step independently runnable and verified before the next, exactly as
`BEE_FORMAT_BLUEPRINT.md` §6 requires.

---

## 7. Explicitly out of scope for now

Keep scope from creeping. Deferred, with reasons:

- **Full P2P-with-strangers (§1a).** Out of scope for the near-term MVP. It
  depends on §4(b) being resolved and on a real payload existing across the
  network (§5.2), and it carries the consent/Napster considerations (§5.3) that
  the narrow MVP does not. Different milestone entirely.
- **Rust.** Not needed here. Per `BEE_FORMAT_BLUEPRINT.md` §4(c), Rust is gated
  to the eventual lossless **codec core** and only enters after §4(a) is decided
  *toward* real predictive+entropy coding *and* the §6 step-5 baseline is
  bit-exact. There is no audio codec being embedded in this MVP — there is barely
  a payload — so Rust is out of scope until there is a real codec core to embed.
- **Any cross-platform UI framework.** Out by explicit user instruction: the iOS
  app is **native** Swift/SwiftUI, mirroring the native macOS app (§4.1).
- **Resolving §4(a) or §4(b).** Not touched here. The MVP is designed so it does
  **not** require either to be resolved (§3); resolving them is `.bee`-core work,
  not distribution-layer work.

---

## 8. Reference files

- `/Users/jgasimli/sonoFaig/BEE_FORMAT_BLUEPRINT.md` — the `.bee` format build
  spec this file is a sibling to. Especially **§4(a)/(b)** (the open decisions
  this MVP must not silently resolve), **§4(c)** (the language-strategy gate
  whose framing this file matches), **§3.2** (loop pool / `content_hash` / the
  citation-hedging style), and **§6** (the build-sequence philosophy and step 5,
  this MVP's hard prerequisite).
- `/Users/jgasimli/sonoFaig/VERDICT.md` — the 2026-06-20 prototype findings (why
  the project pivoted; context for why no payload exists yet).
- `/Users/jgasimli/sonoFaig/handout.md` — extended theory; note its 2026-06-21
  status callout on §1 (the "climb positioned by musical identity" proposal was
  never adopted and is not the built model).
- `/Users/jgasimli/sonoFaig/beehive/audio.py` — `load_audio` and `content_hash`
  (the content-addressing primitive the §1a P2P vision builds on; §5.1).
- `/Users/jgasimli/sonoFaig/beehive/record.py` — what a record stores today
  (only `A`, `I`, `chroma`, `engagement`; no waveform — i.e. no playable payload
  yet, which is the §3 gate in concrete form).
- **`BeehiveMac`** — the existing native macOS Swift app; the `.bee` consumer and
  the template the iOS app and the Mac sender mirror (§4.1).
- `RUST_CODEBASE_BLUEPRINT.md` — **proposed in a separate session but does not
  exist in the repo as of this writing.** Listed only so a future reader knows it
  was intended; do not assume its contents. Not relevant to this MVP regardless
  (§7: no Rust here).

---

## 9. Definition of done (for the narrow §1b MVP)

A real, checkable deliverable — not a vibe:

> **Upload a `.bee` test file from the Mac app, and confirm it appears and plays
> on the iPhone app under the same account, with no manual transfer step beyond
> the initial upload.**

That is the whole test: one action on the Mac (upload), then the file is playable
on the iPhone with nothing else done by hand.

**This requires a real `.bee` file to exist first** — i.e. `BEE_FORMAT_BLUEPRINT.md`
§6 step 5 (the raw-PCM round-trip) must be done and bit-exact in Python before
this test is even possible. **Until that file exists, this document is plan-only**
(see §3, §6 step 0). State that plainly: the definition of done is real and
checkable, but it is gated on an upstream deliverable that has not landed yet.

Both open `.bee` decisions — **§4(a) payload encoding** and **§4(b) dedup
matching** — remain **open**; this MVP neither resolves nor depends on either
(§3), which is precisely what lets the narrow §1b work proceed in parallel with
the still-open core.
