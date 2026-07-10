//! Rust-side round-trip tests. These prove internal consistency; the
//! cross-implementation bit-exactness against the Python reference is proven
//! separately by beecore/interop/test_interop.py.

use bee_format::npz::{read_npz, write_npz, NpyArray};
use bee_format::{read_bee_bytes, write_bee_bytes, AudioMeta, Dtype, Pcm, WriteParams};

/// Deterministic pseudo-random generator (xorshift) so tests need no deps.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn i16(&mut self) -> i16 {
        (self.next() & 0xFFFF) as u16 as i16
    }
    fn i24_shifted(&mut self) -> i32 {
        // 24-bit value, left-justified in i32 (libsndfile convention).
        let v = (self.next() & 0xFF_FFFF) as u32;
        ((v << 8) as i32) >> 8 << 8
    }
    fn f32(&mut self) -> f32 {
        (self.next() as f64 / u64::MAX as f64) as f32 * 2.0 - 1.0
    }
}

fn audio_meta(subtype: &str, dtype: Dtype, frames: u64, channels: u32) -> AudioMeta {
    AudioMeta {
        sample_rate: 22_050,
        channels,
        subtype: subtype.into(),
        frames,
        dtype: dtype.numpy_name().into(),
        byte_order: None,
        source_format: Some("WAV".into()),
        codec: None,
        note: None,
        extra: serde_json::Map::new(),
    }
}

fn helix_fixture(n: usize) -> (Vec<u8>, Vec<u8>) {
    let mut rng = Rng(7);
    let a = NpyArray::f32(vec![n], &(0..n).map(|_| rng.f32()).collect::<Vec<_>>()).unwrap();
    let i = NpyArray::f32(vec![n], &(0..n).map(|_| rng.f32()).collect::<Vec<_>>()).unwrap();
    let chroma =
        NpyArray::f32(vec![n, 12], &(0..n * 12).map(|_| rng.f32()).collect::<Vec<_>>()).unwrap();
    let engagement = NpyArray::f32(vec![n], &vec![0.0; n]).unwrap();
    let npz = write_npz(&[
        ("A", &a),
        ("I", &i),
        ("chroma", &chroma),
        ("engagement", &engagement),
    ])
    .unwrap();
    let meta = serde_json::json!({
        "engine_version": "0.1.0",
        "song_id": "test-fixture",
        "n_frames": n,
    });
    (npz, serde_json::to_vec(&meta).unwrap())
}

fn roundtrip(pcm: Pcm, audio: AudioMeta, expect_codec: &str) {
    let (npz, meta) = helix_fixture(64);
    let params = WriteParams {
        pcm: &pcm,
        audio,
        helix_npz: &npz,
        helix_meta_json: &meta,
        created_at: Some("2026-07-05T00:00:00Z".into()),
    };
    let (bytes, manifest) = write_bee_bytes(&params).unwrap();
    assert_eq!(manifest.audio.codec.as_deref(), Some(expect_codec));

    let bee = read_bee_bytes(&bytes).unwrap();
    assert_eq!(bee.pcm, pcm, "decoded PCM must be bit-exact");
    assert_eq!(bee.helix_npz, npz, "Layer 2 npz must be carried verbatim");
    assert_eq!(bee.helix_meta_json, meta);

    let sc = bee.sidechannel().unwrap();
    assert_eq!(sc.n_frames, 64);
    assert_eq!(sc.chroma_bins, 12);
    assert!(sc.engagement.iter().all(|&e| e == 0.0));
}

#[test]
fn pcm16_stereo_flac_roundtrip() {
    let mut rng = Rng(1);
    let frames = 22_050u64;
    let pcm = Pcm::I16((0..frames * 2).map(|_| rng.i16()).collect());
    roundtrip(pcm, audio_meta("PCM_16", Dtype::I16, frames, 2), "flac");
}

#[test]
fn pcm24_mono_flac_roundtrip() {
    let mut rng = Rng(2);
    let frames = 9_999u64;
    let pcm = Pcm::I32((0..frames).map(|_| rng.i24_shifted()).collect());
    roundtrip(pcm, audio_meta("PCM_24", Dtype::I32, frames, 1), "flac");
}

#[test]
fn float32_stereo_raw_zlib_roundtrip() {
    let mut rng = Rng(3);
    let frames = 5_000u64;
    let pcm = Pcm::F32((0..frames * 2).map(|_| rng.f32()).collect());
    roundtrip(pcm, audio_meta("FLOAT", Dtype::F32, frames, 2), "raw_zlib");
}

#[test]
fn float64_mono_raw_zlib_roundtrip() {
    let mut rng = Rng(4);
    let frames = 3_000u64;
    let pcm = Pcm::F64((0..frames).map(|_| rng.f32() as f64).collect());
    roundtrip(pcm, audio_meta("DOUBLE", Dtype::F64, frames, 1), "raw_zlib");
}

#[test]
fn pcm32_raw_zlib_roundtrip() {
    // PCM_32 is NOT routed to FLAC (mirrors the reference _FLAC_SUBTYPES).
    let mut rng = Rng(5);
    let frames = 2_000u64;
    let pcm = Pcm::I32((0..frames).map(|_| rng.next() as i32).collect());
    roundtrip(pcm, audio_meta("PCM_32", Dtype::I32, frames, 1), "raw_zlib");
}

#[test]
fn pcm24_with_nonzero_low_byte_refused() {
    let pcm = Pcm::I32(vec![0x0000_0101; 100]);
    let (npz, meta) = helix_fixture(4);
    let err = write_bee_bytes(&WriteParams {
        pcm: &pcm,
        audio: audio_meta("PCM_24", Dtype::I32, 100, 1),
        helix_npz: &npz,
        helix_meta_json: &meta,
        created_at: None,
    })
    .unwrap_err();
    assert!(err.to_string().contains("low byte"), "got: {err}");
}

#[test]
fn npz_roundtrip_preserves_shapes_and_bits() {
    let mut rng = Rng(6);
    let vals: Vec<f32> = (0..77 * 12).map(|_| rng.f32()).collect();
    let arr = NpyArray::f32(vec![77, 12], &vals).unwrap();
    let one = NpyArray::f32(vec![77], &vals[..77]).unwrap();
    let bytes = write_npz(&[("chroma", &arr), ("A", &one)]).unwrap();
    let back = read_npz(&bytes).unwrap();
    assert_eq!(back.len(), 2);
    assert_eq!(back[0].0, "chroma");
    assert_eq!(back[0].1.shape, vec![77, 12]);
    assert_eq!(back[0].1.as_f32().unwrap(), vals);
    assert_eq!(back[1].0, "A");
    assert_eq!(back[1].1.shape, vec![77]);
}

#[test]
fn bad_magic_rejected() {
    let err = read_bee_bytes(b"NOTBEE___________").unwrap_err();
    assert!(err.to_string().contains("magic"), "got: {err}");
}

#[test]
fn truncated_section_rejected() {
    let mut rng = Rng(8);
    let pcm = Pcm::I16((0..1000).map(|_| rng.i16()).collect());
    let (npz, meta) = helix_fixture(8);
    let (bytes, _) = write_bee_bytes(&WriteParams {
        pcm: &pcm,
        audio: audio_meta("PCM_16", Dtype::I16, 500, 2),
        helix_npz: &npz,
        helix_meta_json: &meta,
        created_at: None,
    })
    .unwrap();
    let err = read_bee_bytes(&bytes[..bytes.len() - 10]).unwrap_err();
    assert!(err.to_string().contains("past end"), "got: {err}");
}
