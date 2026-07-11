# HANDOFF — 2026-07-11 (latest) · workspace UI, neural trace, clips fix

Three additions on top of the merge below (all committed, nothing pushed;
app reinstalled at `~/Applications/BeeDeck.app`):

- **Single-window workspace UI** (`6434eaf`). The three ad-hoc windows are
  now one Logic-style workspace: toolbar switcher **Perform** (decks, mixer,
  FX) / **Analyze** (helix scene, inspector, library rail), plus a global
  bottom status rail (engine state, Δbeat, encoder status). The **Stage** is
  still its own window on purpose — it's the output surface, meant for a
  projector/second display (toolbar button opens it). Design tokens live in
  `BeehiveMac/Sources/BeehiveApp/Theme.swift`; new chrome should use them.
- **T10 neural video trace** (`9ae8724`). Vision contours on the playing
  clip (OS schedules onto ANE/GPU), five scale strata mapped to the five EQ
  buses (biggest shapes → sub, finest → hi), re-traced once per θ
  quarter-bar beat, band levels animate the strokes between beats. Measured:
  `beehive-cli --tracetest` → 46 contours, median 2.8 ms, worst 26.8 ms per
  512² trace (a 174 bpm beat is 345 ms). The fuller ask — whole clip decoded
  offline into a helix-plane record — is OPEN in roadmap T10.
- **Choose Clips fixed + denser stage overlay** (`44fc959`). The picker was
  a flat directory-only scan that failed silently; now files-or-folders,
  recursive, with visible feedback. Overlay gained beat shockwave rings,
  a 48-tick spectrum ring, a rotating hexagon frame, sub-band video zoom.

---

# Previous handoff — 2026-07-11 (later) · one branch: decks/mixer/FX merged into main

## State of the world (read first)

- **One branch, one tree: `main` at merge commit `7f0dabf`.** The previous
  handoff's open thread #1 is done: `worktree-beedeck` (decks, isolator
  mixer, ten beat FX, library/USB, CBeeDeck C core) is merged into `main`.
  The worktree checkout and the local branch are deleted;
  `origin/worktree-beedeck` still exists remotely but its commits are all
  in `main`'s history. **Nothing has been pushed.**
- **BeeDeck is an app, not a terminal program.** Installed at
  `~/Applications/BeeDeck.app`, built from `7f0dabf`, so the installed app
  now carries everything: helix scene + breathe, AV stage, two decks,
  isolator mixer, the ten θ-synced FX, library with background `.bee`
  auto-convert, Prepare→USB export. Launch from Finder/Spotlight or:

  ```sh
  open ~/Applications/BeeDeck.app
  ```

  Rebuild after code changes: `BeehiveMac/scripts/make_app.sh --install`.
  The terminal is only for development — tests, benches, `bee` CLI, and the
  measured DSP self-test `BeehiveMac/dist/beehive-cli --decktest`.

## What the software is

Two deliverables share this repo:

1. **The `.bee` format** — two-layer audio container: bit-exact PCM
   (Layer 1) + helix analysis record (Layer 2) + zinc keyframe index
   (`zinc_index` section; Python authors at encode time, Rust consumes
   bit-exactly — interop 42/42, T1 DONE note in
   `docs/blueprints/BEEDECK_ROADMAP.md`).
2. **BeeDeck** — the macOS DJ + visuals app on top of it, playing through
   the native Rust core (never reimplementing the codec).

## The app, window by window

**Main window (Beehive).** Library sidebar + 3D helix scene. Load songs;
encoding runs through the Python authoritative encoder
(`scripts/convert_to_bee.py`), with a background watcher auto-converting
library folders. The coil breathes with the live 5-band envelopes; playhead
is CADisplayLink-paced (up to 120 Hz).

**Decks window** (toolbar button). Two decks + mixer + beat FX, DSP in
`CBeeDeck/beedeck.c`:

- **Decks (T3):** hue-colored min/max waveform, beatgrid at θ≡0, 4 hot cues
  per deck, auto/manual loops on the bar math, beat jump, SYNC (match ω,
  phase-lock θ), tempo slider, slip. Measured: loop-wrap declick max step
  1.25× a clean sine's slope; varispeed 440 Hz @ ×1.06 → 466.0 Hz (target
  466.4) — `docs/findings/BEEDECK_T3T4_FINDINGS.md`.
