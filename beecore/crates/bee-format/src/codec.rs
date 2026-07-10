//! Layer-1 payload codecs — the v0 placeholders for blueprint §4(a) (OPEN).
//!
//! Mirrors the reference exactly:
//!   * sources whose subtype is PCM_16 / PCM_24 → FLAC (real lossless
//!     compression via an existing codec);
//!   * everything else → raw samples + zlib (bit-exact by construction).
//!
//! "Lossless" always means bit-exact on the *decoded PCM arrays* (the dtypes
//! in [`crate::pcm`]), never on container bytes: two conformant FLAC encoders
//! produce different bytes for the same (identical) decoded audio.
//!
//! libsndfile convention worth knowing when reading the shifts below: it
//! left-justifies integer samples in the wider dtype, so PCM_24 decoded as
//! int32 carries the 24-bit value in the top 3 bytes (low byte zero). FLAC
//! itself stores right-justified values; the `<< shift` / `>> shift` pairs
//! translate between the two conventions.

use std::io::Cursor;

use crate::error::{Error, Result};
use crate::manifest::AudioMeta;
use crate::pcm::{Dtype, Pcm};

pub const CODEC_FLAC: &str = "flac";
pub const CODEC_RAW_ZLIB: &str = "raw_zlib";

/// FLAC bit depth for subtypes the reference routes to FLAC; None → raw_zlib.
pub fn flac_bits_for_subtype(subtype: &str) -> Option<u32> {
    match subtype {
        "PCM_16" => Some(16),
        "PCM_24" => Some(24),
        _ => None,
    }
}

pub fn encode_payload(pcm: &Pcm, audio: &AudioMeta) -> Result<(Vec<u8>, &'static str)> {
    if let Some(bits) = flac_bits_for_subtype(&audio.subtype) {
        let samples: Vec<i32> = match (pcm, bits) {
            (Pcm::I16(v), 16) => v.iter().map(|&s| i32::from(s)).collect(),
            (Pcm::I32(v), 24) => {
                let mut out = Vec::with_capacity(v.len());
                for &s in v {
                    if s & 0xFF != 0 {
                        return Err(Error::Codec(
                            "PCM_24 sample has nonzero low byte; refusing to encode \
                             lossily (expected libsndfile-style left-justified int32)"
                                .into(),
                        ));
                    }
                    out.push(s >> 8);
                }
                out
            }
            (p, b) => {
                return Err(Error::Codec(format!(
                    "subtype {} (flac {b}-bit) does not match pcm dtype {}",
                    audio.subtype,
                    p.dtype().numpy_name()
                )))
            }
        };
        let bytes = encode_flac(
            &samples,
            audio.channels as usize,
            bits as usize,
            audio.sample_rate as usize,
        )?;
        Ok((bytes, CODEC_FLAC))
    } else {
        let raw = pcm.to_le_bytes();
        Ok((miniz_oxide::deflate::compress_to_vec_zlib(&raw, 9), CODEC_RAW_ZLIB))
    }
}

fn encode_flac(
    samples: &[i32],
    channels: usize,
    bits: usize,
    sample_rate: usize,
) -> Result<Vec<u8>> {
    use flacenc::component::BitRepr;
    use flacenc::error::Verify;

    let config = flacenc::config::Encoder::default()
        .into_verified()
        .map_err(|e| Error::Codec(format!("flac encoder config invalid: {e:?}")))?;
    let source =
        flacenc::source::MemSource::from_samples(samples, channels, bits, sample_rate);
    let stream = flacenc::encode_with_fixed_block_size(&config, source, config.block_size)
        .map_err(|e| Error::Codec(format!("flac encode failed: {e:?}")))?;
    let mut sink = flacenc::bitsink::ByteSink::new();
    stream
        .write(&mut sink)
        .map_err(|e| Error::Codec(format!("flac serialize failed: {e:?}")))?;
    Ok(sink.as_slice().to_vec())
}

pub fn decode_payload(payload: &[u8], audio: &AudioMeta) -> Result<Pcm> {
    let codec = audio
        .codec
        .as_deref()
        .ok_or_else(|| Error::Format("manifest audio.codec missing".into()))?;
    let dtype = Dtype::from_numpy(&audio.dtype)?;
    let expect = (audio.frames * u64::from(audio.channels)) as usize;

    let pcm = match codec {
        CODEC_FLAC => decode_flac(payload, dtype)?,
        CODEC_RAW_ZLIB => {
            // v0 limitation, mirrored from the reference: raw payloads are in
            // the writer's byte order; refuse a cross-endian read rather than
            // silently mis-decoding. (This crate always *writes* "little".)
            let wrote = audio.byte_order.as_deref().unwrap_or("little");
            let host = if cfg!(target_endian = "little") { "little" } else { "big" };
            if wrote != host {
                return Err(Error::Codec(format!(
                    "raw_zlib payload written on a {wrote}-endian host; \
                     cross-endian read is a v0 limitation"
                )));
            }
            let raw = miniz_oxide::inflate::decompress_to_vec_zlib(payload)
                .map_err(|e| Error::Codec(format!("zlib inflate failed: {e:?}")))?;
            Pcm::from_le_bytes(dtype, &raw)?
        }
        other => return Err(Error::Codec(format!("unknown audio codec {other:?}"))),
    };

    if pcm.len() != expect {
        return Err(Error::Codec(format!(
            "decoded {} samples, manifest says frames*channels = {expect}",
            pcm.len()
        )));
    }
    Ok(pcm)
}

fn decode_flac(payload: &[u8], dtype: Dtype) -> Result<Pcm> {
    let mut reader = claxon::FlacReader::new(Cursor::new(payload))
        .map_err(|e| Error::Codec(format!("flac open failed: {e}")))?;
    let bps = reader.streaminfo().bits_per_sample;

    match dtype {
        Dtype::I16 => {
            if bps > 16 {
                return Err(Error::Codec(format!(
                    "flac stream is {bps}-bit but manifest dtype is int16"
                )));
            }
            let shift = 16 - bps;
            let mut out = Vec::new();
            for s in reader.samples() {
                let s = s.map_err(|e| Error::Codec(format!("flac decode failed: {e}")))?;
                out.push((s << shift) as i16);
            }
            Ok(Pcm::I16(out))
        }
        Dtype::I32 => {
            let shift = 32 - bps;
            let mut out = Vec::new();
            for s in reader.samples() {
                let s = s.map_err(|e| Error::Codec(format!("flac decode failed: {e}")))?;
                out.push(s << shift);
            }
            Ok(Pcm::I32(out))
        }
        d => Err(Error::Codec(format!(
            "flac payload cannot decode to {} (integer subtypes only)",
            d.numpy_name()
        ))),
    }
}
