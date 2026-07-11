# sonoFaig — .bee / BeeDeck

Helix-based two-layer audio container (`.bee`) and the BeeDeck macOS DJ+visuals
app built on it. **Read `docs/blueprints/BEE_FORMAT_BLUEPRINT.md` and
`docs/blueprints/BEEDECK_ROADMAP.md` before any non-trivial task** — they are
the sequencing source of truth (what's LOCKED vs OPEN). Measured results live
in `docs/findings/`. The `sonofaig-engineering` skill carries the house rules;
load it for any work in `docs/`, `beecore/`, `beehive/`, or `BeehiveMac/`.

## Layout

- `beehive/` — Python **reference** implementation (format source of truth):
  encoder, `.bee` reader/writer (`beefile.py`), zinc key generator (`zinc.py`)
- `beecore/` — Rust portable core (`crates/bee-format` + `bee-ffi` C ABI);
  bit-exact vs the reference; `bee` CLI in `bee-format/src/bin/bee.rs`
- `BeehiveMac/` — BeeDeck app (Swift + C); plays through the native core
- `kernel/` — loop-clocked engine experiments (separate track)

## Commands

```sh
.venv/bin/python -m pytest tests/ -q          # Python suite
cd beecore && cargo test -p bee-format        # Rust suite
cd beecore && cargo build --release           # needed by interop
.venv/bin/python beecore/interop/test_interop.py  # cross-impl bit-exactness
.venv/bin/python scripts/zinc_report.py       # zinc corpus numbers (real tracks)
BeehiveMac/scripts/make_app.sh --install      # rebuild BeeDeck.app
```

Corpus source tracks: `~/Desktop/Music`.

## Non-negotiable invariants (details in the skill + blueprints)

- **Python authors, Rust consumes.** Encode-time decisions (key placement,
  thresholds) live in `beehive/`; Rust only reads what's baked into the `.bee`.
- **`.bee` sections are additive-only** once shipped; a rename/repurpose is a
  format break requiring a `bee_format_version` bump.
- **Derivable geometry (θ) is recomputed, never stored.**
- **Measure, don't claim** — no quality adjective in a doc without a number
  and a findings citation. Lint docs with the skill's `check_vocab.py`.
- **No third-party code/assets/protocol bytes** (manuals are behavior
  references only; PDFs are gitignored).
