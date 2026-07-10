"""The helichain: an append-only, hash-linked ledger of helix records.

"Each time a new song is played, a helix is analysed once ... like a blockchain,
but helichain, and kept there." So:

  * append-only      -- songs are added as ordered blocks, never rewritten;
  * analysed once    -- adding a song already in the chain (same content hash) is
                        a no-op that returns the existing block (idempotent);
  * hash-linked      -- each block carries the previous block's hash, so the
                        order is tamper-evident (verify_chain re-derives it).

On disk:  <root>/chain.jsonl         one JSON block per line (the ledger)
          <root>/records/<id>.npz    the helix arrays for each song
          <root>/records/<id>.json   its metadata

The block is the lightweight index; the heavy per-frame state lives in the
record next to it.
"""

import hashlib
import json
import os

GENESIS_HASH = "0" * 64


def _block_hash(prev_hash, content_hash, index):
    return hashlib.sha256(f"{prev_hash}{content_hash}{index}".encode()).hexdigest()


class Helichain:
    def __init__(self, root="helichain"):
        self.root = os.path.abspath(root)
        self.records_dir = os.path.join(self.root, "records")
        self.chain_path = os.path.join(self.root, "chain.jsonl")
        os.makedirs(self.records_dir, exist_ok=True)

    def blocks(self):
        """All blocks in order (empty list if the chain is new)."""
        if not os.path.exists(self.chain_path):
            return []
        with open(self.chain_path) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def _find(self, content_hash):
        for b in self.blocks():
            if b["content_hash"] == content_hash:
                return b
        return None

    def add_record(self, record):
        """Append a HelixRecord as a new block; idempotent on content hash.

        Returns (block, created) where created is False if the song was already
        in the chain (analysed once -- nothing recomputed).
        """
        chash = record.meta["content_hash"]
        existing = self._find(chash)
        if existing is not None:
            return existing, False

        blocks = self.blocks()
        index = len(blocks)
        prev_hash = blocks[-1]["block_hash"] if blocks else GENESIS_HASH

        stem = os.path.join(self.records_dir, record.meta["song_id"])
        record.save(stem)

        block = {
            "index": index,
            "song_id": record.meta["song_id"],
            "content_hash": chash,
            "record_file": os.path.relpath(f"{stem}.npz", self.root),
            "created_at": record.meta["created_at"],
            "bpm": record.meta["bpm"],
            "n_frames": record.meta["n_frames"],
            "duration_s": record.meta["duration_s"],
            "prev_hash": prev_hash,
            "block_hash": _block_hash(prev_hash, chash, index),
        }
        with open(self.chain_path, "a") as fh:
            fh.write(json.dumps(block) + "\n")
        return block, True

    def load_record(self, song_id):
        from .record import HelixRecord
        return HelixRecord.load(os.path.join(self.records_dir, song_id))

    def verify_chain(self):
        """Re-derive the hash links; return (ok, first_bad_index_or_None)."""
        prev = GENESIS_HASH
        for b in self.blocks():
            expected = _block_hash(prev, b["content_hash"], b["index"])
            if b["prev_hash"] != prev or b["block_hash"] != expected:
                return False, b["index"]
            prev = b["block_hash"]
        return True, None
