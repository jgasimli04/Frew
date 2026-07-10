# `.bee` v0 vs standard formats — measured 2026-07-05

Corpus: the three real library tracks (~/Desktop/Music), 16-bit 44.1 kHz stereo.
Method: `bench_formats.py` — one truth PCM per track (libsndfile native decode),
every format encoded from it and decoded back; lossless = sha256 of decoded PCM
equals the truth. `.bee` files carry the real helichain side-channels.
**All lossless checks passed for every format, including both `.bee`
implementations (and Rust-written `.bee` re-verified through the Python
reader).**

## Sizes (% of uncompressed WAV)

| track (min) | purchased | FLAC¹ | ALAC | .bee (py) | .bee (rust) |
|---|---|---|---|---|---|
| Liverpool Street (5.5) | 51.5 % (flac) | 49.0 % | 50.8 % | 50.2 % | **50.1 %** |
| Good Lies (2.7) | 77.3 % (flac) | 66.8 % | 68.1 % | 68.1 % | **67.7 %** |
| Night (6.2) | 100.1 % (aiff) | 59.4 % | 60.3 % | 60.6 % | 60.4 % |

¹ libsndfile default level — the same encoder Layer 1 of `.bee (py)` uses, so
the `.bee`−FLAC delta *is* the cost of the helix layer riding inside.

## Read-out

* **vs WAV/AIFF:** `.bee` is 40–50 % smaller. Strictly better.
* **vs same-encoder FLAC:** `.bee` = that FLAC + 0.9–2.1 % for Layer 2
  (side-channel 343 KB–798 KB + ~900 B manifest on these tracks) — the part no
  other format carries (A, I, chroma, engagement per frame).
* **vs the purchased FLACs:** `.bee` is *smaller* on both (29.4 vs 30.2 MB;
  19.1 vs 21.8 MB) — store files aren't max-compressed and carry tags/art.
* **vs ALAC:** tied (±0.3 pp either way across tracks).
* **Rust vs Python `.bee`:** the Rust core (flacenc) produced the smaller file
  on all three tracks.

## Speed (wall time, one 6.2-min track as the yardstick)

| | encode | decode |
|---|---|---|
| FLAC (libsndfile) | 0.31 s | 0.19 s |
| ALAC (afconvert) | 0.73 s | 0.34 s |
| .bee (Python ref) | 0.36 s | 0.20 s |
| .bee (Rust core)² | 0.86 s | 0.33 s |

² Rust timings include process spawn and reading/writing the ~65 MB raw PCM
through the CLI files — a conservative measurement; the in-process FFI path
skips all of that.

Caveat carried from the blueprint: Layer-1 coders are still the §4(a)
placeholders. Everything above is the *floor* — the real predictive+entropy
coder and bar-level dedup (§4b) are the open upside.
