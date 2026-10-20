import AVFoundation
import BeehiveKit
import Foundation

/// End-to-end BeatSync check, fully offline and deterministic:
/// synthesize a 120 BPM click track + 3 solid-color clips, generate a
/// beat-synced timeline, export it, and verify every cut lands on a beat.
/// `beehive-cli --beatsynctest`
func beatsynctest() {
    func check(_ cond: Bool, _ msg: String) { print((cond ? "  PASS " : "  FAIL ") + msg); if !cond { exit(1) } }

    do {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("beatsynctest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // -- 1. synthetic 120 BPM click track, 8 s mono 44.1 kHz -------------
        let sr = 44_100.0, bpm = 120.0, songS = 8.0
        let audioURL = tmp.appendingPathComponent("click.wav")
        var mono = [Float](repeating: 0, count: Int(sr * songS))
        var beat = 0.0
        while beat < songS {                       // 10 ms 2 kHz decaying click
            let s0 = Int(beat * sr)
            for i in 0..<Int(0.010 * sr) where s0 + i < mono.count {
                let t = Double(i) / sr
                mono[s0 + i] += Float(sin(2 * .pi * 2000 * t) * exp(-t * 300))
            }
            beat += 60.0 / bpm
        }
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        // Scope the writer: AVAudioFile finalizes the WAV header on close
        // (deinit), and the asset below must see the real duration.
        try {
            let wav = try AVAudioFile(forWriting: audioURL, settings: wavSettings)
            let fmt = AVAudioFormat(settings: wavSettings)!
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(mono.count)) else {
                check(false, "could not allocate PCM buffer"); fatalError()
            }
            buf.frameLength = AVAudioFrameCount(mono.count)
            mono.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
            try wav.write(from: buf)
        }()

        // -- 2. three synthetic clips (one shorter than a beat interval) -----
        let clipSpecs: [(name: String, seconds: Double, bgra: (UInt8, UInt8, UInt8))] = [
            ("red.mp4", 1.3, (0, 0, 220)),
            ("green.mp4", 0.4, (0, 200, 0)),   // < 0.5 s beat interval -> loop path
            ("blue.mp4", 2.0, (220, 40, 0)),
        ]
        let clipURLs = try clipSpecs.map { spec in
            try makeClip(url: tmp.appendingPathComponent(spec.name),
                         size: CGSize(width: 640, height: 360), fps: 30,
                         seconds: spec.seconds, bgra: spec.bgra)
        }

        // -- 3. async pipeline -------------------------------------------------
        let done = DispatchSemaphore(value: 0)
        Task {
            await beatsyncChecks(tmp: tmp, audioURL: audioURL, clipURLs: clipURLs,
                                 songS: songS, bpm: bpm)
            done.signal()
        }
        done.wait()
        exit(0)
    } catch {
        print("  FAIL setup: \(error)")
        exit(1)
    }
}

