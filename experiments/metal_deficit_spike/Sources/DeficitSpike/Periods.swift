import Foundation

/// Stage 1 — dominant period of a band envelope, expressed in beats.
///
/// **Estimator: normalised autocorrelation of the band envelope.**
/// Chosen because `Tempo.estimateBPM` already uses autocorrelation of an onset
/// envelope to get bpm, so the period and the beat it is divided by come from
/// the same class of estimator and the same frames — a period expressed in
/// beats is then a ratio of two lags from one method, not a comparison across
/// two different ones.
///
/// **Known failure mode: octave and harmonic ambiguity.** A pattern repeating
/// every 2 beats also correlates at 4, 6, 8; a pattern that alternates
/// (kick-clap-kick-clap) correlates at both 1 and 2. Plain argmax over the lag
/// range therefore picks an integer multiple of the true period some of the
/// time. `Tempo.swift` documents the same failure ("Known to lock onto
/// half/double the true tempo"). No octave-correction heuristic is applied here
/// — this spike is measuring whether the raw signal is stable, and tuning the
/// estimator until F1 passes would destroy the meaning of F1.
///
/// **Normalisation, settled by measurement, not by argument.** The first
/// version of this file divided each lag by its term count `(n - lag)` — the
/// textbook unbiased estimator — on the reasoning that the raw sum
/// `Tempo.estimateBPM` maximises decays with lag and would bias a 16:1 lag
/// search toward short periods. `EstimatorCheck.run` (the `control` subcommand)
/// falsified that reasoning: on synthetic envelopes with a known period, the
/// unbiased form returns 4.0 beats for a true 2.0 and 8.0 for a true 4.0,
/// because dividing by a shrinking term count inflates the variance of long
/// lags until a spurious long-lag peak wins. The biased form recovers 1.0, 2.0
/// and 4.0 exactly at noise 0 and 0.3. `biased` is therefore the default and
/// the number reported; `unbiased` is kept so the comparison stays runnable.
enum Periods {

    struct Estimate {
        /// Dominant period as a multiple of the beat.
        let beats: Double
        /// Normalised autocorrelation height at the chosen lag, 0…1 — how
        /// periodic the envelope is at that period, not how right the period is.
        let strength: Double
    }

    /// Lag search bounds, in beats. 0.5 catches an eighth-note layer; 8 catches
    /// a two-bar (B=4) pattern.
    static let minBeats = 0.5
    static let maxBeats = 8.0

    /// Autocorrelation normalisation. Neither is neutral, which is why both are
    /// run: `biased` divides every lag by `n` (terms drop off with lag, so long
    /// lags are penalised — `Tempo.estimateBPM`'s convention); `unbiased`
    /// divides by the term count `(n - lag)`, removing that penalty at the cost
    /// of rising variance at long lags. If the two disagree about F1, the
    /// instability being measured is the estimator's, not the music's.
    enum Norm { case biased, unbiased }

    /// `env` is one band's envelope over the analysis window.
    /// `beatFrames` is the beat period in analysis frames: `60/bpm * fps`.
    static func estimate(env: ArraySlice<Float>, beatFrames: Double,
                         norm: Norm = .biased) -> Estimate? {
        let x = Array(env)
        let n = x.count
        guard n > 8, beatFrames > 0 else { return nil }

        let lagMin = max(1, Int((minBeats * beatFrames).rounded()))
        let lagMax = min(n - 2, Int((maxBeats * beatFrames).rounded()))
        guard lagMax > lagMin else { return nil }

        let mean = Double(x.reduce(0, +)) / Double(n)
        let d = x.map { Double($0) - mean }
        var r0 = 0.0
        for v in d { r0 += v * v }
        r0 /= Double(n)
        // A silent or perfectly flat band has no period to find. Reported as a
        // dropped window rather than a period of 0.
        guard r0 > 1e-12 else { return nil }

        var best = lagMin
        var bestVal = -Double.infinity
        for lag in lagMin...lagMax {
            var s = 0.0
            for i in lag..<n { s += d[i] * d[i - lag] }
            let denom = norm == .unbiased ? Double(n - lag) : Double(n)
            let r = s / denom / r0
            if r > bestVal { bestVal = r; best = lag }
        }
        return Estimate(beats: Double(best) / beatFrames, strength: bestVal)
    }
}
