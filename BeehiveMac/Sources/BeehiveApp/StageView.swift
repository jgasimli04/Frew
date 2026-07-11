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
    @StateObject private var trace = VideoTraceEngine()

    /// When a deck is on air its EQ band taps replace the offline envelopes
    /// as the stage's signal source (T4 hand-off) — and if it's a `.bee`, the
    /// overlay renders that deck's own helix, phase-locked to its playhead.
    private var liveOn: Bool { decks.liveBands != nil }
    private var liveBars: Double? {
        guard let (r, i) = decks.liveStage, i < r.alpha.count else { return nil }
        return r.alpha[i] / (2 * .pi)
    }
    /// Sub-band level for the video zoom pulse — deck taps when live,
    /// otherwise the offline envelope at the playhead.
    private var subLevel: Double {
        if let live = decks.liveBands { return Double(live[0]) }
        guard let env = model.bandEnv else { return 0 }
        return Double(env.values(at: model.playheadFrame)[0])
    }
    /// All five band levels — the trace strata's drivers.
    private var currentBands: [Float] {
        if let live = decks.liveBands { return live }
        guard let env = model.bandEnv else { return [0, 0, 0, 0, 0] }
        return env.values(at: model.playheadFrame)
    }
    /// Beat index on the θ quarter-bar grid — the trace resamples when this
    /// ticks, which is what makes the picture change ON the beat.
    private var beatIndex: Int {
        if let (r, i) = decks.liveStage, i < r.alpha.count {
            return Int(floor(r.alpha[i] / (.pi / 2)))
        }
        guard let r = model.record else { return Int.min }
        let i = min(model.safeCursor, r.alpha.count - 1)
        guard i >= 0 else { return Int.min }
        return Int(floor(r.alpha[i] / (.pi / 2)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // background: the inspiration set, two layers crossfading; the
            // whole video surface breathes with the sub band (zoom pulse)
            Group {
                PlayerLayerView(player: stage.playerA)
                    .opacity(stage.frontIsA ? 1 : 0)
                PlayerLayerView(player: stage.playerB)
                    .opacity(stage.frontIsA ? 0 : 1)
            }
            .scaleEffect(1 + 0.05 * CGFloat(subLevel))

            // the neural trace: video outlines redrawn by the band buses,
            // resampled once per beat (see VideoTraceEngine)
            TraceOverlay(strata: trace.strata, bands: currentBands)
                .scaleEffect(1 + 0.05 * CGFloat(subLevel))   // stays glued to the video

            if let (r, i) = decks.liveStage {
                TimelineView(.animation) { _ in
                    HelixOverlay(record: r,
                                 phase: Double(i),
                                 env: nil,
                                 liveBands: decks.liveBands,
                                 liveDrop: decks.liveDrop)
                }
                .allowsHitTesting(false)
            } else if let r = model.record {
                // redraws are driven by `playheadSeconds`, which the model
                // publishes once per displayed frame (ProMotion: up to 120 Hz)
                HelixOverlay(record: r,
                             phase: model.playheadFrame,
                             env: model.bandEnv)
                    .allowsHitTesting(false)
            }

            if stage.clips.isEmpty {
                VStack(spacing: 6) {
                    Text("Choose clips — or drag videos onto the stage")
                        .font(.title3).foregroundColor(.white.opacity(0.55))
                    if !stage.lastPickNote.isEmpty {
                        Text(stage.lastPickNote)
                            .font(.caption).foregroundColor(.orange.opacity(0.9))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.8), value: stage.frontIsA)
        .dropDestination(for: URL.self) { urls, _ in
            stage.addClips(urls)          // drop mp4/mov straight onto the stage
        }
        .overlay(alignment: .bottom) { controls }
        .onChange(of: model.safeCursor) { _, i in
            guard !liveOn, let r = model.record, i < r.alpha.count else { return }
            stage.sync(bars: r.alpha[i] / (2 * .pi))
        }
        .onChange(of: model.isPlaying) { _, playing in
            guard !liveOn else { return }
            if let r = model.record { stage.setTempo(bpm: r.meta.bpm) }
            stage.setPlaying(playing)
        }
        .onChange(of: liveBars) { _, bars in
            if let b = bars { stage.sync(bars: b) }
        }
        .onChange(of: beatIndex) { _, beat in
            trace.sample(item: stage.frontItem, beat: beat)
        }
        .onChange(of: liveOn) { _, on in
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

/// The generative layer, drawn per display frame. All signals are sampled at a
/// *fractional* frame index (interpolated between the record's grid frames) so
/// motion stays smooth at any refresh rate — ProMotion included — while the
/// picture remains phase-locked to the same grid the helix record and the zinc
/// keys live on. When a deck is on air its EQ band taps (`liveBands`/`liveDrop`)
/// replace the offline envelopes as the band signal source (T4 hand-off).
private struct HelixOverlay: View {
    let record: HelixRecord
    let phase: Double                 // fractional frame index of the playhead
    let env: BandEnvelopes?
    var liveBands: [Float]? = nil     // deck EQ taps, when a deck is on air
    var liveDrop: Float? = nil

    var body: some View {
        Canvas { ctx, size in
            let n = record.nFrames
            guard n > 0 else { return }
            let ft = min(max(phase, 0), Double(n - 1))
            let i = Int(ft), j = min(i + 1, n - 1)
            let u = ft - Double(i)
            func lerp(_ a: [Double]) -> Double { a[i] + (a[j] - a[i]) * u }
            func lerpF(_ a: [Float]) -> Double { Double(a[i]) + (Double(a[j]) - Double(a[i])) * u }

            let bands = liveBands ?? env?.values(at: ft) ?? [0, 0, 0, 0, 0]
            let drop = liveDrop.map(Double.init) ?? Double(env?.drop(at: ft) ?? 0)
            let sub = Double(bands[0]), low = Double(bands[1])
            let hiMid = Double(bands[3]), hi = Double(bands[4])

            // hue is circular — interpolate along the shortest arc
            let h0 = Double(record.hue[i])
            var dh = Double(record.hue[j]) - h0
            if dh > 0.5 { dh -= 1 } else if dh < -0.5 { dh += 1 }
            let hue = (h0 + dh * u + 1).truncatingRemainder(dividingBy: 1)

            let sat = lerpF(record.sat)
            let val = lerpF(record.val)
            let fMax = max(record.fMag.max() ?? 1, 1e-9)
            let f = lerp(record.fMag) / fMax
            let alpha = lerp(record.alpha)     // unwrapped phase: linear is exact

            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) * 0.30

            // drop response: deflate the geometry, veil the video
            let inflate = (0.78 + 0.34 * (0.45 * sub + 0.55 * low)) * (1 - 0.45 * drop)
            if drop > 0.01 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.black.opacity(0.38 * drop)))
            }

            // beat shockwaves: θ places a beat at every quarter bar (4/4 on
            // the same grid SYNC locks to); each beat launches a ring that
            // expands and fades over its beat, radius punched by the low end
            let beatLen = Double.pi / 2
            let beatPhase = ((alpha.truncatingRemainder(dividingBy: beatLen)) + beatLen)
                .truncatingRemainder(dividingBy: beatLen) / beatLen
            let punch = 0.35 + 0.65 * max(sub, low)
            for back in 0..<2 {                     // current beat + the one before
                let p = beatPhase + Double(back)
                guard p < 1.8 else { continue }
                let rad = R * CGFloat(0.5 + 1.9 * p) * CGFloat(inflate)
                let fade = pow(max(1 - p / 1.8, 0), 2) * punch
                guard fade > 0.02 else { continue }
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad,
                                           width: 2 * rad, height: 2 * rad)),
                    with: .color(Color(hue: hue, saturation: 0.5 * sat + 0.2,
                                       brightness: 1).opacity(0.55 * fade)),
                    lineWidth: 1 + 7 * CGFloat(fade))
            }

            // spectrum ring: 48 ticks around the outside, tick length = the
            // 5 band taps splined across the arc (mirrored), turning with α/4
            let specR = R * 1.55 * CGFloat(inflate)
            for t in 0..<48 {
                let frac = Double(t) / 48.0
                let mirrored = frac < 0.5 ? frac * 2 : (1 - frac) * 2   // low..high..low
                let bandPos = mirrored * 4                              // 0..4 across 5 bands
                let bi = min(Int(bandPos), 3)
                let bu = bandPos - Double(bi)
                let level = Double(bands[bi]) * (1 - bu) + Double(bands[bi + 1]) * bu
                guard level > 0.03 else { continue }
                let ang = alpha / 4 + frac * 2 * .pi
                let inner = specR
                let outer = specR + R * CGFloat(0.05 + 0.45 * level)
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + inner * CGFloat(cos(ang)),
                                      y: c.y + inner * CGFloat(sin(ang))))
                tick.addLine(to: CGPoint(x: c.x + outer * CGFloat(cos(ang)),
                                         y: c.y + outer * CGFloat(sin(ang))))
                ctx.stroke(tick,
                           with: .color(Color(hue: (hue + 0.5 * mirrored)
                                                    .truncatingRemainder(dividingBy: 1),
                                              saturation: 0.4 + 0.6 * sat,
                                              brightness: 0.5 + 0.5 * level)
                                        .opacity(0.25 + 0.6 * level)),
                           lineWidth: 2.5)
            }

            // hexagon frame (the beehive cell): counter-rotates at α/3,
            // breathes with the mids, brightens when the full spectrum is hot
            let mid = Double(bands[2])
            let hexR = R * CGFloat((1.18 + 0.14 * mid) * inflate)
            var hex = Path()
            for v in 0..<6 {
                let ang = -alpha / 3 + Double(v) * .pi / 3
                let pt = CGPoint(x: c.x + hexR * CGFloat(cos(ang)),
                                 y: c.y + hexR * CGFloat(sin(ang)))
                if v == 0 { hex.move(to: pt) } else { hex.addLine(to: pt) }
            }
            hex.closeSubpath()
            ctx.stroke(hex,
                       with: .color(Color(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
                                          saturation: 0.6 * sat + 0.2,
                                          brightness: 0.9)
                                    .opacity(0.12 + 0.45 * f * (1 - drop))),
                       style: StrokeStyle(lineWidth: 1.5 + 4 * f, lineJoin: .round))

            // chromatic wash from the timbre hue — the "edit the visuals
            // chromatic" signal, always on while the music is audible
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(hue: hue, saturation: 0.7 * sat + 0.2,
                                        brightness: 1).opacity(0.14 * val * (1 - drop))))

            // twelve chroma petals on the pitch-class wheel, rotated by α:
            // one full turn of the picture = one musical bar
            let rowI = record.chroma[i], rowJ = record.chroma[j]
            let row = (0..<12).map { Double(rowI[$0]) + (Double(rowJ[$0]) - Double(rowI[$0])) * u }
            let cMax = max(row.max() ?? 1, 1e-6)
            for k in 0..<12 {
                let w = row[k] / cMax
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

            // top-end sparkle: two counter-rotating orbits, the outer one
            // wobbling with the high-mids so it shimmers instead of gliding
            if hi + hiMid > 0.05 {
                for (ring, dots, speed, base) in [(1.30, 24, -0.5, hi),
                                                  (1.72, 36, 0.35, hiMid)] {
                    let orbit = R * CGFloat(ring) * CGFloat(inflate)
                    for j in 0..<dots {
                        let a = alpha * speed + Double(j) * 2 * .pi / Double(dots)
                        let wobble = 1 + 0.06 * hiMid * sin(alpha * 3 + Double(j))
                        let p = CGPoint(x: c.x + orbit * CGFloat(cos(a) * wobble),
                                        y: c.y + orbit * CGFloat(sin(a) * wobble))
                        let s = CGFloat(1.2 + 3.5 * base)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2,
                                                        width: s, height: s)),
                                 with: .color(.white.opacity(0.15 + 0.6 * max(base, hi * 0.6))))
                    }
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
    @Published var lastPickNote = ""        // surfaced when a pick yields nothing

    /// The item currently on screen — what the neural trace samples.
    var frontItem: AVPlayerItem? { (frontIsA ? playerA : playerB).currentItem }

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
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Use as Inspiration Set"
        panel.message = "Pick video files (mp4/mov/m4v) or a folder of them — subfolders are scanned too"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var found: [URL] = []
        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                // recursive walk — clips in subfolders count (flat scan was
                // the silent "button does nothing" failure)
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if Self.exts.contains(item.pathExtension.lowercased()) { found.append(item) }
                }
            } else if Self.exts.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        guard !found.isEmpty else {
            lastPickNote = "no mp4/mov/m4v found in that selection"
            return
        }
        lastPickNote = ""
        clips = found.shuffled()
        idx = -1
        lastBlock = Int.min
        advance()
    }

    /// Dropped videos join the set (a folder pick is not required first).
    @discardableResult
    func addClips(_ urls: [URL]) -> Bool {
        let vids = urls.filter { Self.exts.contains($0.pathExtension.lowercased()) }
        guard !vids.isEmpty else {
            lastPickNote = "dropped items had no mp4/mov/m4v"
            return false
        }
        lastPickNote = ""
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
