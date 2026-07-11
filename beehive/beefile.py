"""`.bee` v0 container — the two-layer file format (blueprint §3, build §6 step 5).

A `.bee` file is **two layers stored together** (BEE_FORMAT_BLUEPRINT.md §3):

  Layer 1 — the audio payload: a *lossless* encoding of the source PCM. This is
            the thing that actually reconstructs audio, bit-for-bit. v0 uses an
            existing lossless codec (FLAC for 16/24-bit integer PCM, else raw
            samples + zlib). This is the deliberate placeholder for §4(a), which
            is OPEN: the real predictive + entropy coder is NOT built here.
  Layer 2 — the helix/chroma side-channel: the HelixRecord's stored state
            (A, I, chroma, engagement) plus its meta. This does NOT reconstruct
            audio (exp3/VERDICT.md: chroma is many-to-one in timbre); it rides
            alongside as a navigation / compression-control / indexing channel.

Lossless contract (important): "lossless" here means **bit-exact on the decoded
PCM** — the sample array libsndfile returns. The source is read preserving its
*native* channel count and sample subtype (NOT via `audio.load_audio`, which
mono-averages to float32 and is analysis-only / lossy). If a source is itself
lossy (e.g. mp3), lossless means lossless of the *decoded* samples.

On-disk layout (all multi-byte integers little-endian):

    offset 0   magic         b"BEE\\0"                    (4 bytes)
    offset 4   format_ver    u8                           (1 byte)
    offset 5   manifest_len  u32                          (4 bytes)
    offset 9   manifest      JSON (UTF-8)                 (manifest_len bytes)
    offset 9+manifest_len    section blob                 (rest of file)

The manifest's `sections` map gives each section's (offset, length) **relative to
the start of the section blob** (i.e. relative to offset 9 + manifest_len), which
avoids a circular dependency between the manifest size and the offsets it carries.

Not built here (gated — see blueprint §4 / §7): the real predictive+entropy
coder (§4a OPEN), near-duplicate dedup (§4b OPEN), bar-level loop-pool dedup
(§6 steps 2-4), any helix-layer synthesis, and any Rust/Swift work (§4c gate).
v0 stores the audio payload whole, not yet cut into per-bar loops.
"""

import datetime as _dt
import io
import json
import struct
import sys
import zlib

import numpy as np
import soundfile as sf

from .encode import derive_dynamics
from .record import STORED_FIELDS, HelixRecord
from .zinc import ANCHOR_BYTES, ZINC_VERSION, deserialize_anchors, serialize_anchors

MAGIC = b"BEE\x00"
FORMAT_VERSION = 0
_HEADER = struct.Struct("<4sBI")   # magic, format_ver, manifest_len

# --- lossless read: source subtype -> the numpy dtype that decodes it exactly ---
# libsndfile decodes each subtype losslessly into one of these widths. 24-bit is
# read as int32 (left-justified) and written back as PCM_24 consistently, so the
# round-trip is bit-exact at the array level (verified in tests/test_beefile.py).
_SUBTYPE_READ_DTYPE = {
    "PCM_S8": "int16", "PCM_U8": "int16", "PCM_16": "int16",
    "PCM_24": "int32", "PCM_32": "int32",
    "FLOAT": "float32", "DOUBLE": "float64",
}
# Anything else (ULAW/ALAW/ADPCM/MPEG/...) is lossy-or-exotic: read at full width
# and store the decoded samples raw+zlib. Lossless then means lossless of the
# *decoded* PCM (stated in the module docstring).
_DEFAULT_READ_DTYPE = "float64"

# Subtypes for which FLAC gives real lossless compression (the rest fall back to
# raw+zlib). FLAC supports up to 24-bit integer PCM (see sf.available_subtypes).
_FLAC_SUBTYPES = {"PCM_16", "PCM_24"}

# For decode_bee_to_wav: a WAV-valid subtype per stored dtype, used when the
# original subtype is not itself WAV-writable (e.g. a FLAC/exotic source).
_WAV_SUBTYPE_FOR_DTYPE = {
    "int16": "PCM_16", "int32": "PCM_32",
    "float32": "FLOAT", "float64": "DOUBLE",
}


def _read_dtype_for(subtype):
    return _SUBTYPE_READ_DTYPE.get(subtype, _DEFAULT_READ_DTYPE)


