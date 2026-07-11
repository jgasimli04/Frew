# BeeDeck — CDJ-parity DJ feature specification

**Date: 2026-07-10.** Reference source: AlphaTheta **CDJ-3000X Instruction
Manual** (public document, `4753b69cac3adbf61d9d8940be0d5df6ee0b.pdf`, this
repo root). This spec reads that manual as a **feature-behavior reference
only** — no Pioneer/AlphaTheta code, assets, protocol bytes, or trademarked UI
are reproduced or emulated. Every behavior below is re-specified against
BeeDeck's own architecture: `.bee` container, θ/α helix math, the C DSP core,
Swift/SwiftUI shell. This is the non-goal stated in `BEEDECK_ROADMAP.md` §1 and
it still holds here.

Companion docs: `BEEDECK_ROADMAP.md` (task list T0–T8, source of truth for
sequencing), `BEE_NATIVE_TRANSITION_BLUEPRINT.md` (Swift shell / Rust-C
realtime split), `BEE_ZINC_KEYFRAME_BLUEPRINT.md` (θ/index layer this spec's
quantize and beatgrid features consume).

## 1. What's already built (branch `worktree-beedeck`, commits `68bcc1e`,
`1c32921`, `2f57a94` — not yet on `main`)

| Area | State |
|---|---|
| Decks | 2× `DeckEngine` → C core (`DeckEngine.swift`, `bd_deck_*`), play/pause, seek, cue (set/back-to-cue) |
| Hot cues | 8 slots/deck (`hotCue`, `clearHotCue`, `hotCuePosition`) |
| Loop | Auto-loop by beat count only (`autoLoop(beats:)`), no manual in/out |
| Beat jump | `beatJump(beats:)`, forward/back |
| Sync | `sync(deck:)` matches BPM + phase; live Δbeat-ms readout in UI |
| Tempo | Pitch fader + range (`PitchRange` ±6/10/16), `effectiveBpm` |
| Quantize | `quantized(_:sample:)` snap helper exists, used internally for cue/hot-cue placement — no on/off toggle exposed |
| Mixer | Trim, 5-band full-kill isolator EQ (LR4 crossovers, measured), one-knob filter, fader, crossfader + curve |
| θ/beatgrid | Per-deck dial rendering `record.alpha`, downbeat at 12 o'clock, "θ grid / no grid" chip |
| Library | `LibraryPane` — browse/search a folder, bpm+duration from `.bee` meta, drag-to-deck |
| Prepare → USB | Convert missing `.bee` via venv shell-out, byte-verify, write `beedeck_index.jsonl` |
| Media in | `.bee` native; mp4/mov/m4v via `AVAssetReader` audio-track fallback |
| Stage | Video-clip layer + generative overlay, band-envelope + bass-departure correlation |

Everything in the table above is **status quo, not to be re-implemented** —
this spec's job is to name the CDJ-3000X features still missing and give each
one a concrete, θ-native shape before it's built (mostly landing in T3
follow-up work and T5/T8 of the roadmap).

## 2. Gaps against the CDJ-3000X manual, spec'd

For each: **CDJ reference behavior** (manual §, page), **BeeDeck target**,
**where it lands** (files, roadmap slot).

### 2.1 Manual loop-in/loop-out (manual p.79, "Setting a loop — Manual setting")
CDJ: press LOOP IN at an arbitrary point during playback, LOOP OUT at another;
loop plays the exact span, independent of the beatgrid.
**BeeDeck target:** add `setLoopIn(_:)` / `setLoopOut(_:)` to `DeckEngine`
alongside the existing beat-count `autoLoop`; store both loop-in and loop-out
as raw sample positions in the C core (`bd_deck_set_loop_in/out`), independent
of `autoLoop`'s beat math. Quantize (2.3) snaps these to the nearest θ≡0
crossing when on, leaves them raw when off — this is the one feature that
proves quantize is actually doing something rather than just being cue-time
default behavior.
**Lands in:** `BeehiveKit/DeckEngine.swift`, C core `deck.c`/`deck.h`
(check current core filename), `DecksView.swift` loop controls.

### 2.2 Loop fine-adjust, halve/double, active loop, save/call/delete (p.81–83)
CDJ: nudge loop-in/out by small increments after the fact; halve/double
length in place; a loop stored on the track auto-fires past a saved point on
load (Active Loop); loops persist across sessions per-track.
**BeeDeck target:**
- Halve/double: already partially present as `scaleLoop(by:)` in
  `DeckSession` — keep, wire to manual loops too once 2.1 lands.
- Fine-adjust: nudge loop-in/out by N samples (arrow-key repeat) while loop
  is active; no new engine primitive beyond re-calling `setLoopIn/Out`.
- Save/call/delete: loops (and hot cues, 2.4) are **already representable**
  as extra sections in `.bee` — same append-only section mechanism T1 defines
  for `zinc_index` (`beehive/beefile.py::write_bee`). A `saved_loops` section
  (sample-in, sample-out, label) is the natural sibling section; Rust/Swift
  read it generically, same as T1's "old readers unaffected" property.
