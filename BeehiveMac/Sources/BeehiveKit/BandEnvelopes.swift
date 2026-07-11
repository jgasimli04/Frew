import Accelerate
import Foundation

/// Five-band energy envelopes at the record's own frame grid (nFFT/hop), plus a
/// bass-departure detector — the pure-signal-correlation drivers for the AV
/// stage (BEEDECK_ROADMAP T2). Offline: computed once per loaded song from the
/// decoded PCM, then indexed by the playhead frame at render time, so the
/// visual signals are exactly aligned with the helix record's A/I/chroma/‖F‖.
///
/// The band split mirrors the planned 5-band isolator EQ (T4: crossovers at
/// 60 / 250 / 2000 / 8000 Hz). When the realtime EQ lands, its band taps
/// replace these offline envelopes as the stage's signal source — "the EQ
/// sends the signal to the visuals" — with the same shape, so the stage code
/// doesn't change.
public struct BandEnvelopes {
    public static let edges: [(name: String, lo: Float, hi: Float)] = [
        ("sub", 20, 60),
        ("low", 60, 250),
        ("mid", 250, 2000),
        ("himid", 2000, 8000),
        ("hi", 8000, 20000),
    ]

    public let frames: Int
    /// `[5][frames]`, each 0…1: peak-normalised, release-smoothed band level.
    public let bands: [[Float]]
    /// 0…1 per frame: "the bass just left while the top stayed" — the drop-build
    /// signal (sustained lows collapse, highs persist), decaying over ~1.5 s.
    public let bassDrop: [Float]

    /// Band levels at a frame, in `edges` order (zeros out of range).
    public func values(at frame: Int) -> [Float] {
        guard frame >= 0, frame < frames else { return [Float](repeating: 0, count: 5) }
        return bands.map { $0[frame] }
    }

    /// Band levels at a fractional frame — linearly interpolated between grid
    /// frames so display-rate rendering (ProMotion) doesn't step at the hop rate.
    public func values(at frame: Double) -> [Float] {
        guard frames > 0 else { return [Float](repeating: 0, count: 5) }
        let f = min(max(frame, 0), Double(frames - 1))
        let i = Int(f), j = min(i + 1, frames - 1)
        let u = Float(f - Double(i))
        return bands.map { $0[i] + ($0[j] - $0[i]) * u }
    }

    /// Bass-departure level at a fractional frame, same interpolation.
    public func drop(at frame: Double) -> Float {
        guard frames > 0 else { return 0 }
        let f = min(max(frame, 0), Double(frames - 1))
        let i = Int(f), j = min(i + 1, frames - 1)
        let u = Float(f - Double(i))
        return bassDrop[i] + (bassDrop[j] - bassDrop[i]) * u
    }

    public init(mono: [Float], sr: Double, nFFT: Int, hop: Int) {
        let win = DSP.hann(nFFT)
        let fft = RealFFT(n: nFFT)
        let freqs = DSP.rfftFreqs(n: nFFT, sr: sr)
        let n = mono.count >= nFFT ? (mono.count - nFFT) / hop + 1 : 0
        frames = n

        // bin ranges per band
        let ranges: [Range<Int>] = Self.edges.map { band in
            let lo = freqs.firstIndex { $0 >= band.lo } ?? freqs.count
            let hi = freqs.firstIndex { $0 >= band.hi } ?? freqs.count
            return lo..<max(hi, lo)
        }

        var raw = [[Float]](repeating: [Float](repeating: 0, count: n), count: 5)
        var frame = [Float](repeating: 0, count: nFFT)
        for m in 0..<n {
            let start = m * hop
            frame.withUnsafeMutableBufferPointer { buf in
                mono.withUnsafeBufferPointer { src in
                    buf.baseAddress!.update(from: src.baseAddress! + start, count: nFFT)
                }
            }
            let mags = fft.magnitude(frame, window: win)
            for (b, r) in ranges.enumerated() where !r.isEmpty {
                var e: Float = 0
                for k in r { e += mags[k] * mags[k] }
                raw[b][m] = sqrt(e)
            }
        }

        // per-band 98th-percentile normalisation, then a peak-hold release
        // (~0.3 s) so the meters breathe instead of flickering
        let release = Float(exp(-Double(hop) / sr / 0.30))
        var out = raw
        for b in 0..<5 {
            let sorted = raw[b].sorted()
            let p98 = n > 0 ? max(sorted[min(Int(Double(n) * 0.98), n - 1)], 1e-6) : 1
            var held: Float = 0
            for m in 0..<n {
                let x = min(raw[b][m] / p98, 1)
                held = max(x, held * release)
                out[b][m] = held
            }
        }
        bands = out

        // bass departure: lows were sustained (0.6–0.2 s ago), lows are gone
        // now, top end still alive → fire a pulse that decays over ~1.5 s
        let hopSec = Double(hop) / sr
        let past = max(Int(0.6 / hopSec), 2)
        let recent = max(Int(0.2 / hopSec), 1)
        let decay = Float(exp(-hopSec / 0.65))
        var drop = [Float](repeating: 0, count: n)
        for m in 1..<max(n, 1) {
            let bass = 0.4 * out[0][m] + 0.6 * out[1][m]
            var wasBass: Float = 0
            if m > past {
                var s: Float = 0
                for k in (m - past)..<(m - recent) { s += 0.4 * out[0][k] + 0.6 * out[1][k] }
                wasBass = s / Float(past - recent)
            }
            let topAlive = max(out[3][m], out[4][m])
            let fired: Float = (wasBass > 0.45 && bass < 0.16 && topAlive > 0.18) ? 1 : 0
            drop[m] = max(drop[m - 1] * decay, fired)
        }
        bassDrop = drop
    }
}
