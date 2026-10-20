import AVFoundation
import CoreMedia
import Foundation

/// RhythmSync: automated beat-sync timeline generator.
///
/// Combines the `.bee` beat grid (`beatSamples = sr * 60 / bpm`, beat 0 anchored
/// at sample 0 — the same convention as `DeckEngine`) with `AVMutableComposition`
/// so every video cut lands exactly on a beat timestamp. Pure Swift, async/await.
public enum BeatSync {

    public enum BeatSyncError: Error {
        case noAudioTrack
        case noVideoTrack(index: Int)
        case noMarkers
        case emptyClipList
        case tempoEstimateFailed
        case exportFailed(String)
    }

    /// Frame-safe timescale for all marker/composition math (divisible by
    /// 24, 25, 30, 60 frame durations).
    public static let timescale: CMTimeScale = 600

    // MARK: - Beat markers from the .bee engine

    /// Beat/cut timestamps for an audio asset. Pass `bpm` from the track's
    /// `.bee` `HelixMeta` when available; otherwise tempo is estimated with
    /// `Tempo.estimateBPM` (spectral-flux autocorrelation — can lock onto
    /// half/double the true tempo, so prefer the `.bee` value).
    ///
    /// - Parameters:
    ///   - audioAsset: the backing track (used for duration).
    ///   - url: file URL of the same audio (PCM decode path).
    ///   - bpm: grid tempo override; nil → estimate.
    ///   - beatsPerCut: 1 = marker on every beat, 4 = every bar.
    /// - Returns: markers at timescale 600, starting at t = 0, plus the bpm used.
    public static func beatMarkers(
        for audioAsset: AVAsset,
        url: URL,
        bpm: Double? = nil,
        beatsPerCut: Int = 1
    ) async throws -> (markers: [CMTime], bpm: Double) {
        let duration: CMTime = try await audioAsset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw BeatSyncError.noMarkers }

        let gridBPM: Double
        if let bpm, bpm > 0 {
            gridBPM = bpm
        } else {
            gridBPM = try estimateBPM(url: url)
        }

