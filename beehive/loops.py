"""Loop layer: cut a song into bars (the helix's 2π turns) and dedup repeats.

This is where the helix geometry becomes *load-bearing* for storage rather than
inert metadata. The bar length falls straight out of the tempo math the encoder
already computed — one bar = one full 2π turn = `B · 60/bpm` seconds — so the
side-channel's `ω`/bpm decides where the audio is cut. Identical bars are stored
once (a loop pool); a song becomes a sequence of recall entries that walk the
structure (BEE_FORMAT_BLUEPRINT.md §3.2/§3.3).

Dedup here is **exact** (byte-identical bars), per blueprint §4(b)'s sanctioned
starting point: it is correct and lossless by construction. Whether it actually
*pays* on real audio is an empirical question this module is built to answer with
numbers (`dedup_report`), not assume — see §6 step 4. Near-duplicate matching
(the general, lossy-or-residual case) is §4(b) OPEN and deliberately NOT decided
here.

Bars use a **fixed** integer sample length so two equal-content bars hash equal
(a ±1-sample varying length would defeat hashing). The final partial bar (the
remainder) is carried verbatim and never deduped. Reconstruction concatenates the
bars back to the exact original samples.
"""

import hashlib

import numpy as np


def bar_length_samples(meta):
    """Fixed samples-per-bar from the tempo math: round(B · 60/bpm · sr)."""
    bpm, B, sr = float(meta["bpm"]), float(meta["B"]), int(meta["sr"])
    if bpm <= 0:
        raise ValueError("bpm must be > 0 to define a bar")
    return int(round(B * 60.0 / bpm * sr))


def segment_bars(n_samples, spb):
    """Half-open [start, end) bar boundaries tiling [0, n_samples) with no gap/overlap.
    The last bar is shorter when n_samples isn't a whole multiple of spb."""
    if spb <= 0:
        raise ValueError("samples-per-bar must be positive")
    starts = range(0, n_samples, spb)
    return [(s, min(s + spb, n_samples)) for s in starts]


def _bar_hash(pcm, start, end):
    """SHA-256 of a bar's *native* sample bytes (not the float32 analysis cast,
    which is lossy for int24/int32) — the exact dedup key for the payload."""
    block = np.ascontiguousarray(pcm[start:end])
    return hashlib.sha256(block.tobytes()).hexdigest()


def dedup_song(pcm, spb):
    """Cut `pcm` (frames[, channels]) into fixed-length bars and exact-dedup them.

    Returns (pool, recall, segs):
      pool   : list of unique bar payloads (np arrays), each appearing once;
      recall : list of dicts, one per bar, {"loop": pool_index, "len": n_samples,
               "first": bool} — the recall-entry sequence that walks the song;
      segs   : the [start, end) boundaries used.
    Only full-length bars (== spb) participate in dedup; the remainder tail is its
    own pool entry. Reconstruction is `reconstruct(pool, recall)`.
    """
    segs = segment_bars(pcm.shape[0], spb)
    pool, index_of, recall = [], {}, []
    for (start, end) in segs:
        length = end - start
        full = (length == spb)
        key = _bar_hash(pcm, start, end) if full else None
        if full and key in index_of:
            recall.append({"loop": index_of[key], "len": length, "first": False})
        else:
            idx = len(pool)
            pool.append(np.ascontiguousarray(pcm[start:end]))
            if full:
                index_of[key] = idx
            recall.append({"loop": idx, "len": length, "first": True})
    return pool, recall, segs


def reconstruct(pool, recall):
    """Walk the recall sequence, pulling each bar from the pool -> exact PCM."""
    return np.concatenate([pool[entry["loop"]] for entry in recall], axis=0)


def dedup_report(pcm, spb, dtype_itemsize=None):
    """Measure exact bar-dedup: counts and bytes saved. Numbers, not vibes."""
    pool, recall, segs = dedup_song(pcm, spb)
    total = len(recall)
    dup = sum(1 for e in recall if not e["first"])
    itemsize = dtype_itemsize if dtype_itemsize is not None else pcm.dtype.itemsize
    ch = pcm.shape[1] if pcm.ndim > 1 else 1
    bytes_full = pcm.shape[0] * ch * itemsize
    bytes_pool = sum(b.shape[0] for b in pool) * ch * itemsize
    return {
        "total_bars": total,
        "unique_bars": len(pool),
        "duplicate_bars": dup,
        "dedup_ratio": (dup / total) if total else 0.0,
        "samples_per_bar": spb,
        "bytes_full": bytes_full,
        "bytes_deduped_pool": bytes_pool,
        "payload_saving": 1.0 - (bytes_pool / bytes_full) if bytes_full else 0.0,
    }
