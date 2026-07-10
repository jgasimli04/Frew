# Beehive Foundation Engine — User Manual

The foundation engine turns a real song into a compact **helix record** and keeps
it on standby in the **helichain** — an append-only, hash-linked ledger where each
song is analysed exactly once. This is the real-audio front-end the prototype
never had; everything before it was synthetic.

What one song becomes:

```
audio file ──▶ state s(n)=(A,I) ──▶ force F=ds/dn ──▶ climb h=∫‖F‖ ──▶ helix R(n)
                     │                                                      │
                     └── chroma(n) ─────────────────────── colour (hue) ───┘
                                                              │
                                              HelixRecord ──▶ helichain block
```

- **A(n)** — loudness (dB). **I(n)** — interval, the spectral centroid in
  semitones (pitch *spacing*). Together they are the song's state at frame `n`.
- **F(n) = (dA/dn, dI/dn)** — the force, the energy spent. Its magnitude `‖F‖`
  drives the climb; it is large where the music *moves*, ~0 where it is static.
- **h(n)** — the climb, a running total of `‖F‖`; the third axis of the helix.
- **R(n) = (r₀cos α, r₀sin α, h)** — the helix; `α` rotates at the song's tempo.
- **chroma(n)** — a 12-d timbral-identity vector, mapped to a **hue** (each note a
  light, coloured by its timbre).

---

## Requirements

Python 3.13 with: `numpy`, `scipy`, `soundfile` (decoding), `torch` (only for the
test that checks the numpy math against the verified reference). All already
installed in this environment.

---

## Quick start

```bash
cd ~/sonoFaig

# encode a specific song
python3 scripts/encode_song.py "~/Desktop/Music/506206_Night_(Original Mix).aiff"

# or with no path: picks the first audio file in ~/Desktop/Music (then ~/Downloads)
python3 scripts/encode_song.py
```

Typical output:

```
encoding: .../506206_Night_(Original Mix).aiff
  song_id     506206_Night_(Original Mix)-a719943f
  duration    371.3 s   sr 44100 Hz   frames 15989
  tempo       69.8 bpm (estimated, conf 0.92)   omega 1.828 rad/s
  climb h(N)  17042.2   (total energy spent; outer radius r0=1.0)
  kappa/tau   |kappa| max 4.02e+03, |tau| max 4.73e+04
  helichain   added block #0  hash 4071afc6d501...  -> ~/sonoFaig/helichain
  chain check OK  (1 block(s))
  size        stored 874 KiB logical (778 KiB on disk)  vs  dense STFT 64018 KiB
  lighter by  512x (A,I geometry substrate), 73x (+timbre)  [column count, not adaptive offload]
```

Run it again on the same song and it says **`already in chain (analysed once)`** —
nothing is recomputed. Run it on a new song and a new block is appended.

### CLI options

| Flag | Default | Meaning |
|---|---|---|
| `audio` | first file in `~/Desktop/Music` | path to the song |
| `--bpm N` | estimate | **override** the tempo (see the half/double note below) |
| `--chain DIR` | `~/sonoFaig/helichain` | where the ledger + records live |
| `--hop N` | 1024 | samples between frames (this is what `n` counts) |
| `--n-fft N` | 2048 | FFT / window size |

---

## What a record contains

Only the **independent state** is stored on disk: `A`, `I`, `chroma` (12-d), and
`engagement`. Everything geometric — `F_mag`, `h`, `alpha`, `x/y/z`, `kappa/tau`,
`hue/sat/val` — is a function of that state plus the scalar metadata, so it is
**recomputed on load**, not stored. That is the whole compactness claim: a dense
STFT is exactly what we refuse to keep.

On disk a record is two files in `helichain/records/`:

- `<song_id>.npz` — the stored arrays (compressed float32).
- `<song_id>.json` — metadata: `bpm`, `omega`, `sr`, `hop`, `r0`, the force
  weighting, definitions, and a `caveats` list.

---

## Using records and the chain from Python

