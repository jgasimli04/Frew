"""HelixRecord: the persistent, on-standby encoding of one song.

This is the artifact the project is really after -- a song "analysed once" and
kept, so it can later be run against (taste profile) and have a listener
engagement layer accumulated over it. It stores only the *compact per-frame
state* and the geometry derived from it, never the dense STFT it is meant to
replace.

Layout per record (n = n_frames):
  state      A, I            -- amplitude (dB), interval (semitones)
  force      dA, dI, F_mag   -- the force vector and its magnitude ||F|| (energy spent)
  geometry   h, alpha, x,y,z -- climb, angle, helix position; plus kappa, tau
  colour     chroma(n,12), hue, sat, val   -- notes as lights, dictated by timbre
  engagement engagement(n)   -- RESERVED: the "most rewatched, but for music" layer
                               (zeros until real playback capture exists)

On disk a record is two files: <stem>.npz (arrays) and <stem>.json (metadata).
"""

import json
from dataclasses import dataclass, field

import numpy as np

# Only the *independent* state is stored on disk; everything else is a function
# of these plus the scalar meta and is recomputed by encode.derive_dynamics on
# load. (A dense STFT is what we refuse to keep -- this is the whole compactness
# claim.)  A=loudness, I=interval, chroma=timbre, engagement=listener layer.
STORED_FIELDS = ["A", "I", "chroma", "engagement"]


@dataclass
class HelixRecord:
    meta: dict
    t: np.ndarray
    A: np.ndarray
    I: np.ndarray
    dA: np.ndarray
    dI: np.ndarray
    F_mag: np.ndarray
    h: np.ndarray
    alpha: np.ndarray
    x: np.ndarray
    y: np.ndarray
    z: np.ndarray
    kappa: np.ndarray
    tau: np.ndarray
    chroma: np.ndarray
    hue: np.ndarray
    sat: np.ndarray
    val: np.ndarray
    engagement: np.ndarray = field(default=None)

    @property
    def n_frames(self):
        return int(self.A.shape[0])

    def save(self, stem):
        """Write <stem>.npz (the stored state only) and <stem>.json (metadata)."""
        arrays = {k: np.asarray(getattr(self, k), dtype=np.float32) for k in STORED_FIELDS}
        np.savez_compressed(f"{stem}.npz", **arrays)
        with open(f"{stem}.json", "w", encoding="utf-8") as fh:
            json.dump(self.meta, fh, indent=2)
        return f"{stem}.npz"

    @classmethod
    def load(cls, stem):
        from .encode import derive_dynamics    # local import avoids a cycle

        stem = stem[:-4] if stem.endswith(".npz") else stem
        with np.load(f"{stem}.npz") as data:
            stored = {k: data[k] for k in STORED_FIELDS}
        with open(f"{stem}.json", encoding="utf-8") as fh:
            meta = json.load(fh)
        der = derive_dynamics(stored["A"], stored["I"], stored["chroma"], meta)
        return cls(meta=meta, **stored, **der)

    def compression_report(self):
        """Logical bytes of this representation vs. the dense STFT it replaces.

        Honest accounting (uncompressed float32):
          state  = 2 floats/frame (A, I) -- the helix geometry substrate;
          stored = 14 floats/frame (A, I, chroma[12]) -- what the .npz holds
                   (engagement is reserved zeros and compresses away);
          stft   = n_bins floats/frame -- the dense magnitude spectrogram.

        This counts columns, not adaptive offload: ||F|| says *where* the music
        moves, but every frame is currently stored at the same density. For the
        on-disk (compressed) size, stat the .npz directly.
        """
        n = self.n_frames
        n_bins = int(self.meta["n_fft"] // 2 + 1)
        state = 2 * n * 4                     # A, I
        stored = (2 + 12) * n * 4            # A, I, chroma  (engagement ~ free)
        stft = n_bins * n * 4
        return {
            "n_frames": n,
            "n_bins": n_bins,
            "state_bytes": state,
            "stored_bytes": stored,
            "stft_bytes": stft,
            "ratio_state_vs_stft": stft / max(state, 1),
            "ratio_stored_vs_stft": stft / max(stored, 1),
        }
