import AVFoundation
import Foundation

/// Plays the deinterleaved Float32 PCM a `.bee` decodes to, with seeking and a
/// sample-accurate playhead. AVAudioPlayerNode only schedules whole buffers
/// (segments are an AVAudioFile API), so the channels are kept and a buffer is
/// built from the seek offset on each (re)start — a few tens of ms of memcpy
/// for a full track, fine for a viewer app.
public final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var channels: [[Float]] = []
    private var sr: Double = 44_100
    private var format: AVAudioFormat?
    /// Song position (seconds) of the sample the current schedule started at.
    private var scheduledFrom: Double = 0

    public private(set) var isPlaying = false
    public var duration: Double { Double(channels.first?.count ?? 0) / sr }

    public init() {
        engine.attach(node)
    }

    /// Load deinterleaved float channels. Replaces any current song.
    public func load(channels: [[Float]], sampleRate: Double) {
        stop()
        guard let first = channels.first, !first.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels.count),
                                      interleaved: false)
        else { return }
        self.channels = channels
        sr = sampleRate
        format = fmt
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    /// Current song position in seconds (works while playing and while paused).
    public var currentTime: Double {
        guard isPlaying,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return scheduledFrom }
        return scheduledFrom + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    public func play(from seconds: Double? = nil) {
        guard let fmt = format, let first = channels.first else { return }
        let at = min(max(seconds ?? scheduledFrom, 0), duration)
        node.stop()

        let start = Int(at * sr)
        let remaining = first.count - start
        guard remaining > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(remaining))
        else { return }
        buf.frameLength = AVAudioFrameCount(remaining)
        for (c, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![c].update(from: src.baseAddress! + start,
                                                count: remaining)
            }
        }

        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buf, at: nil)
        scheduledFrom = at
        node.play()
        isPlaying = true
    }

    public func pause() {
        scheduledFrom = currentTime // freeze position before the node forgets it
        node.stop()
        isPlaying = false
    }

    public func seek(to seconds: Double) {
        if isPlaying {
            play(from: seconds)
        } else {
            scheduledFrom = min(max(seconds, 0), duration)
        }
    }

    public func stop() {
        node.stop()
        engine.stop()
        isPlaying = false
        scheduledFrom = 0
        channels = []
    }
}
