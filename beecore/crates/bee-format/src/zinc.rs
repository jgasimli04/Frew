//! Zinc keyframe index — the **consumer only** (ZINC_KEYFRAME_BLUEPRINT §5).
//!
//! Python (`beehive/zinc.py`) authors the keys at encode time and bakes them
//! into the `.bee` as the additive `zinc_index` section; that stored key set is
//! authoritative. Rust does **not** re-derive placement — this module reads the
//! keys and reconstructs the state trajectory (zero-order hold), the runtime
//! path BeeDeck's phase-locked triggers fire from. Bit-exactness is checked on
//! the consumer reproducing `beehive.zinc.reconstruct_state` from the same
//! keys (`beecore/interop/test_interop.py`).
//!
//! Wire format: 24-byte little-endian records `<u32 frame, f32 r, theta, z,
//! a, i>` back-to-back, no header — key count is `len/24`. Policy metadata
//! (tau, lam, version) travels in the manifest, not the blob.

use crate::error::{Error, Result};

/// Size of one serialized key.
pub const ANCHOR_BYTES: usize = 24;

/// One zinc key: an absolute state coordinate that resets the prediction.
/// `r` is constant (== r0) and `theta` is derivable from `frame`; both are kept
/// for self-description, mirroring the Python `Anchor`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Anchor {
    pub frame: u32,
    pub r: f32,
    pub theta: f32,
    pub z: f32,
    /// State A (loudness dB) at the key.
    pub a: f32,
    /// State I (interval, semitones) at the key.
    pub i: f32,
}

/// Parse the Python-authored `zinc_index` section bytes.
pub fn read_anchors(section: &[u8]) -> Result<Vec<Anchor>> {
    if !section.len().is_multiple_of(ANCHOR_BYTES) {
        return Err(Error::Format(format!(
            "zinc_index length {} is not a multiple of {ANCHOR_BYTES}",
            section.len()
        )));
    }
    let f32_at = |c: &[u8], o: usize| f32::from_le_bytes(c[o..o + 4].try_into().unwrap());
    Ok(section
        .chunks_exact(ANCHOR_BYTES)
        .map(|c| Anchor {
            frame: u32::from_le_bytes(c[0..4].try_into().unwrap()),
            r: f32_at(c, 4),
            theta: f32_at(c, 8),
            z: f32_at(c, 12),
            a: f32_at(c, 16),
            i: f32_at(c, 20),
        })
        .collect())
}

/// Zero-order-hold reconstruction of the state trajectory from the keys:
/// `(A, I)` held from each key until the next, snapping exactly at the keys —
/// the mirror of `beehive.zinc.reconstruct_state`, which it must match
/// bit-exactly from the same key bytes.
pub fn reconstruct_state(keys: &[Anchor], n_frames: usize) -> (Vec<f32>, Vec<f32>) {
    let mut a = vec![0.0f32; n_frames];
    let mut i = vec![0.0f32; n_frames];
    for (k, key) in keys.iter().enumerate() {
        let start = key.frame as usize;
        let end = keys.get(k + 1).map_or(n_frames, |nx| nx.frame as usize);
        a[start..end].fill(key.a);
        i[start..end].fill(key.i);
    }
    (a, i)
}