- **Mixer (T4):** trim, 5-band full-kill isolator EQ (LR4 at
  60/250/2000/8000 Hz), channel faders, constant-power crossfader (centre
  −3.01 dB). Measured: all-open band sum flat within ±0.0045 dB; all-band
  kill → rms exactly 0 (true −∞); bass-kill leakage −72 dB (same findings).
- **Beat FX (T5):** ECHO, DUCK, ROLL, REVERSE, DRIVE, ECHO-OUT, SWEEP,
  FLANGER, PHASER, SLICER, REVERB — time parameters quantized to bar
  fractions from ω. Measured: echo tap grid error 0.0 samples native /
  2.1 samples (0.05 ms) at ×1.06; engage/bypass worst step 1.81× a clean
  sine's slope across all ten — `docs/findings/BEEDECK_FX_FINDINGS.md`.
- **Keyboard** (Decks window key): `Q/P` play · `A/L` cue · `S/K` sync ·
  `E/U` auto-loop · `W/R · Y/I` halve/double loop · `Z/X · N/M` beat jump
  ±4 · `1–4` / `7–0` hot cues (⇧ clears) · `←/→` crossfader nudge, `↓`
  centre · `F/J` FX on · `T/O` FX type (⇧ = band target) · `V B / , .` FX
  beats · `G/H` hold = echo-out.

**Stage window** (toolbar button). T2 AV stage: video inspiration set
(folder pick or drag-drop mp4/mov/m4v), 8-bar crossfade advance, rate slaved
to bpm; generative helix overlay (rotation = α, 12 chroma petals,
band-driven inflate, bass-departure deflate/veil), fractional-frame
interpolated. When a deck is on air, its live EQ band taps replace the
offline envelopes as the overlay's signal source (T4 hand-off).

**Prepare → USB (T6, partial).** Export `.bee` + index to a mounted stick
via the Python encoder. The T6 DoD (cold-load on a second Mac + per-file
native-decode verification) has **not** been run yet.

## Roadmap position (source of truth: `docs/blueprints/BEEDECK_ROADMAP.md`)

| Task | State |
|---|---|
| T0 zinc ambient-balance math | DONE (`ZINC_AMBIENT_FINDINGS.md`) |
| T1 zinc keys in `.bee` + Rust consumer | DONE (interop 42/42) |
| T2 AV stage v0 | shipped |
| T3 decks / T4 mixer | shipped, measured (`BEEDECK_T3T4_FINDINGS.md`) |
| T5 beat FX | ten effects shipped, measured; master-bus FX + sub-parameters open |
| T6 Prepare→USB | export works; cold-load DoD not verified |
| T7 visual correlation v1 | not started |
| T8 polish (key detect, MIDI, 4-deck) | not started |
| T9 cross-track auto-mix ("Audio Swap") | not started (spec in roadmap) |

## Verify everything (all green at `7f0dabf`, 2026-07-11)

```sh
.venv/bin/python -m pytest tests/ -q                 # 25/25
cd beecore && cargo test -p bee-format               # 11/11
cd beecore && cargo build --release                  # needed by interop
.venv/bin/python beecore/interop/test_interop.py     # 42/42
cd BeehiveMac && swift build                         # green
BeehiveMac/dist/beehive-cli --decktest               # DSP measured self-test
```

## Merge provenance (what "one branch" cost)

Both trees had independently built T0 (zinc math) and T2 (stage). Resolution
policy: `main`'s versions kept wherever `main` was a strict superset
(`zinc.py` with T1 serialization, fractional-frame `BandEnvelopes`, icon
packaging, `.gitignore`); `worktree-beedeck`'s deck work taken whole
(DeckEngine, DecksView, LibraryPane, CBeeDeck, decktest, FX findings);
hand-blends where both sides carried real features: `StageView.swift` (deck
live source + fractional interpolation), `main.swift` (deck window wiring +
breathe path), `AppModel.swift` (CADisplayLink pacing kept over the 30 Hz
timer), `BEEDECK_ROADMAP.md` (union of statuses). Full detail in `7f0dabf`'s
commit message.

