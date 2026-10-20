import BeehiveKit
import CBeeMeasure
import Foundation

/// Analysis-path verification for the measurement harness.
///
/// IMPORTANT: nothing here measures this engine or any room. It feeds the
/// analysis synthetic input whose answer is known exactly, and checks the
/// analysis recovers it. It is the gate that must pass before a physical
/// measurement is worth trusting — when a loopback number later looks wrong,
/// these tests are what separate "the analysis is broken" from "the cable,
/// the clock or the gain is wrong".
func measureSelftest() {
    var failures = 0
    func check(_ cond: Bool, _ msg: String) {
        print((cond ? "  PASS " : "  FAIL ") + msg)
        if !cond { failures += 1 }
    }

    let sr = 48_000.0
    print("measurement analysis self-test (synthetic input, no audio device)")

    // 1. FFT convolution scaling — convolving with a unit delta must return the
    //    input unchanged. This is what pins the 1/(4N) scale factor.
    do {
        let x = Measure.linearChirp(f0: 100, f1: 8000, durationS: 0.05, sr: sr)
        var delta = [Float](repeating: 0, count: 8); delta[0] = 1
        let y = Measure.convolve(x, delta)
        var maxErr: Float = 0
        for i in 0..<x.count { maxErr = max(maxErr, abs(y[i] - x[i])) }
        check(maxErr < 1e-4, "convolve(x, δ) == x  (max error \(String(format: "%.2e", maxErr)))")
    }

    // 2. Known integer delay — the core of Target 1. An exact sample count in
    //    must come back out, including at low SNR.
    do {
        let emitted = Measure.linearChirp(f0: 50, f1: 12_000, durationS: 0.010, sr: sr)
        for delay in [1, 37, 512, 4096] {
            var captured = [Float](repeating: 0, count: delay + emitted.count + 2048)
            for i in 0..<emitted.count { captured[delay + i] = emitted[i] * 0.25 }
            guard let lag = Measure.estimateLag(captured: captured, emitted: emitted) else {
                check(false, "lag recovery at \(delay) samples: estimator returned nil"); continue
            }
            check(lag.samples == delay,
                  "lag recovery: injected \(delay), recovered \(lag.samples) samples "
                  + "(sub-sample \(String(format: "%.3f", lag.subSample)), peak/runner-up "
                  + String(format: "%.1f", lag.peakRatio) + ")")
        }
        // with noise at roughly -20 dB relative to the signal
        let delay = 733
        var captured = [Float](repeating: 0, count: delay + emitted.count + 4096)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<captured.count {
            captured[i] = Float.random(in: -0.025...0.025, using: &rng)
        }
        for i in 0..<emitted.count { captured[delay + i] += emitted[i] * 0.25 }
        let lag = Measure.estimateLag(captured: captured, emitted: emitted)
        check(lag?.samples == delay,
              "lag recovery with noise at -20 dB: injected \(delay), recovered "
              + "\(lag.map { String($0.samples) } ?? "nil")")
    }

    // 3. Farina sweep ⊛ its inverse must collapse to a delta. If this fails the
    //    IR tool cannot distinguish a room from its own stimulus.
    do {
        let sweep = Measure.expSineSweep(f0: 20, f1: 20_000, durationS: 1.0, sr: sr)
        let inv = Measure.expSweepInverse(f0: 20, f1: 20_000, durationS: 1.0, sr: sr)
        let d = Measure.convolve(sweep, inv)
        var peak: Float = 0, peakIdx = 0
        for (i, v) in d.enumerated() where abs(v) > peak { peak = abs(v); peakIdx = i }
        // energy outside a ±1 ms window around the peak, relative to the peak
        let w = Int(0.001 * sr)
        var sideEnergy = 0.0, peakEnergy = 0.0
        for (i, v) in d.enumerated() {
            let e = Double(v) * Double(v)
            if abs(i - peakIdx) <= w { peakEnergy += e } else { sideEnergy += e }
        }
        let sideDB = 10 * log10(max(sideEnergy, 1e-300) / max(peakEnergy, 1e-300))
        check(sideDB < -20,
              "sweep ⊛ inverse is a delta: side-lobe energy \(String(format: "%.1f", sideDB)) dB "
              + "below the peak (peak at sample \(peakIdx))")
    }

    // 4. Synthetic room with a KNOWN T60 — the end-to-end IR path: build a room,
    //    play a sweep "through" it by convolution, deconvolve, and check the
    //    recovered decay time matches what was built in.
    do {
        let knownT60 = 0.8
        let durS = 2.0
        let irLen = Int(durS * sr)
        let direct = Int(0.005 * sr)
        var room = [Float](repeating: 0, count: irLen)
        var rng = SystemRandomNumberGenerator()
        room[direct] = 1.0
        let k = 6.9078 / knownT60          // amplitude decay: -60 dB at T60
        for i in (direct + 1)..<irLen {
            let t = Double(i - direct) / sr
            let env = exp(-k * t)
            room[i] = Float(Double.random(in: -1...1, using: &rng) * env * 0.5)
        }

        let sweep = Measure.expSineSweep(f0: 20, f1: 20_000, durationS: 3.0, sr: sr)
        let inv = Measure.expSweepInverse(f0: 20, f1: 20_000, durationS: 3.0, sr: sr)
        let played = Measure.convolve(sweep, room)
        let deconv = Measure.convolve(played, inv)

        // the linear IR sits at the inverse filter's group delay (= sweep length)
        var peak: Float = 0, peakIdx = 0
        for (i, v) in deconv.enumerated() where abs(v) > peak { peak = abs(v); peakIdx = i }
        let start = max(0, peakIdx - direct)
        let ir = Array(deconv[start..<min(start + irLen, deconv.count)])

        let m = Measure.roomMetrics(ir: ir, sr: sr)
        let recovered = m.t30 ?? m.t20
        let label = m.t30 != nil ? "T30" : "T20"
        if let r = recovered {
            let errPct = abs(r - knownT60) / knownT60 * 100
            check(errPct < 10,
                  "synthetic room: built T60 = \(knownT60) s, recovered \(label) = "
                  + String(format: "%.3f", r) + " s (\(String(format: "%.1f", errPct))% error)")
        } else {
            check(false, "synthetic room: no decay time recovered — \(m.notes.joined(separator: "; "))")
        }
        check(abs(m.directIndex - direct) <= 2,
              "synthetic room: direct arrival at sample \(m.directIndex) (built at \(direct))")
        print("       C50 \(String(format: "%.1f", m.c50)) dB · D50 "
              + String(format: "%.1f", m.d50) + "% · DRR "
              + String(format: "%.1f", m.drr) + " dB · noise floor "
              + String(format: "%.1f", m.noiseFloorDB) + " dB")
    }

    // 5. A decay that does NOT clear the noise floor must refuse to report T30
    //    rather than return a confident wrong number.
    do {
        let n = Int(sr)
        var ir = [Float](repeating: 0, count: n)
        var rng = SystemRandomNumberGenerator()
        ir[0] = 1.0
        for i in 1..<n { ir[i] = Float(Double.random(in: -1...1, using: &rng) * 0.02) }
        let m = Measure.roomMetrics(ir: ir, sr: sr)
        check(m.t30 == nil, "noise-dominated IR: T30 refused, not faked "
              + "(decay range \(String(format: "%.1f", m.decayRangeDB)) dB)")
    }

    // 6. The lock-free capture ring: integrity, and that overruns are counted
    //    rather than silently dropping capture on the floor.
    do {
        guard let ring = bm_ring_new(1024) else {
            check(false, "ring allocation"); return
        }
        defer { bm_ring_free(ring) }
        var wrote = [Float](repeating: 0, count: 512)
        for i in 0..<512 { wrote[i] = Float(i) }
        let w = bm_ring_write(ring, wrote, 512)
        var read = [Float](repeating: 0, count: 512)
        let r = bm_ring_read(ring, &read, 512)
        check(w == 512 && r == 512 && read == wrote, "ring round-trips 512 frames intact")

        // overflow: capacity is 1024, minus one reserved slot
        bm_ring_reset(ring)
        var big = [Float](repeating: 1, count: 2048)
        _ = bm_ring_write(ring, &big, 2048)
        check(bm_ring_overruns(ring) > 0,
              "ring counts overruns on overflow (\(bm_ring_overruns(ring)) frames dropped)")
    }

    // 7. xrun detection on a fabricated timestamp gap.
    do {
        var x = BMXrun(); bm_xrun_reset(&x)
        bm_xrun_observe(&x, 0, 256)
        bm_xrun_observe(&x, 256, 256)
        bm_xrun_observe(&x, 512, 256)
        check(x.discontinuities == 0, "xrun detector: contiguous timestamps are clean")
        bm_xrun_observe(&x, 1024, 256)      // a 256-frame hole
        check(x.discontinuities == 1, "xrun detector: catches a dropped buffer")
    }

    print(failures == 0
          ? "  analysis self-test passed — the analysis is sound; no latency or room "
            + "number has been measured by this run"
          : "  \(failures) analysis check(s) FAILED — do not trust any measurement "
            + "until these pass")
    if failures > 0 { exit(1) }
}