```python
from beehive import encode_song, Helichain

# 1) encode (in memory) — every derived field is populated
rec = encode_song("~/Desktop/Music/506206_Night_(Original Mix).aiff", bpm=140)
rec.A, rec.I            # state: loudness, interval (one value per frame)
rec.F_mag, rec.h        # force magnitude and climb
rec.x, rec.y, rec.z     # helix coordinates (z == h)
rec.chroma              # (n_frames, 12) timbral identity
rec.hue, rec.sat, rec.val   # per-frame colour ("each note a light")
rec.meta                # all scalars + caveats

# 2) the helichain (append-only ledger)
chain = Helichain("helichain")
block, created = chain.add_record(rec)   # created=False if already present
chain.blocks()                           # list every block in order
chain.verify_chain()                     # (ok, first_bad_index) — re-derives hashes
r2 = chain.load_record(block["song_id"]) # reload; geometry re-derived from state
```

### Inspect a record

```python
import numpy as np
r = chain.load_record(chain.blocks()[0]["song_id"])
print(r.compression_report())              # honest size accounting
peak = int(np.argmax(r.F_mag))             # the most dynamic moment
print(f"biggest move at {peak * r.meta['hop'] / r.meta['sr']:.1f}s")
```

---

## The helichain

- **Append-only**: songs are added as ordered blocks, never rewritten.
- **Analysed once**: adding a song already present (same content hash) is a no-op.
- **Hash-linked**: each block carries the previous block's hash, so the order is
  tamper-evident. `verify_chain()` re-derives every link.

```
helichain/
  chain.jsonl                  # one JSON block per line (the ledger)
  records/<song_id>.npz        # the helix state arrays
  records/<song_id>.json       # the metadata
```

A block is the lightweight index (id, hashes, bpm, duration, frames); the heavy
per-frame state lives in the record beside it.

---

## Known limits (read these)

1. **Tempo is a light estimate.** It uses spectral-flux onset strength +
   autocorrelation, and it commonly locks onto **half or double** the true tempo
   (the Beatport tracks here estimate ~65–70 bpm but are really ~130–140). It sets
   the rotation rate `ω = 2π·bpm/(60·B)`, so a 2× error means "two bars per turn."
   **Fix:** pass `--bpm` / `bpm=` with the real value. (A perceptual tempo prior
   centred ~120 bpm is the planned automatic fix.)
2. **Colour is many-to-one.** Hue comes from the 12-d chroma vector, and different
   timbres can produce the same chroma (shown in `exp3`). Good for a perceptual
   view; not a unique fingerprint.
3. **Compact, but not yet adaptive.** The size win (≈73× with timbre, 512× for the
   bare A/I geometry) is *fewer columns than an STFT*. `‖F‖` marks **where** to
   offload (static) vs highload (moving), but every frame is currently stored at
   the same density — variable-rate offload is not implemented yet.
4. **`engagement` is reserved.** The "most rewatched, but for music" layer
   (`record.engagement`, one value per frame) is all zeros until real
   playback/interaction capture exists. The schema is in place to fill later.
5. **Radius `r₀` is constant.** The radius law (completion = largest radius) is
   still an open part of the model.

---

## Verify the engine

```bash
python3 tests/test_engine.py          # numpy math == verified torch reference, + end-to-end
```

The tests assert the numpy chroma and curvature/torsion match the torch reference
in `beehive/` frame-for-frame, then run a synthetic song through
encode → save/load → helichain.

---

## Where things live

```
beehive/audio.py       decode a file -> mono float + content hash
beehive/features.py    framing, loudness A, interval I (energy-gated), chroma
beehive/tempo.py       spectral-flux + autocorrelation tempo estimate
beehive/encode.py      the engine: encode_song(), derive_dynamics()
beehive/record.py      HelixRecord: store state, derive geometry, save/load
beehive/helichain.py   the append-only, hash-linked ledger
scripts/encode_song.py the CLI
tests/test_engine.py   consistency + end-to-end tests
```

The model and its vocabulary live in the `beehive` skill (`SKILL.md`); the prior
synthetic prototype's findings are in `docs/findings/VERDICT.md`.
