import Accelerate
import Foundation

/// The foundation engine: a real song -> a HelixRecord.
/// decode -> state s(n)=(A,I) -> force F=ds/dn -> climb h -> helix -> colour.
/// Port of beehive/encode.py (numpy path), DSP on Accelerate.
public enum Engine {

    public struct Params {
        public var nFFT = 2048
        public var hop = 1024
        public var B = 4
        public var r0 = 1.0
        public var fRef = 440.0
        public var sigma = 0.5
        public var floorDB = -80.0
        public var bpm: Double? = nil
        public var wAmp = 1.0
        public var wInt = 1.0
        public var smoothFrames = 1
        public init() {}
    }

    /// Encode already-decoded samples.
    public static func encode(samples y: [Float], sr: Double, sourcePath: String,
                              params p: Params = Params()) -> HelixRecord {
        let nFFT = p.nFFT, hop = p.hop, win = p.nFFT
        let window = DSP.hann(win)
        let freqs = DSP.rfftFreqs(n: nFFT, sr: sr)
        let fft = RealFFT(n: nFFT)
        let wMat = Features.chromaMatrix(freqs: freqs, sigma: Float(p.sigma), fRef: Float(p.fRef))

        // framing: frame t covers [t*hop, t*hop+win)
        let nFrames = y.count >= win ? (y.count - win) / hop + 1 : 0
        var A = [Float](repeating: 0, count: nFrames)
        var centroidHz = [Float](repeating: 0, count: nFrames)
        var totals = [Float](repeating: 0, count: nFrames)
        var chroma = [[Float]](repeating: [Float](repeating: 0, count: 12), count: nFrames)
        var mags = [[Float]](repeating: [], count: nFrames)

        for t in 0..<nFrames {
            let frame = Array(y[(t * hop)..<(t * hop + win)])
            let mag = fft.magnitude(frame, window: window)
            mags[t] = mag
            A[t] = Features.loudnessDB(frame, floorDB: Float(p.floorDB))
            let (hz, total) = Features.centroid(mag, freqs: freqs)
            centroidHz[t] = hz
            totals[t] = total
            chroma[t] = Features.chroma(mag, matrix: wMat)
        }

        // I(n): energy-gated centroid in semitones, hold-last across silence.
        let I = intervalSemitones(centroidHz: centroidHz, totals: totals, fRef: Float(p.fRef))

        // tempo -> omega
        var bpm = p.bpm ?? Double.nan
        var conf: Double? = nil
        var source = "provided"
        if p.bpm == nil {
            let est = Tempo.estimateBPM(mags, sr: sr, hop: hop)
            bpm = est.bpm; conf = est.confidence; source = "estimated"
        }
        let omega = 2 * Double.pi * bpm / (60 * Double(p.B))
        let omegaN = omega * Double(hop) / sr

        let chash = Audio.contentHash(y)
        let stem = (sourcePath as NSString).lastPathComponent
            .replacingOccurrences(of: ".\((sourcePath as NSString).pathExtension)", with: "")
        let meta = HelixMeta(
            songId: "\(stem)-\(String(chash.prefix(8)))",
            sourcePath: sourcePath, contentHash: chash,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            sr: sr, nSamples: y.count, durationS: Double(y.count) / sr,
            nFFT: nFFT, hop: hop, win: win, nFrames: nFrames,
            bpm: bpm, bpmConfidence: conf, bpmSource: source, B: p.B,
            omegaRadPerS: omega, omegaRadPerFrame: omegaN,
            r0: p.r0, fRef: p.fRef, sigma: p.sigma, floorDB: p.floorDB,
            wAmp: p.wAmp, wInt: p.wInt, smoothFrames: p.smoothFrames)

        let engagement = [Float](repeating: 0, count: nFrames)
        return assemble(meta: meta, A: A, I: I, chroma: chroma, engagement: engagement)
    }

