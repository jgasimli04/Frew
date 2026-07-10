import AVFoundation
import CryptoKit
import Foundation

/// Real-audio front-end: decode a file to a mono Float signal via AVFoundation
/// (so AIFF/WAV/CAF/MP3/M4A and, on macOS 11+, FLAC all work), plus a stable
/// content hash for analyse-once idempotency. Port of beehive/audio.py.
public enum Audio {

    public enum AudioError: Error { case open(String), read(String) }

    public static func load(url: URL) throws -> (samples: [Float], sr: Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw AudioError.open("\(error)") }

        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let channelData = try? { () -> AVAudioPCMBuffer in
                  try file.read(into: buf); return buf
              }().floatChannelData
        else { throw AudioError.read("could not read PCM frames") }

        let n = Int(buf.frameLength)
        let ch = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if ch == 1 {
            mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: channelData[0], count: n) }
        } else {
            for c in 0..<ch {
                let p = channelData[c]
                for i in 0..<n { mono[i] += p[i] }
            }
            let inv = 1 / Float(ch)
            for i in 0..<n { mono[i] *= inv }
        }
        return (mono, fmt.sampleRate)
    }

    /// Decode a file to deinterleaved Float32 channels at native channel count —
    /// the playback control path. Same unity-gain chain as `.bee` playback, so
    /// in-app A/B comparisons are level-matched by construction. Video
    /// containers (mp4/mov/m4v) fall through to the AVAssetReader path, which
    /// extracts the audio track — AVAudioFile is audio-container-only.
    public static func loadChannels(url: URL) throws -> (channels: [[Float]], sr: Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch {
            if let fromAsset = try? assetChannels(url: url) { return fromAsset }
            throw AudioError.open("\(error)")
        }

        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
        else { throw AudioError.read("empty file") }
        do { try file.read(into: buf) } catch { throw AudioError.read("\(error)") }
        guard let data = buf.floatChannelData else { throw AudioError.read("no float PCM") }

        let n = Int(buf.frameLength)
        let channels = (0..<Int(fmt.channelCount)).map {
            [Float](UnsafeBufferPointer(start: data[$0], count: n))
        }
        return (channels, fmt.sampleRate)
    }

    /// Audio track of any AVAsset (mp4/mov/m4v/…) as deinterleaved Float32 —
    /// the deck path for "drop a music video on it".
    public static func assetChannels(url: URL) throws -> (channels: [[Float]], sr: Double) {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioError.open("no audio track in \(url.lastPathComponent)")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(out)
        guard reader.startReading() else {
            throw AudioError.read("\(reader.error.map(String.init(describing:)) ?? "reader failed")")
        }

        var interleaved: [Float] = []
        var sr = 44_100.0
        var ch = 2
        while let sbuf = out.copyNextSampleBuffer() {
            if let fd = CMSampleBufferGetFormatDescription(sbuf),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                sr = asbd.pointee.mSampleRate
                ch = Int(asbd.pointee.mChannelsPerFrame)
            }
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let p = ptr else { continue }
            let n = length / MemoryLayout<Float>.size
            p.withMemoryRebound(to: Float.self, capacity: n) { fp in
                interleaved.append(contentsOf: UnsafeBufferPointer(start: fp, count: n))
            }
        }
        guard reader.status == .completed, !interleaved.isEmpty else {
            throw AudioError.read("audio track decode failed (\(reader.status.rawValue))")
        }
        let frames = interleaved.count / ch
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: ch)
        for c in 0..<ch {
            for i in 0..<frames { channels[c][i] = interleaved[i * ch + c] }
        }
        return (channels, sr)
    }

    /// SHA-256 of the mono float32 samples (content-keyed, container-independent).
    public static func contentHash(_ samples: [Float]) -> String {
        let digest = samples.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
