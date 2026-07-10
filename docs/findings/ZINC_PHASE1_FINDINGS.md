# Zinc-Finger Keyframe — Phase 1 Findings

**Date: 2026-07-10.** Key generator: `beehive/zinc.py`. Reproduce:
`.venv/bin/python scripts/zinc_report.py`. Corpus: the three real library tracks
(`~/Desktop/Music`, full length, native decode). Spec:
`docs/blueprints/BEE_ZINC_KEYFRAME_BLUEPRINT.md`. This is the Python **key
generator** (authoritative); Rust will consume its output (Phase 3).

## What Phase 1 had to prove (blueprint §6.1 DoD) — and did

1. **Reconstruction error is bounded by `τ` at every frame.** `maxErr <= tau`:
   **True** on all three tracks, and tight (max error == `τ` exactly). The
   `D(t)`-vs-**last-anchor** rule (the fix over `mg.py`'s frame-to-frame drift)
   delivers the guarantee by construction.
2. **Anchors track `‖F‖`.** Anchor rate rises monotonically across `‖F‖`
   deciles (low→high force): Liverpool 6.8%→79.5%, Good Lies 25.5%→86.8%, Night
   5.4%→81.2%. Keyframes cluster in transients, thin out in calm — the
   variable-rate tandem array is real, not asserted.
3. **Unused space is never triggered** — *holds, as a function of operating
   point*. The ambient (bottom-`‖F‖`-decile) anchor rate falls toward zero as `τ`
   climbs (see table). It is **not** ~0 at the seed `τ`; it becomes so at the
   useful operating point.
4. **`τ` is a clean rate–distortion knob.** Anchors fall smoothly and
   compression rises monotonically with `τ`.

## Numbers (seed `τ` and the `τ` sweep)

| track | dur | frames | seed τ | anchors@seed | comp@seed | ambient@seed |
|---|---|---|---|---|---|---|
| Liverpool | 332 s | 14315 | 0.470 | 4637 (14.0/s) | 3.1× | 6.8% |
| Good Lies | 160 s | 6895 | 0.400 | 3701 (23.1/s) | 1.9× | 25.5% |
| Night | 371 s | 15989 | 0.417 | 6536 (17.6/s) | 2.4× | 5.4% |

`τ` sweep — anchors / state-compression / ambient-decile anchor rate:

| track | ×1 | ×2 | ×3 | ×4 |
|---|---|---|---|---|
| Liverpool | 4637 / 3.1× / 6.8% | 2229 / 6.4× / 2.9% | 1360 / 10.5× / 1.4% | 860 / 16.6× / **0.4%** |
| Good Lies | 3701 / 1.9× / 25.5% | 1688 / 4.1× / 13.0% | 845 / 8.2× / 6.7% | 367 / 18.8× / 2.9% |
| Night | 6536 / 2.4× / 5.4% | 3208 / 5.0× / 1.9% | 1683 / 9.5× / 1.3% | 991 / 16.1× / **0.8%** |

## Read-out

* **Mechanism: confirmed.** Bounded-error, force-tracking, variable-rate keying
  works exactly as the blueprint specifies. Compression here means **index
  sparsity** on the `(A, I)` navigation substrate — *not* audio file size (that
  axis is closed, §1c). At the useful operating point (~×3–4 seed) the full
  24-byte index runs **~3.3–3.8 KB/min** (Liverpool 860 keys, Night 991, Good
  Lies 367). A phase-locked topological index at a few KB/min is the axis-1a
  asset.
* **Finding — the seed `τ` over-anchors by ~3–4×.** At the seed, compression is
  only 1.9–3.1× and the ambient decile still fires 5–25%. The seed heuristic
  (`φ·std(‖dS/dt‖)·20 ms`) conflates the **20 ms trigger-latency budget** with
  the **anchor-drift budget** — they are different quantities. The real operating
  band (10–18× compression, ambient <1–3%) sits at ×3–4 seed.
* **Do not bake a magic multiplier.** `τ` is an OPEN R/D decision (blueprint §8);
  Phase 5 sets it against a stated distortion target, not by eyeballing this
  table. Good Lies is the floor case (densest track — matches its 66.8% FLAC in
  `bench/RESULTS.md`): even ×4 leaves 2.9% ambient. A per-track or content-adaptive
  `τ` is the likely Phase 5 outcome.

## Next (blueprint §6)

Phase 2 — write the anchor stream as an additive `SECTION_ZINC_INDEX` (verbatim,
like the helix npz). Phase 3 — Rust `zinc.rs` *consumer* reconstructs bit-exact
against `reconstruct_state`. Phase 4 — axis-1a latency/beat-alignment bench vs an
STFT/onset baseline (the headline claim). Phase 5 — principled `τ` sweep.
