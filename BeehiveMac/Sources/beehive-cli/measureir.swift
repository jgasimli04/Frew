import AVFoundation
import BeehiveKit
import CBeeMeasure
import CoreAudio
import Foundation

/// TARGET 2 — impulse response by exponential sine sweep (Farina).
///
///   beehive-cli --measure-ir [--duration 10] [--f0 20] [--f1 20000]
///                            [--mic "DPA 4006"] [--label "main room"] [--loopback]
///
/// Run it against the loopback cable FIRST. A loopback IR must be a near-delta;
/// if it is not, the chain is wrong and any room measured through that chain is
/// invalid. `--loopback` makes that check an assertion rather than a judgement
/// call: the tool fails if the IR does not collapse to a delta.
func measureIR(_ args: [String]) {
    func strArg(_ flag: String, _ dflt: String) -> String {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return dflt }
        return args[i + 1]
    }
    func dblArg(_ flag: String, _ dflt: Double) -> Double {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return dflt }
        return Double(args[i + 1]) ?? dflt
    }
    let durationS = dblArg("--duration", 10)
    let f0 = dblArg("--f0", 20)
    let f1 = dblArg("--f1", 20_000)
    let mic = strArg("--mic", "unspecified")
    let label = strArg("--label", "unlabelled")
    let isLoopback = args.contains("--loopback")

    guard let device = MeasureDevice.resolveDevice(
        allowMismatch: args.contains("--allow-clock-mismatch")) else { exit(2) }

    let deviceName = MeasureDevice.name(of: device)
    let sr = MeasureDevice.nominalSampleRate(device)
    let bufFrames = MeasureDevice.bufferFrameSize(device)
    let offset = MeasureDevice.knownOffset(device)

    print("""
    impulse response by exponential sine sweep (Farina)
      device      \(deviceName) @ \(sr) Hz, buffer \(bufFrames) frames
      sweep       \(f0)–\(f1) Hz over \(durationS) s
      mic         \(mic)
      label       \(label)\(isLoopback ? "   [LOOPBACK VALIDATION]" : "")
      \(MeasureDevice.osVersion())
    """)

    let sweep = Measure.expSineSweep(f0: f0, f1: f1, durationS: durationS, sr: sr, amplitude: 0.5)
    let inverse = Measure.expSweepInverse(f0: f0, f1: f1, durationS: durationS, sr: sr)
    // tail: room decay plus the return trip
    let tailFrames = Int(3.0 * sr)
    let emitted = sweep + [Float](repeating: 0, count: tailFrames)
    let captureFrames = emitted.count + Int(0.5 * sr)

    let rig = MeasureRig(device: device, ringCapacity: captureFrames * 2)
    rig.load(stimulus: emitted)
    do { try rig.start() } catch {
        print("engine failed to start: \(error.localizedDescription)"); exit(1)
    }
    Thread.sleep(forTimeInterval: 0.25)

    print("\n  sweeping \(String(format: "%.0f", durationS + 3)) s…")
    rig.armMeasurement()
    let armDeadline = Date().addingTimeInterval(2.0)
    while !rig.marksValid && Date() < armDeadline { usleep(500) }
    guard rig.marksValid else {
        print("  FAILED: measurement never started (no callback stamped)."); exit(1)
    }
    let captured = rig.drain(frames: captureFrames,
                             deadline: Date().addingTimeInterval(durationS + 12))
    rig.stop()

    let xruns = rig.outputXruns + rig.inputXruns
    let overruns = rig.ringOverruns
    if xruns > 0 || overruns > 0 {
        print("  DISCARDED: \(xruns) xrun(s), \(overruns) ring overrun frame(s). "
              + "A sweep with a dropout has a discontinuity that deconvolves into a "
              + "spurious arrival. Re-run; close other audio apps.")
        exit(1)
    }
    guard captured.count > sweep.count else {
        print("  FAILED: captured only \(captured.count) of \(captureFrames) frames.")
        exit(1)
    }

    let peakIn = captured.map { abs($0) }.max() ?? 0
    let peakDBFS = 20 * log10(Double(max(peakIn, 1e-10)))
    print(String(format: "  captured %d frames, peak %.1f dBFS", captured.count, peakDBFS))
    if peakDBFS > -1 { print("  warning: input is clipping — reduce gain and re-run") }
    if peakDBFS < -40 { print("  warning: input is very low — raise gain; SNR limits T30") }

    // deconvolve: capture ⊛ inverse filter. The linear IR sits at the inverse
    // filter's group delay; harmonic distortion products land BEFORE it and are
    // cut away by taking the window that starts just ahead of the linear peak.
    let deconv = Measure.convolve(captured, inverse)
    var peak: Float = 0, peakIdx = 0
    for (i, v) in deconv.enumerated() where abs(v) > peak { peak = abs(v); peakIdx = i }

    let preRoll = Int(0.005 * sr)              // keep 5 ms ahead of the direct sound
    let start = max(0, peakIdx - preRoll)
    let irLen = min(Int(4.0 * sr), deconv.count - start)
    guard irLen > Int(0.05 * sr) else {
        print("  FAILED: deconvolved IR too short to analyse."); exit(1)
    }
    var ir = Array(deconv[start..<(start + irLen)])
    // normalise to unit peak — absolute scale is meaningless here, the decay is not
    if peak > 0 { for i in 0..<ir.count { ir[i] /= peak } }

    let m = Measure.roomMetrics(ir: ir, sr: sr)

    // loopback validation: energy outside ±1 ms of the peak must be far down
    let w = Int(0.001 * sr)
    var sideE = 0.0, peakE = 0.0
    for (i, v) in ir.enumerated() {
        let e = Double(v) * Double(v)
        if abs(i - m.directIndex) <= w { peakE += e } else { sideE += e }
    }
    let sideDB = 10 * log10(max(sideE, 1e-300) / max(peakE, 1e-300))

    print("""

      direct arrival   sample \(m.directIndex) (\(String(format: "%.2f", Double(m.directIndex) / sr * 1000)) ms into the IR window)
      noise floor      \(String(format: "%.1f", m.noiseFloorDB)) dB below peak
      truncation       sample \(m.truncationIndex) (\(String(format: "%.3f", Double(m.truncationIndex) / sr)) s) — Schroeder integrated to here
      decay range      \(String(format: "%.1f", m.decayRangeDB)) dB usable
      T20              \(m.t20.map { String(format: "%.3f s", $0) } ?? "unavailable")
      T30              \(m.t30.map { String(format: "%.3f s", $0) } ?? "unavailable")
      C50              \(String(format: "%.1f", m.c50)) dB
      D50              \(String(format: "%.1f", m.d50)) %
      DRR              \(String(format: "%.1f", m.drr)) dB
      off-peak energy  \(String(format: "%.1f", sideDB)) dB below the direct peak
    """)
    for n in m.notes { print("      note: \(n)") }

    if isLoopback {
        let isDelta = sideDB < -20
        print("\n  loopback check: " + (isDelta
            ? "PASS — IR collapses to a delta (\(String(format: "%.1f", sideDB)) dB off-peak). "
              + "The chain is sound; room measurements through it are valid."
            : "FAIL — off-peak energy is only \(String(format: "%.1f", sideDB)) dB down. "
              + "The chain is NOT clean: check the cable, gain staging, and that no "
              + "EQ/processing sits in the path. Do not measure a room until this passes."))
        if !isDelta { exit(1) }
    }

    // artifacts: the IR itself, plus a JSON sidecar carrying the conditions
    let dir = MeasureDevice.measurementsDir()
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd'T'HHmmss"
    let base = "\(stamp.string(from: Date()))-ir-\(label.replacingOccurrences(of: " ", with: "_"))"
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent(base + ".wav")
        try Measure.writeWAVFloat32(ir, sr: sr, to: wav)

        let record: [String: Any] = [
            "kind": "impulse_response",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "label": label,
            "loopback_validation": isLoopback,
            "method": "exponential sine sweep (Farina), deconvolved with the "
                + "amplitude-corrected time-reversed inverse filter",
            "ir_file": wav.lastPathComponent,
            "device": deviceName,
            "sample_rate": sr,
            "buffer_frames": Int(bufFrames),
            "os": MeasureDevice.osVersion(),
            "mic": mic,
            "sweep": ["f0_hz": f0, "f1_hz": f1, "duration_s": durationS,
                      "amplitude_dbfs": 20 * log10(0.5)],
            "captured_peak_dbfs": peakDBFS,
            "known_offset": offset.dict,
            "xruns": Int(xruns),
            "ring_overrun_frames": Int(overruns),
            "metrics": [
                "direct_index": m.directIndex,
                "noise_floor_db": m.noiseFloorDB,
                "truncation_index": m.truncationIndex,
                "truncation_s": Double(m.truncationIndex) / sr,
                "decay_range_db": m.decayRangeDB,
                "t20_s": m.t20 as Any,
                "t30_s": m.t30 as Any,
                "c50_db": m.c50,
                "d50_pct": m.d50,
                "drr_db": m.drr,
                "off_peak_energy_db": sideDB,
                "notes": m.notes,
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: record,
                                              options: [.prettyPrinted, .sortedKeys])
        let jsonURL = dir.appendingPathComponent(base + ".json")
        try json.write(to: jsonURL)
        print("\n  wrote \(wav.path)")
        print("  wrote \(jsonURL.path)")
    } catch {
        print("\n  failed to write artifacts: \(error.localizedDescription)")
        exit(1)
    }
}
