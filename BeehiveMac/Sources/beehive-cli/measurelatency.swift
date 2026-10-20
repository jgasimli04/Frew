import AVFoundation
import BeehiveKit
import CBeeMeasure
import CoreAudio
import Foundation

/// TARGET 1 — round-trip render latency over a physical analog loopback.
///
/// Patch output 1 to input 1 with a short TS cable, output at unity, input gain
/// set so the captured peak sits near -12 dBFS. Then:
///
///   beehive-cli --measure-latency [--repeats 20] [--buffers 64,128,256,512,1024] [--chirp]
///
/// Reports the number three ways, because only the third is this engine's own:
///   total round trip
///   − the device-reported offset (kAudioDevicePropertyLatency +
///     kAudioDevicePropertySafetyOffset + stream latency, both directions)
///   = residual, which is what the render path itself costs.
func measureLatency(_ args: [String]) {
    func intArg(_ flag: String, _ dflt: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return dflt }
        return Int(args[i + 1]) ?? dflt
    }
    let repeats = intArg("--repeats", 20)
    let buffers: [UInt32] = {
        guard let i = args.firstIndex(of: "--buffers"), args.count > i + 1 else {
            return [64, 128, 256, 512, 1024]
        }
        return args[i + 1].split(separator: ",").compactMap { UInt32($0) }
    }()
    let useChirp = args.contains("--chirp")

    // Diagnostics only: runs the rig on mismatched clocks to prove the capture
    // path executes. Such a run is never written to docs/measurements/.
    let allowMismatch = args.contains("--allow-clock-mismatch")
    guard let device = MeasureDevice.resolveDevice(allowMismatch: allowMismatch) else { exit(2) }

    let deviceName = MeasureDevice.name(of: device)
    let sr = MeasureDevice.nominalSampleRate(device)
    let offset = MeasureDevice.knownOffset(device)
    let os = MeasureDevice.osVersion()

    print("""
    round-trip latency, physical analog loopback
      device      \(deviceName)
      sample rate \(sr) Hz
      stimulus    \(useChirp ? "10 ms linear chirp 50 Hz–12 kHz" : "single-sample impulse")
      repeats     \(repeats) per buffer size (any run with an xrun is discarded)
      known offset \(offset.totalFrames) frames = \
    \(String(format: "%.3f", Double(offset.totalFrames) / sr * 1000)) ms \
    (out \(offset.outputLatency)+\(offset.outputSafety)+\(offset.outputStream), \
    in \(offset.inputLatency)+\(offset.inputSafety)+\(offset.inputStream))
      \(os)
    """)
    print("")

    // stimulus: silence to let the device settle, then the event, then room for
    // the return trip to land inside the same capture window
    let padFrames = Int(0.050 * sr)
    let emitted: [Float] = useChirp
        ? [Float](repeating: 0, count: padFrames)
            + Measure.linearChirp(f0: 50, f1: 12_000, durationS: 0.010, sr: sr, amplitude: 0.5)
            + [Float](repeating: 0, count: Int(0.150 * sr))
        : Measure.impulse(frames: padFrames + Int(0.150 * sr), pad: padFrames, amplitude: 0.5)
    let captureFrames = emitted.count + Int(0.100 * sr)

    var table: [[String: Any]] = []
    var headerPrinted = false

    for want in buffers {
        let actual = MeasureDevice.setBufferFrameSize(device, want)
        if actual != want {
            print("  buffer \(want): device granted \(actual) instead — reporting the granted size")
        }

        let rig = MeasureRig(device: device, ringCapacity: captureFrames * 4)
        rig.load(stimulus: emitted)
        do { try rig.start() } catch {
            print("  buffer \(want): engine failed to start: \(error.localizedDescription)")
            continue
        }
        // let the device settle before the first armed run
        Thread.sleep(forTimeInterval: 0.25)

        var lagsFrames: [Double] = []
        var discarded = 0
        var peakDBFS = -120.0
        var lowPeakRatio = 0

        for _ in 0..<repeats {
            rig.armMeasurement()
            // wait for both sides to stamp before draining
            let armDeadline = Date().addingTimeInterval(1.0)
            while !rig.marksValid && Date() < armDeadline { usleep(500) }
            guard rig.marksValid else { discarded += 1; continue }

            let captured = rig.drain(frames: captureFrames,
                                     deadline: Date().addingTimeInterval(2.0))
            if rig.outputXruns > 0 || rig.inputXruns > 0 || rig.ringOverruns > 0 {
                discarded += 1
                continue
            }
            guard captured.count > emitted.count,
                  let lag = Measure.estimateLag(captured: captured, emitted: emitted)
            else { discarded += 1; continue }

            // round trip = correlation lag + the exact clock offset between the
            // two streams' frame 0 (see bm_emit_begin / bm_capture_begin)
            let round = lag.subSample + rig.markOffsetFrames
            guard round > 0 else { discarded += 1; continue }
            if lag.peakRatio < 3 { lowPeakRatio += 1 }
            lagsFrames.append(round)

            let cpeak = captured.map { abs($0) }.max() ?? 0
            peakDBFS = max(peakDBFS, 20 * log10(Double(max(cpeak, 1e-10))))

            Thread.sleep(forTimeInterval: 0.05)
        }
        rig.stop()

        guard !lagsFrames.isEmpty else {
            print("  buffer \(actual): no valid runs (\(discarded) discarded) — "
                  + "is the loopback cable patched and the input unmuted?")
            continue
        }

        let framesStats = Measure.Stats(lagsFrames)
        let msStats = Measure.Stats(lagsFrames.map { $0 / sr * 1000 })
        let residualFrames = framesStats.median - Double(offset.totalFrames)

        if !headerPrinted {
            print("  buf   n   median        min       max     stddev   "
                  + "− known =  residual    peak")
            headerPrinted = true
        }
        print(String(format: "  %4d %3d  %7.3f ms  %7.3f  %7.3f  %6.3f ms  %8.3f ms  %6.1f dBFS",
                     actual, framesStats.n, msStats.median, msStats.min, msStats.max,
                     msStats.stddev, residualFrames / sr * 1000, peakDBFS))
        print(String(format: "       %3d frames: median %.1f, min %.0f, max %.0f, stddev %.2f%@",
                     framesStats.n, framesStats.median, framesStats.min, framesStats.max,
                     framesStats.stddev,
                     discarded > 0 ? "  (\(discarded) discarded)" : ""))
        if lowPeakRatio > 0 {
            print("       warning: \(lowPeakRatio) run(s) had a correlation peak less than 3× "
                  + "the next-highest — low SNR; try --chirp or more input gain")
        }
        if peakDBFS > -1 {
            print("       warning: captured peak \(String(format: "%.1f", peakDBFS)) dBFS — "
                  + "clipping; reduce input gain")
        }

        table.append([
            "buffer_frames_requested": Int(want),
            "buffer_frames_actual": Int(actual),
            "valid_runs": framesStats.n,
            "discarded_runs": discarded,
            "round_trip_frames": ["median": framesStats.median, "min": framesStats.min,
                                  "max": framesStats.max, "stddev": framesStats.stddev],
            "round_trip_ms": ["median": msStats.median, "min": msStats.min,
                              "max": msStats.max, "stddev": msStats.stddev],
            "known_offset_frames": Int(offset.totalFrames),
            "residual_frames": residualFrames,
            "residual_ms": residualFrames / sr * 1000,
            "captured_peak_dbfs": peakDBFS,
        ])
    }

    guard !table.isEmpty else {
        print("\nno valid measurement — nothing written.")
        exit(1)
    }
    if allowMismatch {
        print("""

        plumbing check complete: the rig started, both sides stamped their timestamps, and
        the capture ring drained. NOTHING WAS WRITTEN — the clocks did not match, so the
        numbers above are not a measurement of anything. Patch the loopback cable and run
        without --allow-clock-mismatch.
        """)
        exit(0)
    }

    let record: [String: Any] = [
        "kind": "round_trip_latency",
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "method": "analog loopback, cross-correlation of emitted vs captured, "
            + "host-timestamp aligned",
        "stimulus": useChirp ? "linear_chirp_50_12000_10ms" : "unit_impulse",
        "device": deviceName,
        "device_id": Int(device),
        "sample_rate": sr,
        "os": MeasureDevice.osVersion(),
        "output_channels": 2,
        "repeats_requested": repeats,
        "known_offset": offset.dict,
        "by_buffer_size": table,
    ]
    do {
        let url = try Measure.writeRun(record, kind: "latency", dir: MeasureDevice.measurementsDir())
        print("\nwrote \(url.path)")
    } catch {
        print("\nfailed to write run record: \(error.localizedDescription)")
    }
}