- Active Loop: on load, if `saved_loops` has an entry flagged active, arm it;
  fire when playhead crosses loop-in, same as CDJ.
**Lands in:** `beehive/beefile.py` (new section), `DeckEngine.swift`
(`savedLoops`, `armActiveLoop`), roadmap: fold into **T3 follow-up**, not a
new numbered task — it's the same deck substrate.

### 2.3 Quantize toggle (p.88)
CDJ: global on/off; when on, cue/hot-cue/loop-in/loop-out points snap to
nearest beat (configurable beat value: 1/1, 1/2, 1/4...).
**BeeDeck target:** the snap math (`quantized`) already exists — it's silently
always-on for cue/hot-cue. Expose it as a per-deck toggle in `DeckUI`
(`quantizeOn: Bool`, default true) with a beat-value setting reusing the
existing `record.alpha`/θ grid (snap target = nearest `θ ≡ 0 mod (2π/beatValue)`
crossing, derived, not stored — consistent with the "θ is derivable as fact"
principle in the roadmap). Applies to hot cue, loop-in, loop-out (2.1), cue
point.
**Lands in:** `DeckEngine.swift` (expose toggle + beat-value param),
`DecksView.swift` (UI chip, keyboard: `Q`/`Shift+Q` pattern already used for
other toggles — see §3).

### 2.4 Hot Cue Bank list / auto-load persistence (p.86–87)
CDJ: hot cues stored per-track, auto-recalled on load; a "bank list" groups
hot cues across tracks for browsing.
**BeeDeck target:** same `saved_loops`-sibling section idea — a
`hot_cues` section (slot 0–7, sample position, optional label/color) written
at Prepare time (T6) or on-the-fly in the app; auto-loaded when a `.bee` with
that section is loaded onto a deck. Bank-list browsing is a `LibraryPane`
filter (tracks with ≥1 hot cue), not a new screen.
**Lands in:** `beehive/beefile.py`, `LibraryPane.swift`, `DeckEngine.swift`
load path.

### 2.5 Gate Cue (p.85)
CDJ: hold a Hot Cue button → plays from that point only while held; release →
stop. Distinct from normal Hot Cue (press → latched playback).
**BeeDeck target:** keyboard already models "press vs hold" for nothing yet;
add hold-detection on the hot-cue keys (NSEvent key-down/key-up pairing,
already required infrastructure for scratch-style jog later) — while held,
force `playing = true` from the cue sample; on key-up, stop (or, if Slip
(2.6) is on, resume the background position). Toggle: Gate Cue mode
on/off per the CDJ model, default off (so existing 1234/7890 hot-cue taps
keep current latched behavior).
**Lands in:** `DecksView.swift` key handling, `DeckEngine.swift`
(`gateHotCue(_:slot:down:)`).

