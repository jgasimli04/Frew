# sonoFaig — the `.bee` audio format & BeeDeck

A song as a **3D helix**: rotation set by tempo (one full turn = one bar),
climb set by how fast the music moves. `.bee` is the two-layer file format
that came out of it — a bit-exact lossless audio payload (Layer 1) with the
helix analysis state riding alongside (Layer 2) and a variable-rate keyframe
index (`zinc_index`) on top. BeeDeck is the macOS DJ + visuals app built on
that math.

**→ [`docs/PROVENANCE.md`](docs/PROVENANCE.md) states precisely which
mathematics and algorithms are original to this project and which are
conventional techniques, component by component, with file pointers.**
Read it first if you are reviewing.

## What runs where

| Component | Windows | macOS | Linux |
|---|---|---|---|
| `beehive/` Python reference (encode/decode/inspect, tests) | ✅ | ✅ | ✅ |
| `beecore/` Rust core + `bee` CLI + C ABI | ✅ | ✅ | ✅ |
| Cross-implementation interop suite | ✅ | ✅ | ✅ |
| `kernel/`, `bearing-helix-research/` (Rust research tracks) | ✅ | ✅ | ✅ |
| `BeehiveMac/` — the BeeDeck app (SwiftUI/AVFoundation/Vision) | ❌ | ✅ | ❌ |

The app is macOS-only by its frameworks. Everything the *format* claims —
bit-exact codec, helix records, zinc keys, cross-implementation equality — is
verifiable on Windows from the terminal, and CI runs exactly that on a
Windows runner (`.github/workflows/ci.yml`).

## Windows quickstart (review path)

Prereqs: [Python 3.11+](https://python.org), [Rust](https://rustup.rs)
(MSVC toolchain is fine), git.

```powershell
git clone https://github.com/jgasimli04/Frew.git
cd Frew

# Python env
py -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
# (faster torch: py -m pip install torch --index-url https://download.pytorch.org/whl/cpu)

# 1) Python reference suite — 25 tests
.venv\Scripts\python -m pytest tests -q

# 2) Rust core — build + 11 tests
cd beecore
cargo test -p bee-format
cargo build --release
cd ..

# 3) The load-bearing check: cross-implementation bit-exactness, 42 checks
#    (Python writes → Rust reads, Rust writes → Python reads, zinc keys byte-equal)
.venv\Scripts\python beecore\interop\test_interop.py

# 4) Round-trip your own audio (WAV/FLAC/AIFF in, bit-exact PCM back)
.venv\Scripts\python -m beehive encode path\to\song.wav
.venv\Scripts\python -m beehive inspect path\to\song.bee
.venv\Scripts\python -m beehive decode path\to\song.bee -o roundtrip.wav
```

macOS/Linux: same commands with `.venv/bin/python` and `/` paths. The
reference decodes WAV/FLAC/AIFF (libsndfile); mp3/m4a decode only exists in
the Mac app via AVFoundation.

## The map

| Directory | What it is | Language | Status |
|---|---|---|---|
| `beehive/` | **Reference implementation** — format source of truth: encoder, `.bee` reader/writer, zinc key generator, helichain, loops. `python -m beehive encode\|decode\|inspect` | Python | working, tested |
| `beecore/` | **Portable native core** — `.bee` read/write + zinc consumer + C ABI (`bee-ffi`), `bee` CLI, benchmarks | Rust | bit-exact vs reference (interop 42/42) |
| `BeehiveMac/` | **BeeDeck** — decks, 5-band isolator mixer, θ-synced beat FX, AV stage with neural trace; plays through the native core | Swift + C | macOS app; measured findings in `docs/findings/` |
| `kernel/` | Loop-clocked engine, Demo 1 — adaptive-time-step kernel (equal-energy ticks from `‖F‖`) | Rust | acceptance green |
| `bearing-helix-research/` | The helix fold applied to rotating-machinery vibration | Rust | synthetic bench green; real data open |
| `helichain/` | Data — append-only, hash-linked ledger of encoded songs | data | 3 tracks |
| `tests/` | pytest suite for `beehive/` | Python | 25 tests |
| `scripts/` | Corpus tools (`convert_to_bee.py`, `zinc_report.py`, `encode_song.py`) — point them at your own music folder | Python | — |
| `experiments/` | One-off studies (their measured conclusions live in `docs/findings/`) | Python | historical record |
| `docs/` | Blueprints (specs/roadmaps), findings (measured results), **PROVENANCE.md** | — | — |

## docs/

- **`PROVENANCE.md`** — original math vs. conventional techniques, per component.
- `blueprints/` — build specs & roadmaps: **BEE_FORMAT_BLUEPRINT.md** (the
  format; §4 lists what is still OPEN), **BEEDECK_ROADMAP.md** (the app,
  T0–T10 with DoD and status), BEE_ZINC_KEYFRAME_BLUEPRINT, and the rest.
- `findings/` — measured results that drove decisions: VERDICT.md (chroma is
  many-to-one → the two-layer pivot), ZINC_AMBIENT_FINDINGS.md (anchor
  policy numbers), BEEDECK_T3T4_FINDINGS.md / BEEDECK_FX_FINDINGS.md (deck,
  isolator, FX measurements), LOOP_DEDUP_FINDINGS.md.
- `guides/` — USER_MANUAL.md. `notes/`, `figures/`, `archive/` — the record.

Benchmarks of `.bee` vs FLAC/ALAC/WAV/AIFF: `beecore/bench/RESULTS.md`
(honest result: `.bee` does not beat FLAC on size; that axis is closed there).

## Quick commands (macOS dev box)

```sh
.venv/bin/python -m pytest tests/ -q                 # Python suite
(cd beecore && cargo test -p bee-format)             # Rust suite
(cd beecore && cargo build --release)                # needed by interop
.venv/bin/python beecore/interop/test_interop.py     # cross-impl bit-exactness
BeehiveMac/scripts/make_app.sh --install             # build + install BeeDeck.app
```

## What is deliberately still open (do not silently resolve)

Blueprint §4: **(a)** the real predictive+entropy payload coder (v0 uses
FLAC/raw+zlib placeholders), **(b)** exact vs near-duplicate loop dedup, and
the inherited theory frontier (radius law, `‖F‖` weighting, beehive packing) —
see `docs/blueprints/BEE_FORMAT_BLUEPRINT.md` §4 and `BEEDECK_ROADMAP.md` for
the app-side OPEN items (T6 cold-load DoD, T7, T9, T10's offline extension).
