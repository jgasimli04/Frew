# sonoFaig — the `.bee` audio format & beehive engine

A song as a **3D helix**: rotation set by tempo, climb set by how fast the music
moves. `.bee` is the two-layer file format that came out of it — a lossless
audio payload (Layer 1) with the helix state riding alongside (Layer 2).

## The map

| Directory | What it is | Language | Status |
|---|---|---|---|
| `beehive/` | **Reference implementation** — the format spec source of truth: encoder, `.bee` reader/writer, helichain, loops. `python -m beehive encode\|decode\|inspect` | Python | working, tested |
| `beecore/` | **Portable native core** — `.bee` read/write for iOS/Android/macOS/Windows + C ABI (`bee-ffi`), `bee` CLI, format benchmarks | Rust | bit-exact vs reference (24/24); 4 cross-targets build |
| `BeehiveMac/` | **Consumer app** — helix viewer + `.bee` player (plays through the native core; never reimplements the codec) | Swift | plays `.bee`; A/B control chain |
| `kernel/` | **Loop-clocked engine, Demo 1** — adaptive-time-step kernel: equal-energy ticks from `‖F‖` | Rust | acceptance green |
| `helichain/` | **Data** — append-only, hash-linked ledger of encoded songs (`chain.jsonl` + records) | data | 3 tracks |
| `tests/` | pytest suite for `beehive/` | Python | `.venv/bin/python -m pytest tests` |
| `scripts/` | Daily-use tools: `encode_song.py` (encode → helichain) | Python | — |
| `experiments/` | One-off studies with their outputs: exp1–3 (chroma invertibility), `verify_geometry.py` (sympy κ/τ), `analyze_loop_structure.py` (bar dedup), `convert_and_compare.py` (+ `recon/`) | Python | historical records |
| `docs/` | Everything written — see below | — | — |

## docs/

- `blueprints/` — build specs & roadmaps: **BEE_FORMAT_BLUEPRINT.md** (the format;
  §4 lists what is still OPEN), BEEHIVE_BLUEPRINT, BEEHIVE_SWIFT_UI, P2P_MVP,
  BEE_NEURAL_PLAYBACK_ROADMAP, STUDY_ROADMAP_ENGINE.
- `findings/` — measured results that drove decisions: **VERDICT.md**
  (2026-06-20: chroma is many-to-one in timbre → the two-layer pivot),
  **LOOP_DEDUP_FINDINGS.md** (exact bar dedup = 0% on real mixes; discriminative
  spectral fingerprint is the way).
- `guides/` — USER_MANUAL.md.
- `notes/` — bee-themis-kromus.md (transcription of the handwritten pivot
  pages; the photographed pages are in `notes/pages/`).
- `figures/` — formant_pitch_invariance.png, helix_chroma_projection.png.
- `archive/` — superseded handoffs/prompts kept for the record.

Benchmarks of `.bee` vs FLAC/ALAC/WAV/AIFF: `beecore/bench/RESULTS.md`.

## Quick commands

```sh
# Python reference: encode a song into the helichain
.venv/bin/python scripts/encode_song.py "~/Desktop/Music/<song>" [--bpm N]

# Python reference: .bee round-trip
.venv/bin/python -m beehive encode|decode|inspect …

# Rust core: build + tests + cross-implementation acceptance
(cd beecore && cargo build --release && cargo test --release)
.venv/bin/python beecore/interop/test_interop.py

# Format benchmark on the real library
.venv/bin/python beecore/bench/bench_formats.py

# The Mac app (scans ~/Desktop/Music; .bee files play natively)
(cd BeehiveMac && swift build -c release && .build/release/BeehiveApp)
```

## What is deliberately still open (do not silently resolve)

Blueprint §4: **(a)** the real predictive+entropy payload coder (v0 uses
FLAC/raw+zlib placeholders), **(b)** exact vs near-duplicate loop dedup, and the
inherited theory frontier (radius law, `‖F‖` weighting, beehive packing) — see
`docs/blueprints/BEE_FORMAT_BLUEPRINT.md` and the beehive skill.

`.quarantine/` is user-managed; leave it alone.
