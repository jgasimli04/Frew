import Foundation

/// Tempo estimate: spectral-flux onset envelope + autocorrelation -> bpm.
/// Port of beehive/tempo.py, extended with octave correction: raw integer-lag
/// argmax can lock onto a multiple of the true period (half/double tempo),
/// especially when the beat period falls between frames and its peak smears.
/// The winning lag is therefore verified with a fractional-period comb — a
/// shorter period whose teeth capture strictly more onset energy wins — and
/// refined to sub-frame precision from the envelope's drift pattern.
public enum Tempo {

    /// Half-wave-rectified spectral flux, one value per frame.
    public static func onsetEnvelope(_ mags: [[Float]]) -> [Double] {
        let nFrames = mags.count
        guard nFrames > 1 else { return [Double](repeating: 0, count: nFrames) }
        var env = [Double](repeating: 0, count: nFrames)
        let nBins = mags[0].count
        for t in 1..<nFrames {
            var flux = 0.0
            for b in 0..<nBins {
                let d = Double(mags[t][b]) - Double(mags[t - 1][b])
                if d > 0 { flux += d }
            }
            env[t] = flux
        }
        let mean = env.reduce(0, +) / Double(nFrames)
        return env.map { $0 - mean }
    }

    /// Total rectified onset energy captured by a comb with fractional period
    /// `p` frames: teeth at k·p, each tooth taking the max within ±1 frame
    /// (absorbs the integer-frame quantization of the onset times).
    private static func combScore(_ p: Double, _ env: [Double]) -> Double {
        var s = 0.0
        var k = 1
        while true {
            let c = Int((Double(k) * p).rounded())
            if c >= env.count { break }
            var m = 0.0
            for i in max(0, c - 1)...min(env.count - 1, c + 1) { m = max(m, max(env[i], 0)) }
            s += m
            k += 1
        }
        return s
    }

    /// (bpm, confidence). confidence is the autocorr height at the chosen lag.
    public static func estimateBPM(_ mags: [[Float]], sr: Double, hop: Int,
                                   bpmMin: Double = 60, bpmMax: Double = 200)
        -> (bpm: Double, confidence: Double) {
        let env = onsetEnvelope(mags)
        let n = env.count
        if Num.std(env) < 1e-10 { return (.nan, 0) }

        // autocorrelation for lags >= 1
        var ac = [Double](repeating: 0, count: n)
        for lag in 1..<n {
            var s = 0.0
            for i in lag..<n { s += env[i] * env[i - lag] }
            ac[lag] = s
        }
        let fps = sr / Double(hop)
        let lagMin = max(1, Int((60.0 * fps / bpmMax).rounded()))
        let lagMax = min(n - 1, Int((60.0 * fps / bpmMin).rounded()))
        if lagMax <= lagMin { return (.nan, 0) }

        var best = lagMin
        for lag in lagMin...lagMax where ac[lag] > ac[best] { best = lag }
        let conf = ac[best] / ((ac.max() ?? 1) + 1e-10)

        // Octave correction: the autocorr peak at `best` may be a multiple of
        // the fundamental period (a pulse train is periodic at 2×, 3×, … its
        // period). A shorter candidate only wins if its comb captures clearly
        // more onset energy (>5%) — so real music's weaker off-beat energy
        // does not falsely double the tempo.
        var period = Double(best)
        var base = combScore(period, env)
        var improved = true
        while improved {
            improved = false
            for d in [2.0, 3.0] {
                let cand = period / d
                guard cand >= Double(lagMin) else { continue }
                let score = combScore(cand, env)
                if score > base * 1.05 { period = cand; base = score; improved = true }
            }
        }

        // Sub-frame refinement: scan ±0.6 frames so a beat period of e.g.
        // 21.5 frames lands exactly instead of quantizing to the nearest lag.
        var refined = period
        var bestScore = base
        var p = period - 0.6
        while p <= period + 0.6 {
            if p >= Double(lagMin) {
                let score = combScore(p, env)
                if score > bestScore { refined = p; bestScore = score }
            }
            p += 0.05
        }

        let bpm = 60.0 * fps / refined
        return (bpm, conf)
    }
}
