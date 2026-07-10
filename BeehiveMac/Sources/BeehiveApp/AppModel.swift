import BeehiveKit
import Foundation
import SwiftUI

/// A camera viewpoint request. `nonce` lets the same preset re-fire (re-centre
/// after the user has dragged) — equality changes even when `preset` repeats.
enum CameraPreset: Equatable {
    case top      // look down the climb axis — the "black hole" ring
    case side     // climb axis vertical — reveals the coil/spring
    case orbit    // a 3/4 view that shows it is genuinely 3D
    case zoomIn, zoomOut
}

struct CameraCommand: Equatable {
    var preset: CameraPreset
    var nonce: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published var songs: [URL] = []
    @Published var selected: URL? {
        didSet {
            if selected != oldValue {
                cursor = 0
                stopPlayback()
                if selected != loadedURL { bandEnv = nil }   // stage signals belong to the loaded song
            }
        }
    }
    @Published var records: [URL: HelixRecord] = [:]
    @Published var busy = false
    @Published var status = ""

    // Playback — .bee only: audio comes from the Layer-1 payload, decoded by
    // the native Rust core over the C ABI (blueprint §4c). Other formats stay
    // analysis-only in this app.
    let player = Player()
    @Published var isPlaying = false
    private var playbackTimer: Timer?
    private var loadedURL: URL?

    // AV stage signals: 5-band envelopes + bass-departure, computed offline at
    // the record's frame grid from the same PCM the player holds (T2).
    @Published var bandEnv: BandEnvelopes?
    private var envURL: URL?

    // Navigation state shared across the 3D view, the plots, and the inspector.
    @Published var cursor: Int = 0                 // current frame index (the playhead)
    @Published var autoSpin: Bool = true
    @Published var camera = CameraCommand(preset: .orbit, nonce: 0)

    /// Last addressable frame of the selected record.
    var maxFrame: Int { max((record?.nFrames ?? 1) - 1, 0) }

    /// Clamp cursor into range (records can differ in length).
    var safeCursor: Int { min(max(cursor, 0), maxFrame) }

    func send(camera preset: CameraPreset) {
        camera = CameraCommand(preset: preset, nonce: camera.nonce + 1)
    }

    func scrub(toFraction f: Double) {
        setCursor(Int((f.clamped(0, 1) * Double(maxFrame)).rounded()))
    }

    /// A user-driven cursor move (scrubber/energy plot): also seeks playback.
    func setCursor(_ frame: Int) {
        cursor = frame
        if loadedURL == selected, let r = record {
            player.seek(to: Double(safeCursor) * Double(r.meta.hop) / r.meta.sr)
        }
    }

    // MARK: - Playback
    // .bee plays from Layer 1 through the native core (blueprint §4c). Other
    // formats play through AVFoundation as the *control chain*: identical
    // Player, identical unity gain, identical device — so an in-app A/B of a
    // .bee against its source is level-matched by construction.

    var canPlay: Bool { selected != nil }
    var isBee: Bool { selected?.pathExtension.lowercased() == "bee" }

