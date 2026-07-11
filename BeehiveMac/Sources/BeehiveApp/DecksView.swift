import BeehiveKit
import SwiftUI
import UniformTypeIdentifiers

/// BeeDeck — the two-deck DJ window (BEEDECK_ROADMAP T3/T4).
/// Swift/SwiftUI is shell only: every control forwards to `DeckEngine`, whose
/// audio thread runs the C core. The UI reads engine state on a 30 Hz tick —
/// the same pull pattern the inspector uses.
///
/// Keyboard (deck A / deck B):
///   play Q / P · cue A / L · sync S / K · loop E / U · loop ÷2 W / Y ·
///   loop ×2 R / I · jump −4 Z / N · +4 X / M · hot cues 1234 / 7890
///   (⇧ + hot cue clears) · crossfader ← → nudge, ↓ centre ·
///   FX on/off F / J · FX type T / O (⇧ = band target) · FX beats ÷2 ×2
///   V B / , . · echo-out (hold) G / H
@MainActor
final class DeckSession: ObservableObject {
    let engine = DeckEngine()

    struct DeckUI {
        var name = "—"
        var bpm = 0.0
        var effBpm = 0.0
        var positionS = 0.0
        var duration = 0.0
        var playing = false
        var loopOn = false
        var loopBeats = 4.0
        var pitch = 0.0
        var pitchRange = DeckEngine.PitchRange.ten
        var hotCues: [Double?] = Array(repeating: nil, count: 8)
        var bands: [Float] = [0, 0, 0, 0, 0]
        var eqGain: [Float] = [0, 0, 0, 0, 0]   // dB, UI state
        var eqKill: [Bool] = [false, false, false, false, false]
        var filter: Float = 0
        var fader: Float = 1
        var trimDb: Float = 0
        var wave: [(lo: Float, hi: Float)] = []
        var beatSamples = 0.0
        var sampleRate = 44_100.0
        var lengthSamples: Int64 = 0
        var isBee = false
        var fxType: DeckEngine.FXType = .off
        var fxTarget: DeckEngine.FXTarget = .all
        var fxOn = false
        var fxBeats = 1.0
        var fxAmount: Float = 0.5
        var fxHeld = false            // momentary echo-out
    }

    @Published var deck: [DeckUI] = [DeckUI(), DeckUI()]
    @Published var crossfader: Float = 0
    @Published var xfCurve = 0                    // 0 smooth · 1 sharp · 2 cut
    @Published var master: Float = 0.9
    @Published var masterPeak: (Float, Float) = (0, 0)
    @Published var status = "load a track onto each deck"

    private var timer: Timer?
    private var upgradeCheckCounter = 0

