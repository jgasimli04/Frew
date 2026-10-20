import AVFoundation
import AVKit
import BeehiveKit
import SwiftUI

/// EDIT workspace — the Beat-Sync generator ("RhythmSync"). Pick a backing
/// track and a folder of raw clips; the `.bee` beat grid (or the octave-
/// corrected estimator) cuts every clip change onto a beat and exports an
/// mp4. Pipeline: BeatSync.beatMarkers -> generateBeatSyncedTimeline ->
/// makeVideoComposition -> export.
struct BeatSyncView: View {
    @StateObject private var ui = BeatSyncUI()

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            preview
                .frame(minWidth: 400)
        }
    }

    // MARK: - left rail: inputs + action

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BD.gap * 2) {
                Panel(title: "Backing track") {
                    VStack(alignment: .leading, spacing: BD.gap) {
                        HStack {
                            Button("Choose audio…") { ui.chooseAudio() }
                            Spacer()
                            if let url = ui.audioURL {
                                Text(url.lastPathComponent)
                                    .font(.caption).foregroundColor(BD.textDim).lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("BPM").font(.caption).foregroundColor(BD.textDim)
                            TextField("auto", text: $ui.bpmText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("blank = estimate · use the track's .bee bpm when you have it")
                                .font(.caption2).foregroundColor(BD.textDim)
                        }
                    }
                    .padding(10)
                }

                Panel(title: "Clips") {
                    VStack(alignment: .leading, spacing: BD.gap) {
                        HStack {
                            Button("Choose clips folder…") { ui.chooseClipsFolder() }
                            Spacer()
                            if !ui.clipURLs.isEmpty {
                                Text("\(ui.clipURLs.count) clips")
                                    .font(.caption.monospaced()).foregroundColor(BD.accent)
                            }
                        }
                        if !ui.clipURLs.isEmpty {
                            Text(ui.clipURLs.prefix(3).map { $0.lastPathComponent }.joined(separator: ", ")
                                 + (ui.clipURLs.count > 3 ? " …" : ""))
                                .font(.caption2).foregroundColor(BD.textDim).lineLimit(2)
                        }
                    }
                    .padding(10)
                }

                Panel(title: "Cut") {
                    VStack(alignment: .leading, spacing: BD.gap) {
                        Picker("Cut every", selection: $ui.beatsPerCut) {
                            Text("beat").tag(1)
                            Text("2 beats").tag(2)
                            Text("bar").tag(4)
                            Text("2 bars").tag(8)
                        }
                        .pickerStyle(.segmented)
                        Picker("Render", selection: $ui.render4K) {
                            Text("1080p").tag(false)
                            Text("4K").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(10)
                }

                Button(action: { ui.generate() }) {
                    HStack {
                        Spacer()
                        if ui.busy {
                            ProgressView().controlSize(.small).padding(.trailing, 4)
                            Text("Exporting…")
                        } else {
                            Image(systemName: "bolt.fill")
                            Text("Generate Beat-Synced Edit")
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(BD.accent)
                .disabled(!ui.ready || ui.busy)
                .keyboardShortcut(.return, modifiers: .command)

                if !ui.status.isEmpty {
                    Text(ui.status)
                        .font(.caption2).foregroundColor(ui.failed ? BD.warn : BD.textDim)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
        .background(BD.bg)
    }

    // MARK: - right: result preview

    private var preview: some View {
        ZStack {
            BD.panelDeep
            if let player = ui.player {
                VideoPlayer(player: player)
                    .padding(BD.gap)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 34)).foregroundColor(BD.textDim)
                    Text("The exported edit appears here")
                        .font(.caption).foregroundColor(BD.textDim)
                }
            }
        }
        .layoutPriority(1)
    }
}

// MARK: - view model

@MainActor
final class BeatSyncUI: ObservableObject {
    @Published var audioURL: URL?
    @Published var clipURLs: [URL] = []
    @Published var bpmText = ""
    @Published var beatsPerCut = 1
    @Published var render4K = false
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var status = ""
    @Published private(set) var player: AVPlayer?

    var ready: Bool { audioURL != nil && !clipURLs.isEmpty }

    private static let clipExts: Set<String> = ["mp4", "mov", "m4v"]

    func chooseAudio() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.prompt = "Use as Backing Track"
        p.message = "Pick the audio track (wav/mp3/m4a — or a music video, its audio track is used)"
        guard p.runModal() == .OK, let url = p.url else { return }
        audioURL = url
        player = nil
    }

    func chooseClipsFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Use Clips"
        p.message = "Pick a folder of raw clips (mp4/mov/m4v — subfolders are scanned)"
        guard p.runModal() == .OK, let url = p.url else { return }
        var found: [URL] = []
        if let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let item as URL in walker
            where Self.clipExts.contains(item.pathExtension.lowercased()) { found.append(item) }
        }
        clipURLs = found.sorted { $0.lastPathComponent < $1.lastPathComponent }
        player = nil
        status = clipURLs.isEmpty ? "no mp4/mov/m4v found in that folder" : ""
        failed = clipURLs.isEmpty
    }

    func generate() {
        guard let audioURL, !clipURLs.isEmpty else { return }
        busy = true
        failed = false
        status = "analysing audio…"
        let bpm = Double(bpmText.trimmingCharacters(in: .whitespaces))
        let clips = clipURLs
        let cut = beatsPerCut
        let size = render4K ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080)

        Task {
            do {
                let t0 = Date()
                let audioAsset = AVAsset(url: audioURL)
                let videoAssets = clips.map { AVAsset(url: $0) }

                let (markers, usedBPM) = try await BeatSync.beatMarkers(
                    for: audioAsset, url: audioURL, bpm: bpm, beatsPerCut: cut)
                status = String(format: "%.2f bpm %@ · %d cuts — building timeline…",
                                usedBPM, bpm != nil ? "(override)" : "(estimated)", markers.count)

                let composition = try await BeatSync.generateBeatSyncedTimeline(
                    videoAssets: videoAssets, audioAsset: audioAsset, beatMarkers: markers)
                let vc = try await BeatSync.makeVideoComposition(for: composition, renderSize: size)

                let out = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("BeeDeck BeatSync \(timestamp()).mp4")
                status = "exporting \(out.lastPathComponent)…"
                try await BeatSync.export(composition: composition, videoComposition: vc, to: out)

                status = String(format: "done in %.1f s — %@", -t0.timeIntervalSinceNow, out.path)
                player = AVPlayer(url: out)
                NSWorkspace.shared.selectFile(out.path, inFileViewerRootedAtPath: out.deletingLastPathComponent().path)
            } catch {
                failed = true
                status = "failed: \(error)"
            }
            busy = false
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }
}
