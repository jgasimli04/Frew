import AVFoundation
import BeehiveKit
import CBeeMeasure
import CoreAudio
import Foundation

/// Device plumbing shared by both measurement tools.
///
/// The one rule that shapes this file: a round-trip measurement is only valid
/// if capture and playback ride the *same* clock. macOS will happily give you a
/// default input on one device and a default output on another, and the
/// resulting lag drifts run to run — which looks like a plausible standard
/// deviation rather than an error. So the rig refuses to run on mismatched
/// devices instead of averaging nonsense.
enum MeasureDevice {

    // ---- CoreAudio property helpers -----------------------------------------

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func name(of device: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name)
        return st == noErr ? (name as String) : "unknown(\(device))"
    }

    static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               input: Bool) -> UInt32 {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
        return v
    }

    /// Latency of the first stream on the given scope — the part of the device
    /// latency that lives in the stream rather than the device.
    static func streamLatency(_ device: AudioDeviceID, input: Bool) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr,
              let first = streams.first else { return 0 }

        var latency: UInt32 = 0
        var lsize = UInt32(MemoryLayout<UInt32>.size)
        var laddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyLatency,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(first, &laddr, 0, nil, &lsize, &latency)
        return latency
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var sr: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &sr)
        return sr
    }

    /// Ask the device for a buffer size. The device may refuse or clamp, so the
    /// caller must read back what was actually granted — `DeckEngine`'s own
    /// comment says as much, and a silently-refused 64 would corrupt a sweep.
    @discardableResult
    static func setBufferFrameSize(_ device: AudioDeviceID, _ frames: UInt32) -> UInt32 {
        var v = frames
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &v)
        return bufferFrameSize(device)
    }

    static func bufferFrameSize(_ device: AudioDeviceID) -> UInt32 {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
        return v
    }

    /// The known, device-reported part of the round trip, in frames:
    /// device latency + safety offset + stream latency, on both directions.
    struct KnownOffset {
        let outputLatency: UInt32, outputSafety: UInt32, outputStream: UInt32
        let inputLatency: UInt32, inputSafety: UInt32, inputStream: UInt32
        var totalFrames: UInt32 {
            outputLatency + outputSafety + outputStream
                + inputLatency + inputSafety + inputStream
        }
        var dict: [String: Any] {
            ["output_latency_frames": outputLatency, "output_safety_offset_frames": outputSafety,
             "output_stream_latency_frames": outputStream, "input_latency_frames": inputLatency,
             "input_safety_offset_frames": inputSafety, "input_stream_latency_frames": inputStream,
             "total_frames": totalFrames]
        }
    }

    static func knownOffset(_ device: AudioDeviceID) -> KnownOffset {
        KnownOffset(
            outputLatency: uint32Property(device, kAudioDevicePropertyLatency, input: false),
            outputSafety: uint32Property(device, kAudioDevicePropertySafetyOffset, input: false),
            outputStream: streamLatency(device, input: false),
            inputLatency: uint32Property(device, kAudioDevicePropertyLatency, input: true),
            inputSafety: uint32Property(device, kAudioDevicePropertySafetyOffset, input: true),
            inputStream: streamLatency(device, input: true))
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Where run records go: <repo>/docs/measurements/, resolved from the
    /// working directory so the tool can be run from anywhere in the tree.
    static func measurementsDir() -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs").path) {
                return dir.appendingPathComponent("docs/measurements")
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/measurements")
    }

    // ---- the rig --------------------------------------------------------------

    /// Refuses (returns nil, having explained why) unless capture and playback
    /// are on one device — i.e. one clock.
    /// Device selection itself is done in Audio MIDI Setup, not here — this only
    /// reads the defaults and enforces that they are one device.
    ///
    /// `allowMismatch` exists to exercise the capture path on a machine with no
    /// loopback cable (built-in mic + speakers). It produces a lag that is not a
    /// measurement of anything; it is for checking that the rig runs.
    static func resolveDevice(allowMismatch: Bool = false) -> AudioDeviceID? {
        let outID = defaultDevice(input: false)
        let inID = defaultDevice(input: true)

        guard outID != 0, inID != 0 else {
            print("REFUSED: no default input and/or output device.")
            return nil
        }
        if outID != inID && allowMismatch {
            print("""
            WARNING: --allow-clock-mismatch is set. Input (\(name(of: inID))) and output \
            (\(name(of: outID))) are different devices on different clocks.
            Any latency or decay time produced by this run is NOT A MEASUREMENT — it is a
            plumbing check. Do not record it, quote it, or write it into source.
            """)
            return outID
        }
        guard outID == inID else {
            print("""
            REFUSED: input and output are different devices, so they run on different clocks.
              output: \(name(of: outID))  (id \(outID))
              input:  \(name(of: inID))  (id \(inID))
            A round-trip lag measured across two free-running clocks drifts between repeats,
            and that drift would show up as a believable standard deviation rather than as an
            error. Fix the clock, then measure:
              - use one interface for both directions (select it as input AND output), or
              - Audio MIDI Setup > + > Create Aggregate Device, tick both, set one as clock
                source, then select the aggregate as the system input and output.
            """)
            return nil
        }
        return outID
    }
}