    init() {
        engine.setMaster(0.9)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func startAudio() {
        do { try engine.start() } catch { status = "audio start failed: \(error.localizedDescription)" }
    }

    private func tick() {
        for d in 0..<2 {
            deck[d].positionS = engine.seconds(d)
            deck[d].playing = engine.isPlaying(d)
            deck[d].loopOn = engine.loopActive(d)
            deck[d].effBpm = engine.effectiveBpm(d)
            deck[d].bands = engine.bandLevels(d)
            for s in 0..<8 { deck[d].hotCues[s] = engine.hotCuePosition(d, slot: s) }
        }
        masterPeak = engine.masterLevels()
        tickDrop()
        upgradeCheckCounter += 1
        if upgradeCheckCounter >= 60 {          // ~2 s at 30 Hz
            upgradeCheckCounter = 0
            checkForBeeUpgrades()
        }
    }

    /// A deck playing a plain file whose `.bee` sibling has finished converting
    /// in the background swaps to it in place — position-preserving, no restart
    /// — so the θ grid, SYNC and quantized loops come alive mid-playback. Each
    /// deck self-terminates from this check once `isBee` flips true.
    private func checkForBeeUpgrades() {
        for d in 0..<2 where !deck[d].isBee {
            guard engine.upgradeToBeeIfAvailable(deck: d) else { continue }
            mirror(d)
            status = "\(["A", "B"][d]): \(engine.info[d].name)" +
                String(format: "  %.1f bpm (θ grid) — upgraded in place", engine.info[d].bpm)
        }
    }

    // live bass-departure detector — the same thresholds as the offline
    // BandEnvelopes detector (BeehiveKit), run incrementally at the UI tick:
    // sustained lows collapse while the top stays → the drop-build signal
    private var bassHistory: [Float] = []
    @Published private(set) var liveDrop: Float = 0

    private func tickDrop() {
        guard let bands = liveBands else {
            liveDrop = max(liveDrop * 0.955, 0)     // ~1.5 s decay at 30 Hz
            if liveDrop < 0.01 { liveDrop = 0 }
            bassHistory.removeAll(keepingCapacity: true)
            return
        }
        let bass = 0.5 * (bands[0] + bands[1])
        let top = max(bands[3], bands[4])
        bassHistory.append(bass)
        if bassHistory.count > 30 { bassHistory.removeFirst() }   // ~1 s window
        let wasBass = bassHistory.prefix(15).max() ?? 0
        let fired: Float = (wasBass > 0.45 && bass < 0.16 && top > 0.18) ? 1 : 0
        liveDrop = max(liveDrop * 0.955, fired)
    }

    /// The playing `.bee` deck whose helix the stage should render (loudest
    /// wins when both play), plus its current helix frame.
    var liveStage: (record: HelixRecord, frame: Int)? {
        var best: (Int, Float)? = nil
        for d in 0..<2 where deck[d].playing && engine.info[d].record != nil {
            let loud = deck[d].fader
            if best == nil || loud > best!.1 { best = (d, loud) }
        }
        guard let (d, _) = best, let r = engine.info[d].record else { return nil }
        let frame = Int(engine.position(d)) / max(r.meta.hop, 1)
        return (r, min(max(frame, 0), r.nFrames - 1))
    }

    /// The literal helix angle α at a deck's playhead — the θ math, on a dial.
    func theta(_ d: Int) -> Double? {
        guard let r = engine.info[d].record else { return nil }
        let frame = min(max(Int(engine.position(d)) / max(r.meta.hop, 1), 0), r.nFrames - 1)
        return r.alpha[frame].truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// Beat-phase offset between the decks in milliseconds (θ phase-lock
    /// evidence): 0 ms after SYNC means the grids are locked.
    var beatDeltaMs: Double? {
        guard deck[0].playing, deck[1].playing,
              deck[0].beatSamples > 0, deck[1].beatSamples > 0 else { return nil }
        let pA = engine.position(0).truncatingRemainder(dividingBy: deck[0].beatSamples) / deck[0].beatSamples
        let pB = engine.position(1).truncatingRemainder(dividingBy: deck[1].beatSamples) / deck[1].beatSamples
        var dPhase = pA - pB
        if dPhase > 0.5 { dPhase -= 1 }
        if dPhase < -0.5 { dPhase += 1 }
        let beatSec = deck[0].beatSamples / deck[0].sampleRate / engine.userRate(0)
        return dPhase * beatSec * 1000
    }

    var engineChip: (text: String, ok: Bool) {
        engine.isRunning
            ? (String(format: "engine ▸ %.0f Hz", engine.outputDeviceRate), true)
            : ("engine stopped — press play", false)
    }

    /// Copy engine `TrackInfo` into the deck's published UI mirror — shared by
    /// the initial load and the in-place θ-grid upgrade.
    private func mirror(_ d: Int) {
        let info = engine.info[d]
        deck[d].name = info.name
        deck[d].bpm = info.bpm
        deck[d].duration = info.duration
        deck[d].wave = info.wave
        deck[d].beatSamples = info.beatSamples
        deck[d].sampleRate = info.sampleRate
        deck[d].lengthSamples = info.lengthSamples
        deck[d].isBee = info.isBee
    }

    func load(url: URL, onto d: Int) {
        do {
            try engine.load(url: url, deck: d)
            let info = engine.info[d]
            mirror(d)
            status = "\(["A", "B"][d]): \(info.name)" + (info.bpm > 0
                ? String(format: "  %.1f bpm (θ grid)", info.bpm)
                : "  no grid (not a .bee) — sync off")
            startAudio()
        } catch {
            status = "load failed: \(error.localizedDescription)"
        }
    }

    // controls (forward + mirror for the UI)
    func togglePlay(_ d: Int) { startAudio(); engine.togglePlay(d) }
    func cuePress(_ d: Int) {
        if deck[d].playing { engine.backToCue(d); engine.togglePlay(d) }
        else { engine.setCue(d) }
    }
    func sync(_ d: Int) {
        engine.sync(d)
        deck[d].pitch = engine.pitchFader[d]
        deck[d].pitchRange = engine.pitchRange[d]
    }
    func setPitch(_ d: Int, _ v: Double) { deck[d].pitch = v; engine.setPitchFader(d, v) }
    func setRange(_ d: Int, _ r: DeckEngine.PitchRange) {
        deck[d].pitchRange = r
        engine.pitchRange[d] = r
        engine.setPitchFader(d, deck[d].pitch)
    }
    func autoLoop(_ d: Int) { engine.autoLoop(d, beats: deck[d].loopBeats) }
    func scaleLoop(_ d: Int, by f: Double) {
        deck[d].loopBeats = min(64, max(0.125, deck[d].loopBeats * f))
        if engine.loopActive(d) { engine.autoLoop(d, beats: deck[d].loopBeats) } // re-cut
    }
    func hotCue(_ d: Int, _ slot: Int, clear: Bool) {
        if clear { engine.clearHotCue(d, slot: slot) } else { startAudio(); engine.hotCue(d, slot: slot) }
    }
    func beatJump(_ d: Int, _ beats: Double) { engine.beatJump(d, beats: beats) }
    func setEQ(_ d: Int, band: Int, gain: Float? = nil, kill: Bool? = nil) {
        if let g = gain { deck[d].eqGain[band] = g }
        if let k = kill { deck[d].eqKill[band] = k }
        engine.setEQ(d, band: band, gainDb: deck[d].eqGain[band], kill: deck[d].eqKill[band])
    }
    func setFilter(_ d: Int, _ v: Float) { deck[d].filter = v; engine.setFilter(d, v) }
    func setFader(_ d: Int, _ v: Float) { deck[d].fader = v; engine.setFader(d, v) }
    func setTrim(_ d: Int, _ db: Float) { deck[d].trimDb = db; engine.setTrim(d, db: db) }
    func setCrossfader(_ x: Float) { crossfader = max(-1, min(1, x)); engine.setCrossfader(crossfader, curve: xfCurve) }
    func setCurve(_ c: Int) { xfCurve = c; engine.setCrossfader(crossfader, curve: c) }
    func setMaster(_ v: Float) { master = v; engine.setMaster(v) }

    // ---- beat FX (T5) ----
    private func pushFX(_ d: Int) {
        engine.setFX(d, type: deck[d].fxType, target: deck[d].fxTarget, on: deck[d].fxOn)
    }
    /// Chip click: select + engage; clicking the active effect switches it off.
    func selectFX(_ d: Int, _ type: DeckEngine.FXType) {
        if type == .off || (deck[d].fxType == type && deck[d].fxOn) {
            deck[d].fxOn = false
            if type != .off { deck[d].fxType = type }
        } else {
            deck[d].fxType = type
            deck[d].fxOn = true
            startAudio()
        }
        pushFX(d)
    }
    func toggleFX(_ d: Int) {
        deck[d].fxOn.toggle()
        if deck[d].fxOn {
            if deck[d].fxType == .off { deck[d].fxType = .echo }
            startAudio()
        }
        pushFX(d)
    }
    func cycleFXType(_ d: Int) {
        let all: [DeckEngine.FXType] = [.echo, .duck, .roll, .reverse, .drive,
                                        .sweep, .flanger, .phaser, .slicer, .reverb]
        let next = all[((all.firstIndex(of: deck[d].fxType) ?? -1) + 1) % all.count]
        deck[d].fxType = next
        pushFX(d)
    }
    func setFXTarget(_ d: Int, _ t: DeckEngine.FXTarget) { deck[d].fxTarget = t; pushFX(d) }
    func cycleFXTarget(_ d: Int) {
        let all = DeckEngine.FXTarget.allCases
        setFXTarget(d, all[((all.firstIndex(of: deck[d].fxTarget) ?? 0) + 1) % all.count])
    }
    func scaleFXBeats(_ d: Int, by f: Double) {
        deck[d].fxBeats = min(4, max(1.0 / 16.0, deck[d].fxBeats * f))
        engine.setFXBeats(d, deck[d].fxBeats)
    }
    func setFXAmount(_ d: Int, _ a: Float) {
        deck[d].fxAmount = a
        engine.setFXAmount(d, a)
    }
    /// Momentary echo-out (G/H keys or press-and-hold in the UI).
    func fxRelease(_ d: Int, held: Bool) {
        guard deck[d].fxHeld != held else { return }
        deck[d].fxHeld = held
        if held { startAudio() }
        engine.setFXRelease(d, held)
    }

    /// keyDown/keyUp pairing for the momentary echo-out — keyboardShortcut
    /// buttons can't see key-up, so G/H run through a local event monitor.
    private var keyMonitor: Any?
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard let self,
                  !ev.modifierFlags.contains(.command),
                  let ch = ev.charactersIgnoringModifiers?.lowercased(),
                  ch == "g" || ch == "h",
                  !(NSApp.keyWindow?.firstResponder is NSTextView)   // not while typing
            else { return ev }
            if ev.type == .keyDown && ev.isARepeat { return nil }
            self.fxRelease(ch == "g" ? 0 : 1, held: ev.type == .keyDown)
            return nil
        }
    }

