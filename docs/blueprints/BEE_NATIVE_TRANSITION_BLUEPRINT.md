# Native transition — the Mac runs the engine, the iPhone plays a scheduled stream

**Date: 2026-07-07 (goal sharpened same day). Status: PLAN. Sibling to
`BEE_LIGHT_BLUEPRINT.md` (whose exp5 ears-gate still governs all
container-shaped work) and `P2P_MVP_BLUEPRINT.md` (still blocked; nothing here
forecloses it).**

**The goal, in the user's terms:** ship a production-ready codebase in which
the **core engine runs server-side** (this Mac now, a bought server at
traction) and **streams information to the iPhone in the sequence and timing
we specify** — offloading power burn from the phone and reducing the total
operating cost of running the system.

That is `BEE_LIGHT_BLUEPRINT.md` §1's "stream logic tuned to the format"
promoted from demo to *the product*. The phone does as little as possible:
receive scheduled bursts, decode, play. The server does everything else:
analysis, encoding, chunking, scheduling, storage.

House rules carried forward: every claim below is grounded in something that
exists in the repo (cited), grounded in established platform guidance (hedged
as such), or flagged **OPEN**. Phases are small and each has an acceptance bar.

---

## 1. Where the transition starts from (inventory, measured 2026-07-07)

| Principle / algorithm | Python reference | Rust (beecore) | Swift (BeehiveMac) |
|---|---|---|---|
| `.bee` container read/write | `beehive/beefile.py` | **DONE** (`bee-format`, bit-exact, 24/24 interop) | **DONE** as consumer via C ABI (`BeeFile.swift` → `CBee` → `libbee_ffi.a`) |
| Analysis engine: STFT features, tempo, state (A,I), force, climb, helix, chroma | `beehive/encode.py` + `features/tempo/record` | **MISSING** | ported on Accelerate (`Engine.swift` et al.) |
| Helichain ledger (analyse-once) | `beehive/helichain.py` | MISSING | ported (`Helichain.swift`) |
| Loop/bar segmentation (2π chunks) | `beehive/loops.py` | MISSING | not ported |
| Neural base encode/decode (DAC 16 kbps) | `experiments/exp5_neural_base.py` (PyTorch/MPS) | MISSING | MISSING (Core ML decode = roadmap's **last** gate) |
| Playback of v0 `.bee` | — | decode via CLI/ABI | **DONE** (`Player.swift`, `Audio.swift`) |
| Backend / streaming server | — | **nothing exists** | — |

## 2. Decision A: one algorithm home — Rust; Swift+ObjC is the shell

`BEE_FORMAT_BLUEPRINT.md` §4c already establishes it for the codec: *"Swift
consumes; it never reimplements."* Extended to everything:

- **Rust (`beecore`) is the only production implementation** of the
  algorithms — what the Mac executes today, what a Linux server executes
  later, unchanged.
- **Python stays the reference and the ML lab** — parity oracle
  (`interop/test_interop.py` discipline) and home of the DAC worker until
  exported. Never in the serving path after the engine port lands.
- **Swift+ObjC is the product shell**: UI, audio session, library, API
  client, playback. Local algorithm needs go over the C ABI.
- **Objective-C is the boundary layer**: the C-ABI bridging surface around
  `bee.h` (and future engine/stream calls), and the realtime CoreAudio render
  path, where ObjC/C callbacks keep Swift-runtime hazards off the audio
  thread. Everything above that line is Swift/SwiftUI.

**Consequence:** `BeehiveKit`'s Swift `Engine`/`Tempo`/`Features` port is
demoted to inspector/preview math (its original role,
`BEEHIVE_SWIFT_UI_BLUEPRINT.md`); its test vectors become parity fixtures for
the Rust engine port. Two production engines in two languages is drift waiting
to happen.

## 3. Decision B: backend = one thin Rust binary on the Mac

"From scratch" means no framework baggage, not inventing infrastructure:

- One new crate in the beecore workspace: **`bee-server`** (axum or
  equivalent minimal HTTP). Single binary, single process.
- **Storage is the "hardware database"**: a flat content-addressed store
  (sources, `.bee`, per-bar chunk cache, token payloads) + one SQLite file as
  the index (songs, hashes, stream plans, job states, helichain meta). No DB
  server; files + SQLite move to a future server with `rsync`.
- **Job model**: SQLite-backed in-process queue (reboot-safe). Job = ingest
  source → run engine → write `.bee` → **verify by native decode hash** — the
  `scripts/convert_to_bee.py` acceptance bar; a job that fails verification
  leaves no `.bee`, ever.
- **The one non-Rust worker, explicitly temporary**: the neural encode is
  PyTorch/MPS today (exp5); `bee-server` calls it as a subprocess behind a
  trait, replaced later by in-process ONNX (`ort`) or candle. Nothing else in
  the backend may depend on Python or macOS-only APIs — that single
  constraint is what makes the eventual Linux migration a copy, not a port.
- **Reachability**: Tailscale first (your devices only, zero public
  exposure); Cloudflare Tunnel when a public URL is needed. No port
  forwarding, no static-IP dependence. Auth = one bearer token for now.
- **Mac-as-server hygiene**: `launchd` `KeepAlive` for `bee-server`; `pmset`
  no-sleep on AC; CAS + SQLite under backup (Time Machine + periodic off-Mac
  `rsync` — the helichain ledger is the irreplaceable part); a status
  endpoint a phone can ping.

## 4. The shipping target: the scheduled stream ("sequence and timing we specify")

The stream is not client-driven generic HTTP; the server computes, at author
time, a per-song **stream plan** from the helix record, and the client obeys
it:

- **Sequence** = the bar grid: chunk boundaries on the ω/bpm 2π loops
  (`beehive/loops.py` segmentation), so one chunk = one musical bar-loop —
  the unit `BEE_LIGHT_BLUEPRINT.md` §2 already fixed for streaming.
- **Timing** = a burst schedule: chunks are grouped into bursts sized by
  playback deadline and by ‖F‖-driven prefetch depth (calm passages → deep
  prefetch, few radio wakes; volatile passages → tighter cadence). Batching
  radio traffic into bursts and letting the radio sleep between them is
  established platform guidance (Apple's energy documentation recommends
  batched transfers; cellular radios pay a tail-energy cost per wake) — this
  is the "offload burning power" mechanism on the wire side, stated as
  guidance, to be **measured on our own traffic in Phase 5, not assumed**.
- **The plan is data, not code**: a manifest (chunk ids = content hashes,
  order, burst grouping, deadlines) served per song. Client logic stays dumb:
  fetch burst, sleep radio, feed decoder. Content-addressed chunks make
  fetches idempotent and resumable for free.
- **Gate discipline**: pre-ears-gate, chunks are **server-side cache
  artifacts** — per-bar lossless segments cut/re-encoded by `bee-server`
  from the v0 `.bee`'s decoded PCM. The container is not touched, so
  `BEE_LIGHT_BLUEPRINT.md` §4's freeze is respected. Post-gate, the same
  plan/manifest shape carries bar-aligned **token** chunks instead — the
  transport is designed once, the payload swaps.

### The power/cost ledger, stated honestly

Total operating cost = bytes served (bandwidth) + server watts (Mac
electricity now) + phone battery (the user-facing cost). The levers:

- **Wire bytes**: post-gate, the neural base measured 22–44× lighter than
  the FLAC-weight v0 (`NEURAL_BASE_FINDINGS.md` Result 1, ~32 kbps stereo).
  This is the dominant bandwidth/radio lever.
- **Phone decode**: the tension nobody gets to skip — the lossless v0 stream
  is heavy on the wire but cheap to decode; the neural base is light on the
  wire but its decode was the *heavier* direction even on M-series MPS (~6×
  realtime, exp5). Whether Core ML/ANE decode on an iPhone costs less battery
  than the radio savings buy is **unmeasured and is precisely what the
  roadmap's last gate must measure**. No architecture bet is placed on the
  answer: the stream plan is payload-agnostic, so the phone ships v0 chunks
  first and the neural payload swaps in only if its measured phone-side
  energy passes.
- **Server side**: authoring, neural encode, residuals, chunk cutting — all
  burn on the Mac (wall power, already paid for) instead of the phone. That
  part of "offload" is unconditional and starts in Phase 2.

## 5. Client architecture (Swift + Objective-C)

One SwiftPM workspace, evolving `BeehiveMac`:

- **`CBee` / ObjC boundary target** — the header shim over `libbee_ffi.a`,
  growing engine/stream entry points as they land in the ABI; hosts the ObjC
  audio-render glue.
- **`BeeKit` (Swift)** — product layer: `.bee` open/decode (exists), playback
  (exists), helix navigation, library model, and new: **`BeeClient`**
  (URLSession API client) and **`StreamScheduler`** (executes the manifest:
  burst fetching, chunk cache, decoder feed, gapless splicing at bar
  boundaries).
- **`BeehiveApp` (macOS)** — authoring console: import songs, submit jobs to
  `bee-server`, browse library, inspect (the five visualization views stay as
  the inspector).
- **`BeePlayer` (iOS) — the product**: a deliberately thin streaming player.
  **Resolved (was OPEN):** the iPhone does **no on-device analysis** — it is
  upload-and-stream only; the whole point is offloading that burn to the
  server. Offline listening = pinning chunks in the local CAS cache, same
  data path as streaming.
- **Packaging fix (load-bearing)**: replace the hand-copied
  `Libraries/libbee_ffi.a` with a scripted `bee.xcframework` (macOS + iOS +
  sim slices; the cross-target `.a`s already build, `beecore/README.md`).
  Makes the iOS target real instead of theoretical.

## 6. Phases, in order, each with its acceptance bar

The streaming path (1→5) is the critical path; the engine port (6) runs
behind it; container work (7) stays behind the ears-gate.

1. **Packaging** — script `beecore → bee.xcframework`; `BeehiveMac` links it.
   *Bar:* `beehive-cli --selftest` passes on the framework build; an iOS-sim
   smoke target links and opens a `.bee`.
2. **`bee-server` v0** — ingest/job/library endpoints wrapping today's
   pipeline (Rust container + Python engine subprocess, i.e.
   `convert_to_bee.py` behind HTTP); launchd + Tailscale + backup live.
   *Bar:* from a second device: upload a source, get a `.bee` whose native
   decode hash matches — the convert bar, over the wire. Jobs survive reboot.
3. **Stream plan + chunk service** — server computes the manifest (bar grid
   from the helix record, burst grouping, ‖F‖ prefetch depth) and cuts
   per-bar lossless chunks into the CAS (container untouched).
   *Bar:* fetch manifest + chunks in plan order with plain HTTP, reassemble,
   PCM is bit-exact vs the `.bee` decode; chunk boundaries land on the bar
   grid.
4. **`BeePlayer` iOS MVP** — `StreamScheduler` + playback over Tailscale;
   offline pinning; MetricKit/os_signpost telemetry wired from day one.
   *Bar:* an iPhone plays a full track from the Mac, gapless across chunk
   boundaries, with radio activity in the planned bursts (observed in
   Instruments, not assumed); a mid-track network drop resumes without
   replaying fetched chunks.
5. **The power/cost harness — the goal, measured** — A/B on real hardware:
   scheduled-burst `.bee` streaming vs naive FLAC-over-HTTP. Record
   bytes-to-first-sound, bytes/minute, radio-on time, phone energy
   (MetricKit/Instruments), server draw (`powermetrics`).
   *Bar:* a findings doc in `docs/findings/` with real numbers; per project
   norms, "cheaper/lighter/cooler" is claimed only from this data. These
   numbers become the KPI baseline every later phase must not regress.
6. **Engine → Rust (`bee-engine`)** — port STFT features, tempo, state,
   force, climb, helix, chroma, loops, helichain; expose over the C ABI; the
   Python engine subprocess retires; stream plans (bar grid, ‖F‖) now come
   from Rust.
   *Bar:* interop-style parity harness vs the Python reference on the three
   helichain tracks (tolerance-based for float paths, exact for meta);
   `Engine.swift` test vectors reused as fixtures.
7. **Ears-gate dependent (sequence unchanged from `BEE_LIGHT_BLUEPRINT.md`
   §5)** — base section in the container, bar-aligned token chunks in the
   *same* manifest shape, residual profile, decode-headroom/true-peak policy
   (exp5 Result 2) as part of the server decode contract. Neural encode runs
   only on the backend; the bit-exact residual is computed on the backend
   with the pinned CPU decode (this Mac *is* the pinned platform — the
   float-determinism hazard becomes a deployment property). Core ML decoder
   on iPhone ships **only if Phase 5's harness shows the battery math wins**
   (the roadmap's last gate, now with a concrete pass metric).
8. **Neural worker de-Pythonized** — DAC encode via ONNX (`ort`)/candle
   in-process. *Bar:* token streams byte-identical to the Python worker on
   the three tracks, or a measured equivalence report — no silent tolerance.
9. **Traction → real server** — pure Rust + flat CAS + SQLite means: build
   the Linux binary (Docker image kept warm in CI from Phase 2), `rsync` the
   store, move the tunnel hostname. *Bar:* Phases 2–4's over-the-wire tests
   pass against the new host with zero client change.

## 7. Production-readiness checklist (thin, but real)

Versioned API from v0 (`/v0/...`); resumable, idempotent chunk fetch (free
via content addressing); TLS via the tunnel; bearer-token auth; client
offline cache with pinning; MetricKit + crash telemetry in `BeePlayer`; CI
that builds server binary + xcframework and runs the interop/parity suites;
TestFlight for `BeePlayer`. Explicitly **not** production scope yet:
accounts, multi-user auth, CDN, autoscaling — those arrive with the bought
server, not before.

## 8. Risks and OPEN items (do not paper over)

- **exp5 ears-gate is still OPEN** — Phase 7 is hostage to it, by design. A
  fail at full depth reroutes per `NEURAL_BASE_FINDINGS.md` Result 3.
- **Phone decode energy is the live unknown** (§4 ledger): the neural
  payload's battery cost on ANE/Core ML is unmeasured; the plan ships v0
  chunks first and swaps payloads only on measured wins. No claim before
  Phase 5/7 numbers.
- **Residential reality**: upstream bandwidth caps what streaming from the
  Mac can demo; fine for own-device production, a known ceiling before real
  users. Power loss ≠ data loss (SQLite journaling + CAS immutability), but
  it is downtime — accepted until traction, stated now.
- **ONNX/candle export fidelity of DAC** (Phase 8) unmeasured; the
  byte-identity bar exists so a gap is caught, not assumed.
- **OPEN:** burst sizing policy details (deadline margins, low-battery /
  poor-signal adaptation) — decided against Phase 5 data, not upfront; auth
  beyond one bearer token; whether `BeehiveKit`'s Swift math thins to pure
  view models. None of these block Phases 1–5.
