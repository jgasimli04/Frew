//! Decoded PCM buffers in the exact dtypes the Python reference uses.
//!
//! The reference (`beehive/beefile.py`) decodes every source into one of four
//! numpy dtypes — int16, int32, float32, float64 — chosen per libsndfile
//! subtype so the decode is lossless. The lossless contract of `.bee` is
//! bit-exactness on *these arrays*, so this enum mirrors them one-to-one.
//! Layout is always interleaved C-order `(frames, channels)`.

use crate::error::{Error, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dtype {
    I16,
    I32,
    F32,
    F64,
}

impl Dtype {
    /// numpy dtype name as it appears in the manifest (`audio.dtype`).
    pub fn from_numpy(name: &str) -> Result<Self> {
        match name {
            "int16" => Ok(Dtype::I16),
            "int32" => Ok(Dtype::I32),
            "float32" => Ok(Dtype::F32),
            "float64" => Ok(Dtype::F64),
            other => Err(Error::Format(format!("unsupported audio dtype {other:?}"))),
        }
    }

    pub fn numpy_name(self) -> &'static str {
        match self {
            Dtype::I16 => "int16",
            Dtype::I32 => "int32",
            Dtype::F32 => "float32",
            Dtype::F64 => "float64",
        }
    }

    pub fn itemsize(self) -> usize {
        match self {
            Dtype::I16 => 2,
            Dtype::I32 | Dtype::F32 => 4,
            Dtype::F64 => 8,
        }
    }
}

/// Interleaved PCM samples, `frames * channels` long, C-order.
#[derive(Debug, Clone, PartialEq)]
pub enum Pcm {
    I16(Vec<i16>),
    I32(Vec<i32>),
    F32(Vec<f32>),
    F64(Vec<f64>),
}

impl Pcm {
    pub fn dtype(&self) -> Dtype {
        match self {
            Pcm::I16(_) => Dtype::I16,
            Pcm::I32(_) => Dtype::I32,
            Pcm::F32(_) => Dtype::F32,
            Pcm::F64(_) => Dtype::F64,
        }
    }

    /// Total sample count (frames * channels).
    pub fn len(&self) -> usize {
        match self {
            Pcm::I16(v) => v.len(),
            Pcm::I32(v) => v.len(),
            Pcm::F32(v) => v.len(),
            Pcm::F64(v) => v.len(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn byte_len(&self) -> usize {
        self.len() * self.dtype().itemsize()
    }

    /// Serialize to little-endian bytes (the v0 raw payload representation;
    /// the manifest records `byte_order: "little"`).
    pub fn to_le_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.byte_len());
        match self {
            Pcm::I16(v) => {
                for &s in v {
                    out.extend_from_slice(&s.to_le_bytes());
                }
            }
            Pcm::I32(v) => {
                for &s in v {
                    out.extend_from_slice(&s.to_le_bytes());
                }
            }
            Pcm::F32(v) => {
                for &s in v {
                    out.extend_from_slice(&s.to_le_bytes());
                }
            }
            Pcm::F64(v) => {
                for &s in v {
                    out.extend_from_slice(&s.to_le_bytes());
                }
            }
        }
        out
    }

    pub fn from_le_bytes(dtype: Dtype, bytes: &[u8]) -> Result<Pcm> {
        if !bytes.len().is_multiple_of(dtype.itemsize()) {
            return Err(Error::Format(format!(
                "raw pcm length {} is not a multiple of itemsize {}",
                bytes.len(),
                dtype.itemsize()
            )));
        }
        Ok(match dtype {
            Dtype::I16 => Pcm::I16(
                bytes
                    .chunks_exact(2)
                    .map(|c| i16::from_le_bytes([c[0], c[1]]))
                    .collect(),
            ),
            Dtype::I32 => Pcm::I32(
                bytes
                    .chunks_exact(4)
                    .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect(),
            ),
            Dtype::F32 => Pcm::F32(
                bytes
                    .chunks_exact(4)
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect(),
            ),
            Dtype::F64 => Pcm::F64(
                bytes
                    .chunks_exact(8)
                    .map(|c| {
                        f64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]])
                    })
                    .collect(),
            ),
        })
    }
}