    /// Live post-EQ band levels for the stage (T4→T2 hand-off): loudest deck wins.
    var liveBands: [Float]? {
        let a = deck[0].playing ? deck[0].bands : nil
        let b = deck[1].playing ? deck[1].bands : nil
        switch (a, b) {
        case (nil, nil): return nil
        case let (x?, nil): return x
        case let (nil, y?): return y
        case let (x?, y?): return zip(x, y).map(max)
        }
    }
}

// MARK: - the window

struct DecksView: View {
    @EnvironmentObject var session: DeckSession
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                DeckPane(d: 0)
                DeckPane(d: 1)
            }
            MixerPane()
            LibraryPane()
            keysLegend
        }
        .padding(10)
        .background(KeyMap())     // hidden buttons carrying the shortcuts
        .onAppear {
            session.startAudio()
            session.installKeyMonitor()   // momentary echo-out (G/H key-up)
        }
    }

    private var keysLegend: some View {
        HStack {
            Spacer()
            Text("keys: Q/P play · A/L cue · S/K sync · E/U loop · F/J FX · G/H echo-out · ←→ xfade")
                .font(.caption2.monospaced()).foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
    }
}

// MARK: - one deck

private struct DeckPane: View {
    @EnvironmentObject var session: DeckSession
    @EnvironmentObject var model: AppModel
    let d: Int