def _read_source_pcm(audio_path):
    """Decode the source losslessly, preserving native channels + subtype.

    Returns (data, info_dict). `data` is always 2-D (frames, channels) in the
    exact dtype that decodes the source's subtype without loss. Deliberately does
    NOT use audio.load_audio (which is mono/float32 — analysis-only, lossy).
    """
    info = sf.info(audio_path)
    dtype = _read_dtype_for(info.subtype)
    data, sr = sf.read(audio_path, dtype=dtype, always_2d=True)
    data = np.ascontiguousarray(data)
    return data, {
        "sample_rate": int(sr),
        "channels": int(data.shape[1]),
        "subtype": info.subtype,
        "frames": int(data.shape[0]),
        "dtype": str(data.dtype),
        # TODO(v0->v1): the raw_zlib payload stores samples in the writer's native
        # byte order; recorded here so a reader can detect a mismatch. All current
        # targets are little-endian, so this does not affect v0, but a portable
        # cross-platform format should normalise to little-endian on write.
        "byte_order": sys.byteorder,
        "source_format": info.format,
    }


def _encode_audio_payload(data, audio_meta):
    """Layer 1: encode the decoded PCM losslessly. Returns (payload_bytes, codec)."""
    subtype = audio_meta["subtype"]
    if subtype in _FLAC_SUBTYPES:
        buf = io.BytesIO()
        sf.write(buf, data, audio_meta["sample_rate"], subtype=subtype, format="FLAC")
        return buf.getvalue(), "flac"
    # raw samples (C-order, native endianness of the array) + zlib — the §4(a)
    # raw-PCM baseline; trivially bit-exact by construction.
    return zlib.compress(data.tobytes(), 9), "raw_zlib"


def _decode_audio_payload(payload, audio_meta, codec):
    """Inverse of _encode_audio_payload -> (frames, channels) array, exact dtype."""
    dtype = np.dtype(audio_meta["dtype"])
    if codec == "flac":
        data, _ = sf.read(io.BytesIO(payload), dtype=dtype.name, always_2d=True)
        return np.ascontiguousarray(data)
    if codec == "raw_zlib":
        if audio_meta.get("byte_order", sys.byteorder) != sys.byteorder:
            raise NotImplementedError(
                "raw_zlib payload was written on a "
                f"{audio_meta['byte_order']}-endian host; cross-endian read is a "
                "v0 limitation (see _read_source_pcm TODO)")
        raw = zlib.decompress(payload)
        return np.frombuffer(raw, dtype=dtype).reshape(
            audio_meta["frames"], audio_meta["channels"]
        ).copy()
    raise ValueError(f"unknown audio codec {codec!r}")


def _serialize_sidechannel(record):
    """Layer 2: the HelixRecord's stored arrays (npz bytes) and meta (JSON bytes).

    Reuses record.STORED_FIELDS so the stored-field list stays single-sourced; the
    geometry is NOT stored (it is re-derived on read via derive_dynamics), exactly
    as HelixRecord.save/load do on disk.
    """
    buf = io.BytesIO()
    arrays = {k: np.asarray(getattr(record, k), dtype=np.float32) for k in STORED_FIELDS}
    np.savez_compressed(buf, **arrays)
    return buf.getvalue(), json.dumps(record.meta).encode("utf-8")


def _deserialize_sidechannel(arrays_bytes, meta_bytes):
    """Rebuild a HelixRecord from the side-channel bytes (mirror of HelixRecord.load)."""
    meta = json.loads(meta_bytes.decode("utf-8"))
    with np.load(io.BytesIO(arrays_bytes), allow_pickle=False) as data:
        stored = {k: data[k] for k in STORED_FIELDS}
    der = derive_dynamics(stored["A"], stored["I"], stored["chroma"], meta)
    return HelixRecord(meta=meta, **stored, **der)


