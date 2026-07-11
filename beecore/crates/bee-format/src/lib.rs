//! `.bee` v0 — portable production core of the two-layer audio container.
//!
//! Role in the project (BEE_FORMAT_BLUEPRINT.md §4(c)): **Python
//! (`beehive/beefile.py`) is the reference implementation and stays the
//! single source of truth for the format definition.** This crate is the
//! production core that has to run natively everywhere — iOS, Android,
//! macOS, Windows, Linux — via pure-Rust dependencies only (no C libraries),
//! consumed from platform code through the C ABI in the sibling `bee-ffi`
//! crate. Its acceptance bar is cross-implementation bit-exactness: a `.bee`
//! written by either implementation decodes to identical PCM arrays and an
//! identical Layer-2 side-channel in the other.
//!
//! The two layers (blueprint §3):
//! * **Layer 1 — audio payload**: losslessly reconstructs the decoded PCM.
//!   v0 coders are placeholders (FLAC for PCM_16/24 sources, raw+zlib
//!   otherwise); the real predictive+entropy coder is §4(a), **OPEN**.
//! * **Layer 2 — helix side-channel**: the stored state `A, I, chroma,
//!   engagement` plus meta. Navigation/indexing only — it does **not**
//!   reconstruct audio (exp3: chroma is many-to-one in timbre). This crate
//!   carries it verbatim; geometry re-derivation is the engine's job.
//!
//! Also deliberately unresolved here: §4(b) dedup matching and the bar/loop
//! pool (§6 steps 2–4 live in the Python reference for now).

pub mod codec;
pub mod container;
pub mod error;
pub mod manifest;
pub mod npz;
pub mod pcm;
pub mod zinc;

pub use container::{
    bee_info, read_bee, read_bee_bytes, write_bee, write_bee_bytes, BeeFile, Sidechannel,
    WriteParams, FORMAT_VERSION, MAGIC,
};
pub use error::{Error, Result};
pub use manifest::{AudioMeta, Manifest, Section};
pub use pcm::{Dtype, Pcm};