    var ui: DeckSession.DeckUI { session.deck[d] }
    var accent: Color { d == 0 ? .cyan : .orange }

    var body: some View {
        VStack(spacing: 8) {
            header
            WaveOverview(ui: ui, accent: accent) { frac in
                session.engine.seek(d, seconds: frac * ui.duration)
            }
            .frame(height: 56)
            WaveZoom(ui: ui, accent: accent)
                .frame(height: 88)
            transport
            HStack(spacing: 10) {
                hotCues
                Spacer()
                loopCluster
                pitchCluster
            }
            fxPane
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: BD.radius).fill(BD.panel))
        .overlay(RoundedRectangle(cornerRadius: BD.radius).strokeBorder(BD.seam.opacity(0.5), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(ui.playing ? accent.opacity(0.55) : .clear, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first { session.load(url: u, onto: d); return true }
            return false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(["A", "B"][d]).font(.headline).foregroundColor(accent)
            Text(ui.name).font(.callout).lineLimit(1)
            if ui.isBee {
                Text("bee").font(.caption2.monospaced()).foregroundColor(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.yellow.opacity(0.85), in: Capsule())
            }
            Spacer()
            ThetaDial(theta: session.theta(d), accent: accent)
            Text(ui.bpm > 0 ? "θ grid" : "no grid")
                .font(.caption2.monospaced())
                .foregroundColor(ui.bpm > 0 ? .yellow : .secondary)
                .help(ui.bpm > 0 ? "beatgrid = the helix angle from the .bee record — quantize, loops and SYNC run on it"
                                 : "no helix record — load a .bee for the θ grid (sync/loops off)")
            if ui.bpm > 0 {
                Text(String(format: "%.1f", ui.effBpm)).font(.title3.monospaced()).foregroundColor(accent)
                Text("BPM").font(.caption2).foregroundColor(.secondary)
            }
            Button {
                if let sel = model.selected { session.load(url: sel, onto: d) }
            } label: { Label("Load", systemImage: "tray.and.arrow.down") }
                .help("Load the song selected in the library window (or drop a file here)")
            Button {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.audio, UTType(filenameExtension: "bee") ?? .data]
                if p.runModal() == .OK, let u = p.url { session.load(url: u, onto: d) }
            } label: { Image(systemName: "folder") }
                .help("Open a file…")
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { session.togglePlay(d) } label: {
                Image(systemName: ui.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17)).frame(width: 42, height: 30)
            }
            .buttonStyle(.borderedProminent).tint(accent.opacity(0.8))
            Button { session.cuePress(d) } label: {
                Text("CUE").font(.caption.bold()).frame(width: 42, height: 30)
            }
            .buttonStyle(.bordered)
            .help("playing: back to cue + stop · paused: set cue here")
            Button { session.sync(d) } label: {
                Text("SYNC").font(.caption.bold()).frame(width: 46, height: 30)
            }
            .buttonStyle(.bordered).disabled(ui.bpm <= 0)
            Spacer()
            Text(mmsscs(ui.positionS)).font(.body.monospaced()).foregroundColor(accent)
            Text("/ " + mmss(ui.duration)).font(.caption.monospaced()).foregroundColor(.secondary)
            Spacer()
            Button { session.beatJump(d, -4) } label: { Image(systemName: "backward.frame") }
            Button { session.beatJump(d, 4) } label: { Image(systemName: "forward.frame") }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var hotCues: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { s in
                Button {
                    session.hotCue(d, s, clear: NSEvent.modifierFlags.contains(.shift))
                } label: {
                    Text("\(s + 1)").font(.caption2.monospaced())
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .background(ui.hotCues[s] != nil ? accent.opacity(0.55) : Color(white: 0.16),
                            in: RoundedRectangle(cornerRadius: 4))
                .help(ui.hotCues[s] != nil ? "jump (⇧-click clears)" : "set hot cue \(s + 1)")
            }
        }
    }

