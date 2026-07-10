//! The `.bee` manifest — the JSON block after the 9-byte header.
//!
//! Field-compatible with what `beehive/beefile.py` writes; unknown keys are
//! preserved through `extra` so a Rust rewrite of a Python-written file never
//! silently drops manifest content.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Where a section lives, relative to the start of the section blob
/// (i.e. relative to `9 + manifest_len`), matching the reference layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub offset: u64,
    pub length: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioMeta {
    pub sample_rate: u32,
    pub channels: u32,
    /// libsndfile subtype of the *source* (PCM_16, PCM_24, FLOAT, ...).
    pub subtype: String,
    pub frames: u64,
    /// numpy dtype the source decodes to losslessly (int16/int32/float32/float64).
    pub dtype: String,
    /// Byte order of a raw_zlib payload ("little"/"big"). v0 limitation carried
    /// over from the reference: cross-endian reads are refused, not converted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub byte_order: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_format: Option<String>,
    /// "flac" or "raw_zlib" — the v0 placeholder coders. The real predictive+
    /// entropy coder is blueprint §4(a), still OPEN; this slot is where it plugs in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub bee_format_version: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    pub audio: AudioMeta,
    /// Layer-2 summary (engine_version, song_id, n_frames, stored_fields,
    /// reconstructs_audio=false). Opaque here: the format core carries the
    /// side-channel, the engine interprets it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidechannel: Option<serde_json::Value>,
    pub sections: BTreeMap<String, Section>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layers: Option<String>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// Section names used by v0.
pub const SECTION_AUDIO: &str = "audio";
pub const SECTION_HELIX_ARRAYS: &str = "helix_arrays";
pub const SECTION_HELIX_META: &str = "helix_meta";