        let spacing = Double(beatsPerCut) * 60.0 / gridBPM
        var markers: [CMTime] = []
        var t = 0.0
        while t < duration.seconds {
            markers.append(CMTime(seconds: t, preferredTimescale: timescale))
            t += spacing
        }
        guard markers.count >= 2 else { throw BeatSyncError.noMarkers }
        return (markers, gridBPM)
    }

    /// Spectral-flux tempo estimate over the decoded PCM (mono mixdown).
    private static func estimateBPM(url: URL) throws -> Double {
        let (channels, sr) = try Audio.loadChannels(url: url)
        guard let first = channels.first, !first.isEmpty else { throw BeatSyncError.noAudioTrack }
        var mono = first
        if channels.count > 1 {
            let inv = 1 / Float(channels.count)
            for i in mono.indices { mono[i] *= inv }
            for c in channels.dropFirst() {
                for i in mono.indices { mono[i] += c[i] * inv }
            }
        }

        let nFFT = 2048, hop = 1024
        let fft = RealFFT(n: nFFT)
        let win = DSP.hann(nFFT)
        var mags: [[Float]] = []
        var pos = 0
        while pos + nFFT <= mono.count {
            mags.append(fft.magnitude(Array(mono[pos..<(pos + nFFT)]), window: win))
            pos += hop
        }
        let est = Tempo.estimateBPM(mags, sr: sr, hop: hop)
        guard est.bpm.isFinite, est.bpm > 0 else { throw BeatSyncError.tempoEstimateFailed }
        return est.bpm
    }

    // MARK: - Timeline generator

    /// Build a composition where every video cut lands on a beat marker.
    ///
    /// Video segments are taken from `videoAssets` in order, cycling back to the
    /// first clip when there are more beat intervals than clips. Clip audio is
    /// excluded — the backing track is the only audio. Segment boundaries are
    /// quantized to whole frames of the output frame rate, each rounded from its
    /// ideal beat time (no accumulated drift), so cuts land within half a frame
    /// of the beat and no frames are dropped at cut points.
    public static func generateBeatSyncedTimeline(
        videoAssets: [AVAsset],
        audioAsset: AVAsset,
        beatMarkers: [CMTime]
    ) async throws -> AVMutableComposition {
        guard !videoAssets.isEmpty else { throw BeatSyncError.emptyClipList }
        guard beatMarkers.count >= 2 else { throw BeatSyncError.noMarkers }

        let audioTracks: [AVAssetTrack] = try await audioAsset.load(.tracks)
        guard let srcAudio = audioTracks.first(where: { $0.mediaType == .audio })
        else { throw BeatSyncError.noAudioTrack }
        let audioDuration: CMTime = try await audioAsset.load(.duration)

        // Load every clip's video track, duration and frame rate up front.
        struct Clip {
            let track: AVAssetTrack
            let duration: CMTime
            let nominalFPS: Float
        }
        var clips: [Clip] = []
        clips.reserveCapacity(videoAssets.count)
        for (i, asset) in videoAssets.enumerated() {
            let vids: [AVAssetTrack] = try await asset.load(.tracks)
            guard let track = vids.first(where: { $0.mediaType == .video })
            else { throw BeatSyncError.noVideoTrack(index: i) }
            let dur: CMTime = try await asset.load(.duration)
            let fps: Float = try await track.load(.nominalFrameRate)
            clips.append(Clip(track: track, duration: dur, nominalFPS: fps))
        }

        // Output frame rate: fastest clip, capped at 60 fps, min 24.
        let maxFPS = clips.map { Double($0.nominalFPS) }.max() ?? 30
        let fps = max(24, min(60, (maxFPS).rounded()))
        let frame = CMTime(value: 1, timescale: CMTimeScale(fps * 100))
        /// Round a beat time to the nearest whole output frame — computed from
        /// the ideal marker time each time, so rounding error never accumulates.
        func quantize(_ t: CMTime) -> CMTime {
            let frames = (t.seconds / frame.seconds).rounded()
            return CMTime(seconds: frames * frame.seconds, preferredTimescale: timescale)
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BeatSyncError.exportFailed("could not create composition tracks") }

        try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration),
                                      of: srcAudio, at: .zero)

        // Beat intervals: [marker_k, marker_k+1), last one runs to audio end.
        var boundaries = beatMarkers
        boundaries.append(audioDuration)
        var offsets = [Int: Double]()   // per-clip rotating source offset
        for k in 0..<(boundaries.count - 1) {
            let segStart = quantize(boundaries[k])
            let segEnd = quantize(boundaries[k + 1])
            var segDur = CMTimeSubtract(segEnd, segStart)
            guard CMTimeCompare(segDur, .zero) > 0 else { continue }

            let clipIndex = k % clips.count
            let clip = clips[clipIndex]
            let use = offsets[clipIndex, default: 0]

            if CMTimeCompare(clip.duration, segDur) >= 0 {
                // Clip covers the segment: advance the source window on each reuse.
                let maxStart = max(0.0, clip.duration.seconds - segDur.seconds)
                let start = maxStart > 0 ? use.truncatingRemainder(dividingBy: maxStart) : 0
                let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: timescale),
                                        duration: segDur)
                try compVideo.insertTimeRange(range, of: clip.track, at: segStart)
                offsets[clipIndex] = start + segDur.seconds
            } else {
                // Clip shorter than the segment: loop it until the segment is full.
                var at = segStart
                while CMTimeCompare(segDur, .zero) > 0 {
                    let take = CMTimeMinimum(segDur, clip.duration)
                    try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: take),
                                                  of: clip.track, at: at)
                    at = CMTimeAdd(at, take)
                    segDur = CMTimeSubtract(segDur, take)
                }
            }
        }
        return composition
    }

    // MARK: - Export prep

    /// Per-segment render instructions: applies each clip's preferred transform
    /// and letterbox-scales into a uniform render size, so mixed-size/mixed-
    /// orientation clips export at 1080p/4K without squashing or dropped frames.
    public static func makeVideoComposition(
        for composition: AVComposition,
        renderSize: CGSize? = nil,
        frameRate: Int32? = nil
    ) async throws -> AVMutableVideoComposition {
        // AVComposition is a local object: its tracks and properties are
        // available synchronously (no async key-value loading required).
        let videoTracks = composition.tracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw BeatSyncError.exportFailed("no video track in composition") }

        let natural = track.naturalSize
        let preferred = track.preferredTransform
        let transformed = natural.applying(preferred)
        let baseSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let size = renderSize ?? baseSize

        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        let fps = frameRate ?? 30
        vc.frameDuration = CMTime(value: 1, timescale: fps)

        // One instruction per segment so every cut gets its own layer pass.
        // (AVCompositionTrackSegment exposes timeMapping, not timeRange.)
        let segments = track.segments
        if segments.isEmpty {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: track.timeRange.duration)
            instruction.layerInstructions = [layerInstruction(track: track, preferred: preferred,
                                                              baseSize: baseSize, renderSize: size)]
            vc.instructions = [instruction]
        } else {
            vc.instructions = segments.map { seg in
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = seg.timeMapping.target
                instruction.layerInstructions = [layerInstruction(track: track, preferred: preferred,
                                                                  baseSize: baseSize, renderSize: size)]
                return instruction
            }
        }
        return vc
    }

    /// preferredTransform ∘ uniform scale ∘ center translate into `renderSize`.
    private static func layerInstruction(track: AVCompositionTrack,
                                         preferred: CGAffineTransform,
                                         baseSize: CGSize,
                                         renderSize: CGSize) -> AVMutableVideoCompositionLayerInstruction {
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let sx = baseSize.width > 0 ? renderSize.width / baseSize.width : 1
        let sy = baseSize.height > 0 ? renderSize.height / baseSize.height : 1
        let scale = min(sx, sy)
        let tx = (renderSize.width - baseSize.width * scale) / 2
        let ty = (renderSize.height - baseSize.height * scale) / 2
        let t = preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        li.setTransform(t, at: .zero)
        return li
    }

    /// Export the composition to an mp4 via `AVAssetExportSession`
    /// (completion-handler API wrapped in a continuation — the async
    /// `export(to:as:)` requires macOS 15, deployment target here is macOS 14).
    public static func export(
        composition: AVComposition,
        videoComposition: AVVideoComposition?,
        to outputURL: URL,
        preset: String = AVAssetExportPresetHighestQuality
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset)
        else { throw BeatSyncError.exportFailed("could not create export session") }
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = videoComposition

        nonisolated(unsafe) let unsafeSession = session
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            unsafeSession.exportAsynchronously {
                switch unsafeSession.status {
                case .completed:
                    cont.resume()
                case .failed, .cancelled:
                    cont.resume(throwing: BeatSyncError.exportFailed(
                        unsafeSession.error.map(String.init(describing:)) ?? "status \(unsafeSession.status.rawValue)"))
                default:
                    cont.resume(throwing: BeatSyncError.exportFailed(
                        "unexpected status \(unsafeSession.status.rawValue)"))
                }
            }
        }
    }
}