## Open threads (next session)

1. Listen-test the helix breathe in the merged app; tune the four knobs
   (`HelixSceneView` `applyAudio`/`init`).
2. T5 remainder: master-bus FX, per-effect sub-parameters.
3. T6 DoD: prepare a stick, cold-load on another Mac, native-decode verify.
4. Decide whether to push `main` and retire `origin/worktree-beedeck`
   (user call; nothing pushed so far).
5. Known limits (from 2026-07-10): type-switch while engaged hard-cuts old
   wet; ROLL wrap hard cut by design; stage visuals tap pre-FX band
   envelopes; non-`.bee` tracks free-run FX on a 0.5 s pseudo-beat.

---

# Previous handoff — 2026-07-11 · BeeDeck visuals finalized, shipping from main

*(Superseded by the merge above: the "not in the installed app" caveat and
open thread #1 no longer apply; zinc files listed as uncommitted are
committed as of `68f5398`/`1ac93cc`.)*

## State of the world (read first)

- **Canonical source = the main worktree** (`~/sonoFaig`, branch `main`) — user
  decision 2026-07-11 after main and `worktree-beedeck` diverged.
  `~/Applications/BeeDeck.app` is now a **main** build (0.2.0, ad-hoc signed).
- **Not in the installed app**: the T3–T5 deck work — DecksView, the CBeeDeck
  C isolator, the ten θ-synced beat FX. All of that lives only on
  `worktree-beedeck` (`dceabdd`, 4 commits ahead of main's base; checkout at
  `.claude/worktrees/beedeck`, locked). The installed app is the
  helix/stage/library app until that branch is merged into main → **open
  thread #1**.
- Rebuild/install any time: `BeehiveMac/scripts/make_app.sh --install`
  (build → package → quit running instance → swap bundle → `lsregister -f` →
  Dock refresh).

## Today's work (this commit on `main`, not pushed)

### 1. The 3D helix now acts on the music (the complaint that started the day)
The coil in `HelixSceneView` was a constant-radius helix baked from
`record.x/y/h` (`Engine.swift:112-113`) — encoded, reacting to nothing. New
`Coordinator.applyAudio(cursor:env:)` runs per displayed frame:

- **radius breathe** — `helixNode.scale = (inflate, inflate, 1)` with
  `inflate = (0.78 + 0.34·(0.45·sub + 0.55·low)) · (1 − 0.45·drop)` — the
  exact formula from the 2D stage (`StageView.swift:130`), so 2D and 3D agree;
- **bloom on the highs** — `bloomIntensity = 0.2 + 2.0·max(hi, hiMid)`
  (camera does `wantsHDR`, threshold 0.4, blur 12, set in `init`);
- **deflate + dim on bass-departure** — the drop term above plus material
  `transparency = 1 − 0.45·drop`;
- nil `bandEnv` → rest state (scale 1, baseline bloom, opaque), zero-duration
  `SCNTransaction` so nothing lags the playhead.

**Tuning knobs** (in `applyAudio` / `init`): bloom gain `2.0`, inflate depth
`0.34`, drop dim `0.45`, `bloomThreshold 0.4`.

### 2. The visual stack under it, finalized in the same commit
Was sitting uncommitted on main; now in:

- `AppModel.swift` — CADisplayLink-paced playhead (`playheadSeconds`
  published once per displayed frame, up to 120 Hz), fractional
  `playheadFrame`, `BandEnvelopes` computed off the main actor after decode,
  cached peak list; ".bee decoded natively in N s" status (beecore FFI path).
- `StageView.swift` (new) — T2 AV stage: two AVQueuePlayer video slots
  crossfading on 8-bar boundaries, tempo-slaved rate, generative overlay
  (chroma petals rotated by α, breathing core ring, sparkle orbit, chromatic
  wash, drop veil).
- `BeehiveKit/BandEnvelopes.swift` (new) — 5-band envelopes (20/60/250/2k/8k
  edges) at the record grid, 98th-pct normalise + peak-hold release, and the
  `bassDrop` detector. Future realtime EQ taps replace these offline
  envelopes with the same shape (see file header).
