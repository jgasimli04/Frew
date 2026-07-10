//! The `.bee` v0 container: header, manifest, section blob.
//!
//! On-disk layout (all multi-byte integers little-endian), identical to the
//! reference `beehive/beefile.py`:
//!
//! ```text
//! offset 0   magic         b"BEE\0"      (4 bytes)
//! offset 4   format_ver    u8            (1 byte)
//! offset 5   manifest_len  u32           (4 bytes)
//! offset 9   manifest      JSON (UTF-8)  (manifest_len bytes)
//! offset 9+manifest_len    section blob  (rest of file)
//! ```
//!
//! Section offsets in the manifest are relative to the start of the blob.

use std::collections::BTreeMap;
use std::path::Path;

use crate::codec;
use crate::error::{Error, Result};
use crate::manifest::{
    AudioMeta, Manifest, Section, SECTION_AUDIO, SECTION_HELIX_ARRAYS, SECTION_HELIX_META,
};
use crate::npz::{self, NpyArray};
use crate::pcm::{Dtype, Pcm};

pub const MAGIC: [u8; 4] = *b"BEE\0";
pub const FORMAT_VERSION: u8 = 0;
pub const HEADER_LEN: usize = 9;

/// A fully read `.bee`: manifest, decoded PCM, and the raw Layer-2 sections.
#[derive(Debug, Clone)]
pub struct BeeFile {
    pub manifest: Manifest,
    /// Bit-exact decoded PCM, interleaved `(frames, channels)` C-order.
    pub pcm: Pcm,
    /// Layer 2 arrays, verbatim npz bytes (numpy savez_compressed format).
    pub helix_npz: Vec<u8>,
    /// Layer 2 meta, verbatim JSON bytes.
    pub helix_meta_json: Vec<u8>,
}

/// Layer 2 unpacked: the stored per-frame state (nothing here reconstructs
/// audio — exp3: chroma is many-to-one in timbre; geometry is re-derived by
/// the engine from these plus the meta).
#[derive(Debug, Clone)]
pub struct Sidechannel {
    pub n_frames: usize,
    pub a: Vec<f32>,
    pub i: Vec<f32>,
    /// Row-major `(n_frames, chroma_bins)`.
    pub chroma: Vec<f32>,
    pub chroma_bins: usize,
    pub engagement: Vec<f32>,
    pub meta: serde_json::Value,
}

fn parse_header(bytes: &[u8]) -> Result<usize> {
    if bytes.len() < HEADER_LEN {
        return Err(Error::Format("file shorter than the .bee header".into()));
    }
    if bytes[..4] != MAGIC {
        return Err(Error::Format(format!("not a .bee file (bad magic {:?})", &bytes[..4])));
    }
    if bytes[4] != FORMAT_VERSION {
        return Err(Error::Format(format!(
            "unsupported .bee format version {} (expected {FORMAT_VERSION})",
            bytes[4]
        )));
    }
    Ok(u32::from_le_bytes([bytes[5], bytes[6], bytes[7], bytes[8]]) as usize)
}

/// Parse header + manifest; returns the manifest and the blob start offset.
pub fn parse_manifest(bytes: &[u8]) -> Result<(Manifest, usize)> {
    let manifest_len = parse_header(bytes)?;
    let end = HEADER_LEN
        .checked_add(manifest_len)
        .filter(|&e| e <= bytes.len())
        .ok_or_else(|| Error::Format("manifest extends past end of file".into()))?;
    let manifest: Manifest = serde_json::from_slice(&bytes[HEADER_LEN..end])?;
    Ok((manifest, end))
}

