import BeehiveKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(model.songs, id: \.self, selection: $model.selected) { url in
                HStack(spacing: 6) {
                    Text(model.shortName(url)).lineLimit(1)
                    if url.pathExtension.lowercased() == "bee" {
                        Text("bee")
                            .font(.caption2.monospaced()).foregroundColor(.black)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.yellow.opacity(0.85), in: Capsule())
                    }
                }
                .tag(url)
            }
            .listStyle(.sidebar)
            .navigationTitle("Songs")
        } detail: {
            if let r = model.record {
                HStack(spacing: 0) {
                    stage(r)
                    Divider()
                    inspector(r)
                        .frame(width: 290)
                        .background(Color(white: 0.07))
                }
            } else {
                placeholder
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "decks")
                } label: {
                    Label("Decks", systemImage: "circle.grid.2x1")
                }
                .help("Open BeeDeck — two decks, 5-band isolator mixer, θ-synced")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "stage")
                } label: {
                    Label("Stage", systemImage: "sparkles.tv")
                }
                .help("Open the AV stage — inspiration clips + the helix overlay")
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundColor(.secondary)
                }
                .frame(minWidth: 140, alignment: .trailing)
            }
        }
        .onAppear { model.start() }
    }

    // MARK: - left stage: 3D helix + plots + scrubber

    @ViewBuilder
    private func stage(_ r: HelixRecord) -> some View {
        VStack(spacing: 0) {
            HelixSceneView(record: r,
                           cursor: model.playheadFrame,
                           autoSpin: model.autoSpin,
                           camera: model.camera,
                           env: model.bandEnv)
                .frame(minHeight: 280)
                .layoutPriority(1)
                .overlay(alignment: .topTrailing) { CameraControls(model: model).padding(10) }
                .overlay(alignment: .bottomLeading) { CompressionChip(record: r).padding(10) }

            EnergyView(record: r, peaks: model.peakMoments(), playhead: model.playheadFrame,
                       onScrub: { model.scrub(toFraction: $0) })
                .frame(height: 84)
            HueStripView(record: r, playhead: model.playheadFrame)
                .frame(height: 16)
            scrubber(r)
        }
    }

    @ViewBuilder
    private func scrubber(_ r: HelixRecord) -> some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundColor(model.isBee ? .yellow : .white)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(!model.canPlay)
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isBee ? "Play the .bee Layer-1 payload (decoded by the native core)"
                              : "Play via AVFoundation — the level-matched control chain for A/B against a .bee")
            Text(mmsscs(model.playheadSeconds))
                .font(.caption.monospaced()).foregroundColor(.cyan)
                .frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { model.playheadFrame },
                                  set: { model.setCursor(Int($0.rounded())) }),
                   in: 0...Double(max(r.nFrames - 1, 1)))
            Text(mmss(r.meta.durationS))
                .font(.caption.monospaced()).foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black)
    }

    // MARK: - right inspector column

    @ViewBuilder
    private func inspector(_ r: HelixRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeriveView(record: r, cursor: model.safeCursor)
                Divider()
                AnalyzeView(record: r, peaks: model.peakMoments().map { $0.time })
                Divider()
                TasteView(matches: model.tasteMatches())
            }
            .padding(14)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if model.busy { ProgressView() }
            Text(model.status.isEmpty ? "Add audio files to ~/Desktop/Music" : model.status)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - overlays

private struct CameraControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            preset("Top", "circle") { model.send(camera: .top) }
            preset("Side", "square.stack.3d.up.fill") { model.send(camera: .side) }
            preset("Orbit", "rotate.3d") { model.send(camera: .orbit) }
            Divider().frame(height: 14)
            icon("minus.magnifyingglass") { model.send(camera: .zoomOut) }
            icon("plus.magnifyingglass") { model.send(camera: .zoomIn) }
            Divider().frame(height: 14)
            Button { model.autoSpin.toggle() } label: {
                Image(systemName: model.autoSpin ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain).help("Auto-spin")
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func preset(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }.buttonStyle(.plain)
    }

    private func icon(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(.plain)
    }
}

private struct CompressionChip: View {
    let record: HelixRecord
    var body: some View {
        let cr = record.compressionReport()
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
            Text("\(cr.ratioStored)× lighter than STFT").font(.caption.monospaced())
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct BeehiveApplication: App {
    @StateObject private var model = AppModel()
    @StateObject private var decks = DeckSession()

    var body: some Scene {
        WindowGroup("Beehive") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 760)

        Window("Stage", id: "stage") {
            StageView()
                .environmentObject(model)
                .environmentObject(decks)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 640)

        Window("BeeDeck", id: "decks") {
            DecksView()
                .environmentObject(model)
                .environmentObject(decks)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 720)
    }
}

BeehiveApplication.main()
