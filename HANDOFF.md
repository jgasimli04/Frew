# HANDOFF — 2026-07-11 · BeeDeck visuals finalized, shipping from main

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

## Deliberately left uncommitted (separate streams)
- **zinc**: `beehive/zinc.py`, `scripts/zinc_report.py`, `tests/test_zinc.py`,
  `docs/blueprints/BEE_ZINC_KEYFRAME_BLUEPRINT.md`,
  `docs/findings/ZINC_PHASE1_FINDINGS.md`, `docs/findings/ZINC_AMBIENT_FINDINGS.md`.
- `CLAUDE.md` (untracked), the two PDFs in the repo root (CDJ-3000X manual
  9.3 MB + RMX-IGNITE manual) — still undecided: commit, move to
  `docs/reference/`, or ignore (2026-07-10 thread).

## Open threads (next session)
1. **Merge `worktree-beedeck` → `main`** — restores decks/isolator/FX into the
   shipping app. Both sides touched `main.swift`, `AppModel.swift`,
   `Package.swift`; expect real conflicts, re-run `beehive-cli --decktest`
   (tests 7–18) after.
2. Listen-test the helix breathe; tune the four knobs.
3. T5 remainder: master-bus FX, per-effect sub-parameters.
4. Known limits (unchanged, from 2026-07-10): type-switch while engaged
   hard-cuts old wet; ROLL wrap hard cut by design; stage visuals tap pre-FX
   band envelopes; non-`.bee` tracks free-run FX on a 0.5 s pseudo-beat.

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

Note (2026-07-11): the "rebuild via make_app.sh" pointer from this section now
refers to **main's** `BeehiveMac/scripts/make_app.sh`; the worktree copy is
stale, and the installed app no longer carries the FX until the merge (open
thread #1 above).
