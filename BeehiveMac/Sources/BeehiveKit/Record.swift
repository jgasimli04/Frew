import Foundation

/// Metadata for one encoded song (scalars + definitions). Codable for the ledger.
public struct HelixMeta: Codable {
    public var engineVersion = "0.1.0-swift"
    public var songId: String
    public var sourcePath: String
    public var contentHash: String
    public var createdAt: String
    public var sr: Double
    public var nSamples: Int
    public var durationS: Double
    public var nFFT: Int
    public var hop: Int
    public var win: Int
    public var nFrames: Int
    public var bpm: Double
    public var bpmConfidence: Double?
    public var bpmSource: String
    public var B: Int
    public var omegaRadPerS: Double
    public var omegaRadPerFrame: Double
    public var r0: Double
    public var fRef: Double
    public var sigma: Double
    public var floorDB: Double
    public var wAmp: Double
    public var wInt: Double
    public var smoothFrames: Int

    public init(engineVersion: String = "0.1.0-swift", songId: String, sourcePath: String,
                contentHash: String, createdAt: String, sr: Double, nSamples: Int,
                durationS: Double, nFFT: Int, hop: Int, win: Int, nFrames: Int, bpm: Double,
                bpmConfidence: Double?, bpmSource: String, B: Int, omegaRadPerS: Double,
                omegaRadPerFrame: Double, r0: Double, fRef: Double, sigma: Double,
                floorDB: Double, wAmp: Double, wInt: Double, smoothFrames: Int) {
        self.engineVersion = engineVersion; self.songId = songId; self.sourcePath = sourcePath
        self.contentHash = contentHash; self.createdAt = createdAt; self.sr = sr
        self.nSamples = nSamples; self.durationS = durationS; self.nFFT = nFFT; self.hop = hop
        self.win = win; self.nFrames = nFrames; self.bpm = bpm; self.bpmConfidence = bpmConfidence
        self.bpmSource = bpmSource; self.B = B; self.omegaRadPerS = omegaRadPerS
        self.omegaRadPerFrame = omegaRadPerFrame; self.r0 = r0; self.fRef = fRef
        self.sigma = sigma; self.floorDB = floorDB; self.wAmp = wAmp; self.wInt = wInt
        self.smoothFrames = smoothFrames
    }
}

/// The persistent, on-standby encoding of one song. Only the independent state
/// (A, I, chroma, engagement) is stored; everything geometric is recomputed by
/// Engine.deriveDynamics on load. Port of beehive/record.py.
public struct HelixRecord {
    public let meta: HelixMeta
    // stored state
    public let A: [Float]
    public let I: [Float]
    public let chroma: [[Float]]          // nFrames x 12
    public var engagement: [Float]
    // derived
    public let t: [Double]
    public let dA: [Double]
    public let dI: [Double]
    public let fMag: [Double]
    public let h: [Double]
    public let alpha: [Double]
    public let x: [Double]
    public let y: [Double]
    public let z: [Double]
    public let kappa: [Double]
    public let tau: [Double]
    public let hue: [Float]
    public let sat: [Float]
    public let val: [Float]

    public var nFrames: Int { A.count }

    /// What this compact representation costs vs. the dense STFT it replaces.
    public func compressionReport() -> (stored: Int, stft: Int, ratioState: Int, ratioStored: Int) {
        let n = nFrames, bins = meta.nFFT / 2 + 1
        let state = 2 * n * 4
        let stored = (2 + 12) * n * 4
        let stft = bins * n * 4
        return (stored, stft, stft / max(state, 1), stft / max(stored, 1))
    }
}

/// Codable wrapper for persisting only the stored state.
struct StoredState: Codable {
    let meta: HelixMeta
    let A: [Float]
    let I: [Float]
    let chroma: [[Float]]
    let engagement: [Float]
}

public extension HelixRecord {
    func save(to url: URL) throws {
        let s = StoredState(meta: meta, A: A, I: I, chroma: chroma, engagement: engagement)
        let data = try JSONEncoder().encode(s)
        try data.write(to: url)
    }

    static func load(from url: URL) throws -> HelixRecord {
        let s = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: url))
        return Engine.assemble(meta: s.meta, A: s.A, I: s.I, chroma: s.chroma, engagement: s.engagement)
    }
}
