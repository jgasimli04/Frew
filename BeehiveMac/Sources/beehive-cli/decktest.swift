import BeehiveKit
import CBeeDeck
import Foundation

/// End-to-end deck load check, no audio device: `.bee` → native Rust decode →
/// C core → offline render. `beehive-cli --deckload <file.bee>`.
func deckload(_ path: String) {
    let eng = DeckEngine()
    do {
        try eng.load(url: URL(fileURLWithPath: path), deck: 0)
        let info = eng.info[0]
        print("loaded: \(info.name)")
        print(String(format: "  %.1f min @ %.0f Hz   bpm %.2f   beat %.1f samples   bee=%@  record=%@",
                     info.duration / 60, info.sampleRate, info.bpm, info.beatSamples,
                     info.isBee ? "yes" : "no", info.record != nil ? "yes" : "no"))
        eng.togglePlay(0)
        var L = [Float](repeating: 0, count: 44_100)
        var R = L
        // render straight through the C core (bypassing the audio device)
        var done = 0
        while done < L.count {
            let n = min(512, L.count - done)
            L.withUnsafeMutableBufferPointer { lp in
                R.withUnsafeMutableBufferPointer { rp in
                    bd_mixer_render(eng.testMixer, lp.baseAddress! + done, rp.baseAddress! + done, Int32(n))
                }
            }
            done += n
        }
        let rms = sqrt(L.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(L.count))
        print(String(format: "  1 s offline render: rms %.4f  position %.3f s", rms, eng.seconds(0)))
        print(rms > 1e-4 ? "  PASS deck pipeline carries signal" : "  FAIL silent render")
        exit(rms > 1e-4 ? 0 : 1)
    } catch {
        print("load failed: \(error)")
        exit(1)
    }
}

