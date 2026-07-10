import AVFoundation
import CBeeDeck
import Foundation

/// Two-deck DJ engine (BEEDECK_ROADMAP T3/T4). Swift here is shell only: it
/// loads tracks, forwards control changes, and hosts one AVAudioSourceNode
/// whose render block calls straight into the C core (`CBeeDeck`) — no Swift
/// on the audio thread beyond the closure trampoline, no locks, no allocation.
///
/// `.bee` is the library format: Layer 1 PCM through the Rust core is the
/// deck's ground truth, and Layer 2 meta carries the beatgrid (bpm, B; the
/// helix grid is θ-anchored at sample 0). Plain audio files load as a
/// convenience with an unknown grid (sync disabled) — the library loop stays
/// `.bee`-first by design.
public final class DeckEngine {

    public struct TrackInfo {
        public var name = ""
        public var lengthSamples: Int64 = 0
        public var sampleRate: Double = 44_100
        public var bpm: Double = 0            // 0 = no grid (sync disabled)
        public var isBee = false
        /// The full Layer-2 record when the track is a `.bee` — the stage
        /// renders the playing deck's own helix (α, chroma, hue) from this.
        public var record: HelixRecord?
        /// min/max waveform pyramid, ~2048 buckets for the overview
        public var wave: [(lo: Float, hi: Float)] = []
        public var duration: Double { Double(lengthSamples) / sampleRate }
        public var beatSamples: Double { bpm > 0 ? sampleRate * 60.0 / bpm : 0 }
    }

    public let decks: [OpaquePointer]        // BDDeck ×2
    private let mixer: OpaquePointer         // BDMixer
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    public private(set) var info: [TrackInfo] = [TrackInfo(), TrackInfo()]
    public private(set) var outputSampleRate: Double

    /// Pitch-fader range presets, ± fraction (WIDE ≈ vinyl stop..double).
    public enum PitchRange: Double, CaseIterable {
        case six = 0.06, ten = 0.10, sixteen = 0.16, wide = 1.0
        public var label: String {
            switch self { case .six: "±6"; case .ten: "±10"; case .sixteen: "±16"; case .wide: "WIDE" }
        }
    }
    public var pitchRange: [PitchRange] = [.ten, .ten]
    /// UI pitch fader positions, -1…+1 (0 = native). Applied through range.
    public private(set) var pitchFader: [Double] = [0, 0]

    public init() {
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        outputSampleRate = hwRate > 0 ? hwRate : 44_100
        decks = [bd_deck_new(outputSampleRate), bd_deck_new(outputSampleRate)]
        mixer = bd_mixer_new(outputSampleRate)
        bd_mixer_attach(mixer, decks[0], decks[1])
        bd_mixer_set_crossfader(mixer, 0, 0)

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: outputSampleRate,
                                channels: 2, interleaved: false)!
        let mx = mixer
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2,
                  let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            // the C core renders at most 4096 frames per call; chunk so an
            // oversized host request never leaves tail garbage in the buffer
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let n = min(4096, total - done)
                bd_mixer_render(mx, l + done, r + done, Int32(n))
                done += n
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        source = node