def write_bee(path, *, audio_path, record, anchors=None, zinc_policy=None):
    """Pack a `.bee`: header + lossless audio payload (Layer 1) + helix side-channel
    (Layer 2). `audio_path` is the source whose PCM is preserved bit-exactly;
    `record` is its HelixRecord. Returns the manifest dict that was written.

    `anchors` (optional): the Python-authored zinc keys, written verbatim as the
    additive `zinc_index` section (ZINC_KEYFRAME_BLUEPRINT §5 — Python authors,
    Rust consumes; old readers ignore the extra section). `zinc_policy` is the
    ZincPolicy that placed them, recorded in the manifest as reference metadata.
    """
    data, audio_meta = _read_source_pcm(audio_path)
    payload, codec = _encode_audio_payload(data, audio_meta)
    audio_meta["codec"] = codec
    audio_meta["note"] = ("lossless = bit-exact on the decoded PCM; v0 placeholder "
                          "coder (real predictive+entropy coding is OPEN, blueprint §4a)")

    arrays_bytes, meta_bytes = _serialize_sidechannel(record)

    # lay the sections out back-to-back; offsets are relative to blob start
    chunks = [("audio", payload),
              ("helix_arrays", arrays_bytes),
              ("helix_meta", meta_bytes)]
    if anchors is not None:
        chunks.append(("zinc_index", serialize_anchors(anchors)))
    sections, blob, cursor = {}, bytearray(), 0
    for name, chunk in chunks:
        sections[name] = {"offset": cursor, "length": len(chunk)}
        blob += chunk
        cursor += len(chunk)

    manifest = {
        "bee_format_version": FORMAT_VERSION,
        "created_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "audio": audio_meta,
        "sidechannel": {
            "engine_version": record.meta.get("engine_version"),
            "song_id": record.meta.get("song_id"),
            "n_frames": record.n_frames,
            "stored_fields": list(STORED_FIELDS),
            "reconstructs_audio": False,  # exp3: chroma is many-to-one in timbre
        },
        "sections": sections,
        "layers": "L1 audio payload reconstructs PCM; L2 helix side-channel = "
                  "navigation/indexing only, not audio reconstruction (blueprint §3)",
    }
    if anchors is not None:
        manifest["zinc"] = {
            "version": zinc_policy.version if zinc_policy is not None else ZINC_VERSION,
            "n_keys": len(anchors),
            "key_bytes": ANCHOR_BYTES,
            "layout": "<u32 frame, f32 r, theta, z, a, i> little-endian, no header",
            # reference metadata only -- the stored keys are authoritative
            "policy": None if zinc_policy is None else {
                "tau_event": zinc_policy.tau_event,
                "tau_max": zinc_policy.tau_max,
                "lam": zinc_policy.lam,
            },
        }
    manifest_bytes = json.dumps(manifest).encode("utf-8")

    with open(path, "wb") as f:
        f.write(_HEADER.pack(MAGIC, FORMAT_VERSION, len(manifest_bytes)))
        f.write(manifest_bytes)
        f.write(blob)
    return manifest


def _read_container(path):
    """Parse header + manifest + slice out the raw section bytes. -> (manifest, sections)."""
    with open(path, "rb") as f:
        magic, ver, manifest_len = _HEADER.unpack(f.read(_HEADER.size))
        if magic != MAGIC:
            raise ValueError(f"not a .bee file (bad magic {magic!r})")
        if ver != FORMAT_VERSION:
            raise ValueError(f"unsupported .bee format version {ver} (expected {FORMAT_VERSION})")
        manifest = json.loads(f.read(manifest_len).decode("utf-8"))
        blob = f.read()
    raw = {}
    for name, where in manifest["sections"].items():
        start = where["offset"]
        raw[name] = blob[start:start + where["length"]]
    return manifest, raw


def read_bee(path):
    """Read a `.bee` -> (HelixRecord, pcm). `pcm` is the bit-exact decoded sample
    array, shape (frames, channels), in the source's native dtype."""
    manifest, raw = _read_container(path)
    record = _deserialize_sidechannel(raw["helix_arrays"], raw["helix_meta"])
    pcm = _decode_audio_payload(raw["audio"], manifest["audio"], manifest["audio"]["codec"])
    return record, pcm


def read_zinc_index(path):
    """The Python-authored zinc keys of a `.bee`, or None if the file predates
    the `zinc_index` section (additive — old files stay valid)."""
    _, raw = _read_container(path)
    blob = raw.get("zinc_index")
    return None if blob is None else deserialize_anchors(blob)


def decode_bee_to_wav(path, wav_out):
    """Reconstruct the audio payload of a `.bee` to a WAV file (lossless). Returns wav_out."""
    manifest, raw = _read_container(path)
    am = manifest["audio"]
    pcm = _decode_audio_payload(raw["audio"], am, am["codec"])
    # prefer the original subtype if WAV can write it; else a lossless WAV subtype
    # matching the stored dtype (so exotic/FLAC sources still write a valid WAV).
    wav_subtypes = sf.available_subtypes("WAV")
    subtype = am["subtype"] if am["subtype"] in wav_subtypes else _WAV_SUBTYPE_FOR_DTYPE[am["dtype"]]
    sf.write(wav_out, pcm, am["sample_rate"], subtype=subtype)
    return wav_out


def bee_info(path):
    """Return the manifest dict without decoding the payload (for inspection/CLI)."""
    manifest, _ = _read_container(path)
    return manifest
