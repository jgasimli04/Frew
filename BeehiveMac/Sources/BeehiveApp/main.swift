import BeehiveKit
import SwiftUI

/// The single-window workspace (Logic-style): a mode strip in the toolbar
/// switches the center between PERFORM (decks + mixer + FX) and ANALYZE
/// (helix scene + inspector); the library browser is the persistent left
/// rail in ANALYZE, and PERFORM carries its own load-to-deck browser. The
/// Stage stays a separate window on purpose — it is the *output* surface,
/// meant for a second display, not a workspace mode.
enum Workspace: String, CaseIterable {
    case perform = "Perform"
    case analyze = "Analyze"

    var symbol: String {
        switch self {
        case .perform: return "circle.grid.2x1"
        case .analyze: return "waveform.and.magnifyingglass"
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var decks: DeckSession
    @Environment(\.openWindow) private var openWindow
    @AppStorage("workspace") private var workspaceRaw = Workspace.perform.rawValue

    private var workspace: Workspace {
        get { Workspace(rawValue: workspaceRaw) ?? .perform }
    }

    var body: some View {
        Group {
            switch workspace {
            case .perform: DecksView()
            case .analyze: AnalyzeView2Pane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BD.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $workspaceRaw) {
                    ForEach(Workspace.allCases, id: \.rawValue) { w in
                        Label(w.rawValue, systemImage: w.symbol).tag(w.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .help("Workspace — Perform: decks, mixer, FX · Analyze: the helix record")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "stage")
                } label: {
                    Label("Stage", systemImage: "sparkles.tv")
                }
                .help("Open the Stage output window — clips, neural trace, helix overlay (put it on the projector)")
            }
        }
        .navigationTitle("BeeDeck")
        .onAppear { model.start() }
    }

    /// Global status rail — one line of truth across both workspaces, the
    /// way Logic's control bar persists under every view.
    private var statusBar: some View {
        HStack(spacing: BD.gap) {
            let chip = decks.engineChip
            Circle().fill(chip.ok ? BD.good : BD.warn).frame(width: 6, height: 6)
            Readout(value: chip.text, color: BD.textDim, size: 10)
            if let delta = decks.beatDeltaMs {
                Readout(value: String(format: "Δbeat %+.1f ms", delta),
                        color: abs(delta) < 10 ? BD.good : BD.accent, size: 10)
            }
            Divider().frame(height: 12)
            if model.busy { ProgressView().controlSize(.mini) }
            Text(model.status)
                .font(.caption2).foregroundColor(BD.textDim)
                .lineLimit(1)
            Spacer()
            Readout(value: decks.status, color: BD.textDim, size: 10)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(white: 0.10))
        .overlay(alignment: .top) { Rectangle().fill(BD.seam.opacity(0.5)).frame(height: 1) }
    }
}

// MARK: - ANALYZE: browser rail · helix scene · inspector

private struct AnalyzeView2Pane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            browser
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            if let r = model.record {
                HStack(spacing: 0) {
                    scene(r)
                    Divider().overlay(BD.seam.opacity(0.4))
                    inspector(r)
                        .frame(width: 290)
                        .background(Color(white: 0.07))
                }
            } else {
                placeholder
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundColor(BD.textDim)
                Spacer()
                Text("\(model.songs.count)")
                    .font(.caption2.monospaced()).foregroundColor(BD.textDim)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(white: 0.14))

            List(model.songs, id: \.self, selection: $model.selected) { url in
                HStack(spacing: 6) {
                    Text(model.shortName(url)).lineLimit(1)
                        .font(.system(size: 12))
                    Spacer(minLength: 2)
                    if url.pathExtension.lowercased() == "bee" {
                        Text("BEE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(BD.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .tag(url)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(BD.panel)
        }
        .background(BD.panel)
    }

    @ViewBuilder
    private func scene(_ r: HelixRecord) -> some View {
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
                    .foregroundColor(model.isBee ? BD.accent : .white)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(!model.canPlay)
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isBee ? "Play the .bee Layer-1 payload (decoded by the native core)"
                              : "Play via AVFoundation — the level-matched control chain for A/B against a .bee")
            Readout(value: mmsscs(model.playheadSeconds), color: BD.accent)
                .frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { model.playheadFrame },
                                  set: { model.setCursor(Int($0.rounded())) }),
                   in: 0...Double(max(r.nFrames - 1, 1)))
            Readout(value: mmss(r.meta.durationS), color: BD.textDim)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(BD.panelDeep)
    }

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
                .foregroundColor(BD.textDim)
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
        WindowGroup("BeeDeck") {
            WorkspaceView()
                .environmentObject(model)
                .environmentObject(decks)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 800)

        Window("Stage — Output", id: "stage") {
            StageView()
                .environmentObject(model)
                .environmentObject(decks)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 640)
    }
}

BeehiveApplication.main()
