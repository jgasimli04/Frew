import BeehiveKit
import Foundation

/// One track, decoded once, taken through Stage 1 and Stage 2.
struct TrackAnalysis {
    let label: String
    let sr: Double
    let durationS: Double
    let bpm: Double
    let bpmConfidence: Double
    let fps: Double
    let beatFrames: Double
    /// `[6][frames]`.
    let envelopes: [[Float]]
    /// Per band, the period estimate from each analysis window (dropped windows
    /// absent), in beats.
    let windowPeriods: [[Double]]
    /// Per band, the median across windows — the radius fed to the octahedron.
    let periods: [Double]
    /// Per band, std/mean across windows. This is F1.
    let cov: [Double]
    let deficitsDeg: [Double]
    let descartesResidual: Double
}

enum Analysis {

    /// `Engine.Params` defaults, so the spike frames audio the way the rest of
    /// the codebase does.
    static let nFFT = 2048
    static let hop = 1024
    /// Beats per bar, matching `Engine.Params.B`.
    static let B = 4

    /// F1's sliding window: 32 beats (8 bars at B=4), hopped 16 beats.
    /// 32 beats holds four repetitions of the longest period searched (8 beats),
    /// which is the fewest that gives autocorrelation anything to average over.
    static let windowBeats = 32.0
    static let windowHopBeats = 16.0

    enum Failure: Error, CustomStringConvertible {
        case bpmUnavailable(String)
        case tooShort(String)
        case bandSilent(String, Int)
        var description: String {
            switch self {
            case .bpmUnavailable(let t): return "\(t): Tempo.estimateBPM returned NaN"
            case .tooShort(let t): return "\(t): shorter than one 32-beat analysis window"
            case .bandSilent(let t, let b): return "\(t): band \(b) produced no period in any window"
            }
        }
    }

    /// Full Stage 1 + Stage 2 for already-decoded samples.
    /// `edges` is a parameter so F2 can scale them with the resample factor.
    static func analyse(mono: [Float], sr: Double, label: String,
                        edges: Bands.Edges = Bands.six,
                        bpmOverride: Double? = nil,
                        norm: Periods.Norm = .biased) throws -> TrackAnalysis {
        let spec = Envelopes.spectrogram(mono: mono, sr: sr, nFFT: nFFT, hop: hop)
        let env = Envelopes.bands(spec, edges: edges, sr: sr, hop: hop)

        let est = Tempo.estimateBPM(spec.mags, sr: sr, hop: hop)
        let bpm = bpmOverride ?? est.bpm
        guard bpm.isFinite, bpm > 0 else { throw Failure.bpmUnavailable(label) }

        let beatFrames = 60.0 / bpm * spec.fps
        let winFrames = Int((windowBeats * beatFrames).rounded())
        let hopFrames = max(1, Int((windowHopBeats * beatFrames).rounded()))
        guard spec.frames > winFrames else { throw Failure.tooShort(label) }

        var windowPeriods = [[Double]](repeating: [], count: edges.count)
        var start = 0
        while start + winFrames <= spec.frames {
            for b in 0..<edges.count {
                if let e = Periods.estimate(env: env[b][start..<(start + winFrames)],
                                            beatFrames: beatFrames, norm: norm) {
                    windowPeriods[b].append(e.beats)
                }
            }
            start += hopFrames
        }

        for b in 0..<edges.count where windowPeriods[b].isEmpty {
            throw Failure.bandSilent(label, b)
        }

        // Median, not mean: the estimator's known failure is octave jumps, which
        // are large one-sided outliers. The median keeps a minority of flipped
        // windows from moving the radius; the mean would not. F1's CoV is
        // reported on the raw per-window values, so this choice cannot hide the
        // jitter it is robust to.
        let periods = windowPeriods.map { Stats.median($0) }
        let cov = windowPeriods.map { Stats.cov($0) }
        let result = Octahedron.deficits(radii: periods)

        return TrackAnalysis(
            label: label, sr: sr, durationS: Double(mono.count) / sr,
            bpm: bpm, bpmConfidence: est.confidence,
            fps: spec.fps, beatFrames: beatFrames,
            envelopes: env, windowPeriods: windowPeriods, periods: periods,
            cov: cov, deficitsDeg: result.degrees, descartesResidual: result.residual)
    }

    /// Varispeed resample by linear interpolation: `factor > 1` shortens the
    /// signal, so tempo and every spectral component scale by `factor`.
    ///
    /// Linear interpolation, not a windowed-sinc: this is a test fixture, and
    /// its interpolation error is broadband and low-level relative to the band
    /// energies being summed. Stated as a caveat in RESULTS.md rather than
    /// hidden — a sinc resampler would remove the caveat and is the obvious
    /// thing to try if F2's residual comes out near the noise floor.
    static func varispeed(_ x: [Float], factor: Double) -> [Float] {
        guard factor > 0, x.count > 1 else { return x }
        let n = Int(Double(x.count) / factor)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let s = Double(i) * factor
            let i0 = min(Int(s), x.count - 1)
            let i1 = min(i0 + 1, x.count - 1)
            let u = Float(s - Double(i0))
            out[i] = x[i0] * (1 - u) + x[i1] * u
        }
        return out
    }

    /// The stdout line the prompt asks for: six periods and six deficits per
    /// track, printed as the track loads.
    static func report(_ a: TrackAnalysis) {
        let names = Bands.six.map(\.name)
        print("  \(a.label)")
        print(String(format: "    %.1f s, sr %.0f, bpm %.2f (conf %.3f), %.1f frames/beat",
                     a.durationS, a.sr, a.bpm, a.bpmConfidence, a.beatFrames))
        print("    periods (beats):  " + zip(names, a.periods)
            .map { String(format: "%@=%.3f", $0.0, $0.1) }.joined(separator: "  "))
        print("    deficits (deg):   " + zip(names, a.deficitsDeg)
            .map { String(format: "%@=%.2f", $0.0, $0.1) }.joined(separator: "  "))
        print("    CoV per band:     " + zip(names, a.cov)
            .map { String(format: "%@=%.3f", $0.0, $0.1) }.joined(separator: "  "))
        print(String(format: "    windows: %d,  Descartes residual: %.3e",
                     a.windowPeriods[0].count, a.descartesResidual))
    }
}
