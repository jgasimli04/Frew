import AVFoundation
import BeehiveKit
import Foundation

/// Real-media beat-sync run:
/// `beehive-cli beatsync <audio-file> <clips-dir> <out.mp4> [bpm] [beatsPerCut]`
///
/// - audio-file: wav/mp3/m4a (or a music video — audio track is extracted).
/// - clips-dir: folder of .mp4/.mov clips, used in alphabetical order.
/// - bpm: optional grid override (use the track's .bee HelixMeta bpm when you
///   have it); omit to auto-estimate.
/// - beatsPerCut: 1 = cut every beat (default), 4 = every bar.
func beatsyncRun(_ args: [String]) {
    func usage() -> Never {
        print("usage: beehive-cli beatsync <audio-file> <clips-dir> <out.mp4> [bpm] [beatsPerCut]")
        exit(2)
    }
    guard args.count >= 3 else { usage() }
    let audioURL = URL(fileURLWithPath: args[0])
    let clipsDir = URL(fileURLWithPath: args[1])
    let outURL = URL(fileURLWithPath: args[2])
    let bpm = args.count > 3 ? Double(args[3]) : nil
    let beatsPerCut = args.count > 4 ? Int(args[4]) ?? 1 : 1

    let fm = FileManager.default
    guard fm.fileExists(atPath: audioURL.path) else { print("no such audio file: \(audioURL.path)"); exit(2) }
    let clipExts: Set<String> = ["mp4", "mov", "m4v"]
    let clipURLs = (try? fm.contentsOfDirectory(at: clipsDir, includingPropertiesForKeys: nil))?
        .filter { clipExts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    guard !clipURLs.isEmpty else { print("no .mp4/.mov/.m4v clips in \(clipsDir.path)"); exit(2) }
    print("clips: \(clipURLs.map { $0.lastPathComponent }.joined(separator: ", "))")

    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let t0 = Date()
            let audioAsset = AVAsset(url: audioURL)
            let videoAssets = clipURLs.map { AVAsset(url: $0) }

            let (markers, usedBPM) = try await BeatSync.beatMarkers(
                for: audioAsset, url: audioURL, bpm: bpm, beatsPerCut: beatsPerCut)
            print(String(format: "bpm %.2f (%@)  →  %d cut markers",
                         usedBPM, bpm != nil ? "override" : "estimated", markers.count))

            let composition = try await BeatSync.generateBeatSyncedTimeline(
                videoAssets: videoAssets, audioAsset: audioAsset, beatMarkers: markers)
            let vc = try await BeatSync.makeVideoComposition(for: composition,
                                                             renderSize: CGSize(width: 1920, height: 1080))
            print(String(format: "timeline: %.2f s, render %dx%d — exporting…",
                         composition.duration.seconds, Int(vc.renderSize.width), Int(vc.renderSize.height)))

            try await BeatSync.export(composition: composition, videoComposition: vc, to: outURL)
            print(String(format: "wrote %@ in %.1f s", outURL.path, -t0.timeIntervalSinceNow))
        } catch {
            print("beatsync failed: \(error)")
            exit(1)
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
