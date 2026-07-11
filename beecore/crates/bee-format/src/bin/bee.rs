//! `bee` — thin CLI over bee-format, used by the cross-implementation
//! acceptance tests (beecore/interop) and for inspection.
//!
//! Subcommands:
//!   bee info <file.bee>
//!   bee decode <file.bee> --pcm-out <raw.bin> [--audio-meta-out <am.json>]
//!   bee extract-helix <file.bee> --npz-out <h.npz> --meta-out <hm.json>
//!   bee encode --pcm <raw.bin> --audio-meta <am.json>
//!              --helix-npz <h.npz> --helix-meta <hm.json> --out <file.bee>
//!   bee index <file.bee> [--out <keys.json>] [--reconstruct-out <raw.bin>]
//!
//! Raw PCM files are little-endian interleaved samples in the dtype named by
//! the audio meta JSON (exactly `numpy.ndarray.tobytes()` on a LE host).

use std::collections::HashMap;
use std::process::ExitCode;

use bee_format::zinc;
use bee_format::{read_bee, write_bee, AudioMeta, Dtype, Pcm, WriteParams};

fn flags(args: &[String]) -> Result<(Vec<String>, HashMap<String, String>), String> {
    let mut pos = Vec::new();
    let mut kv = HashMap::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(name) = a.strip_prefix("--") {
            let v = it.next().ok_or_else(|| format!("--{name} needs a value"))?;
            kv.insert(name.to_string(), v.clone());
        } else {
            pos.push(a.clone());
        }
    }
    Ok((pos, kv))
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("");
    let (pos, kv) = flags(&args[args.len().min(1)..])?;

    match cmd {
        "info" => {
            let path = pos.first().ok_or("usage: bee info <file.bee>")?;
            let manifest = bee_format::bee_info(path).map_err(|e| e.to_string())?;
            println!(
                "{}",
                serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?
            );
        }
        "decode" => {
            let path = pos.first().ok_or("usage: bee decode <file.bee> --pcm-out <bin>")?;
            let pcm_out = kv.get("pcm-out").ok_or("--pcm-out required")?;
            let bee = read_bee(path).map_err(|e| e.to_string())?;
            std::fs::write(pcm_out, bee.pcm.to_le_bytes()).map_err(|e| e.to_string())?;
            if let Some(am_out) = kv.get("audio-meta-out") {
                let json = serde_json::to_string_pretty(&bee.manifest.audio)
                    .map_err(|e| e.to_string())?;
                std::fs::write(am_out, json).map_err(|e| e.to_string())?;
            }
            eprintln!(
                "decoded {} samples ({} frames x {} ch, {})",
                bee.pcm.len(),
                bee.manifest.audio.frames,
                bee.manifest.audio.channels,
                bee.manifest.audio.dtype
            );
        }
        "extract-helix" => {
            let path = pos
                .first()
                .ok_or("usage: bee extract-helix <file.bee> --npz-out <npz> --meta-out <json>")?;
            let npz_out = kv.get("npz-out").ok_or("--npz-out required")?;
            let meta_out = kv.get("meta-out").ok_or("--meta-out required")?;
            let bee = read_bee(path).map_err(|e| e.to_string())?;
            std::fs::write(npz_out, &bee.helix_npz).map_err(|e| e.to_string())?;
            std::fs::write(meta_out, &bee.helix_meta_json).map_err(|e| e.to_string())?;
            let sc = bee.sidechannel().map_err(|e| e.to_string())?;
            eprintln!("side-channel: {} frames, {} chroma bins", sc.n_frames, sc.chroma_bins);
        }
        "encode" => {
            let pcm_path = kv.get("pcm").ok_or("--pcm required")?;
            let am_path = kv.get("audio-meta").ok_or("--audio-meta required")?;
            let npz_path = kv.get("helix-npz").ok_or("--helix-npz required")?;
            let hm_path = kv.get("helix-meta").ok_or("--helix-meta required")?;
            let out = kv.get("out").ok_or("--out required")?;

            let am_bytes = std::fs::read(am_path).map_err(|e| e.to_string())?;
            let audio: AudioMeta = serde_json::from_slice(&am_bytes).map_err(|e| e.to_string())?;
            let dtype = Dtype::from_numpy(&audio.dtype).map_err(|e| e.to_string())?;
            let pcm_bytes = std::fs::read(pcm_path).map_err(|e| e.to_string())?;
            let pcm = Pcm::from_le_bytes(dtype, &pcm_bytes).map_err(|e| e.to_string())?;
            let helix_npz = std::fs::read(npz_path).map_err(|e| e.to_string())?;
            let helix_meta = std::fs::read(hm_path).map_err(|e| e.to_string())?;
            // Optional Python-authored key blob, carried verbatim (never generated here).
            let zinc_blob = kv
                .get("zinc-index")
                .map(std::fs::read)
                .transpose()
                .map_err(|e| e.to_string())?;

            let manifest = write_bee(
                out,
                &WriteParams {
                    pcm: &pcm,
                    audio,
                    helix_npz: &helix_npz,
                    helix_meta_json: &helix_meta,
                    zinc_index: zinc_blob.as_deref(),
                    zinc_meta: None,
                    created_at: None,
                },
            )
            .map_err(|e| e.to_string())?;
            eprintln!(
                "wrote {out} (codec {})",
                manifest.audio.codec.as_deref().unwrap_or("?")
            );
        }
        // Inspect the Python-authored zinc index (this binary never generates
        // keys — Python authors, Rust consumes; ZINC_KEYFRAME_BLUEPRINT §5).
        "index" => {
            let path = pos.first().ok_or("usage: bee index <file.bee> [--out <keys.json>]")?;
            let bee = read_bee(path).map_err(|e| e.to_string())?;
            let Some(blob) = bee.zinc_index.as_deref() else {
                return Err(format!("{path} has no zinc_index section (pre-index file)"));
            };
            let keys = zinc::read_anchors(blob).map_err(|e| e.to_string())?;
            let sc = bee.sidechannel().map_err(|e| e.to_string())?;

            let dur_min =
                bee.manifest.audio.frames as f64 / f64::from(bee.manifest.audio.sample_rate) / 60.0;
            eprintln!(
                "zinc index: {} keys over {} frames ({:.1}x sparsity) — {} B, {:.1} KB/min",
                keys.len(),
                sc.n_frames,
                sc.n_frames as f64 / keys.len() as f64,
                blob.len(),
                blob.len() as f64 / 1024.0 / dur_min,
            );

            let out = serde_json::json!({
                "zinc": bee.manifest.zinc,
                "n_frames": sc.n_frames,
                "n_keys": keys.len(),
                "bytes": blob.len(),
                "kb_per_min": blob.len() as f64 / 1024.0 / dur_min,
                "keys": keys.iter().map(|k| serde_json::json!({
                    "frame": k.frame, "r": k.r, "theta": k.theta,
                    "z": k.z, "a": k.a, "i": k.i,
                })).collect::<Vec<_>>(),
            });
            let json = serde_json::to_string_pretty(&out).map_err(|e| e.to_string())?;
            match kv.get("out") {
                Some(p) => std::fs::write(p, json).map_err(|e| e.to_string())?,
                None => println!("{json}"),
            }

            // ZOH reconstruction as raw f32 LE (A then I) — what the interop
            // harness diffs bit-for-bit against beehive.zinc.reconstruct_state.
            if let Some(p) = kv.get("reconstruct-out") {
                let (a, i) = zinc::reconstruct_state(&keys, sc.n_frames);
                let mut raw = Vec::with_capacity(8 * sc.n_frames);
                for v in a.iter().chain(i.iter()) {
                    raw.extend_from_slice(&v.to_le_bytes());
                }
                std::fs::write(p, raw).map_err(|e| e.to_string())?;
            }
        }
        _ => {
            return Err("usage: bee <info|decode|extract-helix|encode|index> ... \
                        (see source header for flags)"
                .into())
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("bee: {e}");
            ExitCode::FAILURE
        }
    }
}
