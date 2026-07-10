"""Real-audio front-end: decode a file to a mono float waveform.

This is the piece the prototype never had -- everything in the package until now
was synthetic (`signals.synth_harmonic_spectrum`). The encode engine starts here:
a real file (AIFF, WAV, FLAC, ...) becomes a 1-D float32 signal plus its sample
rate, and a content hash that lets the helichain analyse each song exactly once.

Decoding uses libsndfile (via `soundfile`); the codec is not the novel part, the
representation is, so we lean on a robust reader rather than reimplementing one.
"""

import hashlib

import numpy as np
import soundfile as sf


def load_audio(path, mono=True):
    """Decode an audio file to a float32 waveform.

    Parameters
    ----------
    path : str, path to an audio file readable by libsndfile (AIFF/WAV/FLAC/...).
    mono : if True, average channels down to one signal.

    Returns
    -------
    y : np.ndarray (n_samples,) float32 if mono, else (n_samples, n_channels).
    sr : int, sample rate in Hz.
    """
    y, sr = sf.read(path, dtype="float32", always_2d=True)   # (n_samples, n_ch)
    if mono:
        y = y.mean(axis=1)
    return np.ascontiguousarray(y), int(sr)


def content_hash(y, sample_range=None):
    """Stable SHA-256 of the decoded waveform, or of a sample range within it.

    Keyed to the audio *content* (the float samples), not the container bytes, so
    the same song re-encoded in a different format hashes the same -- this is what
    makes "analyse each song once" idempotent in the helichain.

    Parameters
    ----------
    y : np.ndarray, the decoded waveform.
    sample_range : optional (start, end) tuple. When given, only the half-open
        slice ``y[start:end]`` is hashed (same convention as Python/numpy
        indexing); slicing happens before the float32 cast, so a range carved out
        of a song hashes identically to that same slice standing alone. When None
        (the default) the whole waveform is hashed -- byte-for-byte unchanged from
        before, so existing whole-song hashes are preserved. Hashing one bar's
        range is what the .bee loop-dedup pivot reuses (see
        BEE_FORMAT_BLUEPRINT.md §3.2); the indices are raw sample offsets -- where
        a bar's boundaries come from (bpm/omega math) is a separate concern.
    """
    if sample_range is not None:
        start, end = sample_range
        y = y[start:end]
    return hashlib.sha256(np.ascontiguousarray(y, dtype=np.float32).tobytes()).hexdigest()
