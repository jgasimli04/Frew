import Foundation

/// Cross-song tonal matching -- the "taste profile" the helichain runs against.
///
/// A song's signature is two mean-centred, L2-normalised 12-d blocks concatenated
/// into one unit vector:
///   * tonal SHAPE  -- mean chroma over audible frames, then centred. Which pitch
///     classes dominate *relative to flat*. Cosine of two shapes is their Pearson
///     correlation -- the Krumhansl/Gómez tonal-profile descriptor (established).
///   * tonal MOTION -- per-bin mean |Δchroma| between consecutive audible frames,
///     then centred. Which pitch classes *move* the most: the chroma analog of the
///     force F = ds/dn. This is on-theme to the helix, not a cited similarity
///     method -- so it is weighted in, not relied on.
///
/// Centring is the fix: whole-song mean chroma is non-negative and, averaged over
/// thousands of frames, collapses toward the uniform vector (1,…,1); every cosine
/// then pinned near 1 by that shared common mode, regardless of the music.
/// Subtracting each profile's own mean removes that common mode, so genuinely
/// different songs separate. `motionWeight` λ blends the two:
///   cosine(a,b) = (1−λ)·shapeCorr + λ·motionCorr,   λ = 0 → shape only.
///
/// Established caveat (unchanged): chroma→timbre is many-to-one, so this is a
/// similarity descriptor, not a unique fingerprint.
public enum Taste {

    public static func signature(_ record: HelixRecord, audibleDB: Float = -40,
                                 motionWeight: Float = 0.4) -> [Float] {
        let shape = tonalShape(record, audibleDB: audibleDB)
        let motion = tonalMotion(record, audibleDB: audibleDB)
        let ws = (1 - motionWeight).squareRoot()
        let wm = motionWeight.squareRoot()
        var sig = [Float](repeating: 0, count: 24)
        for k in 0..<12 { sig[k] = ws * shape[k]; sig[12 + k] = wm * motion[k] }
        return normalize(sig)   // safety: degrades to the non-empty block if one is zero
    }

    /// Mean chroma over audible frames, mean-centred and L2-normalised (12-d).
    public static func tonalShape(_ record: HelixRecord, audibleDB: Float = -40) -> [Float] {
        var acc = [Float](repeating: 0, count: 12)
        var count = 0
        for i in 0..<record.nFrames where record.A[i] > audibleDB {
            for k in 0..<12 { acc[k] += record.chroma[i][k] }
            count += 1
        }
        guard count > 0 else { return acc }
        for k in 0..<12 { acc[k] /= Float(count) }
        return normalize(center(acc))
    }

    /// Per-bin mean |Δchroma| between consecutive audible frames, centred and
    /// L2-normalised (12-d): the chroma analog of the force F = ds/dn.
    public static func tonalMotion(_ record: HelixRecord, audibleDB: Float = -40) -> [Float] {
        var acc = [Float](repeating: 0, count: 12)
        var count = 0
        var i = 1
        while i < record.nFrames {
            if record.A[i] > audibleDB && record.A[i - 1] > audibleDB {
                for k in 0..<12 { acc[k] += abs(record.chroma[i][k] - record.chroma[i - 1][k]) }
                count += 1
            }
            i += 1
        }
        guard count > 0 else { return acc }
        for k in 0..<12 { acc[k] /= Float(count) }
        return normalize(center(acc))
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        for k in 0..<min(a.count, b.count) { dot += a[k] * b[k] }
        return dot   // inputs are unit-normalised
    }

    /// Mean of liked-song signatures, renormalised -> the taste profile vector.
    public static func profile(_ signatures: [[Float]]) -> [Float] {
        guard let first = signatures.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for s in signatures { for k in 0..<min(s.count, acc.count) { acc[k] += s[k] } }
        for k in acc.indices { acc[k] /= Float(signatures.count) }
        return normalize(acc)
    }

    /// How well a song matches a taste profile (cosine, in [-1, 1]).
    public static func score(profile: [Float], song: HelixRecord) -> Float {
        cosine(profile, signature(song))
    }

    /// Subtract the vector's own mean — removes the uniform common mode.
    static func center(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let m = v.reduce(0, +) / Float(v.count)
        return v.map { $0 - m }
    }

    static func normalize(_ v: [Float]) -> [Float] {
        var n: Float = 0
        for x in v { n += x * x }
        n = n.squareRoot()
        return n > 1e-10 ? v.map { $0 / n } : v
    }
}
