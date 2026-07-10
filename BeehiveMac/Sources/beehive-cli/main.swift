import BeehiveKit
import Foundation

func ts(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

func peakMoments(_ r: HelixRecord, audibleDB: Float = -40, top: Int = 5) -> [Double] {
    var scored: [(Int, Double)] = []
    for i in 0..<r.nFrames where r.A[i] > audibleDB { scored.append((i, r.fMag[i])) }
    let topIdx = scored.sorted { $0.1 > $1.1 }.prefix(top).map { $0.0 }
    return topIdx.map { Double($0) * Double(r.meta.hop) / r.meta.sr }.sorted()
}

// Native self-test (same checks as the XCTest target, runnable under CLT).
func selftest() {
    func check(_ cond: Bool, _ msg: String) { print((cond ? "  PASS " : "  FAIL ") + msg); if !cond { exit(1) } }

    // centroid of a 1000 Hz sine sits near 1000 Hz
    let sr = 22050.0, n = 2048, f = 1000.0
    var frame = [Float](repeating: 0, count: n)
    for i in 0..<n { frame[i] = Float(sin(2 * Double.pi * f * Double(i) / sr)) }
    let mag = RealFFT(n: n).magnitude(frame, window: DSP.hann(n))
    let (hz, total) = Features.centroid(mag, freqs: DSP.rfftFreqs(n: n, sr: sr))
    check(total > 0 && abs(Double(hz) - f) < 30, "centroid of 1kHz sine = \(hz) Hz (≈1000)")

    // static passage -> tau = 0, kappa = 1/r0
    let meta = HelixMeta(songId: "t", sourcePath: "t", contentHash: "0", createdAt: "t",
        sr: 22050, nSamples: 200 * 1024, durationS: 1, nFFT: 2048, hop: 1024, win: 2048,
        nFrames: 200, bpm: 120, bpmConfidence: Double?.none, bpmSource: "provided", B: 4,
        omegaRadPerS: 0.04 * 22050 / 1024, omegaRadPerFrame: 0.04, r0: 1.0, fRef: 440,
        sigma: 0.5, floorDB: -80, wAmp: 1, wInt: 1, smoothFrames: 1)
    let rs = Engine.assemble(meta: meta, A: [Float](repeating: -12, count: 200),
        I: [Float](repeating: 0, count: 200),
        chroma: [[Float]](repeating: [Float](repeating: 1, count: 12), count: 200),
        engagement: [Float](repeating: 0, count: 200))
    check((rs.tau.map { abs($0) }.max() ?? 1) < 1e-9, "static passage: torsion τ = 0 (flat circle)")
    check((rs.kappa.map { abs($0 - 1.0) }.max() ?? 1) < 1e-9, "static passage: curvature κ = 1/r0")

    // geometry invariants on a moving record
    let A2 = (0..<64).map { Float(-12 + 4 * sin(Double($0) * 0.3)) }
    let I2 = (0..<64).map { Float(2 * cos(Double($0) * 0.2)) }
    let ch2 = (0..<64).map { i in (0..<12).map { Float(($0 + i) % 12) } }
    var m2 = meta; m2.nFrames = 64
    let r2 = Engine.assemble(meta: m2, A: A2, I: I2, chroma: ch2, engagement: [Float](repeating: 0, count: 64))
    var geomOK = true
    let r0sq = m2.r0 * m2.r0
    for i in 0..<64 {
        let radius: Double = r2.x[i] * r2.x[i] + r2.y[i] * r2.y[i]
        if abs(radius - r0sq) > 1e-9 { geomOK = false }
    }
    check(geomOK, "x²+y² = r0² for all frames")
    check(zip(r2.z, r2.h).allSatisfy { abs($0 - $1) < 1e-12 }, "z axis == climb h")
    print("  all self-tests passed")
}

if CommandLine.arguments.contains("--selftest") { selftest(); exit(0) }

// Play a .bee natively: Layer 1 decoded by the Rust core (bee-ffi) over the
// C ABI, rendered through AVAudioEngine. `beehive-cli play <file.bee> [seconds]`
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "play" {
    let path = CommandLine.arguments[2]
    let seconds = CommandLine.arguments.count > 3 ? (Double(CommandLine.arguments[3]) ?? 5) : 5
    do {
        let t0 = Date()
        let bee = try BeeFile(path: path)
        let pcm = bee.floatPCM()
        let openS = -t0.timeIntervalSinceNow
        let r = try bee.record()
        print((path as NSString).lastPathComponent)
        print(String(format: "  opened natively in %.2f s  (%d Hz, %d ch, %d frames, %.1f min)",
                     openS, Int(bee.sampleRate), bee.channels, bee.frames,
                     Double(bee.frames) / bee.sampleRate / 60))
        print("  record: \(r.meta.songId)   bpm \(String(format: "%.1f", r.meta.bpm))   helix frames \(r.nFrames)")
        let player = Player()
        player.load(channels: pcm, sampleRate: bee.sampleRate)
        player.play(from: 0)
        print("  playing \(String(format: "%.0f", seconds)) s through the default output…")
        let start = Date()
        while -start.timeIntervalSinceNow < seconds {
            Thread.sleep(forTimeInterval: 1.0)
            print(String(format: "  t = %5.2f s", player.currentTime))
        }
        player.stop()
        print("  done — audio path OK (bee-ffi → AVAudioEngine)")
        exit(0)
    } catch {
        print("play failed: \(error)")
        exit(1)
    }
}

let musicDir = ("~/Desktop/Music" as NSString).expandingTildeInPath
let fm = FileManager.default
let exts = ["aiff", "aif", "wav", "flac", "mp3", "m4a"]
let files = ((try? fm.contentsOfDirectory(atPath: musicDir)) ?? [])
    .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
    .sorted()

let args = CommandLine.arguments
let targets: [String]
if args.count > 1 { targets = [args[1]] }
else { targets = files.map { "\(musicDir)/\($0)" } }

var records: [HelixRecord] = []
for path in targets {
    let url = URL(fileURLWithPath: path)
    guard let (y, sr) = try? Audio.load(url: url) else { print("skip (decode failed): \(path)"); continue }
    let r = Engine.encode(samples: y, sr: sr, sourcePath: path)
    records.append(r)
    let name = (path as NSString).lastPathComponent
    print("\n\(name)")
    print("  duration  \(ts(r.meta.durationS))   sr \(Int(r.meta.sr))   frames \(r.nFrames)")
    let confStr = r.meta.bpmConfidence.map { String(format: " conf %.2f", $0) } ?? ""
    print(String(format: "  tempo     %.1f bpm (%@%@)   omega %.3f rad/s",
                 r.meta.bpm, r.meta.bpmSource, confStr, r.meta.omegaRadPerS))
    print("  climb     \(String(format: "%.1f", r.h.last ?? 0))")
    print("  peaks     " + peakMoments(r).map(ts).joined(separator: " · "))
    let cr = r.compressionReport()
    print("  size      \(cr.stored / 1024) KiB stored  vs  \(cr.stft / 1024) KiB STFT  (\(cr.ratioStored)x lighter)")
}

func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
}

func tasteMatrix(_ title: String, _ sigs: [[Float]], _ names: [String]) {
    print("\n=== \(title) ===")
    print(pad("", 8) + names.map { pad($0, 8) }.joined())
    for i in sigs.indices {
        var row = pad(names[i], 8)
        for j in sigs.indices { row += pad(String(format: "%.2f", Taste.cosine(sigs[i], sigs[j])), 8) }
        print(row)
    }
}

if records.count > 1 {
    let names = records.map { String(($0.meta.songId.split(separator: "-").first.map(String.init) ?? "").prefix(7)) }
    // Shown separately so the two ingredients can be judged on their own: the
    // shape matrix is the real fix (centred key-profile correlation); motion is
    // the on-theme extension — keep it only if it carries independent structure.
    tasteMatrix("tonal shape  (centred key profile)", records.map { Taste.tonalShape($0) }, names)
    tasteMatrix("tonal motion (chroma flux)",         records.map { Taste.tonalMotion($0) }, names)
    tasteMatrix("blended      (λ=0.4, what the app uses)", records.map { Taste.signature($0) }, names)
}
