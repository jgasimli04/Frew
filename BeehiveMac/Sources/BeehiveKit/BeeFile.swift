import CBee
import Foundation

/// A `.bee` file, read through the native core (bee-ffi / bee-format, Rust)
/// over the C ABI. Swift consumes; it never reimplements the codec
/// (BEE_FORMAT_BLUEPRINT.md §4c).
///
/// Layer 1 gives the bit-exact PCM (playback). Layer 2 gives the stored state
/// (A, I, chroma, engagement) + meta, from which the full HelixRecord is
/// re-derived by Engine.assemble — opening a `.bee` needs **no analysis pass**.
public final class BeeFile {
    public enum BeeError: Error, CustomStringConvertible {
        case open(String), meta(String)
        public var description: String {
            switch self {
            case .open(let m): return "bee_open failed: \(m)"
            case .meta(let m): return "bee meta: \(m)"
            }
        }
    }

    private let handle: OpaquePointer

    public init(path: String) throws {
        guard let h = bee_open(path) else {
            throw BeeError.open(String(cString: bee_last_error()))
        }
        handle = h
    }

    deinit { bee_close(handle) }

    public var sampleRate: Double { Double(bee_sample_rate(handle)) }
    public var channels: Int { Int(bee_channels(handle)) }
    public var frames: Int { Int(bee_frames(handle)) }

    /// Decoded PCM as deinterleaved Float32 in [-1, 1] — the playback format.
    /// (The bit-exact integer/float samples stay the format's ground truth;
    /// this is only the render copy.)
    public func floatPCM() -> [[Float]] {
        var byteLen: UInt64 = 0
        guard let raw = bee_pcm_bytes(handle, &byteLen) else { return [] }
        let ch = channels, n = frames
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)

        switch bee_dtype(handle) {
        case 0: // int16
            raw.withMemoryRebound(to: Int16.self, capacity: n * ch) { p in
                let inv = Float(1.0 / 32768.0)
                for c in 0..<ch {
                    for i in 0..<n { out[c][i] = Float(p[i * ch + c]) * inv }
                }
            }
        case 1: // int32 (PCM_24 left-justified or PCM_32 — same normalisation)
            raw.withMemoryRebound(to: Int32.self, capacity: n * ch) { p in
                let inv = Float(1.0 / 2147483648.0)
                for c in 0..<ch {
                    for i in 0..<n { out[c][i] = Float(p[i * ch + c]) * inv }
                }
            }
        case 2: // float32
            raw.withMemoryRebound(to: Float.self, capacity: n * ch) { p in
                for c in 0..<ch {
                    for i in 0..<n { out[c][i] = p[i * ch + c] }
                }
            }
        case 3: // float64
            raw.withMemoryRebound(to: Double.self, capacity: n * ch) { p in
                for c in 0..<ch {
                    for i in 0..<n { out[c][i] = Float(p[i * ch + c]) }
                }
            }
        default:
            break
        }
        return out
    }

    /// Rebuild the full HelixRecord from Layer 2 (stored state + meta).
    public func record() throws -> HelixRecord {
        let n = Int(bee_helix_frames(handle))
        let bins = Int(bee_helix_chroma_bins(handle))

        func field(_ name: String, _ count: Int) throws -> [Float] {
            var len: UInt64 = 0
            guard let p = bee_helix_field(handle, name, &len), Int(len) == count else {
                throw BeeError.meta("side-channel field \(name) missing or wrong length")
            }
            return [Float](UnsafeBufferPointer(start: p, count: count))
        }

        let a = try field("A", n)
        let i = try field("I", n)
        let flat = try field("chroma", n * bins)
        let engagement = try field("engagement", n)
        let chroma = (0..<n).map { Array(flat[$0 * bins..<($0 + 1) * bins]) }

        let meta = try Self.helixMeta(fromJSON: String(cString: bee_helix_meta_json(handle)))
        return Engine.assemble(meta: meta, A: a, I: i, chroma: chroma, engagement: engagement)
    }

    /// Map the reference encoder's meta JSON (snake_case, beehive/encode.py)
    /// onto HelixMeta. Unknown keys are ignored; missing knobs get the
    /// encoder defaults so records from older engines still open.
    static func helixMeta(fromJSON json: String) throws -> HelixMeta {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw BeeError.meta("helix meta is not a JSON object") }

        func num(_ k: String, _ fallback: Double? = nil) throws -> Double {
            if let v = obj[k] as? Double { return v }
            if let v = obj[k] as? Int { return Double(v) }
            if let f = fallback { return f }
            throw BeeError.meta("missing numeric key \(k)")
        }
        func str(_ k: String, _ fallback: String = "") -> String { obj[k] as? String ?? fallback }

        let weighting = obj["force_weighting"] as? [String: Any] ?? [:]
        func weight(_ k: String) -> Double {
            (weighting[k] as? Double) ?? (weighting[k] as? Int).map(Double.init) ?? 1.0
        }

        return HelixMeta(
            engineVersion: str("engine_version", "?"),
            songId: str("song_id"),
            sourcePath: str("source_path"),
            contentHash: str("content_hash"),
            createdAt: str("created_at"),
            sr: try num("sr"),
            nSamples: Int(try num("n_samples", 0)),
            durationS: try num("duration_s", 0),
            nFFT: Int(try num("n_fft", 2048)),
            hop: Int(try num("hop", 1024)),
            win: Int(try num("win", 2048)),
            nFrames: Int(try num("n_frames")),
            bpm: try num("bpm", 120),
            bpmConfidence: obj["bpm_confidence"] as? Double,
            bpmSource: str("bpm_source", "unknown"),
            B: Int(try num("B", 4)),
            omegaRadPerS: try num("omega_rad_per_s"),
            omegaRadPerFrame: try num("omega_rad_per_frame"),
            r0: try num("r0", 1),
            fRef: try num("f_ref", 440),
            sigma: try num("sigma", 0.5),
            floorDB: try num("floor_db", -80),
            wAmp: weight("w_amp"),
            wInt: weight("w_int"),
            smoothFrames: Int(try num("smooth_frames", 1))
        )
    }
}