- `Panels.swift` — Energy/Hue views take the fractional playhead.
- `Package.swift` — platform macOS 13 → 14 (two-param `onChange`,
  display-link API).

### 3. Packaging + the missing icon (tonight's bug)
The Dock/notification icon was the generic placeholder because **no build of
BeeDeck ever contained an `.icns`** (worktree bundles had only
Info.plist + binary), and today's bundle swap also broke the Dock tile's
cached alias. Fixed:

- `BeehiveMac/scripts/make_icon.swift` — renders the icon (honey hexagon,
  two glowing helix strands, white playhead bead at their crossing) at all 10
  iconset sizes and packs `Resources/BeeDeck.icns` (committed, ~750 KB).
- `make_app.sh` — copies the icns into `Contents/Resources`, plist gains
  `CFBundleIconFile`, version 0.2.0/2; `--install` now quits the running app,
  re-registers with LaunchServices and restarts the Dock.
- Verified end-to-end: `NSWorkspace.shared.icon(forFile:)` on the installed
  bundle returns the new artwork; app smoke-launched and quit clean.
- If the user's Dock still shows a stale/generic tile: it's a pinned alias
  from before the swap — remove it and re-pin from `~/Applications`.

## Verification still owed (needs ears + eyes, can't be done headless)
Load a song, play, watch the 3D helix panel: coil widens on bass / narrows
between hits; strands bloom on hi-hats; coil deflates + dims on a drop; 3D
breathe tracks the 2D stage overlay (same `bandEnv`, same playhead); auto-spin
composes with the breathe; bead stays on the curve. Adjust the knobs above if
too strong/subtle.

---

# Previous handoff — 2026-07-10 · BeeDeck beat FX (T5 first wave)

## What shipped (branch `worktree-beedeck`, commits `adb7b83` + `88d40e8`)

θ-synced Beat FX are in BeeDeck — designed from the **RMX-IGNITE manual**
(`RMX-IGNITE_DRI2033-A_EN_manual.pdf`, behavior reference only) and
re-derived on the `.bee` θ math, which turned out to be the heavy lifting
already done: the RMX's BPM/Phase-Meter machinery **is** `θ = ω_n·n mod 2π`,
so DUCK, ROLL and REVERSE needed zero new timing code.

- **Engine** (`BeehiveMac/Sources/CBeeDeck/beedeck.c|h`): one FX slot per
  deck on the isolator band buses — the 5-band LR4 split doubles as the FX
  router (LOW/MID/HI/ALL). ECHO (beat-fraction feedback delay, tape-glide),
  DUCK (pure g(φ)), ROLL/REVERSE (previous-θ-cycle capture replay,
  slip-style), DRIVE (tanh), ECHO-OUT (momentary release punch). All
  transitions declick-smoothed; realtime-safe (preallocated rings, atomics,
  no locks).
- **UI** (`DecksView.swift`): FX row per deck — effect chips, band target,
  beats ÷2/×2 (1/16…4), amount slider, ECHO OUT press-and-hold. Keys:
  **F/J** FX on · **T/O** type (⇧ = target) · **V B / , .** beats ·
  **G/H** hold for echo-out (NSEvent monitor for key-up).
- **Verified, measured** (`beehive-cli --decktest`, tests 7–13; numbers in
  `docs/findings/BEEDECK_FX_FINDINGS.md`): echo taps on the grid with
  **0.0 samples** error at native rate, **2.1 samples (0.05 ms)** at ×1.06;
  engage/bypass worst step 1.81× a clean sine's slope (click-free DoD);
  duck −33.3 dB on-beat / −0.00 dB off-beat; release decay monotonic
  −12.5 dB per 3 taps; prior T3/T4 suite unchanged; 97× realtime.

## Second wave (same session, commit `88d40e8`)

The catalog is complete: **SWEEP, FLANGER, PHASER, SLICER, REVERB** joined
the first five — ten effects total, all θ-synced, all measured (decktest
14–18: sweep −42.8 dB closed/+0.1 dB open; flanger 10.1 dB / phaser 11.0 dB
notch swing; slicer 8/8 on pattern; reverb tail monotonic from −34 dB with
exact-silence floor; engage/bypass click-free across all ten).