    private var loopCluster: some View {
        HStack(spacing: 5) {
            Button { session.scaleLoop(d, by: 0.5) } label: { Text("½").font(.caption) }
            Button { session.autoLoop(d) } label: {
                Text(loopLabel).font(.caption.bold())
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(ui.loopOn ? accent.opacity(0.55) : Color(white: 0.16),
                                in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("auto-loop \(loopLabel) beats (θ-quantized) — press again to release")
            Button { session.scaleLoop(d, by: 2) } label: { Text("×2").font(.caption) }
        }
        .buttonStyle(.bordered).controlSize(.mini)
        .disabled(ui.bpm <= 0)
    }

    private var loopLabel: String {
        ui.loopBeats < 1 ? "1/\(Int(1 / ui.loopBeats))" : "\(Int(ui.loopBeats))"
    }

    // ---- beat FX row (T5): the θ math on knobs — cycle = beats × the grid,
    // DUCK/ROLL/REV are pure φ functions, ECHO glides tape-style ----
    private var fxPane: some View {
        HStack(spacing: 8) {
            Text("FX").font(.caption2.bold())
                .foregroundColor(ui.fxOn ? accent : .secondary)
            HStack(spacing: 3) {
                ForEach([DeckEngine.FXType.echo, .duck, .roll, .reverse, .drive,
                         .sweep, .flanger, .phaser, .slicer, .reverb], id: \.self) { t in
                    fxChip(t.label, active: ui.fxType == t && ui.fxOn) {
                        session.selectFX(d, t)
                    }
                }
            }
            Divider().frame(height: 14)
            HStack(spacing: 3) {
                ForEach(DeckEngine.FXTarget.allCases, id: \.self) { t in
                    fxChip(t.label, active: ui.fxTarget == t, dim: true) {
                        session.setFXTarget(d, t)
                    }
                }
            }
            Divider().frame(height: 14)
            HStack(spacing: 4) {
                Button { session.scaleFXBeats(d, by: 0.5) } label: { Text("½").font(.caption2) }
                Text(fxBeatsLabel + " b").font(.caption2.monospaced())
                    .foregroundColor(.yellow.opacity(0.9)).frame(width: 44)
                    .help("FX cycle in beats — echo time, duck period, roll/reverse slice (θ-derived)")
                Button { session.scaleFXBeats(d, by: 2) } label: { Text("×2").font(.caption2) }
            }
            .buttonStyle(.bordered).controlSize(.mini)
            Slider(value: Binding(get: { Double(ui.fxAmount) },
                                  set: { session.setFXAmount(d, Float($0)) }), in: 0...1)
                .frame(width: 70)
                .help("amount — echo feedback / duck depth / drive")
            Spacer()
            Text("ECHO OUT").font(.caption2.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(ui.fxHeld ? Color.red.opacity(0.85) : Color(white: 0.16),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundColor(ui.fxHeld ? .white : .secondary)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !ui.fxHeld { session.fxRelease(d, held: true) } }
                    .onEnded { _ in session.fxRelease(d, held: false) })
                .help("hold: mute the deck into beat-spaced decaying repeats (also key \(d == 0 ? "G" : "H"))")
        }
    }

    private func fxChip(_ label: String, active: Bool, dim: Bool = false,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 9, weight: .bold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .background(active ? (dim ? accent.opacity(0.35) : accent.opacity(0.6)) : Color(white: 0.16),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private var fxBeatsLabel: String {
        ui.fxBeats < 1 ? "1/\(Int((1 / ui.fxBeats).rounded()))" : "\(Int(ui.fxBeats))"
    }

    private var pitchCluster: some View {
        HStack(spacing: 6) {
            VStack(spacing: 2) {
                Slider(value: Binding(get: { -session.deck[d].pitch },
                                      set: { session.setPitch(d, -$0) }),
                       in: -1...1)
                    .frame(width: 110)
                Text(String(format: "%+.2f%%  \(ui.pitchRange.label)",
                            session.deck[d].pitch * ui.pitchRange.rawValue * 100))
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
            }
            Menu {
                ForEach(DeckEngine.PitchRange.allCases, id: \.self) { r in
                    Button(r.label) { session.setRange(d, r) }
                }
            } label: { Image(systemName: "plusminus") }
                .menuStyle(.borderlessButton).frame(width: 24)
        }
    }
}

// MARK: - waveforms

private struct WaveOverview: View {
    let ui: DeckSession.DeckUI
    let accent: Color
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !ui.wave.isEmpty else { return }
                let w = size.width, h = size.height, mid = h / 2
                let n = ui.wave.count
                var path = Path()
                for i in 0..<n {
                    let x = CGFloat(i) / CGFloat(n - 1) * w
                    let (lo, hi) = ui.wave[i]
                    path.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * mid))
                    path.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * mid))
                }
                ctx.stroke(path, with: .color(accent.opacity(0.75)), lineWidth: 1)
                if ui.duration > 0 {
                    let px = CGFloat(ui.positionS / ui.duration) * w
                    ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: h)) },
                               with: .color(.white), lineWidth: 1.5)
                }
            }
            .background(Color.black)
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                onSeek(min(max(v.location.x / geo.size.width, 0), 1))
            })
        }
    }
}

