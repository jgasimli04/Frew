//! C ABI over `bee-format` — the one native surface every platform consumes:
//! Swift on iOS/macOS, Kotlin/JNI on Android, C/C++/C# on Windows/Linux.
//! The header is hand-maintained at `include/bee.h`; keep the two in sync.
//!
//! Conventions:
//! * `bee_open` returns NULL on failure; `bee_last_error()` (thread-local)
//!   holds the message until the next failing call on the same thread.
//! * All pointers returned from a handle stay valid until `bee_close`.
//! * PCM is exposed as little-endian interleaved bytes; the element type is
//!   `bee_dtype()` and the layout is `(frames, channels)` C-order — exactly
//!   the array the lossless contract is defined over.

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use bee_format::{AudioMeta, BeeFile, Dtype, Pcm, Sidechannel, WriteParams};

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_error(msg: String) {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(c));
}

pub struct BeeHandle {
    file: BeeFile,
    side: Sidechannel,
    pcm_le: Vec<u8>,
    manifest_json: CString,
    helix_meta_json: CString,
}

/// Dtype codes in the header: 0=int16, 1=int32, 2=float32, 3=float64.
fn dtype_code(d: Dtype) -> i32 {
    match d {
        Dtype::I16 => 0,
        Dtype::I32 => 1,
        Dtype::F32 => 2,
        Dtype::F64 => 3,
    }
}

unsafe fn cstr<'a>(p: *const c_char, what: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{what} is NULL"));
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| format!("{what} is not valid UTF-8"))
}

/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn bee_open(path: *const c_char) -> *mut BeeHandle {
    let open = || -> Result<BeeHandle, String> {
        let path = cstr(path, "path")?;
        let file = bee_format::read_bee(path).map_err(|e| e.to_string())?;
        let side = file.sidechannel().map_err(|e| e.to_string())?;
        let manifest_json = CString::new(
            serde_json::to_string(&file.manifest).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        let helix_meta_json = CString::new(file.helix_meta_json.clone())
            .map_err(|_| "helix meta contains NUL".to_string())?;
        let pcm_le = file.pcm.to_le_bytes();
        Ok(BeeHandle { file, side, pcm_le, manifest_json, helix_meta_json })
    };
    match open() {
        Ok(h) => Box::into_raw(Box::new(h)),
        Err(e) => {
            set_error(e);
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `h` must come from `bee_open` and not have been closed.
#[no_mangle]
pub unsafe extern "C" fn bee_close(h: *mut BeeHandle) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

/// Last error message on this thread (empty string if none). Valid until the
/// next failing call on the same thread.
#[no_mangle]
pub extern "C" fn bee_last_error() -> *const c_char {
    LAST_ERROR.with(|e| match &*e.borrow() {
        Some(c) => c.as_ptr(),
        None => c"".as_ptr(),
    })
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_manifest_json(h: *const BeeHandle) -> *const c_char {
    (*h).manifest_json.as_ptr()
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_sample_rate(h: *const BeeHandle) -> u32 {
    (*h).file.manifest.audio.sample_rate
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_channels(h: *const BeeHandle) -> u32 {
    (*h).file.manifest.audio.channels
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_frames(h: *const BeeHandle) -> u64 {
    (*h).file.manifest.audio.frames
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_dtype(h: *const BeeHandle) -> i32 {
    dtype_code((*h).file.pcm.dtype())
}

/// Bit-exact decoded PCM: little-endian, interleaved, `(frames, channels)`.
///
/// # Safety
/// `h` must be a live handle; `out_len` may be NULL.
#[no_mangle]
pub unsafe extern "C" fn bee_pcm_bytes(h: *const BeeHandle, out_len: *mut u64) -> *const u8 {
    if !out_len.is_null() {
        *out_len = (*h).pcm_le.len() as u64;
    }
    (*h).pcm_le.as_ptr()
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_helix_frames(h: *const BeeHandle) -> u64 {
    (*h).side.n_frames as u64
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_helix_chroma_bins(h: *const BeeHandle) -> u32 {
    (*h).side.chroma_bins as u32
}

/// Layer-2 stored state by name: "A", "I", "engagement" (length = n_frames)
/// or "chroma" (length = n_frames * chroma_bins, row-major). NULL if unknown.
///
/// # Safety
/// `h` must be a live handle; `name` NUL-terminated; `out_len` may be NULL.
#[no_mangle]
pub unsafe extern "C" fn bee_helix_field(
    h: *const BeeHandle,
    name: *const c_char,
    out_len: *mut u64,
) -> *const f32 {
    let side = &(*h).side;
    let field: Option<&[f32]> = match cstr(name, "field name") {
        Ok("A") => Some(&side.a),
        Ok("I") => Some(&side.i),
        Ok("chroma") => Some(&side.chroma),
        Ok("engagement") => Some(&side.engagement),
        Ok(other) => {
            set_error(format!("unknown helix field {other:?}"));
            None
        }
        Err(e) => {
            set_error(e);
            None
        }
    };
    match field {
        Some(f) => {
            if !out_len.is_null() {
                *out_len = f.len() as u64;
            }
            f.as_ptr()
        }
        None => {
            if !out_len.is_null() {
                *out_len = 0;
            }
            ptr::null()
        }
    }
}

/// # Safety
/// `h` must be a live handle from `bee_open`.
#[no_mangle]
pub unsafe extern "C" fn bee_helix_meta_json(h: *const BeeHandle) -> *const c_char {
    (*h).helix_meta_json.as_ptr()
}

/// Write a `.bee`. `pcm` is little-endian interleaved samples matching the
/// dtype/frames/channels in `audio_meta_json` (keys: sample_rate, channels,
/// subtype, frames, dtype[, source_format]). The Layer-2 side-channel is
/// passed verbatim (npz bytes + meta JSON). Returns 0 on success, -1 on error
/// (see `bee_last_error`).
///
/// # Safety
/// All pointers must be valid for their stated lengths; strings NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn bee_write_file(
    path: *const c_char,
    pcm: *const u8,
    pcm_len: u64,
    audio_meta_json: *const c_char,
    helix_npz: *const u8,
    helix_npz_len: u64,
    helix_meta_json: *const c_char,
) -> i32 {
    let write = || -> Result<(), String> {
        let path = cstr(path, "path")?;
        let audio: AudioMeta = serde_json::from_str(cstr(audio_meta_json, "audio meta")?)
            .map_err(|e| e.to_string())?;
        let dtype = Dtype::from_numpy(&audio.dtype).map_err(|e| e.to_string())?;
        if pcm.is_null() {
            return Err("pcm is NULL".into());
        }
        let pcm_bytes = std::slice::from_raw_parts(pcm, pcm_len as usize);
        let pcm = Pcm::from_le_bytes(dtype, pcm_bytes).map_err(|e| e.to_string())?;
        let npz = if helix_npz.is_null() {
            &[][..]
        } else {
            std::slice::from_raw_parts(helix_npz, helix_npz_len as usize)
        };
        let meta = cstr(helix_meta_json, "helix meta")?;
        bee_format::write_bee(
            path,
            &WriteParams {
                pcm: &pcm,
                audio,
                helix_npz: npz,
                helix_meta_json: meta.as_bytes(),
                // FFI writer does not author keys (Python does); zinc plumb-through
                // lands with the BeeDeck consumer step.
                zinc_index: None,
                zinc_meta: None,
                created_at: None,
            },
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    };
    match write() {
        Ok(()) => 0,
        Err(e) => {
            set_error(e);
            -1
        }
    }
}
