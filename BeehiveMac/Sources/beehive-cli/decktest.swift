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

    // ======================= beat FX (T5, θ-synced) =========================
    let beat = sr * 60.0 / 120.0                    // 120 bpm → 22050 samples

    /// |peak| positions above `thresh`, grouped so one tap = one peak.
    func taps(_ x: [Float], thresh: Float, minGap: Int) -> [Int] {
        var out: [Int] = []
        var i = 0
        while i < x.count {
            if abs(x[i]) > thresh {
                var best = i
                for j in i..<min(i + minGap, x.count) where abs(x[j]) > abs(x[best]) { best = j }
                out.append(best)
                i = best + minGap
            } else { i += 1 }
        }
        return out
    }

    // ---- 7. echo taps land on the θ grid — at native rate and varispeed ----
    // DoD (BEEDECK_ROADMAP T5): "echo tail lands on the grid at any tempo".
    // A single impulse through ECHO(1 beat) must repeat every beat_src/rate
    // output samples; measured tap spacing error is the claim.
    for rate in [1.0, 1.06] {
        var track = [Float](repeating: 0, count: Int(6 * sr))
        track[4410] = 1.0                            // past the play-in ramp
        let (d, m, render) = rig(track)
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_ECHO), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_beats(d, 1)
        bd_deck_set_fx_amount(d, 0.7)
        if rate != 1.0 { bd_deck_set_rate(d, rate) }
        let (L, _) = render(Int(4.5 * sr))
        let expected = beat / rate
        let t = taps(L, thresh: 0.02, minGap: 4000)
        var spacings: [Double] = []
        for k in 1..<t.count { spacings.append(Double(t[k] - t[k - 1])) }
        let worstErr = spacings.map { abs($0 - expected) }.max() ?? .infinity
        print(String(format: "  echo @rate %.2f: %d taps, spacing target %.1f, worst err %.1f samples (%.2f ms)",
                     rate, t.count, expected, worstErr, worstErr / sr * 1000))
        check(t.count >= 5, "echo rings ≥5 taps above -34 dB (rate \(rate))")
        check(worstErr <= 5, "every echo tap lands on the grid within 5 samples ≈ 0.11 ms (rate \(rate))")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 8. FX engage/bypass is click-free (DoD) ----------------------------
    do {
        let track = sine(440, seconds: 4.0)
        let natural = Double(track.indices.dropFirst().map { abs(track[$0] - track[$0 - 1]) }.max()!)
        let (d, m, render) = rig(track)
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx_amount(d, 0.7)
        _ = render(Int(0.3 * sr))                    // settle
        var worstStep = 0.0
        for ty in [BD_FX_ECHO, BD_FX_DUCK, BD_FX_ROLL, BD_FX_REVERSE, BD_FX_DRIVE,
                   BD_FX_SWEEP, BD_FX_FLANGER, BD_FX_PHASER, BD_FX_SLICER, BD_FX_REVERB] {
            bd_deck_set_fx(d, Int32(ty), Int32(BD_FXT_ALL), true)
            let (a, _) = render(Int(0.6 * sr))
            bd_deck_set_fx(d, Int32(ty), Int32(BD_FXT_ALL), false)
            let (b, _) = render(Int(0.4 * sr))
            for x in [a, b] {
                let s = Double(x.indices.dropFirst().map { abs(x[$0] - x[$0 - 1]) }.max()!)
                if s > worstStep { worstStep = s }
            }
        }
        print(String(format: "  FX engage/bypass: worst step %.4f vs clean sine %.4f (×%.2f)",
                     worstStep, natural, worstStep / natural))
        check(worstStep < 2.5 * natural, "all ten FX engage and bypass click-free (DoD)")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 9. DUCK is the φ envelope: silent on the beat, unity off-beat ------
    do {
        let (d, m, render) = rig(sine(1000, seconds: 5.0))
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_DUCK), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_beats(d, 1)
        bd_deck_set_fx_amount(d, 1.0)
        let (L, _) = render(Int(4.0 * sr))
        let w = Int(0.025 * sr)                      // ±25 ms windows
        let clean = rms(sine(1000, seconds: 1.0)[0..<(2 * w)])
        var beatDb = 0.0, offDb = 0.0, cnt = 0.0
        for k in 3...5 {
            let c = Int(Double(k) * beat), o = c + Int(beat / 2)
            beatDb += db(rms(L[(c - w)..<(c + w)]) / clean)
            offDb += db(rms(L[(o - w)..<(o + w)]) / clean)
            cnt += 1
        }
        print(String(format: "  duck: %.1f dB on the beat · %+.2f dB off-beat (φ envelope)",
                     beatDb / cnt, offDb / cnt))
        check(beatDb / cnt < -15, "duck ≥15 dB down at φ=0")
        check(abs(offDb / cnt) < 1.5, "duck transparent at φ=0.5 (<1.5 dB)")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 10. REVERSE plays the previous θ-cycle backwards -------------------
    do {
        let n = Int(5 * sr)
        let track = (0..<n).map { 0.8 * Float($0 % Int(beat)) / Float(beat) }  // rising saw per beat
        let (d, m, render) = rig(track)
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_REVERSE), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_beats(d, 1)
        let (L, _) = render(Int(4.0 * sr))
        var falling = 0, total = 0
        for k in 2...5 {                             // settled cycles
            let s = Int(Double(k) * beat)
            let q = Int(beat / 4)
            let firstHalf = rms(L[(s + q / 2)..<(s + q + q / 2)])
            let secondHalf = rms(L[(s + 2 * q + q / 2)..<(s + 3 * q + q / 2)])
            total += 1
            if firstHalf > secondHalf { falling += 1 }   // reversed saw: high → low
        }
        print("  reverse: \(falling)/\(total) cycles play high→low (input plays low→high)")
        check(falling == total, "REVERSE inverts every θ cycle")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 11. ROLL freezes the last θ-cycle (slip-style) ---------------------
    do {
        let base = sine(330, seconds: 6.0)
        let loud = Int(2 * beat)                     // 2 beats at 0.8, then 0.1
        let track = base.indices.map { base[$0] * ($0 < loud ? 1.6 : 0.2) }
        let (d, m, render) = rig(track)
        bd_deck_set_grid(d, beat, 0)
        _ = render(Int(2.1 * Double(beat) / sr * sr))      // capture the loud cycle
        bd_deck_set_fx(d, Int32(BD_FX_ROLL), Int32(BD_FXT_ALL), true)    // grab it
        _ = render(Int(0.1 * sr))
        let (rollOut, _) = render(Int(beat))
        bd_deck_set_fx(d, Int32(BD_FX_ROLL), Int32(BD_FXT_ALL), false)   // let go
        _ = render(Int(0.3 * sr))
        let (dryOut, _) = render(Int(beat))
        let rollRms = rms(rollOut[...]), dryRms = rms(dryOut[...])
        print(String(format: "  roll: held rms %.3f (loud slice) vs released rms %.3f (quiet input)",
                     rollRms, dryRms))
        check(rollRms > 0.35, "ROLL keeps replaying the captured loud cycle")
        check(dryRms < 0.12, "releasing ROLL falls back to the (quiet) live input")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 12. RELEASE echo-out: dry mutes, repeats decay on the grid, dry returns
    do {
        let (d, m, render) = rig(sine(440, seconds: 8.0))
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx_beats(d, 0.5)                 // repeats every half beat
        _ = render(Int(0.5 * sr))
        let (pre, _) = render(Int(0.3 * sr))
        bd_deck_set_fx_release(d, true)              // hold
        _ = render(Int(0.05 * sr))                   // mute transition
        let D = Int(beat / 2)
        let (held, _) = render(4 * D)
        var winDb: [Double] = []
        for k in 0..<4 { winDb.append(db(rms(held[(k * D)..<((k + 1) * D)]))) }
        bd_deck_set_fx_release(d, false)             // let go
        _ = render(Int(0.4 * sr))
        let (post, _) = render(Int(0.3 * sr))
        let drop = winDb[3] - winDb[0]
        let back = db(rms(post[...]) / rms(pre[...]))
        print(String(format: "  release: repeat windows %@ dB → decay %.1f dB over 3 taps; dry back within %+.2f dB",
                     winDb.map { String(format: "%.1f", $0) }.joined(separator: " / "), drop, back))
        check(winDb[3] < winDb[0] - 8, "repeats decay ≥8 dB across 3 taps while held")
        check(zip(winDb, winDb.dropFirst()).allSatisfy { $0 >= $1 - 0.5 }, "decay is monotonic")
        check(abs(back) < 2.0, "dry returns within 2 dB after release")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 13. DRIVE actually distorts (crest factor collapses) ---------------
    do {
        let (d, m, render) = rig(sine(220, seconds: 3.0))
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_DRIVE), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_amount(d, 1.0)
        _ = render(Int(0.5 * sr))
        let (L, _) = render(Int(0.5 * sr))
        let peak = Double(L.map { abs($0) }.max()!)
        let crest = peak / rms(L[...])
        print(String(format: "  drive: crest factor %.3f (clean sine 1.414 → square 1.0)", crest))
        check(crest < 1.15, "waveshaper squares the sine (crest < 1.15)")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 14. SWEEP: resonant LP rides φ — closed on the beat, open mid-cycle
    do {
        let (d, m, render) = rig(sine(6000, seconds: 5.0))
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_SWEEP), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_beats(d, 1)
        bd_deck_set_fx_amount(d, 0.5)
        let (L, _) = render(Int(4.0 * sr))
        let w = Int(0.02 * sr)
        let clean = rms(sine(6000, seconds: 1.0)[0..<(2 * w)])
        var closedDb = 0.0, openDb = 0.0
        for k in 3...5 {
            let c = Int(Double(k) * beat), o = c + Int(beat / 2)
            closedDb += db(rms(L[(c - w)..<(c + w)]) / clean) / 3
            openDb += db(rms(L[(o - w)..<(o + w)]) / clean) / 3
        }
        print(String(format: "  sweep: 6 kHz %.1f dB at φ=0 (fc 200 Hz) · %+.1f dB at φ=0.5 (open)",
                     closedDb, openDb))
        check(closedDb < -25, "sweep closes ≥25 dB on the beat")
        check(openDb > -4, "sweep opens by mid-cycle (>-4 dB)")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 15/16. FLANGER and PHASER: φ-swept notch modulates a 1 kHz tone ----
    for (name, ty, minRange) in [("flanger", BD_FX_FLANGER, 6.0), ("phaser", BD_FX_PHASER, 4.0)] {
        let (d, m, render) = rig(sine(1000, seconds: 6.0))
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(ty), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_beats(d, 2)                   // one full LFO per 2 beats
        bd_deck_set_fx_amount(d, 1.0)
        _ = render(Int(1.0 * sr))                    // settle
        let cyc = Int(2 * beat)
        let (L, _) = render(2 * cyc)
        var lo = Double.infinity, hi = -Double.infinity
        let win = cyc / 20
        for k in 0..<(2 * cyc / win) {
            let v = db(rms(L[(k * win)..<((k + 1) * win)]))
            lo = min(lo, v); hi = max(hi, v)
        }
        print(String(format: "  %@: 1 kHz level swings %.1f dB across the θ cycle", name, hi - lo))
        check(hi - lo > minRange, "\(name) notch sweeps through the tone (≥\(Int(minRange)) dB swing)")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 17. SLICER re-sequences the previous cycle -------------------------
    // Input: 8 slices per beat with staircase amplitude (slice s → (s+1)/8).
    // Pattern at amount 0 = [0,0,2,2,4,4,6,6]; output slice rms must follow
    // the *pattern's* source slices, not the live input.
    do {
        let n = Int(5 * sr)
        let slice = beat / 8.0
        let base = sine(500, seconds: 5.0, amp: 1.0)
        let track = (0..<n).map { i -> Float in
            let s = Int(Double(i).truncatingRemainder(dividingBy: beat) / slice) & 7
            return base[i] * Float(s + 1) / 8.0
        }
        let (d, m, render) = rig(track)
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_SLICER), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_beats(d, 1)
        bd_deck_set_fx_amount(d, 0.0)
        let (L, _) = render(Int(4.0 * sr))
        let pat = [0, 0, 2, 2, 4, 4, 6, 6]
        var okSlices = 0
        let cyc0 = Int(2 * beat)                     // settled cycle
        for s in 0..<8 {
            let a = cyc0 + Int((Double(s) + 0.25) * slice)
            let b = cyc0 + Int((Double(s) + 0.75) * slice)
            let got = rms(L[a..<b])
            let want = Double(pat[s] + 1) / 8.0 * rms(base[0..<Int(slice / 2)])
            if abs(db(got / want)) < 1.5 { okSlices += 1 }
        }
        print("  slicer: \(okSlices)/8 output slices match pattern [0,0,2,2,4,4,6,6] within 1.5 dB")
        check(okSlices == 8, "SLICER replays the previous cycle in pattern order")
        bd_mixer_free(m); bd_deck_free(d)
    }

    // ---- 18. REVERB: tail rings past the dry and decays ----------------------
    do {
        var track = [Float](repeating: 0, count: Int(6 * sr))
        for i in 0..<Int(0.05 * sr) { track[Int(1.0 * sr) + i] = sine(800, seconds: 0.1)[i] }  // 50 ms burst at t=1
        let (d, m, render) = rig(track)
        bd_deck_set_grid(d, beat, 0)
        bd_deck_set_fx(d, Int32(BD_FX_REVERB), Int32(BD_FXT_ALL), true)
        bd_deck_set_fx_amount(d, 1.0)                // RT60 ≈ 2.2 s
        let (L, _) = render(Int(4.0 * sr))
        let t1 = db(rms(L[Int(1.6 * sr)..<Int(1.9 * sr)]))
        let t2 = db(rms(L[Int(2.5 * sr)..<Int(2.8 * sr)]))
        let floor0 = db(rms(L[Int(0.3 * sr)..<Int(0.8 * sr)]))
        print(String(format: "  reverb: tail %.1f dB @1.75 s · %.1f dB @2.65 s (pre-burst floor %.1f dB)",
                     t1, t2, floor0))
        check(t1 > -60 && t1 < -10, "tail is audible 0.6 s after a 50 ms burst")
        check(t2 < t1 - 3, "tail decays monotonically (≥3 dB per 0.9 s at RT60 2.2 s)")
        check(floor0 == -Double.infinity || floor0 < -80, "silence before the burst stays silent")
        bd_mixer_free(m); bd_deck_free(d)
    }

    print(failures == 0 ? "  all deck DSP checks passed" : "  \(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}