/// Async half of beatsynctest(): markers -> timeline -> video composition ->
/// export, asserting the beat-sync invariants at each stage.
private func beatsyncChecks(tmp: URL, audioURL: URL, clipURLs: [URL],
                            songS: Double, bpm: Double) async {
    func check(_ cond: Bool, _ msg: String) { print((cond ? "  PASS " : "  FAIL ") + msg); if !cond { exit(1) } }
    do {
        let audioAsset = AVAsset(url: audioURL)
        let videoAssets = clipURLs.map { AVAsset(url: $0) }

        // markers: explicit .bee-style bpm
        let (markers, usedBPM) = try await BeatSync.beatMarkers(
            for: audioAsset, url: audioURL, bpm: bpm, beatsPerCut: 1)
        check(abs(usedBPM - bpm) < 1e-9, "grid bpm == \(bpm)")
        let spacings = zip(markers, markers.dropFirst()).map { $1.seconds - $0.seconds }
        check(spacings.allSatisfy { abs($0 - 0.5) < 0.001 }, "marker spacing 0.5 s ± 1 ms")
        check(markers.first!.seconds == 0, "first marker at t = 0")

        // tempo estimate path (no override): octave-corrected spectral flux
        let est = try await BeatSync.beatMarkers(for: audioAsset, url: audioURL).bpm
        print(String(format: "  info  estimated bpm %.2f (true %.1f)", est, bpm))
        check(abs(est - bpm) < 2, "estimated bpm within ±2 of true tempo (octave-corrected)")

        // timeline
        let composition = try await BeatSync.generateBeatSyncedTimeline(
            videoAssets: videoAssets, audioAsset: audioAsset, beatMarkers: markers)
        let compDur: CMTime = try await composition.load(.duration)
        check(abs(compDur.seconds - songS) < 1.0 / 30.0,
              "composition duration == audio duration ± 1 frame (\(compDur.seconds))")

        // AVComposition is local: sync track access, segments via timeMapping.
        guard let vtrack = composition.tracks(withMediaType: .video).first
        else { check(false, "composition has no video track"); return }
        let segs = vtrack.segments ?? []
        check(segs.count >= spacings.count, "video segments cover every beat interval (\(segs.count) segments)")

        // no gaps/overlaps at cuts: contiguous coverage of [0, songS)
        var contiguous = true
        var cursor = 0.0
        for s in segs.sorted(by: { $0.timeMapping.target.start < $1.timeMapping.target.start }) {
            if abs(s.timeMapping.target.start.seconds - cursor) > 0.002 { contiguous = false }
            cursor = s.timeMapping.target.end.seconds
        }
        check(contiguous && abs(cursor - songS) < 1.0 / 30.0, "cut points are gapless (no dropped frames)")

        // every beat boundary has a cut on it (within half a frame).
        // (Segments that loop a short clip have extra internal repeat cuts
        // mid-interval — expected, they are the same clip restarting.)
        let frame = 1.0 / 30.0
        let segStarts = segs.map { $0.timeMapping.target.start.seconds }
        var everyBeatHasCut = true
        for m in markers.dropFirst() {   // t = 0 needs no cut
            if !segStarts.contains(where: { abs($0 - m.seconds) <= frame / 2 + 0.002 }) {
                everyBeatHasCut = false
            }
        }
        check(everyBeatHasCut, "every beat lands a cut within half a frame")

        // video composition + export
        let vc = try await BeatSync.makeVideoComposition(for: composition, frameRate: 30)
        check(vc.renderSize == CGSize(width: 640, height: 360), "render size matches source (640x360)")
        check(!vc.instructions.isEmpty, "video composition has per-segment instructions")

        let outURL = tmp.appendingPathComponent("out.mp4")
        try await BeatSync.export(composition: composition, videoComposition: vc, to: outURL)
        let exported = AVAsset(url: outURL)
        let expDur: CMTime = try await exported.load(.duration)
        check(abs(expDur.seconds - songS) < 0.15, "exported mp4 duration ≈ \(songS) s (\(expDur.seconds))")
        let expTracks: [AVAssetTrack] = try await exported.load(.tracks)
        check(expTracks.contains { $0.mediaType == .video } && expTracks.contains { $0.mediaType == .audio },
              "exported file carries video + audio")
        print("  all beat-sync tests passed")
    } catch {
        print("  FAIL \(error)")
        exit(1)
    }
}

/// Solid-color H.264 clip via AVAssetWriter.
private func makeClip(url: URL, size: CGSize, fps: Int32, seconds: Double,
                      bgra: (UInt8, UInt8, UInt8)) throws -> URL {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: attrs)
    guard writer.canAdd(input) else { throw NSError(domain: "beatsynctest", code: 1) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "beatsynctest", code: 2) }
    writer.startSession(atSourceTime: .zero)

    let total = Int64((seconds * Double(fps)).rounded())
    for frame in 0..<total {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var pb: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let px = pb else { throw NSError(domain: "beatsynctest", code: 3) }
        CVPixelBufferLockBaseAddress(px, [])
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let rowBytes = CVPixelBufferGetBytesPerRow(px)
        if let base = CVPixelBufferGetBaseAddress(px) {
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    row[x * 4 + 0] = bgra.0
                    row[x * 4 + 1] = bgra.1
                    row[x * 4 + 2] = bgra.2
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(px, [])
        guard adaptor.append(px, withPresentationTime: CMTime(value: frame, timescale: fps)) else {
            throw writer.error ?? NSError(domain: "beatsynctest", code: 4)
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "beatsynctest", code: 5) }
    return url
}
