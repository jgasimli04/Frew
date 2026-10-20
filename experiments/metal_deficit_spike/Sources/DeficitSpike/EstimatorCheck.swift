import Foundation

/// Synthetic control for `Periods.estimate`.
///
/// F1 came out at CoV ~0.8 on real music. That number is only evidence about
/// the *architecture* if the estimator recovers a period it is handed. This
/// builds envelopes with a known period, in the same units and at the same
/// frame rate the real envelopes use, and checks what comes back. If these
/// fail, F1 is measuring a bug; if they pass, F1 is measuring the music.
enum EstimatorCheck {

    /// Impulse train at `periodBeats`, smoothed with the same 0.30 s peak-hold
    /// release `BandEnvelopes`/`Envelopes.bands` apply, plus optional noise.
    static func synthetic(periodBeats: Double, beatFrames: Double, frames: Int,
                          noise: Float, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let step = periodBeats * beatFrames
        // hop/sr = 1024/44100 s per frame; matches Analysis.hop at 44.1 kHz.
        let release = Float(exp(-(1024.0 / 44100.0) / 0.30))
        var out = [Float](repeating: 0, count: frames)
        var held: Float = 0
        for m in 0..<frames {
            let phase = Double(m).truncatingRemainder(dividingBy: step)
            let hit: Float = phase < 1 ? 1 : 0
            held = max(hit, held * release)
            out[m] = min(max(held + noise * (Float(rng.nextUnit()) - 0.5), 0), 1)
        }
        return out
    }

    static func run() {
        print("== estimator control — synthetic envelopes with a known period ==")
        print("  32-beat windows, 37.0 frames/beat (the 69.84 bpm case in the corpus),")
        print("  0.30 s peak-hold release, 21 windows per condition.\n")
        let beatFrames = 37.0
        let winFrames = Int(Analysis.windowBeats * beatFrames)
        let hopFrames = Int(Analysis.windowHopBeats * beatFrames)
        let windows = 21
        let frames = winFrames + hopFrames * (windows - 1)

        print("  truth   noise   norm       recovered(median)  CoV     strength(median)")
        for truth in [1.0, 2.0, 4.0] {
            for noise in [Float(0), 0.3, 1.0] {
                let env = synthetic(periodBeats: truth, beatFrames: beatFrames,
                                    frames: frames, noise: noise, seed: 42)
                for norm in [Periods.Norm.biased, .unbiased] {
                    var got: [Double] = [], strength: [Double] = []
                    var start = 0
                    while start + winFrames <= frames {
                        if let e = Periods.estimate(env: env[start..<(start + winFrames)],
                                                    beatFrames: beatFrames, norm: norm) {
                            got.append(e.beats); strength.append(e.strength)
                        }
                        start += hopFrames
                    }
                    print(String(format: "  %-7.1f %-7.1f %-10@ %-18.3f %-7.3f %.3f",
                                 truth, Double(noise),
                                 (norm == .biased ? "biased" : "unbiased") as NSString,
                                 Stats.median(got), Stats.cov(got), Stats.median(strength)))
                }
            }
        }
        superimposed(beatFrames: beatFrames, winFrames: winFrames,
                     hopFrames: hopFrames, frames: frames)
    }

    /// Two superimposed periodicities: a hit every beat with every 4th hit
    /// accented. Real drum programming looks like this, and "the dominant
    /// period" is genuinely ambiguous — 1 beat and 4 beats are both correct
    /// answers to different questions.
    ///
    /// This separates two readings of F1's CoV 0.775: "the band has no stable
    /// period" versus "the band has more than one, and a single-lag argmax
    /// reports whichever wins this window". The second is a modelling limit of
    /// Stage 1 as specified, not noise in the music.
    static func superimposed(beatFrames: Double, winFrames: Int, hopFrames: Int, frames: Int) {
        print("\n  superimposed periodicities (hit every 1 beat, accent every 4):")
        print("  accent   recovered(median)  CoV     strength(median)")
        let release = Float(exp(-(1024.0 / 44100.0) / 0.30))
        for accent in [Float(0.4), 0.7, 1.0] {
            var env = [Float](repeating: 0, count: frames)
            var held: Float = 0
            for m in 0..<frames {
                let beatPhase = Double(m).truncatingRemainder(dividingBy: beatFrames)
                let beatIndex = Int(Double(m) / beatFrames)
                var hit: Float = 0
                if beatPhase < 1 { hit = beatIndex % 4 == 0 ? 1.0 : accent }
                held = max(hit, held * release)
                env[m] = held
            }
            var got: [Double] = [], strength: [Double] = []
            var start = 0
            while start + winFrames <= frames {
                if let e = Periods.estimate(env: env[start..<(start + winFrames)],
                                            beatFrames: beatFrames) {
                    got.append(e.beats); strength.append(e.strength)
                }
                start += hopFrames
            }
            print(String(format: "  %-8.1f %-18.3f %-7.3f %.3f",
                         Double(accent), Stats.median(got), Stats.cov(got), Stats.median(strength)))
        }
    }
}

/// Deterministic PRNG so the control reproduces exactly.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) * 0x1p-53 }
}
