import Accelerate
import BeehiveKit
import Foundation

/// Spectrogram + band envelopes.
///
/// `BeehiveKit.BandEnvelopes` is the reference for this file and is reused
/// verbatim wherever the spike does not need to vary something. Two things are
/// varied here, both forced by the falsifiers:
///
///  1. **Six bands, not five.** `BandEnvelopes.edges` has five. The octahedron
///     needs six radii. See `Bands.six` for the split and its justification.
///  2. **Parametrised edges.** F2 resamples the audio, which moves spectral
///     content across fixed edges; testing tempo invariance without moving the
///     edges by the same factor cannot separate "not tempo-invariant" from
///     "the test moved the content out of the band". `BandEnvelopes.edges` is a
///     `static let`, so the spike needs its own edge-taking path.
///
/// The normalisation (98th-percentile) and release constant (0.30 s peak-hold)
/// are copied from `BandEnvelopes.init` deliberately so the sixth band is
/// commensurable with the five. `Envelopes.selfCheck` asserts this file
/// reproduces `BandEnvelopes.bands` exactly on the five canonical edges — if
/// that check fails, this file has drifted from the reference and every number
/// downstream is suspect.
enum Bands {

    typealias Edges = [(name: String, lo: Float, hi: Float)]

    /// The five canonical edges, mirrored from `BandEnvelopes.edges`.
    static let five: Edges = BandEnvelopes.edges

    /// Six disjoint bands: `BandEnvelopes.edges` with the mid band split at
    /// 800 Hz.
    ///
    /// Why split mid and not add a band elsewhere: 250–2000 Hz is three
    /// octaves and is the one band that reliably carries two *different*
    /// rhythmic layers — snare/clap body sits at the bottom of it, piano,
    /// guitar and vocal fundamentals at the top. Every other band in
    /// `BandEnvelopes.edges` is already about one octave-and-a-half or is
    /// bounded by physics (sub) and so does not split into two layers.
    ///
    /// Rejected alternative: `BandEnvelopes.bassDrop` as the sixth channel. It
    /// is a detector, not a band — a decaying pulse that is zero for most of a
    /// track — so its autocorrelation has no dominant period to find, and it
    /// would put a near-constant radius on one axis.
    ///
    /// To falsify the choice: move the split (600 Hz, 1 kHz) and re-run F3. If
    /// the pairwise distance structure changes materially, the sixth band is
    /// carrying an arbitrary choice rather than a rhythmic layer.
    static let six: Edges = [
        ("sub", 20, 60),
        ("low", 60, 250),
        ("midlo", 250, 800),
        ("midhi", 800, 2000),
        ("himid", 2000, 8000),
        ("hi", 8000, 20000),
    ]

    /// Edges scaled by a varispeed factor — the F2 confound fix.
    static func scaled(_ edges: Edges, by factor: Double) -> Edges {
        edges.map { ($0.name, $0.lo * Float(factor), $0.hi * Float(factor)) }
    }
}

enum Envelopes {

    struct Spectrogram {
        let mags: [[Float]]
        let freqs: [Float]
        let frames: Int
        /// Analysis frames per second: `sr / hop`.
        let fps: Double
    }

    /// One STFT pass, shared by the band envelopes and `Tempo.estimateBPM`, so
    /// the bpm the periods are expressed against comes from the same frames the
    /// periods do. `RealFFT` and `DSP.hann`/`DSP.rfftFreqs` are BeehiveKit's.
    static func spectrogram(mono: [Float], sr: Double, nFFT: Int, hop: Int) -> Spectrogram {
        let win = DSP.hann(nFFT)
        let fft = RealFFT(n: nFFT)
        let freqs = DSP.rfftFreqs(n: nFFT, sr: sr)
        let n = mono.count >= nFFT ? (mono.count - nFFT) / hop + 1 : 0

        var mags = [[Float]](repeating: [], count: n)
        var frame = [Float](repeating: 0, count: nFFT)
        for m in 0..<n {
            let start = m * hop
            frame.withUnsafeMutableBufferPointer { buf in
                mono.withUnsafeBufferPointer { src in
                    buf.baseAddress!.update(from: src.baseAddress! + start, count: nFFT)
                }
            }
            mags[m] = fft.magnitude(frame, window: win)
        }
        return Spectrogram(mags: mags, freqs: freqs, frames: n, fps: sr / Double(hop))
    }

    /// Band envelopes, `[band][frame]`, each 0…1.
    /// Same normalisation and release as `BandEnvelopes.init`; see `selfCheck`.
    static func bands(_ spec: Spectrogram, edges: Bands.Edges, sr: Double, hop: Int) -> [[Float]] {
        let n = spec.frames
        let nb = edges.count
        let ranges: [Range<Int>] = edges.map { band in
            let lo = spec.freqs.firstIndex { $0 >= band.lo } ?? spec.freqs.count
            let hi = spec.freqs.firstIndex { $0 >= band.hi } ?? spec.freqs.count
            return lo..<max(hi, lo)
        }

        var raw = [[Float]](repeating: [Float](repeating: 0, count: n), count: nb)
        for m in 0..<n {
            let mag = spec.mags[m]
            for (b, r) in ranges.enumerated() where !r.isEmpty {
                var e: Float = 0
                for k in r { e += mag[k] * mag[k] }
                raw[b][m] = sqrt(e)
            }
        }

        let release = Float(exp(-Double(hop) / sr / 0.30))
        var out = raw
        for b in 0..<nb {
            let sorted = raw[b].sorted()
            let p98 = n > 0 ? max(sorted[min(Int(Double(n) * 0.98), n - 1)], 1e-6) : 1
            var held: Float = 0
            for m in 0..<n {
                let x = min(raw[b][m] / p98, 1)
                held = max(x, held * release)
                out[b][m] = held
            }
        }
        return out
    }

    /// Max abs difference between this file's five-band output and
    /// `BandEnvelopes.bands` on the same input. Expected exactly 0.
    static func selfCheck(mono: [Float], sr: Double, nFFT: Int, hop: Int) -> Float {
        let reference = BandEnvelopes(mono: mono, sr: sr, nFFT: nFFT, hop: hop)
        let spec = spectrogram(mono: mono, sr: sr, nFFT: nFFT, hop: hop)
        let mine = bands(spec, edges: Bands.five, sr: sr, hop: hop)
        guard reference.frames == spec.frames, mine.count == reference.bands.count else {
            return .infinity
        }
        var worst: Float = 0
        for b in 0..<mine.count {
            for m in 0..<spec.frames {
                worst = max(worst, abs(mine[b][m] - reference.bands[b][m]))
            }
        }
        return worst
    }
}
