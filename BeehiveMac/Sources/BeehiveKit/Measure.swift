import Accelerate
import Foundation

/// Measurement analysis: stimulus generation, FFT cross-correlation and
/// deconvolution, and the room metrics derived from an impulse response.
///
/// This file is pure signal processing on arrays — no audio device, no clock.
/// That split is deliberate: everything here is verifiable against synthetic
/// input with a known answer (`beehive-cli --measure-selftest`), so when a
/// physical measurement looks wrong we can tell an analysis bug from a cabling
/// or clocking problem.
///
/// Nothing in this file produces a number that may be quoted as a measurement
/// of this engine or of a room; it produces the *analysis* that turns a capture
/// into such a number. See docs/measurements/README.md.
public enum Measure {

    // ---- stimulus ----------------------------------------------------------

    /// Single-sample unit impulse, `pad` frames of silence, then 1.0, then
    /// silence out to `frames`. The pad lets the device settle before the event.
    public static func impulse(frames: Int, pad: Int, amplitude: Float = 0.5) -> [Float] {
        var x = [Float](repeating: 0, count: frames)
        if pad >= 0 && pad < frames { x[pad] = amplitude }
        return x
    }

    /// Linear chirp, `f0` → `f1` over `durationS`, Hann-faded at both ends.
    /// The fallback stimulus when a single impulse is too low-SNR to correlate.
    public static func linearChirp(f0: Double, f1: Double, durationS: Double,
                                   sr: Double, amplitude: Float = 0.5) -> [Float] {
        let n = max(1, Int(durationS * sr))
        let k = (f1 - f0) / durationS
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let phase = 2 * Double.pi * (f0 * t + 0.5 * k * t * t)
            x[i] = Float(sin(phase)) * amplitude
        }
        applyEdgeFade(&x, fadeFrames: min(n / 8, Int(0.001 * sr)))
        return x
    }

    /// Exponential (logarithmic) sine sweep — Farina's method.
    ///
    ///   x(t) = sin( 2π f0 T / ln(f1/f0) · ( e^{ t ln(f1/f0) / T } − 1 ) )
    ///
    /// Its inverse filter is the time-reversed sweep with a −6 dB/oct amplitude
    /// correction, which makes the deconvolution yield the linear impulse
    /// response with the harmonic distortion products pushed to *negative* time
    /// (they arrive before the linear peak and are simply cut away).
    public static func expSineSweep(f0: Double = 20, f1: Double = 20_000,
                                    durationS: Double = 10, sr: Double,
                                    amplitude: Float = 0.5) -> [Float] {
        let n = max(1, Int(durationS * sr))
        let T = Double(n) / sr
        let lnK = log(f1 / f0)
        let a = 2 * Double.pi * f0 * T / lnK
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            x[i] = Float(sin(a * (exp(t * lnK / T) - 1))) * amplitude
        }
        // fade the ends: a hard start/stop on a 20 Hz sweep is a click, and the
        // click lands in the IR as a spurious pre-arrival
        applyEdgeFade(&x, fadeFrames: min(n / 4, Int(0.050 * sr)))
        return x
    }

    /// Analytically-derived inverse of `expSineSweep` with the same arguments:
    /// time-reversal with an exponential amplitude envelope that falls 6 dB per
    /// octave, so that sweep ⊛ inverse = delta (band-limited).
    public static func expSweepInverse(f0: Double = 20, f1: Double = 20_000,
                                       durationS: Double = 10, sr: Double) -> [Float] {
        let sweep = expSineSweep(f0: f0, f1: f1, durationS: durationS, sr: sr, amplitude: 1)
        let n = sweep.count
        let T = Double(n) / sr
        let lnK = log(f1 / f0)
        var inv = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            // Amplitude correction, -6 dB/oct. The sweep spends ~1/f time at
            // each frequency, so its energy density rises toward the low end;
            // the inverse must therefore ATTENUATE low frequencies, scaling
            // each sample by f(t)/f1 where f(t) = f0·e^{t·ln(f1/f0)/T}.
            // (Scaling by f0/f(t) instead — the intuitive-looking sign — boosts
            // the lows and smears the deconvolved delta into a several-ms
            // blob, which then biases every decay time fitted from it.)
            let env = exp((t / T - 1) * lnK)
            inv[n - 1 - i] = sweep[i] * Float(env)
        }
        // normalise so the deconvolved delta has unit peak regardless of length
        let norm = sqrt(inv.reduce(0) { $0 + Double($1) * Double($1) })
        if norm > 0 { for i in 0..<n { inv[i] /= Float(norm) } }
        return inv
    }

    private static func applyEdgeFade(_ x: inout [Float], fadeFrames: Int) {
        let f = max(0, min(fadeFrames, x.count / 2))
        guard f > 1 else { return }
        for i in 0..<f {
            let w = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(f - 1)))
            x[i] *= w
            x[x.count - 1 - i] *= w
        }
    }

    // ---- FFT convolution ----------------------------------------------------

    /// Linear convolution of `a` and `b` via vDSP's packed real FFT.
    ///
    /// Scaling note: `vDSP_fft_zrip` forward returns 2× the true DFT, and its
    /// inverse returns N× the true inverse, so a two-transform convolution
    /// round-trip carries a factor of 4N. The 1/(4N) below undoes exactly that
    /// — and `--measure-selftest` convolves against a delta to prove it, rather
    /// than trusting the arithmetic.
    public static func convolve(_ a: [Float], _ b: [Float]) -> [Float] {
        let outLen = a.count + b.count - 1
        guard outLen > 0 else { return [] }
        let log2n = vDSP_Length(ceil(log2(Double(outLen))))
        let n = 1 << Int(log2n)
        let half = n / 2

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let aPad = a + [Float](repeating: 0, count: n - a.count)
        let bPad = b + [Float](repeating: 0, count: n - b.count)

        var aRe = [Float](repeating: 0, count: half), aIm = [Float](repeating: 0, count: half)
        var bRe = [Float](repeating: 0, count: half), bIm = [Float](repeating: 0, count: half)
        var out = [Float](repeating: 0, count: n)

        aRe.withUnsafeMutableBufferPointer { aRe in
        aIm.withUnsafeMutableBufferPointer { aIm in
        bRe.withUnsafeMutableBufferPointer { bRe in
        bIm.withUnsafeMutableBufferPointer { bIm in
            var aSplit = DSPSplitComplex(realp: aRe.baseAddress!, imagp: aIm.baseAddress!)
            var bSplit = DSPSplitComplex(realp: bRe.baseAddress!, imagp: bIm.baseAddress!)

            aPad.withUnsafeBufferPointer {
                $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &aSplit, 1, vDSP_Length(half))
                }
            }
            bPad.withUnsafeBufferPointer {
                $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &bSplit, 1, vDSP_Length(half))
                }
            }

            vDSP_fft_zrip(setup, &aSplit, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_fft_zrip(setup, &bSplit, 1, log2n, FFTDirection(FFT_FORWARD))

            // bin 0 is the packed (DC, Nyquist) pair — it is two *real* values,
            // not a complex number, so it must be multiplied element-wise and
            // excluded from the complex multiply below.
            let dc = aSplit.realp[0] * bSplit.realp[0]
            let nyq = aSplit.imagp[0] * bSplit.imagp[0]

            var prodRe = [Float](repeating: 0, count: half)
            var prodIm = [Float](repeating: 0, count: half)
            prodRe.withUnsafeMutableBufferPointer { pRe in
            prodIm.withUnsafeMutableBufferPointer { pIm in
                var prod = DSPSplitComplex(realp: pRe.baseAddress!, imagp: pIm.baseAddress!)
                var aTail = DSPSplitComplex(realp: aSplit.realp + 1, imagp: aSplit.imagp + 1)
                var bTail = DSPSplitComplex(realp: bSplit.realp + 1, imagp: bSplit.imagp + 1)
                var pTail = DSPSplitComplex(realp: prod.realp + 1, imagp: prod.imagp + 1)
                vDSP_zvmul(&aTail, 1, &bTail, 1, &pTail, 1, vDSP_Length(half - 1), 1)
                prod.realp[0] = dc
                prod.imagp[0] = nyq

                vDSP_fft_zrip(setup, &prod, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&prod, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }}
        }}}}

        var scale = Float(1.0 / (4.0 * Double(n)))
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return Array(out[0..<outLen])
    }

    /// Cross-correlation of `x` against reference `ref`, computed as
    /// convolution with the time-reversed reference.
    public static func crossCorrelate(_ x: [Float], ref: [Float]) -> [Float] {
        convolve(x, ref.reversed())
    }

    // ---- lag estimation ------------------------------------------------------

    public struct Lag {
        /// Peak lag in whole samples.
        public let samples: Int
        /// Parabolically interpolated peak, for sub-sample resolution.
        public let subSample: Double
        /// Correlation peak value, and the next-highest peak outside a guard
        /// band — their ratio is how much to trust this lag.
        public let peak: Float
        public let runnerUp: Float
        public var peakRatio: Double { runnerUp > 0 ? Double(peak / runnerUp) : .infinity }
        public var milliseconds: (Double) -> Double { { sr in self.subSample / sr * 1000 } }
    }

    /// Locate the dominant lag of `captured` relative to `emitted`.
    /// Only non-negative lags are considered: the capture cannot precede the
    /// emission, so a negative peak means the correlation is meaningless.
    public static func estimateLag(captured: [Float], emitted: [Float],
                                   guardSamples: Int = 32) -> Lag? {
        guard !captured.isEmpty, !emitted.isEmpty else { return nil }
        let xc = crossCorrelate(captured, ref: emitted)
        // convolution with the reversed reference puts lag 0 at index len(ref)-1
        let zero = emitted.count - 1
        guard xc.count > zero else { return nil }

        var bestIdx = zero
        var best: Float = -.infinity
        for i in zero..<xc.count where abs(xc[i]) > best {
            best = abs(xc[i]); bestIdx = i
        }
        var runner: Float = 0
        for i in zero..<xc.count where abs(i - bestIdx) > guardSamples {
            runner = max(runner, abs(xc[i]))
        }

        // parabolic interpolation around the peak for sub-sample resolution
        var sub = Double(bestIdx - zero)
        if bestIdx > 0, bestIdx + 1 < xc.count {
            let ym1 = Double(abs(xc[bestIdx - 1]))
            let y0 = Double(abs(xc[bestIdx]))
            let yp1 = Double(abs(xc[bestIdx + 1]))
            let denom = ym1 - 2 * y0 + yp1
            if abs(denom) > 1e-20 { sub += 0.5 * (ym1 - yp1) / denom }
        }
        return Lag(samples: bestIdx - zero, subSample: sub, peak: best, runnerUp: runner)
    }

    // ---- statistics -----------------------------------------------------------

    public struct Stats {
        public let n: Int, median: Double, min: Double, max: Double, stddev: Double
        public init(_ xs: [Double]) {
            n = xs.count
            guard !xs.isEmpty else { median = 0; min = 0; max = 0; stddev = 0; return }
            let s = xs.sorted()
            median = s.count % 2 == 1 ? s[s.count / 2]
                                      : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
            min = s.first!; max = s.last!
            let mean = xs.reduce(0, +) / Double(xs.count)
            stddev = xs.count < 2 ? 0
                : sqrt(xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count - 1))
        }
    }

    // ---- room metrics ----------------------------------------------------------

    public struct RoomMetrics {
        public let sampleRate: Double
        public let directIndex: Int
        public let noiseFloorDB: Double
        public let truncationIndex: Int
        public let decayRangeDB: Double
        public let t20: Double?
        public let t30: Double?
        public let c50: Double
        public let d50: Double
        public let drr: Double
        /// Why a null T20/T30 is null — printed next to the number, never hidden.
        public let notes: [String]
    }

    /// Schroeder backward integration with an explicit noise-floor truncation.
    ///
    /// T30 is meaningless if the decay never clears the noise floor by 35 dB
    /// (5 dB head start + 30 dB of slope), and T20 needs 25 dB. Rather than
    /// return a confident-looking number from a decay that is really noise,
    /// this returns nil for those and says so in `notes`.
    public static func roomMetrics(ir: [Float], sr: Double) -> RoomMetrics {
        var notes: [String] = []
        guard ir.count > 16 else {
            return RoomMetrics(sampleRate: sr, directIndex: 0, noiseFloorDB: 0,
                               truncationIndex: 0, decayRangeDB: 0, t20: nil, t30: nil,
                               c50: 0, d50: 0, drr: 0, notes: ["IR too short to analyse"])
        }

        // direct sound = the peak
        var direct = 0
        var peak: Float = 0
        for (i, v) in ir.enumerated() where abs(v) > peak { peak = abs(v); direct = i }

        let energy = ir.map { Double($0) * Double($0) }
        let peakE = energy[direct]

        // noise floor: mean energy of the last 10% of the tail
        let tailStart = max(direct + 1, ir.count - ir.count / 10)
        let tail = Array(energy[tailStart...])
        let noiseE = tail.isEmpty ? 0 : tail.reduce(0, +) / Double(tail.count)
        let noiseDB = 10 * log10(max(noiseE, 1e-300) / max(peakE, 1e-300))

        // truncation: last index whose smoothed energy still stands 5 dB above
        // the noise floor. Integrating past this point integrates noise, which
        // bends the Schroeder curve flat and inflates T30.
        let threshold = noiseE * pow(10.0, 5.0 / 10.0)
        var truncation = ir.count - 1
        let win = max(1, Int(sr * 0.001))
        var i = direct
        var runIdx = ir.count - 1
        var smoothed = 0.0
        while i + win <= ir.count {
            smoothed = energy[i..<(i + win)].reduce(0, +) / Double(win)
            if smoothed < threshold { runIdx = i; break }
            i += win
        }
        truncation = max(direct + win, min(runIdx, ir.count - 1))
        if truncation >= ir.count - win {
            notes.append("decay never reached noise floor + 5 dB; integrated to end of IR")
        }

        // Schroeder backward integration over [direct, truncation]
        let seg = Array(energy[direct...truncation])
        var cum = [Double](repeating: 0, count: seg.count)
        var acc = 0.0
        for k in stride(from: seg.count - 1, through: 0, by: -1) {
            acc += seg[k]
            cum[k] = acc
        }
        let total = max(cum.first ?? 0, 1e-300)
        let curve = cum.map { 10 * log10(max($0, 1e-300) / total) }
        let decayRange = -(curve.last ?? 0)

        /// Least-squares fit of the Schroeder curve between two dB levels,
        /// extrapolated to 60 dB. Returns nil — with the reason — unless the
        /// segment is both long enough and actually straight.
        ///
        /// Straightness is the test that catches the case a noise-floor check
        /// alone misses: a clean direct arrival sitting on flat noise has a
        /// large peak-to-noise ratio, but its Schroeder curve plunges in a
        /// couple of samples and then lies flat. That is not a decay, and
        /// fitting it yields a confident reverberation time for a room that was
        /// never measured. ISO 3382 calls the same quantity non-linearity.
        func slopeTime(from d1: Double, to d2: Double, label: String) -> Double? {
            guard let i1 = curve.firstIndex(where: { $0 <= d1 }),
                  let i2 = curve.firstIndex(where: { $0 <= d2 }), i2 > i1 else {
                notes.append("\(label) unavailable: curve never crosses \(Int(d2)) dB")
                return nil
            }
            let spanS = Double(i2 - i1) / sr
            let minSpanS = 0.020
            guard i2 - i1 >= 16, spanS >= minSpanS else {
                notes.append("\(label) unavailable: the \(Int(d1))…\(Int(d2)) dB segment lasts "
                             + "only \(String(format: "%.1f", spanS * 1000)) ms "
                             + "(\(i2 - i1) samples) — a step, not a decay")
                return nil
            }
            let xs = (i1...i2).map { Double($0) / sr }
            let ys = (i1...i2).map { curve[$0] }
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var num = 0.0, den = 0.0, ssTot = 0.0
            for k in 0..<xs.count {
                num += (xs[k] - mx) * (ys[k] - my)
                den += (xs[k] - mx) * (xs[k] - mx)
                ssTot += (ys[k] - my) * (ys[k] - my)
            }
            guard den > 0, num < 0 else {
                notes.append("\(label) unavailable: the fitted slope is not a decay")
                return nil
            }
            let slope = num / den            // dB per second, negative
            let intercept = my - slope * mx
            var ssRes = 0.0
            for k in 0..<xs.count {
                let pred = slope * xs[k] + intercept
                ssRes += (ys[k] - pred) * (ys[k] - pred)
            }
            let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0
            guard r2 >= 0.95 else {
                notes.append("\(label) unavailable: decay is not exponential "
                             + "(fit r² = \(String(format: "%.3f", r2)), needs ≥ 0.95)")
                return nil
            }
            return -60.0 / slope
        }

        // Two independent limits, and the smaller one governs:
        //   - how far the Schroeder curve actually falls, and
        //   - how far the peak stands above the noise floor.
        // The second matters on its own: an IR that is a clean direct arrival
        // sitting on flat noise produces a steep-looking Schroeder curve with
        // no decay in it at all, and fitting that yields a confident, wrong
        // reverberation time. Peak-to-noise is what says whether there is a
        // decay to measure.
        var t20: Double?, t30: Double?
        let usableDB = Swift.min(decayRange, -noiseDB)
        if usableDB >= 25 { t20 = slopeTime(from: -5, to: -25, label: "T20") }
        else { notes.append("T20 unavailable: only \(String(format: "%.1f", usableDB)) dB usable "
                            + "(decay range \(String(format: "%.1f", decayRange)) dB, "
                            + "noise floor \(String(format: "%.1f", noiseDB)) dB); needs 25 dB") }
        if usableDB >= 35 { t30 = slopeTime(from: -5, to: -35, label: "T30") }
        else { notes.append("T30 unavailable: only \(String(format: "%.1f", usableDB)) dB usable "
                            + "(decay range \(String(format: "%.1f", decayRange)) dB, "
                            + "noise floor \(String(format: "%.1f", noiseDB)) dB); needs 35 dB") }

        // C50 / D50: 50 ms split measured from the direct arrival
        let split = direct + Int(0.050 * sr)
        let early = energy[direct..<min(split, energy.count)].reduce(0, +)
        let late = split < energy.count ? energy[split...].reduce(0, +) : 0
        let c50 = 10 * log10(max(early, 1e-300) / max(late, 1e-300))
        let d50 = early / max(early + late, 1e-300) * 100

        // direct-to-reverberant: direct window is ±2.5 ms around the peak
        let half = Int(0.0025 * sr)
        let dStart = max(0, direct - half), dEnd = min(energy.count, direct + half)
        let directE = energy[dStart..<dEnd].reduce(0, +)
        let revE = dEnd < energy.count ? energy[dEnd...].reduce(0, +) : 0
        let drr = 10 * log10(max(directE, 1e-300) / max(revE, 1e-300))

        return RoomMetrics(sampleRate: sr, directIndex: direct, noiseFloorDB: noiseDB,
                           truncationIndex: truncation, decayRangeDB: decayRange,
                           t20: t20, t30: t30, c50: c50, d50: d50, drr: drr, notes: notes)
    }

    // ---- 32-bit float WAV -------------------------------------------------------

    /// Minimal 32-bit float mono WAV writer. The IR is the primary artifact of a
    /// room measurement, so it is written losslessly at analysis precision.
    public static func writeWAVFloat32(_ samples: [Float], sr: Double, to url: URL) throws {
        let dataBytes = samples.count * 4
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3)                                  // IEEE float
        u16(1)                                  // mono
        u32(UInt32(sr))
        u32(UInt32(sr) * 4)                     // byte rate
        u16(4)                                  // block align
        u16(32)                                 // bits
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count).withMemoryRebound(to: UInt8.self) { Data($0) }) }
        try d.write(to: url)
    }

    // ---- run records --------------------------------------------------------------

    /// Every measurement writes one dated JSON file under docs/measurements/, so
    /// numbers are diffable and carry their conditions. Prose never carries a
    /// number that isn't in one of these files.
    public static func writeRun(_ object: [String: Any], kind: String,
                                dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HHmmss"
        fmt.timeZone = TimeZone.current
        let name = "\(fmt.string(from: Date()))-\(kind).json"
        let url = dir.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        return url
    }
}