/// ±4 s around the playhead, beatgrid lines from the θ-anchored grid
/// (downbeats emphasized — one bar = one 2π helix loop).
private struct WaveZoom: View {
    let ui: DeckSession.DeckUI
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            guard !ui.wave.isEmpty, ui.duration > 0 else { return }
            let w = size.width, h = size.height, mid = h / 2
            let window = 8.0                                 // seconds shown
            let t0 = ui.positionS - window / 2
            let n = ui.wave.count
            let cols = Int(w)
            var path = Path()
            for c in 0..<cols {
                let t = t0 + Double(c) / Double(cols) * window
                guard t >= 0, t < ui.duration else { continue }
                let i = min(Int(t / ui.duration * Double(n)), n - 1)
                let x = CGFloat(c)
                let (lo, hi) = ui.wave[i]
                path.move(to: CGPoint(x: x, y: mid - CGFloat(hi) * mid * 0.95))
                path.addLine(to: CGPoint(x: x, y: mid - CGFloat(lo) * mid * 0.95))
            }
            ctx.stroke(path, with: .color(accent), lineWidth: 1)

            if ui.beatSamples > 0 {
                let beatS = ui.beatSamples / ui.sampleRate
                var beat = (t0 / beatS).rounded(.down) * beatS
                while beat < t0 + window {
                    if beat >= 0, beat <= ui.duration {
                        let x = CGFloat((beat - t0) / window) * w
                        let isBar = Int((beat / beatS).rounded()) % 4 == 0
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                                   with: .color(.white.opacity(isBar ? 0.5 : 0.18)),
                                   lineWidth: isBar ? 1.2 : 0.6)
                    }
                    beat += beatS
                }
            }
            let cx = w / 2
            ctx.stroke(Path { $0.move(to: CGPoint(x: cx, y: 0)); $0.addLine(to: CGPoint(x: cx, y: h)) },
                       with: .color(.white), lineWidth: 1.5)
        }
        .background(Color.black)
    }
}