    func togglePlay() {
        guard let url = selected, let r = record else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
            return
        }
        do {
            if loadedURL != url {
                status = "Opening \(url.lastPathComponent)…"
                let t0 = Date()
                let channels: [[Float]]
                let sr: Double
                if url.pathExtension.lowercased() == "bee" {
                    let bee = try BeeFile(path: url.path)
                    channels = bee.floatPCM()
                    sr = bee.sampleRate
                    player.load(channels: channels, sampleRate: sr)
                    status = String(format: ".bee decoded natively in %.2f s",
                                    -t0.timeIntervalSinceNow)
                } else {
                    (channels, sr) = try Audio.loadChannels(url: url)
                    player.load(channels: channels, sampleRate: sr)
                    status = String(format: "decoded by AVFoundation (control chain) in %.2f s",
                                    -t0.timeIntervalSinceNow)
                }
                loadedURL = url
                computeBandEnvelopes(channels: channels, sr: sr, meta: r.meta, for: url)
            }
            var t = Double(safeCursor) * Double(r.meta.hop) / r.meta.sr
            if t >= player.duration - 0.05 { t = 0 }
            player.play(from: t)
            isPlaying = true
            startTimer()
        } catch {
            status = "\(error)"
        }
    }

    private func stopPlayback() {
        player.pause()
        isPlaying = false
        stopTimer()
    }

    /// Offline stage signals from the just-decoded PCM — off the main actor;
    /// the stage degrades gracefully (record-driven only) until they land.
    private func computeBandEnvelopes(channels: [[Float]], sr: Double,
                                      meta: HelixMeta, for url: URL) {
        guard envURL != url else { return }
        envURL = url
        bandEnv = nil
        Task.detached(priority: .utility) {
            let n = channels.first?.count ?? 0
            var mono = [Float](repeating: 0, count: n)
            for ch in channels {
                for i in 0..<min(n, ch.count) { mono[i] += ch[i] }
            }
            if channels.count > 1 {
                let inv = 1 / Float(channels.count)
                for i in 0..<n { mono[i] *= inv }
            }
            let env = BandEnvelopes(mono: mono, sr: sr, nFFT: meta.nFFT, hop: meta.hop)
            await MainActor.run {
                if self.envURL == url { self.bandEnv = env }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Playhead → cursor: the helix, plots and inspector all follow the music.
    private func tick() {
        guard isPlaying, let r = record else { return }
        let t = player.currentTime
        if t >= player.duration {
            player.pause()
            player.seek(to: 0)
            isPlaying = false
            stopTimer()
            cursor = maxFrame
            return
        }
        cursor = min(Int(t * r.meta.sr / Double(r.meta.hop)), maxFrame)
    }

    private let exts: Set<String> = ["aiff", "aif", "wav", "flac", "mp3", "m4a", "bee"]
    let musicDir = URL(fileURLWithPath: ("~/Desktop/Music" as NSString).expandingTildeInPath)

    var record: HelixRecord? { selected.flatMap { records[$0] } }

    func start() {
        scan()
        encodeAll()
    }

    func scan() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: musicDir, includingPropertiesForKeys: nil)) ?? []
        songs = items.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if selected == nil { selected = songs.first }
    }

    func encodeAll() {
        let urls = songs
        guard !urls.isEmpty else { status = "No audio in ~/Desktop/Music"; return }
        busy = true
        status = "Encoding \(urls.count) song(s)…"
        Task.detached(priority: .userInitiated) {
            var out: [URL: HelixRecord] = [:]
            for u in urls {
                if u.pathExtension.lowercased() == "bee" {
                    // A .bee already carries its record (Layer 2): read it
                    // through the native core — no analysis pass at all.
                    out[u] = try? BeeFile(path: u.path).record()
                } else if let (y, sr) = try? Audio.load(url: u) {
                    out[u] = Engine.encode(samples: y, sr: sr, sourcePath: u.path)
                }
            }
            await MainActor.run {
                self.records = out
                self.busy = false
                self.status = "Encoded \(out.count) song(s)"
                if self.selected == nil { self.selected = urls.first }
            }
        }
    }

    // MARK: - Derived views of the selected record

    func peakMoments(audibleDB: Float = -40, top: Int = 6) -> [(time: Double, fmag: Double)] {
        guard let r = record else { return [] }
        var scored: [(Int, Double)] = []
        for i in 0..<r.nFrames where r.A[i] > audibleDB { scored.append((i, r.fMag[i])) }
        let best = scored.sorted { $0.1 > $1.1 }.prefix(top)
        return best.map { (Double($0.0) * Double(r.meta.hop) / r.meta.sr, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    /// Cosine similarity of the selected song to every other encoded song.
    func tasteMatches() -> [(name: String, score: Float)] {
        guard let r = record else { return [] }
        let sig = Taste.signature(r)
        var out: [(String, Float)] = []
        for (url, other) in records where url != selected {
            out.append((shortName(url), Taste.cosine(sig, Taste.signature(other))))
        }
        return out.sorted { $0.1 > $1.1 }
    }

    func shortName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        // drop a leading numeric id like "506206_"
        if let r = base.range(of: "_"), base[..<r.lowerBound].allSatisfy(\.isNumber) {
            return String(base[r.upperBound...])
        }
        return base
    }
}

func mmss(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

/// m:ss.cc — finer time readout for the scrubber/inspector.
func mmsscs(_ seconds: Double) -> String {
    let cs = max(0, Int((seconds * 100).rounded()))
    return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
