import AppKit
import AVFoundation
import BeehiveKit
import SwiftUI

/// The AV stage (BEEDECK_ROADMAP T2): a background "inspiration set" of local
/// video clips, advanced on 8-bar boundaries with a crossfade, under a
/// generative overlay whose geometry IS the search logic's geometry — the
/// overlay is the helix itself: rotation = α (the literal bar phase), twelve
/// chroma petals as the pitch-class colour wheel, radius inflating/deflating
/// with the low bands, sparkle from the top bands, a chromatic wash from the
/// record's timbre hue, and a deflate/darken response when the bass leaves
/// while the top stays (the drop-build signal). Mapping is pure signal
/// correlation — no manual assignment (user decision, 2026-07-10).
struct StageView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var decks: DeckSession
    @StateObject private var stage = StageController()

    /// When a deck is on air its EQ band taps replace the offline envelopes
    /// as the stage's signal source (T4 hand-off) — and if it's a `.bee`, the
    /// overlay renders that deck's own helix, phase-locked to its playhead.
    private var liveOn: Bool { decks.liveBands != nil }
    private var liveBars: Double? {
        guard let (r, i) = decks.liveStage, i < r.alpha.count else { return nil }
        return r.alpha[i] / (2 * .pi)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // background: the inspiration set, two layers crossfading
            PlayerLayerView(player: stage.playerA)
                .opacity(stage.frontIsA ? 1 : 0)
            PlayerLayerView(player: stage.playerB)
                .opacity(stage.frontIsA ? 0 : 1)

            if let (r, i) = decks.liveStage {
                TimelineView(.animation) { _ in
                    HelixOverlay(record: r,
                                 frame: i,
                                 env: nil,
                                 liveBands: decks.liveBands,
                                 liveDrop: decks.liveDrop,
                                 playing: true)
                }
                .allowsHitTesting(false)
            } else if let r = model.record {
                TimelineView(.animation) { _ in
                    HelixOverlay(record: r,
                                 frame: model.safeCursor,
                                 env: model.bandEnv,
                                 playing: model.isPlaying)
                }
                .allowsHitTesting(false)
            }

            if stage.clips.isEmpty {
                Text("Choose a clips folder — the inspiration set")
                    .font(.title3).foregroundColor(.white.opacity(0.55))
            }
        }
        .animation(.easeInOut(duration: 0.8), value: stage.frontIsA)
        .dropDestination(for: URL.self) { urls, _ in
            stage.addClips(urls)          // drop mp4/mov straight onto the stage
        }
        .overlay(alignment: .bottom) { controls }
        .onChange(of: model.safeCursor) { i in
            guard !liveOn, let r = model.record, i < r.alpha.count else { return }
            stage.sync(bars: r.alpha[i] / (2 * .pi))
        }
        .onChange(of: model.isPlaying) { playing in
            guard !liveOn else { return }
            if let r = model.record { stage.setTempo(bpm: r.meta.bpm) }
            stage.setPlaying(playing)
        }
        .onChange(of: liveBars) { bars in
            if let b = bars { stage.sync(bars: b) }
        }
        .onChange(of: liveOn) { on in
            if on {
                let bpm = max(decks.deck[0].playing ? decks.deck[0].effBpm : 0,
                              decks.deck[1].playing ? decks.deck[1].effBpm : 0)
                if bpm > 0 { stage.setTempo(bpm: bpm) }
            }
            stage.setPlaying(on || model.isPlaying)
        }
        .onAppear {
            if let r = model.record { stage.setTempo(bpm: r.meta.bpm) }
            stage.setPlaying(liveOn || model.isPlaying)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14)).foregroundColor(.yellow).frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!model.canPlay)

            Button("Choose Clips…") { stage.chooseFolder() }
                .font(.caption)

            if !stage.clips.isEmpty {
                Text("\(stage.clips.count) clips").font(.caption).foregroundColor(.secondary)
                Text(stage.currentName).font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            if model.bandEnv == nil, model.isPlaying {
                Text("analysing bands…").font(.caption2).foregroundColor(.secondary)
            }
            if let name = model.selected.map(model.shortName) {
                Text(name).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

/// The generative layer, drawn per display frame. All signals are indexed by
/// the playhead frame — the same grid the helix record and the zinc keys live
/// on, so the picture is phase-locked to the index by construction.
private struct HelixOverlay: View {
    let record: HelixRecord
    let frame: Int
    let env: BandEnvelopes?
    var liveBands: [Float]? = nil     // deck EQ taps, when a deck is on air
    var liveDrop: Float? = nil
    let playing: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = record.nFrames
            guard n > 0 else { return }
            let i = min(max(frame, 0), n - 1)

            let bands = liveBands ?? env?.values(at: i) ?? [0, 0, 0, 0, 0]
            let drop = liveDrop.map(Double.init)
                ?? Double(env.map { $0.bassDrop[min(i, max($0.frames - 1, 0))] } ?? 0)
            let sub = Double(bands[0]), low = Double(bands[1])
            let hiMid = Double(bands[3]), hi = Double(bands[4])

            let hue = Double(record.hue[i])
            let sat = Double(record.sat[i])
            let val = Double(record.val[i])
            let fMax = max(record.fMag.max() ?? 1, 1e-9)
            let f = record.fMag[i] / fMax
            let alpha = record.alpha[i]                    // the helix angle, as fact

            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) * 0.30

            // drop response: deflate the geometry, veil the video
            let inflate = (0.78 + 0.34 * (0.45 * sub + 0.55 * low)) * (1 - 0.45 * drop)
            if drop > 0.01 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.black.opacity(0.38 * drop)))
            }

            // chromatic wash from the timbre hue — the "edit the visuals
            // chromatic" signal, always on while the music is audible
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(hue: hue, saturation: 0.7 * sat + 0.2,
                                        brightness: 1).opacity(0.14 * val * (1 - drop))))

            // twelve chroma petals on the pitch-class wheel, rotated by α:
            // one full turn of the picture = one musical bar
            let row = record.chroma[i]
            let cMax = max(row.max() ?? 1, 1e-6)
            for k in 0..<12 {
                let w = Double(row[k] / cMax)
                let ang = alpha + Double(k) * .pi / 6
                let len = R * CGFloat((0.30 + 0.70 * w) * inflate)
                let tip = CGPoint(x: c.x + len * CGFloat(cos(ang)),
                                  y: c.y + len * CGFloat(sin(ang)))
                var petal = Path()
                petal.move(to: c)
                petal.addLine(to: tip)
                let col = Color(hue: Double(k) / 12.0,
                                saturation: 0.35 + 0.65 * sat,
                                brightness: (0.25 + 0.75 * val) * (0.35 + 0.65 * w))
                ctx.stroke(petal, with: .color(col.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2 + 6 * f, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 3 - 5 * w, y: tip.y - 3 - 5 * w,
                                                width: 6 + 10 * w, height: 6 + 10 * w)),
                         with: .color(col.opacity(0.5 + 0.5 * w)))
            }

            // breathing core ring: the sub band made visible
            let ring = R * CGFloat((0.34 + 0.30 * sub) * inflate)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring,
                                              width: 2 * ring, height: 2 * ring)),
                       with: .color(.white.opacity(0.18 + 0.55 * val)),
                       lineWidth: 1.5 + 5 * CGFloat(sub))

            // top-end sparkle orbit, counter-rotating at half phase
            if hi + hiMid > 0.05 {
                let orbit = R * 1.30 * CGFloat(inflate)
                for j in 0..<24 {
                    let a = -alpha * 0.5 + Double(j) * .pi / 12
                    let p = CGPoint(x: c.x + orbit * CGFloat(cos(a)),
                                    y: c.y + orbit * CGFloat(sin(a)))
                    let s = CGFloat(1.2 + 3.5 * hi)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2,
                                                    width: s, height: s)),
                             with: .color(.white.opacity(0.15 + 0.6 * max(hi, hiMid * 0.6))))
                }
            }
        }
    }
}