// MARK: - mixer

private struct MixerPane: View {
    @EnvironmentObject var session: DeckSession
    private let bandNames = ["SUB", "LOW", "MID", "HIM", "HI"]

    var body: some View {
        HStack(spacing: 14) {
            channel(0)
            VStack(spacing: 6) {
                meters
                crossfader
            }
            .frame(maxWidth: .infinity)
            channel(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: BD.radius).fill(BD.panel))
        .overlay(RoundedRectangle(cornerRadius: BD.radius).strokeBorder(BD.seam.opacity(0.5), lineWidth: 1))
    }

    private func channel(_ d: Int) -> some View {
        let accent: Color = d == 0 ? .cyan : .orange
        return HStack(spacing: 10) {
            if d == 1 { faderView(d, accent) }
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text("TRIM").font(.caption2).foregroundColor(.secondary)
                    Slider(value: Binding(get: { session.deck[d].trimDb },
                                          set: { session.setTrim(d, $0) }), in: -12...12)
                        .frame(width: 90)
                    Text("FILT").font(.caption2).foregroundColor(.secondary)
                    Slider(value: Binding(get: { session.deck[d].filter },
                                          set: { session.setFilter(d, $0) }), in: -1...1)
                        .frame(width: 90)
                }
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { b in
                        VStack(spacing: 3) {
                            Slider(value: Binding(get: { session.deck[d].eqGain[b] },
                                                  set: { session.setEQ(d, band: b, gain: $0) }),
                                   in: -26...6)
                                .frame(width: 64)
                            Button {
                                session.setEQ(d, band: b, kill: !session.deck[d].eqKill[b])
                            } label: {
                                Text(bandNames[b]).font(.system(size: 8, weight: .bold))
                                    .frame(width: 30, height: 14)
                            }
                            .buttonStyle(.plain)
                            .background(session.deck[d].eqKill[b] ? Color.red.opacity(0.8) : Color(white: 0.16),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .help("\(bandNames[b]) — click = full kill (true -inf)")
                            // live band level under the fader: the visual tap
                            Capsule().fill(accent.opacity(0.9))
                                .frame(width: 26, height: max(2, CGFloat(min(session.deck[d].bands[b], 1)) * 16))
                                .frame(height: 16, alignment: .bottom)
                        }
                    }
                }
            }
            if d == 0 { faderView(d, accent) }
        }
    }

    private func faderView(_ d: Int, _ accent: Color) -> some View {
        VStack(spacing: 2) {
            Text("VOL").font(.caption2).foregroundColor(.secondary)
            Slider(value: Binding(get: { session.deck[d].fader },
                                  set: { session.setFader(d, $0) }), in: 0...1)
                .frame(width: 90)
                .tint(accent)
        }
    }

    private var meters: some View {
        HStack(spacing: 3) {
            meterBar(session.masterPeak.0)
            meterBar(session.masterPeak.1)
            Text("MASTER").font(.caption2).foregroundColor(.secondary)
            Slider(value: Binding(get: { session.master }, set: { session.setMaster($0) }), in: 0...1)
                .frame(width: 110)
        }
    }

    private func meterBar(_ v: Float) -> some View {
        let db = v > 0 ? 20 * log10(Double(v)) : -60
        let frac = max(0, min(1, (db + 60) / 60))
        return Capsule()
            .fill(db > -3 ? Color.red : db > -12 ? Color.yellow : Color.green)
            .frame(width: 44 * frac, height: 5)
            .frame(width: 44, alignment: .leading)
            .background(Capsule().fill(Color(white: 0.15)))
    }

    private var crossfader: some View {
        HStack(spacing: 8) {
            Text("A").font(.caption.bold()).foregroundColor(.cyan)
            Slider(value: Binding(get: { session.crossfader },
                                  set: { session.setCrossfader($0) }), in: -1...1)
                .frame(maxWidth: 380)
            Text("B").font(.caption.bold()).foregroundColor(.orange)
            Picker("", selection: Binding(get: { session.xfCurve }, set: { session.setCurve($0) })) {
                Text("smooth").tag(0); Text("sharp").tag(1); Text("cut").tag(2)
            }
            .pickerStyle(.segmented).frame(width: 190)
        }
    }
}

