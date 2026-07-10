import Foundation

/// Tempo estimate: spectral-flux onset envelope + autocorrelation -> bpm.
/// Port of beehive/tempo.py. Known to lock onto half/double the true tempo;
/// the engine accepts a bpm override.
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
        let bpm = 60.0 * fps / Double(best)
        let conf = ac[best] / ((ac.max() ?? 1) + 1e-10)
        return (bpm, conf)
    }
}