### 2.6 Slip mode (p.91–92)
CDJ: background "phantom" playback continues silently during pause/loop/
reverse/scratch/hot-cue-hold; when the foreground action ends, audible
playback resumes from where the phantom position would be — rhythm never
breaks.
**BeeDeck target:** this is the single largest new engine primitive. Needs a
second position counter in the C core that always advances at the track's
natural rate regardless of what the audible position is doing
(`bd_deck_slip_position`), plus a foreground/background crossfade-free swap
when Slip resolves (sample-accurate re-seek, not a fade — CDJ behavior is a
hard cut back onto the phantom's exact sample). UI: yellow/white waveform
line split already anticipated by the existing θ-dial infrastructure (one
more rendered position marker). This is a `DoD`-worthy standalone item —
recommend its own line item in the roadmap (**new: T3.5 — Slip mode**) rather
than folding silently into T3, since it changes the deck's internal state
model (two positions, not one).
**Lands in:** C core (new dual-position tracking), `DeckEngine.swift`,
`DecksView.swift`.

### 2.7 Beatgrid manual adjust (p.95)
CDJ: nudge the whole grid, snap first-beat to a cue point, double/halve beat
count, shift by 1 ms — because rekordbox's auto-analysis is occasionally
wrong and the DJ must correct it before the grid is trustworthy.
**BeeDeck target:** BeeDeck's grid is *derived*, not stored (`θ = ω_n·n mod
2π` from the manifest) — there is no "wrong grid" in the rekordbox sense
unless the *analysis* (bar/beat detection in `beehive/zinc.py` or the tempo
tracker) mis-tracked. Rather than a manual per-beat nudge UI, the BeeDeck
equivalent is a **global phase/tempo override** stored as a correction
delta in a `grid_override` section (phase offset in samples, tempo
multiplier) applied on top of the derived θ — same append-only section
pattern as 2.2/2.4. Cheaper to build, honest about where the correction
actually lives (a stored correction to a derived quantity, not a rewritten
grid).
**Lands in:** `beehive/beefile.py`, `DeckEngine.swift` (apply override when
computing θ for display/quantize).

### 2.8 Key Sync / Key Shift (p.96–97)
CDJ: Key Sync matches musical key to the sync master (choosing the smallest
rotation among relative/dominant/subdominant); Key Shift manually transposes
by semitones, independent of tempo (master tempo / time-stretch already
decouples pitch from rate).
**BeeDeck target:** needs musical key *detection* first — the roadmap
already names this exact gap: **T8 "Musical key detection (Krumhansl-style
over stored per-frame chroma — substrate already in every record)."** This
spec's addition: once key is known per track, Key Shift is a pitch-only
transform layered on the existing tempo/rate path (`applyRate`,
`PitchRange`) — same decoupled-rate machinery as Master Tempo already uses,
just with a semitone parameter instead of a % parameter. Key Sync is then
"pick the semitone shift that minimizes rotation distance to the other
deck's key," pure arithmetic once both keys are known. No new DSP primitive
beyond what Master Tempo already requires.
**Lands in:** T8 as roadmapped; no change to sequencing recommended here.

### 2.9 Beat FX (p. — not in this manual; CDJ-3000 FX are mixer-side, but the
roadmap already owns this as T5)
No manual excerpt needed — T5 ("Beat FX (θ-synced)": echo, delay, reverb,
flanger, phaser, filter sweep, roll/slicer, all bar-fraction-quantized via
θ) already covers this correctly and is unchanged by this spec.

### 2.10 Not adopting
- **Touch Preview / Touch Cue / Tag List** (p.60–66): touchscreen-specific
  CDJ interactions with no keyboard/trackpad analogue worth forcing. Skip —
  `LibraryPane`'s search + drag-to-deck already covers the underlying job
  (audition before load).
- **PRO DJ LINK / multi-unit master election** (p.8, p.93–94 "Changing the
  sync master"): BeeDeck v1 is a single-Mac, 2-deck app; there's no network
  of units to elect a master across. Deck A/B "who's master" is already
  implicit in the existing `sync(deck:)` (non-master syncs to master).
  Re-visit only if a 4-deck layout (T8) reintroduces the question.
- **Wireless LAN / streaming services (Beatport/TIDAL) / CloudDirectPlay**
  (p.39–53): out of scope — BeeDeck's library is local `.bee` by design
  (roadmap §1, "Library lives entirely in `.bee`").

## 3. Keyboard map additions

Extends the existing scheme documented in `DecksView.swift`'s header comment
(`play Q/P · cue A/L · sync S/K · loop E/U · loop ÷2 W/Y · loop ×2 R/I · jump
−4 Z/N · +4 X/M · hot cues 1234/7890`). New bindings, deck A / deck B:

| Function | Deck A | Deck B |
|---|---|---|
| Quantize toggle | `⇧Q` | `⇧P` |
| Slip mode toggle | `D` | `H` |
| Gate Cue mode toggle | `⌥A` | `⌥L` |
| Loop-in (manual) | `[` | `⌥[` (or dedicated B-side key — TBD, see open questions) |
| Loop-out (manual) | `]` | `⌥]` |
| Save current loop/cue | `⇧M` (shares "memory" mnemonic with `MEMORY` button) | `⇧,` |
| Key Shift ± | `-`/`=` | `_`/`+` |

Open question: deck B is short on unshifted single-key real estate once
manual loop-in/out is added — worth deciding whether deck B moves to a
`J`-anchored cluster (mirroring deck A's `Z/X/C`-ish left-hand layout on the
right hand) before this lands in code, rather than retrofitting `⌥`-prefixed
keys.

## 4. Sequencing recommendation

Ordered by dependency, not manual page order:
1. **2.1 (manual loop) + 2.3 (quantize toggle)** — same PR, they're
   coupled (quantize needs something non-trivial to snap).
2. **2.2 (save/call/delete loops) + 2.4 (hot cue persistence)** — same PR,
   both are "new `.bee` section, generic read" work, T1's pattern reused.
3. **2.5 (Gate Cue)** — small, needs key hold-detection infra useful for
   later scratch/jog work too.
4. **2.7 (grid override)** — only if analysis errors actually show up in
   practice; don't build speculatively.
5. **2.6 (Slip)** — largest, own roadmap line (T3.5), do after 1–3 land so
   the dual-position model isn't fighting a moving loop/cue API underneath
   it.
6. **2.8 (Key Sync/Shift)** — stays at T8 as already roadmapped.

## 5. Verification norms (unchanged from roadmap §3)

Each item above ships with a runnable DoD before being called done: `swift
build` green, a manual keyboard-driven check against a real pair of tracks
(beatmatch, loop-save-recall-across-reload, slip-resolves-to-exact-sample —
measured, e.g. by diffing expected vs actual sample position after a slip
episode), not an adjective.