// MARK: - keyboard map (hidden buttons; shortcuts work while the window is key)

private struct KeyMap: View {
    @EnvironmentObject var session: DeckSession

    var body: some View {
        Group {
            key("q") { session.togglePlay(0) }
            key("p") { session.togglePlay(1) }
            key("a") { session.cuePress(0) }
            key("l") { session.cuePress(1) }
            key("s") { session.sync(0) }
            key("k") { session.sync(1) }
            key("e") { session.autoLoop(0) }
            key("u") { session.autoLoop(1) }
            key("w") { session.scaleLoop(0, by: 0.5) }
            key("r") { session.scaleLoop(0, by: 2) }
            key("y") { session.scaleLoop(1, by: 0.5) }
            key("i") { session.scaleLoop(1, by: 2) }
            key("z") { session.beatJump(0, -4) }
            key("x") { session.beatJump(0, 4) }
            key("n") { session.beatJump(1, -4) }
            key("m") { session.beatJump(1, 4) }
            ForEach(0..<4, id: \.self) { s in
                key(KeyEquivalent(Character("\(s + 1)"))) { session.hotCue(0, s, clear: false) }
                key(KeyEquivalent(Character("\(s + 1)")), mods: .shift) { session.hotCue(0, s, clear: true) }
            }
            ForEach(0..<4, id: \.self) { s in
                let label: Character = s < 3 ? Character("\(s + 7)") : "0"
                key(KeyEquivalent(label)) { session.hotCue(1, s, clear: false) }
                key(KeyEquivalent(label), mods: .shift) { session.hotCue(1, s, clear: true) }
            }
            key(.leftArrow) { session.setCrossfader(session.crossfader - 0.08) }
            key(.rightArrow) { session.setCrossfader(session.crossfader + 0.08) }
            key(.downArrow) { session.setCrossfader(0) }
            // beat FX: F/J on-off, T/O type (⇧ = band target), V B / , . beats
            // (the momentary echo-out G/H needs key-up and lives in the
            // session's NSEvent monitor, not here)
            key("f") { session.toggleFX(0) }
            key("j") { session.toggleFX(1) }
            key("t") { session.cycleFXType(0) }
            key("o") { session.cycleFXType(1) }
            key("t", mods: .shift) { session.cycleFXTarget(0) }
            key("o", mods: .shift) { session.cycleFXTarget(1) }
            key("v") { session.scaleFXBeats(0, by: 0.5) }
            key("b") { session.scaleFXBeats(0, by: 2) }
            key(",") { session.scaleFXBeats(1, by: 0.5) }
            key(".") { session.scaleFXBeats(1, by: 2) }
        }
        .frame(width: 0, height: 0).opacity(0)
    }

    private func key(_ k: KeyEquivalent, mods: EventModifiers = [],
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(k, modifiers: mods)
            .buttonStyle(.plain)
    }
}

// (time formatting: mmss / mmsscs live in AppModel.swift)