/// Offline verification of the BeeDeck DSP core (BEEDECK_ROADMAP T3/T4 DoD):
/// renders through the exact code the audio thread runs and measures — kill
/// depth, all-open band-sum flatness, loop/seek declick, varispeed accuracy,
/// crossfader law, and realtime headroom. `beehive-cli --decktest`.
func decktest() {
    let sr = 44_100.0
    var failures = 0
    func check(_ cond: Bool, _ msg: String) {
        print((cond ? "  PASS " : "  FAIL ") + msg)
        if !cond { failures += 1 }
    }

    func sine(_ hz: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { amp * Float(sin(2.0 * .pi * hz * Double($0) / sr)) }
    }

    /// Fresh deck+mixer playing `track` from 0; returns a render closure.
    func rig(_ track: [Float]) -> (deck: OpaquePointer, mixer: OpaquePointer,
                                   render: (Int) -> ([Float], [Float])) {
        let d = bd_deck_new(sr)!
        let m = bd_mixer_new(sr)!
        bd_mixer_attach(m, d, nil)
        bd_mixer_set_crossfader(m, -1, 0)   // full A: unity, no centre -3 dB
        track.withUnsafeBufferPointer { p in
            bd_deck_load(d, p.baseAddress!, p.baseAddress!, Int64(track.count), 120, 0)
        }
        bd_deck_play(d)
        let render: (Int) -> ([Float], [Float]) = { frames in
            var L = [Float](repeating: 0, count: frames)
            var R = [Float](repeating: 0, count: frames)
            var done = 0
            while done < frames {
                let n = min(512, frames - done)
                L.withUnsafeMutableBufferPointer { lp in
                    R.withUnsafeMutableBufferPointer { rp in
                        bd_mixer_render(m, lp.baseAddress! + done, rp.baseAddress! + done, Int32(n))
                    }
                }
                done += n
            }
            return (L, R)
        }
        return (d, m, render)
    }

    func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }
    func db(_ v: Double) -> Double { v <= 0 ? -Double.infinity : 20 * log10(v) }

    print("=== BeeDeck DSP core — offline verification (sr \(Int(sr))) ===")

    // ---- 1. all-open band-sum flatness (the LR4 tree + phase comp) --------
    // Sine-by-sine transfer: EQ flat, no filter — deviation from unity.
    var worst = 0.0, worstHz = 0.0
    for k in 0..<40 {
        let hz = 25.0 * pow(18_000.0 / 25.0, Double(k) / 39.0)
        let (d, m, render) = rig(sine(hz, seconds: 1.0))
        let (L, _) = render(Int(0.9 * sr))
        let settle = Int(0.4 * sr)
        // integer number of periods in the RMS window, or the window itself
        // biases the measurement at low frequencies
        let len = Int(floor(0.45 * hz) / hz * sr)
        let g = rms(L[settle..<settle + len]) / rms(sine(hz, seconds: 1.0)[settle..<settle + len])
        let dev = abs(db(g))
        if dev > worst { worst = dev; worstHz = hz }
        bd_mixer_free(m); bd_deck_free(d)
    }
    print(String(format: "  band-sum flatness: worst %+.4f dB @ %.0f Hz", worst, worstHz))
    check(worst < 0.5, "all-open sum flat within ±0.5 dB (DoD)")
    check(worst < 0.05, "…and within ±0.05 dB (the tree is exact, not just passing)")

    // ---- 2. kill is a true kill --------------------------------------------
    // (a) All five bands killed → the output must be *exactly* zero (each band
    //     gain snaps to literal 0 — no -90 dB floor pretending to be off).
    // (b) Bass kill on a 45 Hz sine: the residual is the crossover leakage of
    //     the adjacent (open) bands — LR4 physics, reported honestly in dB.
    // (c) A bass kill must not touch mid content.
    do {
        let (d, m, render) = rig(sine(45, seconds: 3.0))
        _ = render(Int(0.3 * sr))                       // play-in, gain settled
        let (refL, _) = render(Int(0.5 * sr))
        let refDb = db(rms(refL[...]))
        for b in 0..<5 { bd_deck_set_eq(d, Int32(b), 0, true) }
        _ = render(Int(0.5 * sr))                       // smoothing + snap
        let (allKillL, _) = render(Int(0.5 * sr))
        let allKillRms = rms(allKillL[...])
        print(String(format: "  all-band kill: rms %.3g (%@)", allKillRms,
                     allKillRms == 0 ? "exact zero → true -inf" : "NOT a true kill"))
        check(allKillRms == 0, "killed bands reach a true zero gain (DoD: kill = -inf)")

        for b in 0..<5 { bd_deck_set_eq(d, Int32(b), 0, false) }  // reopen
        bd_deck_set_eq(d, 0, 0, true)                   // bass kill: sub+low
        bd_deck_set_eq(d, 1, 0, true)
        _ = render(Int(0.5 * sr))
        let (killL, _) = render(Int(0.5 * sr))
        let leakDb = db(rms(killL[...])) - refDb
        print(String(format: "  45 Hz under bass kill: %+.1f dB (adjacent-band LR4 leakage)", leakDb))
        check(leakDb < -70, "bass-kill leakage ≤ -70 dB (inaudible; DJM-class)")

        // and the rest of the spectrum survives: 1 kHz through a bass kill
        let (d2, m2, render2) = rig(sine(1000, seconds: 2.0))
        bd_deck_set_eq(d2, 0, 0, true)
        bd_deck_set_eq(d2, 1, 0, true)
        _ = render2(Int(0.5 * sr))
        let (thruL, _) = render2(Int(0.5 * sr))
        let thruDev = abs(db(rms(thruL[...]) / rms(sine(1000, seconds: 2.0)[0..<Int(0.5 * sr)])))
        print(String(format: "  1 kHz through a bass kill: dev %.3f dB", thruDev))
        check(thruDev < 0.5, "mid content unaffected by bass kill (<0.5 dB)")
        bd_mixer_free(m); bd_deck_free(d); bd_mixer_free(m2); bd_deck_free(d2)
    }

    // ---- 3. loop wrap and seek are click-free ------------------------------
    // A loop whose length is a non-integer number of 440 Hz periods forces a
    // phase jump at the wrap; the declick crossfade must keep the largest
    // sample step near a clean sine's own slope.
    do {
        let track = sine(440, seconds: 4.0)
        let natural = Double(track.indices.dropFirst().map { abs(track[$0] - track[$0 - 1]) }.max()!)
        let (d, m, render) = rig(track)
        bd_deck_set_loop(d, 4410, 4410 + 9_999, true)   // 99.77 periods
        _ = render(Int(0.3 * sr))
        let (L, _) = render(Int(1.5 * sr))              // ~6 wraps
        let maxStep = Double(L.indices.dropFirst().map { abs(L[$0] - L[$0 - 1]) }.max()!)
        print(String(format: "  loop wrap: max step %.4f vs clean sine %.4f (×%.2f)",
                     maxStep, natural, maxStep / natural))
        check(maxStep < 2.5 * natural, "loop wrap declicked (max step < 2.5× sine slope)")
        bd_deck_seek(d, 100)                            // hot-cue style jump
        let (L2, _) = render(Int(0.2 * sr))
        let maxStep2 = Double(L2.indices.dropFirst().map { abs(L2[$0] - L2[$0 - 1]) }.max()!)
        check(maxStep2 < 2.5 * natural, "seek/hot-cue jump declicked")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 4. varispeed: rate accuracy and true pitch shift ------------------
    do {
        let (d, m, render) = rig(sine(440, seconds: 6.0))
        bd_deck_set_rate(d, 1.06)
        _ = render(Int(1.0 * sr))                       // rate smoothing settled
        let p0 = bd_deck_position(d)
        let frames = Int(2.0 * sr)
        let (L, _) = render(frames)
        let advance = (bd_deck_position(d) - p0) / Double(frames)
        print(String(format: "  varispeed: advance %.6f per frame (target 1.060000)", advance))
        check(abs(advance - 1.06) < 1e-4, "rate accurate to 1e-4")
        var crossings = 0
        for i in 1..<L.count where L[i - 1] < 0 && L[i] >= 0 { crossings += 1 }
        let hz = Double(crossings) / 2.0
        print(String(format: "  varispeed pitch: %.1f Hz (expect 466.4 = 440×1.06)", hz))
        check(abs(hz - 466.4) < 2.0, "vinyl-style pitch follows rate")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 5. crossfader law --------------------------------------------------
    do {
        let (d, m, render) = rig(sine(1000, seconds: 2.0))
        bd_mixer_set_crossfader(m, -1, 0)               // full A
        _ = render(Int(0.3 * sr))
        let (fullL, _) = render(Int(0.3 * sr))
        bd_mixer_set_crossfader(m, 0, 0)                // centre, constant-power
        _ = render(Int(0.3 * sr))
        let (midL, _) = render(Int(0.3 * sr))
        let drop = db(rms(midL[...]) / rms(fullL[...]))
        print(String(format: "  crossfader centre: %.2f dB (constant-power target -3.01)", drop))
        check(abs(drop + 3.01) < 0.1, "constant-power centre at -3 dB")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 6. realtime headroom ----------------------------------------------
    do {
        let (d, m, render) = rig(sine(220, seconds: 61.0))
        let t0 = Date()
        _ = render(Int(60.0 * sr))
        let took = -t0.timeIntervalSinceNow
        print(String(format: "  60 s render in %.2f s → %.0f× realtime (one deck, full strip)", took, 60.0 / took))
        check(took < 6.0, "≥10× realtime headroom")
        bd_mixer_free(m); bd_deck_free(d)
    }

    print(failures == 0 ? "  all deck DSP checks passed" : "  \(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}