/// One measurement engine: a stimulus table played out of an AVAudioSourceNode,
/// and the device input captured through an AVAudioSinkNode into a lock-free
/// ring. The graph deliberately mirrors `DeckEngine.swift:65-93` — source node
/// into `mainMixerNode` at the device rate — so the number this produces
/// includes the real render path rather than a bare device open.
final class MeasureRig {
    let engine = AVAudioEngine()
    let device: AudioDeviceID
    let sampleRate: Double
    private(set) var ring: OpaquePointer?
    private var player: OpaquePointer?
    private let outXrun = UnsafeMutablePointer<BMXrun>.allocate(capacity: 1)
    private let inXrun = UnsafeMutablePointer<BMXrun>.allocate(capacity: 1)
    private let outMark = bm_mark_new()
    private let inMark = bm_mark_new()
    /// Scratch for de-interleaving channel 0 on the capture callback. Allocated
    /// here, never on the audio thread; blocks larger than this are chunked.
    static let scratchCapacity = 8192
    private let deinterleaveScratch =
        UnsafeMutablePointer<Float>.allocate(capacity: MeasureRig.scratchCapacity)
    private var source: AVAudioSourceNode?
    private var sink: AVAudioSinkNode?

    init(device: AudioDeviceID, ringCapacity: Int) {
        self.device = device
        self.sampleRate = MeasureDevice.nominalSampleRate(device)
        self.ring = bm_ring_new(ringCapacity)
        bm_xrun_reset(outXrun)
        bm_xrun_reset(inXrun)

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 2, interleaved: false)!

