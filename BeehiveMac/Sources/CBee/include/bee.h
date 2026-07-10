/* bee.h — C ABI for the .bee v0 audio container core (bee-ffi crate).
 *
 * One native library for every platform: link libbee_ffi (staticlib or
 * cdylib) and include this header from Swift (via a modulemap/bridging
 * header), Kotlin/JNI, C, C++, or C#/P-Invoke.
 *
 * Memory model: everything returned from a BeeHandle stays valid until
 * bee_close(handle). bee_last_error() is thread-local and valid until the
 * next failing call on the same thread. No returned pointer is ever freed
 * by the caller.
 *
 * Layer 1 (audio): bee_pcm_bytes() is the bit-exact decoded PCM —
 * little-endian, interleaved, (frames x channels) C-order, element type
 * given by bee_dtype(). Layer 2 (helix side-channel): per-frame float32
 * state A, I, chroma, engagement — navigation/indexing only, it does not
 * reconstruct audio.
 */

#ifndef BEE_H
#define BEE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BeeHandle BeeHandle;

/* Element type of the PCM buffer: matches the manifest's numpy dtype. */
typedef enum {
  BEE_DTYPE_INT16 = 0,
  BEE_DTYPE_INT32 = 1,
  BEE_DTYPE_FLOAT32 = 2,
  BEE_DTYPE_FLOAT64 = 3
} BeeDtype;

/* Open and fully decode a .bee file. NULL on failure (see bee_last_error). */
BeeHandle *bee_open(const char *path);
void bee_close(BeeHandle *h);

/* Thread-local message for the most recent failure ("" if none). */
const char *bee_last_error(void);

/* The manifest as a JSON string (owned by the handle). */
const char *bee_manifest_json(const BeeHandle *h);

uint32_t bee_sample_rate(const BeeHandle *h);
uint32_t bee_channels(const BeeHandle *h);
uint64_t bee_frames(const BeeHandle *h);
int32_t bee_dtype(const BeeHandle *h); /* BeeDtype */

/* Bit-exact decoded PCM bytes; *out_len receives the byte length. */
const uint8_t *bee_pcm_bytes(const BeeHandle *h, uint64_t *out_len);

/* Layer-2 side-channel. Field names: "A", "I", "engagement" (length =
 * bee_helix_frames) and "chroma" (length = frames * chroma_bins, row-major).
 * Returns NULL for an unknown name. */
uint64_t bee_helix_frames(const BeeHandle *h);
uint32_t bee_helix_chroma_bins(const BeeHandle *h);
const float *bee_helix_field(const BeeHandle *h, const char *name,
                             uint64_t *out_len);
const char *bee_helix_meta_json(const BeeHandle *h);

/* Write a .bee. pcm: little-endian interleaved samples matching
 * audio_meta_json (JSON keys: sample_rate, channels, subtype, frames,
 * dtype[, source_format]). helix_npz/helix_meta_json: the Layer-2
 * side-channel, passed through verbatim (numpy .npz bytes + JSON).
 * Returns 0 on success, -1 on error (see bee_last_error). */
int32_t bee_write_file(const char *path, const uint8_t *pcm, uint64_t pcm_len,
                       const char *audio_meta_json, const uint8_t *helix_npz,
                       uint64_t helix_npz_len, const char *helix_meta_json);

#ifdef __cplusplus
}
#endif

#endif /* BEE_H */