    /// Reconstruct every derived field from the stored state + scalar meta.
    /// Shared by encode and HelixRecord.load (port of derive_dynamics).
    public static func assemble(meta: HelixMeta, A: [Float], I: [Float],
                                chroma: [[Float]], engagement: [Float]) -> HelixRecord {
        let n = A.count
        let Ad = A.map(Double.init)
        let Id = I.map(Double.init)

        let dA = Num.gradient(smooth(Ad, meta.smoothFrames))
        let dI = Num.gradient(smooth(Id, meta.smoothFrames))
        let sA = Num.std(dA) == 0 ? 1 : Num.std(dA)
        let sI = Num.std(dI) == 0 ? 1 : Num.std(dI)
        var fMag = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = meta.wAmp * dA[i] / sA
            let b = meta.wInt * dI[i] / sI
            fMag[i] = (a * a + b * b).squareRoot()
        }
        let h = Num.cumsum(fMag)

        let omegaN = meta.omegaRadPerFrame
        var t = [Double](repeating: 0, count: n)
        var alpha = [Double](repeating: 0, count: n)
        var x = [Double](repeating: 0, count: n)
        var yv = [Double](repeating: 0, count: n)
        for i in 0..<n {
            t[i] = Double(i) * Double(meta.hop) / meta.sr
            alpha[i] = omegaN * Double(i)
            x[i] = meta.r0 * cos(alpha[i])
            yv[i] = meta.r0 * sin(alpha[i])
        }
        let z = h

        let h2 = Num.gradient(fMag)
        let h3 = Num.gradient(h2)
        let (kappa, tau) = Geometry.curvatureTorsion(omega: omegaN, r0: meta.r0,
                                                      h1: fMag, h2: h2, h3: h3)

        // colour: hue = circular mean of the 12-d chroma
        var hue = [Float](repeating: 0, count: n)
        var sat = [Float](repeating: 0, count: n)
        var val = [Float](repeating: 0, count: n)
        let twoPi = 2 * Float.pi
        for i in 0..<n {
            var re: Float = 0, im: Float = 0, sum: Float = 0
            for k in 0..<12 {
                let ang = twoPi * Float(k) / 12
                re += chroma[i][k] * cos(ang)
                im += chroma[i][k] * sin(ang)
                sum += chroma[i][k]
            }
            var hh = atan2(im, re) / twoPi
            if hh < 0 { hh += 1 }
            hue[i] = hh
            sat[i] = sum > 1e-10 ? (re * re + im * im).squareRoot() / sum : 0
            val[i] = max(0, min(1, Float((Double(A[i]) - meta.floorDB) / (0 - meta.floorDB))))
        }

        return HelixRecord(meta: meta, A: A, I: I, chroma: chroma, engagement: engagement,
                           t: t, dA: dA, dI: dI, fMag: fMag, h: h, alpha: alpha,
                           x: x, y: yv, z: z, kappa: kappa, tau: tau,
                           hue: hue, sat: sat, val: val)
    }

    /// I(n): centroid -> semitones, energy-gated with hold-last across silence.
    static func intervalSemitones(centroidHz: [Float], totals: [Float],
                                  fRef: Float, energyFloorRatio: Float = 1e-2) -> [Float] {
        let n = centroidHz.count
        let pos = totals.filter { $0 > 0 }.sorted()
        let median: Float = pos.isEmpty ? 0 :
            (pos.count % 2 == 1 ? pos[pos.count / 2]
                                : (pos[pos.count / 2 - 1] + pos[pos.count / 2]) / 2)
        let thresh = energyFloorRatio * median

        var out = [Float](repeating: 0, count: n)
        var lastValid: Float? = nil
        for i in 0..<n {
            if totals[i] > thresh {
                let c = max(centroidHz[i], 1e-10)
                let v = 12 * log2(c / fRef)
                out[i] = v
                lastValid = v
            } else {
                out[i] = lastValid ?? 0
            }
        }
        return out
    }

    static func smooth(_ x: [Double], _ k: Int) -> [Double] {
        guard k > 1 else { return x }
        let n = x.count
        var out = [Double](repeating: 0, count: n)
        let half = k / 2
        for i in 0..<n {
            var s = 0.0, c = 0
            for j in max(0, i - half)...min(n - 1, i + half) { s += x[j]; c += 1 }
            out[i] = s / Double(c)
        }
        return out
    }
}
