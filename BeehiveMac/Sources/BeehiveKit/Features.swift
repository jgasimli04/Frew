import Accelerate
import Foundation

/// Per-frame features: the state s(n) = (A, I) plus the 12-d chroma identity.
/// Direct port of beehive/features.py.
public enum Features {

    static let eps: Float = 1e-10

    /// A(n): loudness in dB from the (un-windowed) frame, floored for silence.
    public static func loudnessDB(_ frame: [Float], floorDB: Float = -80) -> Float {
        var ms: Float = 0
        vDSP_measqv(frame, 1, &ms, vDSP_Length(frame.count))   // mean of squares
        let rms = sqrt(Double(ms) + 1e-10)
        return max(Float(20.0 * log10(rms + 1e-10)), floorDB)
    }

    /// Energy-weighted spectral centroid (Hz) and total spectral energy of a frame.
    public static func centroid(_ mag: [Float], freqs: [Float]) -> (hz: Float, total: Float) {
        var total: Float = 0
        vDSP_sve(mag, 1, &total, vDSP_Length(mag.count))
        if total <= eps { return (0, 0) }
        var weighted: Float = 0
        vDSP_dotpr(mag, 1, freqs, 1, &weighted, vDSP_Length(mag.count))
        return (weighted / total, total)
    }

    /// Constant soft-assignment matrix W, shape (12, nFreqs), row-major.
    /// chroma(frame) = W * mag(frame). Mirrors chroma.soft_chroma_projection:
    /// periodic Gaussian over circular distance on the mod-12 ring, normalised
    /// per frequency across the 12 classes; non-positive bins zeroed.
    public static func chromaMatrix(freqs: [Float], sigma: Float = 0.5,
                                    fRef: Float = 440, nBins: Int = 12) -> [Float] {
        let nf = freqs.count
        var w = [Float](repeating: 0, count: nBins * nf)       // [k*nf + i]
        for i in 0..<nf {
            guard freqs[i] > 0 else { continue }
            let midi = Float(nBins) * log2(freqs[i] / fRef)
            var col = [Float](repeating: 0, count: nBins)
            var sum: Float = 0
            for k in 0..<nBins {
                let raw = (midi - Float(k)).truncatingRemainder(dividingBy: Float(nBins))
                let m = raw < 0 ? raw + Float(nBins) : raw           // [0,12)
                let circ = min(m, Float(nBins) - m)                  // [0,6]
                let val = exp(-(circ * circ) / (2 * sigma * sigma))
                col[k] = val
                sum += val
            }
            if sum > eps { for k in 0..<nBins { w[k * nf + i] = col[k] / sum } }
        }
        return w
    }

    /// chroma = W (nBins x nFreqs) * mag (nFreqs) -> nBins, via Accelerate BLAS.
    public static func chroma(_ mag: [Float], matrix w: [Float],
                              nBins: Int = 12) -> [Float] {
        let nf = mag.count
        var out = [Float](repeating: 0, count: nBins)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(nBins), Int32(nf),
                    1.0, w, Int32(nf), mag, 1, 0.0, &out, 1)
        return out
    }
}