        // Cue/loop trigger-to-audio latency rides on the HAL buffer: ask for
        // 256 frames (~5.3 ms @48 kHz). Best-effort; the device may refuse.
        var frames: UInt32 = 256
        if let unit = engine.outputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize,
                                 kAudioUnitScope_Global, 0,
                                 &frames, UInt32(MemoryLayout<UInt32>.size))
        }
    }

    deinit {
        engine.stop()
        bd_mixer_free(mixer)
        decks.forEach { bd_deck_free($0) }
    }

    public func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    /// Live engine diagnostics for the status line — silence must be visible.
    public var isRunning: Bool { engine.isRunning }
    public var outputDeviceRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    // ---- loading -----------------------------------------------------------

    /// Load a `.bee` (native Rust decode; grid from Layer-2 meta) or a plain
    /// audio file (grid unknown) onto deck 0/1.
    public func load(url: URL, deck: Int) throws {
        var channels: [[Float]]
        var sr: Double
        var bpm = 0.0
        var isBee = false
        var record: HelixRecord?
        if url.pathExtension.lowercased() == "bee" {
            let bee = try BeeFile(path: url.path)
            channels = bee.floatPCM()
            sr = bee.sampleRate
            record = try? bee.record()
            bpm = record?.meta.bpm ?? 0
            isBee = true
        } else {
            (channels, sr) = try Audio.loadChannels(url: url)
        }
        guard let first = channels.first, !first.isEmpty else {
            throw NSError(domain: "BeeDeck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty audio: \(url.lastPathComponent)"])
        }
        let left = first
        let right = channels.count > 1 ? channels[1] : first

        left.withUnsafeBufferPointer { lp in
            right.withUnsafeBufferPointer { rp in
                // helix grid convention: θ-anchored at sample 0 (beat0 = 0)
                bd_deck_load(decks[deck], lp.baseAddress!, rp.baseAddress!,
                             Int64(left.count), bpm, 0)
            }
        }
        // the FX beatgrid wants the beat in *source* samples
        bd_deck_set_grid(decks[deck], bpm > 0 ? sr * 60.0 / bpm : 0, 0)

        var t = TrackInfo()
        t.name = url.deletingPathExtension().lastPathComponent
        t.lengthSamples = Int64(left.count)
        t.sampleRate = sr
        t.bpm = bpm
        t.isBee = isBee
        t.record = record
        t.wave = Self.wavePyramid(left, right, buckets: 2048)
        info[deck] = t
        applyRate(deck)                       // track sr vs engine sr
    }

    static func wavePyramid(_ l: [Float], _ r: [Float], buckets: Int) -> [(Float, Float)] {
        let n = l.count
        guard n > buckets else { return l.indices.map { (min(l[$0], r[$0]), max(l[$0], r[$0])) } }
        var out: [(Float, Float)] = []
        out.reserveCapacity(buckets)
        let step = n / buckets
        for b in 0..<buckets {
            var lo: Float = 0, hi: Float = 0
            for i in (b * step)..<min((b + 1) * step, n) {
                let v = 0.5 * (l[i] + r[i])
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            out.append((lo, hi))
        }
        return out
    }

    // ---- transport ---------------------------------------------------------

    public func togglePlay(_ deck: Int) {
        bd_deck_is_playing(decks[deck]) ? bd_deck_pause(decks[deck]) : bd_deck_play(decks[deck])
    }
    public func isPlaying(_ deck: Int) -> Bool { bd_deck_is_playing(decks[deck]) }
    /// Position in track samples (fractional).
    public func position(_ deck: Int) -> Double { bd_deck_position(decks[deck]) }
    public func seconds(_ deck: Int) -> Double { position(deck) / info[deck].sampleRate }
    public func seek(_ deck: Int, seconds s: Double) {
        bd_deck_seek(decks[deck], s * info[deck].sampleRate)
    }

    /// CDJ cue: hold behaviour is the view's job; this is set/return.
    public func setCue(_ deck: Int) { bd_deck_set_cue(decks[deck], position(deck)) }
    public func backToCue(_ deck: Int) {
        bd_deck_seek(decks[deck], bd_deck_cue(decks[deck]))
    }
    public func hotCue(_ deck: Int, slot: Int) {
        let d = decks[deck]
        let at = bd_deck_hot_cue(d, Int32(slot))
        if at < 0 {
            bd_deck_set_hot_cue(d, Int32(slot), quantized(deck, position(deck)))
        } else {
            bd_deck_seek(d, at)
            bd_deck_play(d)
        }
    }
    public func clearHotCue(_ deck: Int, slot: Int) {
        bd_deck_set_hot_cue(decks[deck], Int32(slot), -1)
    }
    public func hotCuePosition(_ deck: Int, slot: Int) -> Double? {
        let v = bd_deck_hot_cue(decks[deck], Int32(slot))
        return v < 0 ? nil : v
    }

    /// Beat-quantize a sample position to the θ-anchored grid (identity when
    /// the track has no grid).
    public func quantized(_ deck: Int, _ sample: Double) -> Double {
        let beat = info[deck].beatSamples
        guard beat > 0 else { return sample }
        return (sample / beat).rounded() * beat
    }

    // ---- loops & jumps -----------------------------------------------------

    public private(set) var loopBeats: [Double] = [4, 4]

    public func autoLoop(_ deck: Int, beats: Double) {
        let d = decks[deck]
        if bd_deck_loop_active(d) && loopBeats[deck] == beats {
            bd_deck_set_loop(d, 0, 0, false)             // toggle off
            return
        }
        loopBeats[deck] = beats
        let beat = info[deck].beatSamples
        guard beat > 0 else { return }
        let start = quantized(deck, position(deck))
        bd_deck_set_loop(d, start, start + beats * beat, true)
    }
    public func loopActive(_ deck: Int) -> Bool { bd_deck_loop_active(decks[deck]) }
    public func beatJump(_ deck: Int, beats: Double) {
        let beat = info[deck].beatSamples
        guard beat > 0 else { return }
        bd_deck_seek(decks[deck], max(0, position(deck) + beats * beat))
    }

    // ---- tempo & sync ------------------------------------------------------

    public func setPitchFader(_ deck: Int, _ v: Double) {
        pitchFader[deck] = max(-1, min(1, v))
        applyRate(deck)
    }
    /// User rate (1.0 = native tempo), before the sr correction.
    public func userRate(_ deck: Int) -> Double {
        1.0 + pitchFader[deck] * pitchRange[deck].rawValue
    }
    public func effectiveBpm(_ deck: Int) -> Double { info[deck].bpm * userRate(deck) }

    private func applyRate(_ deck: Int) {
        // the C core advances in *track* samples per *engine* sample
        let srFix = info[deck].sampleRate / outputSampleRate
        bd_deck_set_rate(decks[deck], userRate(deck) * srFix)
    }

    /// SYNC: match this deck's effective bpm to the other's, then phase-lock
    /// the beat (θ alignment) with a quantized micro-jump.
    public func sync(_ deck: Int) {
        let other = 1 - deck
        let myBpm = info[deck].bpm, refBpm = effectiveBpm(other)
        guard myBpm > 0, refBpm > 0 else { return }
        let wantRate = refBpm / myBpm
        pitchFader[deck] = 0
        // widen the range if the needed rate exceeds it, rekordbox-style
        while abs(wantRate - 1) > pitchRange[deck].rawValue, pitchRange[deck] != .wide {
            let all = PitchRange.allCases
            pitchRange[deck] = all[min(all.firstIndex(of: pitchRange[deck])! + 1, all.count - 1)]
        }
        pitchFader[deck] = (wantRate - 1) / pitchRange[deck].rawValue
        applyRate(deck)

        // phase-lock: put my beat phase where the reference deck's is
        let myBeat = info[deck].beatSamples, refBeat = info[other].beatSamples
        guard myBeat > 0, refBeat > 0 else { return }
        let refPhase = (bd_deck_position(decks[other]).truncatingRemainder(dividingBy: refBeat)) / refBeat
        let mine = bd_deck_position(decks[deck])
        let myPhase = (mine.truncatingRemainder(dividingBy: myBeat)) / myBeat
        var delta = (refPhase - myPhase) * myBeat
        if delta > myBeat / 2 { delta -= myBeat }
        if delta < -myBeat / 2 { delta += myBeat }
        bd_deck_seek(decks[deck], mine + delta)
    }

    // ---- mixer & strip -----------------------------------------------------

    public func setTrim(_ deck: Int, db: Float) { bd_deck_set_trim_db(decks[deck], db) }
    public func setFader(_ deck: Int, _ v: Float) { bd_deck_set_fader(decks[deck], v) }
    public func setEQ(_ deck: Int, band: Int, gainDb: Float, kill: Bool) {
        bd_deck_set_eq(decks[deck], Int32(band), gainDb, kill)
    }
    public func setFilter(_ deck: Int, _ knob: Float) { bd_deck_set_filter(decks[deck], knob) }
    public func setCrossfader(_ x: Float, curve: Int) { bd_mixer_set_crossfader(mixer, x, Int32(curve)) }
    public func setMaster(_ v: Float) { bd_mixer_set_master(mixer, v) }

    // ---- beat FX (T5, θ-synced) ---------------------------------------------

    /// The FX catalog — RMX-class effects re-derived on the θ math: DUCK,
    /// ROLL and REVERSE are pure functions of the beat phase; ECHO's delay
    /// time is the beat fraction (tape-style glide on changes); DRIVE is a
    /// waveshaper. See `beedeck.h` for the DSP contract.
    public enum FXType: Int32, CaseIterable {
        case off = 0, echo, duck, roll, reverse, drive
        public var label: String {
            switch self {
            case .off: "OFF"; case .echo: "ECHO"; case .duck: "DUCK"
            case .roll: "ROLL"; case .reverse: "REV"; case .drive: "DRIVE"
            }
        }
    }
    /// Band routing for the FX bus over the 5-band isolator split
    /// (LOW = sub+low, MID = mid, HI = himid+hi).
    public enum FXTarget: Int32, CaseIterable {
        case low = 0, mid, hi, all
        public var label: String {
            switch self { case .low: "LOW"; case .mid: "MID"; case .hi: "HI"; case .all: "ALL" }
        }
    }

    public func setFX(_ deck: Int, type: FXType, target: FXTarget, on: Bool) {
        bd_deck_set_fx(decks[deck], type.rawValue, target.rawValue, on)
    }
    public func setFXBeats(_ deck: Int, _ beats: Double) {
        bd_deck_set_fx_beats(decks[deck], beats)
    }
    public func setFXAmount(_ deck: Int, _ a: Float) {
        bd_deck_set_fx_amount(decks[deck], a)
    }
    /// Momentary "echo out" punch: hold to mute the deck into beat-spaced
    /// decaying repeats; release brings the dry back while the tail rings out.
    public func setFXRelease(_ deck: Int, _ held: Bool) {
        bd_deck_set_fx_release(decks[deck], held)
    }
    /// Current FX cycle in output samples (what the echo tail is spaced by).
    public func fxCycleSamples(_ deck: Int) -> Double { bd_deck_fx_cycle(decks[deck]) }

    /// Live post-EQ band envelopes — the stage's signal source when a deck is
    /// on air (T4: "the EQ sends the signal to the visuals", literally).
    public func bandLevels(_ deck: Int) -> [Float] {
        var out = [Float](repeating: 0, count: Int(BD_BANDS))
        bd_deck_band_levels(decks[deck], &out)
        return out
    }
    public func masterLevels() -> (Float, Float) {
        var out: [Float] = [0, 0]
        bd_mixer_levels(mixer, &out)
        return (out[0], out[1])
    }

    /// The mixer handle, exposed for offline test rendering only
    /// (`beehive-cli --deckload`); the app never touches it.
    public var testMixer: OpaquePointer { mixer }
}