        // playback: copy from the preallocated stimulus table, nothing else
        let playerBox = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        playerBox.pointee = nil
        self.playerBox = playerBox
        let ox = outXrun
        let om = outMark
        let node = AVAudioSourceNode(format: fmt) { _, timestamp, frameCount, abl -> OSStatus in
            bm_xrun_observe(ox, timestamp.pointee.mSampleTime, Int32(frameCount))
            if let p = playerBox.pointee {
                bm_emit_begin(p, om, timestamp.pointee.mSampleTime)
            }
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2,
                  let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            if let p = playerBox.pointee {
                _ = bm_player_render(p, l, r, Int32(frameCount))
            } else {
                for i in 0..<Int(frameCount) { l[i] = 0; r[i] = 0 }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        source = node

        // capture: channel 0 of the input, straight into the ring
        let rg = ring
        let ix = inXrun
        let im = inMark
        let scratch = deinterleaveScratch
        let scratchCapacity = MeasureRig.scratchCapacity
        let sinkNode = AVAudioSinkNode { timestamp, frameCount, abl -> OSStatus in
            bm_xrun_observe(ix, timestamp.pointee.mSampleTime, Int32(frameCount))
            bm_capture_begin(rg, im, timestamp.pointee.mSampleTime)
            let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = bufs.first,
                  let data = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if first.mNumberChannels == 1 {
                _ = bm_ring_write(rg, data, Int32(frameCount))
            } else {
                // Interleaved input: de-interleave channel 0 into a scratch
                // buffer allocated at init, then write the block in one call.
                // Writing frame-by-frame would cost an acquire load and a
                // release store per sample inside the capture callback — the
                // block write is the same shape as DeckEngine's chunked render.
                let stride = Int(first.mNumberChannels)
                var done = 0
                let total = Int(frameCount)
                while done < total {
                    let n = min(scratchCapacity, total - done)
                    for i in 0..<n { scratch[i] = data[(done + i) * stride] }
                    _ = bm_ring_write(rg, scratch, Int32(n))
                    done += n
                }
            }
            return noErr
        }
        engine.attach(sinkNode)
        engine.connect(engine.inputNode, to: sinkNode,
                       format: engine.inputNode.outputFormat(forBus: 0))
        sink = sinkNode
    }

    private var playerBox: UnsafeMutablePointer<OpaquePointer?>

    deinit {
        engine.stop()
        if let p = playerBox.pointee { bm_player_free(p) }
        playerBox.deallocate()
        if let r = ring { bm_ring_free(r) }
        outXrun.deallocate()
        inXrun.deallocate()
        bm_mark_free(outMark)
        bm_mark_free(inMark)
        deinterleaveScratch.deallocate()
    }

    var outputXruns: UInt64 { outXrun.pointee.discontinuities }
    var inputXruns: UInt64 { inXrun.pointee.discontinuities }
    var ringOverruns: UInt64 { ring.map { bm_ring_overruns($0) } ?? 0 }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }

    /// Arm one measurement. The audio thread does the actual reset-and-stamp on
    /// both sides (see `bm_emit_begin` / `bm_capture_begin`), so the emitted and
    /// captured streams each carry an exact device timestamp for their own
    /// frame 0. Do not drain until `marksValid` is true.
    func armMeasurement() {
        bm_xrun_reset(outXrun)
        bm_xrun_reset(inXrun)
        bm_mark_arm(outMark)
        bm_mark_arm(inMark)
    }

    var marksValid: Bool { bm_mark_valid(outMark) && bm_mark_valid(inMark) }
    /// mSampleTime of the cycle in which stimulus frame 0 was emitted.
    var emitStart: Double { bm_mark_value(outMark) }
    /// mSampleTime of the cycle in which ring frame 0 was captured.
    var captureStart: Double { bm_mark_value(inMark) }
    /// The exact clock offset between the two streams' frame 0, in frames.
    var markOffsetFrames: Double { captureStart - emitStart }

    /// Install a stimulus table (allocates — call between runs, never during).
    func load(stimulus: [Float]) {
        if let old = playerBox.pointee { bm_player_free(old) }
        playerBox.pointee = stimulus.withUnsafeBufferPointer {
            bm_player_new($0.baseAddress!, Int64($0.count))
        }
    }

    var stimulusDone: Bool {
        playerBox.pointee.map { bm_player_done($0) } ?? true
    }

    /// Drain the capture ring on this (non-realtime) thread until `frames` have
    /// been collected or the deadline passes.
    func drain(frames: Int, deadline: Date) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        var got = 0
        var chunk = [Float](repeating: 0, count: 4096)
        while got < frames && Date() < deadline {
            let want = min(chunk.count, frames - got)
            let n = Int(bm_ring_read(ring, &chunk, Int32(want)))
            if n > 0 {
                for i in 0..<n { out[got + i] = chunk[i] }
                got += n
            } else {
                usleep(1000)
            }
        }
        return Array(out[0..<got])
    }
}