fn section<'a>(
    bytes: &'a [u8],
    blob_start: usize,
    sections: &BTreeMap<String, Section>,
    name: &str,
) -> Result<&'a [u8]> {
    let s = sections
        .get(name)
        .ok_or_else(|| Error::Format(format!("manifest has no {name:?} section")))?;
    let start = blob_start
        .checked_add(s.offset as usize)
        .ok_or_else(|| Error::Format(format!("section {name:?} offset overflow")))?;
    bytes
        .get(start..start + s.length as usize)
        .ok_or_else(|| Error::Format(format!("section {name:?} extends past end of file")))
}

/// Read a `.bee` from memory, decoding the audio payload.
pub fn read_bee_bytes(bytes: &[u8]) -> Result<BeeFile> {
    let (manifest, blob_start) = parse_manifest(bytes)?;
    let audio = section(bytes, blob_start, &manifest.sections, SECTION_AUDIO)?;
    let helix_npz = section(bytes, blob_start, &manifest.sections, SECTION_HELIX_ARRAYS)?;
    let helix_meta = section(bytes, blob_start, &manifest.sections, SECTION_HELIX_META)?;
    let pcm = codec::decode_payload(audio, &manifest.audio)?;
    Ok(BeeFile {
        manifest,
        pcm,
        helix_npz: helix_npz.to_vec(),
        helix_meta_json: helix_meta.to_vec(),
    })
}

pub fn read_bee(path: impl AsRef<Path>) -> Result<BeeFile> {
    read_bee_bytes(&std::fs::read(path)?)
}

/// Manifest only, without decoding the payload (mirror of `bee_info`).
pub fn bee_info(path: impl AsRef<Path>) -> Result<Manifest> {
    let bytes = std::fs::read(path)?;
    Ok(parse_manifest(&bytes)?.0)
}

impl BeeFile {
    pub fn dtype(&self) -> Result<Dtype> {
        Dtype::from_numpy(&self.manifest.audio.dtype)
    }

    pub fn sidechannel(&self) -> Result<Sidechannel> {
        let entries = npz::read_npz(&self.helix_npz)?;
        let get = |name: &str| -> Result<&NpyArray> {
            entries
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, a)| a)
                .ok_or_else(|| Error::Format(format!("side-channel npz missing {name:?}")))
        };
        let a = get("A")?.as_f32()?;
        let i = get("I")?.as_f32()?;
        let chroma_arr = get("chroma")?;
        let chroma = chroma_arr.as_f32()?;
        let chroma_bins = match chroma_arr.shape.as_slice() {
            [n, b] if *n == a.len() => *b,
            other => {
                return Err(Error::Format(format!(
                    "chroma shape {other:?} does not match n_frames {}",
                    a.len()
                )))
            }
        };
        let engagement = get("engagement")?.as_f32()?;
        if i.len() != a.len() || engagement.len() != a.len() {
            return Err(Error::Format(format!(
                "side-channel arrays disagree on n_frames (A={}, I={}, engagement={})",
                a.len(),
                i.len(),
                engagement.len()
            )));
        }
        let meta = serde_json::from_slice(&self.helix_meta_json)?;
        Ok(Sidechannel { n_frames: a.len(), a, i, chroma, chroma_bins, engagement, meta })
    }
}

/// Everything needed to write a `.bee`. The side-channel comes in as verbatim
/// bytes (npz + meta JSON) — the format core carries Layer 2, it does not
/// interpret or re-derive it (that is the engine's job).
pub struct WriteParams<'a> {
    pub pcm: &'a Pcm,
    /// `codec`, `byte_order`, `note` are filled in by the writer.
    pub audio: AudioMeta,
    pub helix_npz: &'a [u8],
    pub helix_meta_json: &'a [u8],
    /// Optional ISO-8601 timestamp; defaults to now (UTC).
    pub created_at: Option<String>,
}