/// AVPlayerLayer wrapped for SwiftUI — the video background surface.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}

/// Owns the two video slots (front/back), clip order, tempo slaving, and the
/// 8-bar advance. Clips loop in place (AVPlayerLooper) until advanced.
@MainActor
final class StageController: ObservableObject {
    @Published private(set) var clips: [URL] = []
    @Published private(set) var currentName = ""
    @Published private(set) var frontIsA = true

    let playerA = AVQueuePlayer()
    let playerB = AVQueuePlayer()
    private var looperA: AVPlayerLooper?
    private var looperB: AVPlayerLooper?
    private var idx = -1
    private var lastBlock = Int.min
    private var rate: Float = 1
    private var transportOn = false
    private var generation = 0

    private static let exts: Set<String> = ["mp4", "mov", "m4v"]

    init() {
        playerA.isMuted = true
        playerB.isMuted = true
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Inspiration Set"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        clips = items.filter { Self.exts.contains($0.pathExtension.lowercased()) }.shuffled()
        idx = -1
        lastBlock = Int.min
        if !clips.isEmpty { advance() }
    }

    /// Dropped videos join the set (a folder pick is not required first).
    @discardableResult
    func addClips(_ urls: [URL]) -> Bool {
        let vids = urls.filter { Self.exts.contains($0.pathExtension.lowercased()) }
        guard !vids.isEmpty else { return false }
        let wasEmpty = clips.isEmpty
        clips.append(contentsOf: vids.filter { !clips.contains($0) })
        if wasEmpty, !clips.isEmpty { idx = -1; lastBlock = Int.min; advance() }
        return true
    }

    /// Video speed gently slaved to the music's tempo.
    func setTempo(bpm: Double) {
        guard bpm.isFinite, bpm > 0 else { return }
        rate = Float(min(max(bpm / 120.0, 0.5), 1.5))
    }

    func setPlaying(_ on: Bool) {
        transportOn = on
        let front = frontIsA ? playerA : playerB
        if on {
            front.play()
            front.rate = rate
        } else {
            playerA.pause()
            playerB.pause()
        }
    }

    /// Called with the musical position in bars; advances the clip every 8 bars.
    func sync(bars: Double) {
        let block = Int(bars / 8)
        if block != lastBlock {
            lastBlock = block
            if transportOn, clips.count > 1 { advance() }
        }
    }

    private func advance() {
        guard !clips.isEmpty else { return }
        idx = (idx + 1) % clips.count
        let url = clips[idx]
        currentName = url.deletingPathExtension().lastPathComponent

        let back = frontIsA ? playerB : playerA
        back.removeAllItems()
        let looper = AVPlayerLooper(player: back, templateItem: AVPlayerItem(url: url))
        if frontIsA { looperB = looper } else { looperA = looper }
        if transportOn || idx == 0 {          // roll the very first clip even at rest
            back.play()
            back.rate = transportOn ? rate : 1
        }
        frontIsA.toggle()

        // after the crossfade lands, stop the hidden slot's decode work
        generation += 1
        let gen = generation
        let hidden = frontIsA ? playerB : playerA
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.generation == gen else { return }
            hidden.pause()
        }
    }
}