/// Serialize a `.bee` to memory. Returns (bytes, manifest-as-written).
pub fn write_bee_bytes(p: &WriteParams<'_>) -> Result<(Vec<u8>, Manifest)> {
    let expect = (p.audio.frames * u64::from(p.audio.channels)) as usize;
    if p.pcm.len() != expect {
        return Err(Error::Format(format!(
            "pcm has {} samples but audio meta says frames*channels = {expect}",
            p.pcm.len()
        )));
    }
    let dtype = Dtype::from_numpy(&p.audio.dtype)?;
    if dtype != p.pcm.dtype() {
        return Err(Error::Format(format!(
            "audio meta dtype {} does not match pcm dtype {}",
            p.audio.dtype,
            p.pcm.dtype().numpy_name()
        )));
    }

    let mut audio = p.audio.clone();
    let (payload, codec_name) = codec::encode_payload(p.pcm, &audio)?;
    audio.codec = Some(codec_name.to_string());
    audio.byte_order = Some(if cfg!(target_endian = "little") { "little" } else { "big" }.into());
    if audio.note.is_none() {
        audio.note = Some(
            "lossless = bit-exact on the decoded PCM; v0 placeholder coder \
             (real predictive+entropy coding is OPEN, blueprint §4a)"
                .into(),
        );
    }

    // Layer-2 summary for the manifest: stored_fields read from the actual npz
    // (truthful, not hardcoded), scalars echoed from the meta JSON if present.
    let helix_meta: serde_json::Value =
        serde_json::from_slice(p.helix_meta_json).unwrap_or(serde_json::Value::Null);
    let stored_fields: Vec<String> =
        npz::read_npz(p.helix_npz)?.into_iter().map(|(k, _)| k).collect();
    let sidechannel = serde_json::json!({
        "engine_version": helix_meta.get("engine_version").cloned().unwrap_or(serde_json::Value::Null),
        "song_id": helix_meta.get("song_id").cloned().unwrap_or(serde_json::Value::Null),
        "n_frames": helix_meta.get("n_frames").cloned().unwrap_or(serde_json::Value::Null),
        "stored_fields": stored_fields,
        "reconstructs_audio": false, // exp3: chroma is many-to-one in timbre
    });

    let mut sections = BTreeMap::new();
    let mut blob = Vec::with_capacity(payload.len() + p.helix_npz.len() + p.helix_meta_json.len());
    for (name, chunk) in [
        (SECTION_AUDIO, payload.as_slice()),
        (SECTION_HELIX_ARRAYS, p.helix_npz),
        (SECTION_HELIX_META, p.helix_meta_json),
    ] {
        sections.insert(
            name.to_string(),
            Section { offset: blob.len() as u64, length: chunk.len() as u64 },
        );
        blob.extend_from_slice(chunk);
    }

    let manifest = Manifest {
        bee_format_version: FORMAT_VERSION,
        created_at: Some(p.created_at.clone().unwrap_or_else(now_iso_utc)),
        audio,
        sidechannel: Some(sidechannel),
        sections,
        layers: Some(
            "L1 audio payload reconstructs PCM; L2 helix side-channel = \
             navigation/indexing only, not audio reconstruction (blueprint §3)"
                .into(),
        ),
        extra: serde_json::Map::new(),
    };
    let manifest_bytes = serde_json::to_vec(&manifest)?;

    let mut out = Vec::with_capacity(HEADER_LEN + manifest_bytes.len() + blob.len());
    out.extend_from_slice(&MAGIC);
    out.push(FORMAT_VERSION);
    out.extend_from_slice(&(manifest_bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(&manifest_bytes);
    out.extend_from_slice(&blob);
    Ok((out, manifest))
}

pub fn write_bee(path: impl AsRef<Path>, p: &WriteParams<'_>) -> Result<Manifest> {
    let (bytes, manifest) = write_bee_bytes(p)?;
    std::fs::write(path, bytes)?;
    Ok(manifest)
}

/// ISO-8601 UTC timestamp without external date dependencies
/// (civil-from-days per Howard Hinnant's algorithm).
fn now_iso_utc() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);

    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mth = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mth <= 2 { y + 1 } else { y };
    format!("{y:04}-{mth:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}
