import BeehiveKit
import Foundation

enum Falsifiers {

    // MARK: - Corpus load

    static func loadCorpus(norm: Periods.Norm = .biased) -> [TrackAnalysis] {
        let (rows, bee, excluded) = Corpus.scan()
        print("== corpus: \(Corpus.root.path) ==")
        for e in excluded { print("  EXCLUDED  \(e.0)  — \(e.1)") }
        for e in bee {
            print("  EXCLUDED  \(e.url.lastPathComponent) — .bee of a track already in the corpus; "
                  + "used as the same-audio control below, not as a row")
        }
        print("  \(rows.count) rows\n")

        var out: [TrackAnalysis] = []
        var checked = false
        for row in rows {
            do {
                let (mono, sr) = try Audio.load(url: row.url)
                if !checked {
                    // Guards this spike's parametrised band code against drift
                    // from BeehiveKit.BandEnvelopes, which it mirrors.
                    let worst = Envelopes.selfCheck(mono: Array(mono.prefix(Int(sr * 30))),
                                                    sr: sr, nFFT: Analysis.nFFT, hop: Analysis.hop)
                    print(String(format: "  selfCheck vs BandEnvelopes (5 bands, first 30 s): max abs diff %.3e\n", worst))
                    precondition(worst == 0, "band envelope path has drifted from BandEnvelopes")
                    checked = true
                }
                let a = try Analysis.analyse(mono: mono, sr: sr, label: row.label, norm: norm)
                Analysis.report(a)
                out.append(a)
            } catch {
                print("  FAILED    \(row.label) — \(error)")
            }
        }
        return out
    }

    // MARK: - F1

    static func f1(_ tracks: [TrackAnalysis]) {
        print("\n== F1 — period extraction stability (CoV of period across 32-beat windows) ==")
        let names = Bands.six.map(\.name)
        print("  " + "track".padding(toLength: 28, withPad: " ", startingAt: 0)
              + names.map { $0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined()
              + "  windows")
        var perBand = [[Double]](repeating: [], count: 6)
        for t in tracks {
            var line = "  " + t.label.padding(toLength: 28, withPad: " ", startingAt: 0)
            for b in 0..<6 {
                line += String(format: "%-8.3f", t.cov[b])
                perBand[b].append(t.cov[b])
            }
            line += "  \(t.windowPeriods[0].count)"
            print(line)
        }
        print("  " + "median across tracks".padding(toLength: 28, withPad: " ", startingAt: 0)
              + perBand.map { String(format: "%-8.3f", Stats.median($0)) }.joined())
        let all = perBand.flatMap { $0 }
        print(String(format: "  overall: min %.3f  median %.3f  max %.3f",
                     all.min() ?? .nan, Stats.median(all), all.max() ?? .nan))
    }

    // MARK: - F3

    static func f3(_ tracks: [TrackAnalysis]) {
        print("\n== F3 — groove discrimination ==")
        guard tracks.count > 1 else { print("  fewer than two tracks analysed"); return }

        print("\n  pairwise Euclidean distance between six-deficit vectors (degrees):")
        let w = 14
        print("  " + String(repeating: " ", count: 28)
              + tracks.map { String($0.label.prefix(w - 1)).padding(toLength: w, withPad: " ", startingAt: 0) }.joined())
        var pairs: [(Double, String, String)] = []
        for (i, a) in tracks.enumerated() {
            var line = "  " + a.label.padding(toLength: 28, withPad: " ", startingAt: 0)
            for (j, b) in tracks.enumerated() {
                let d = Octahedron.distance(a.deficitsDeg, b.deficitsDeg)
                line += String(format: "%-14.3f", d)
                if j > i { pairs.append((d, a.label, b.label)) }
            }
            print(line)
        }

        let ds = pairs.map(\.0).sorted()
        let closest = pairs.min { $0.0 < $1.0 }!
        let farthest = pairs.max { $0.0 < $1.0 }!
        print(String(format: "\n  %d pairs: min %.3f  median %.3f  max %.3f  (degrees)",
                     pairs.count, ds.first!, Stats.median(ds), ds.last!))
        print(String(format: "  closest:  %.3f  %@  vs  %@", closest.0, closest.1, closest.2))
        print(String(format: "  farthest: %.3f  %@  vs  %@", farthest.0, farthest.1, farthest.2))
    }

    /// The null F3 has to be read against: two disjoint halves of the same
    /// track. Each half is analysed independently, including its own
    /// `Tempo.estimateBPM` call, so the null carries the same estimator noise a
    /// between-track comparison does. If between-track distance is not clearly
    /// above this, the six-deficit vector is not identifying tracks.
    static func f3Null(norm: Periods.Norm = .biased) -> [Double] {
        print("\n== F3 null — same track, two disjoint halves ==")
        let (rows, _, _) = Corpus.scan()
        var within: [Double] = []
        for row in rows {
            guard let (mono, sr) = try? Audio.load(url: row.url) else { continue }
            let mid = mono.count / 2
            do {
                let a = try Analysis.analyse(mono: Array(mono[0..<mid]), sr: sr, label: row.label + " [1/2]", norm: norm)
                let b = try Analysis.analyse(mono: Array(mono[mid...]), sr: sr, label: row.label + " [2/2]", norm: norm)
                let d = Octahedron.distance(a.deficitsDeg, b.deficitsDeg)
                within.append(d)
                print(String(format: "  %-28@ %.3f    bpm %.2f / %.2f%@",
                             row.label as NSString, d, a.bpm, b.bpm,
                             abs(a.bpm - b.bpm) > 1 ? "  (bpm differs between halves)" : ""))
            } catch {
                print("  \(row.label): \(error)")
            }
        }
        if !within.isEmpty {
            print(String(format: "  within-track: min %.3f  median %.3f  max %.3f  (degrees)",
                         within.min()!, Stats.median(within), within.max()!))
        }
        return within
    }

    /// The window-count-matched version of F3.
    ///
    /// The plain F3 matrix comes from full-track analyses (9–41 windows) while
    /// the null comes from half-track analyses, which have about half as many
    /// windows each. Fewer windows means a noisier median period, so the null
    /// is inflated relative to the between-track figure and the ratio
    /// understates discrimination. This rebuilds the between-track matrix from
    /// first halves only, so both sides of the ratio carry the same window count.
    static func f3Matched(norm: Periods.Norm = .biased) -> Double {
        print("\n== F3 matched — between-track distance from first halves only ==")
        let (rows, _, _) = Corpus.scan()
        var halves: [TrackAnalysis] = []
        for row in rows {
            guard let (mono, sr) = try? Audio.load(url: row.url) else { continue }
            if let a = try? Analysis.analyse(mono: Array(mono[0..<(mono.count / 2)]),
                                             sr: sr, label: row.label, norm: norm) {
                halves.append(a)
            }
        }
        var pairs: [Double] = []
        for i in 0..<halves.count {
            for j in (i + 1)..<halves.count {
                pairs.append(Octahedron.distance(halves[i].deficitsDeg, halves[j].deficitsDeg))
            }
        }
        guard !pairs.isEmpty else { print("  too few halves analysed"); return .nan }
        let m = Stats.median(pairs)
        print(String(format: "  %d pairs, median window count %d: min %.3f  median %.3f  max %.3f  (degrees)",
                     pairs.count,
                     Int(Stats.median(halves.map { Double($0.windowPeriods[0].count) })),
                     pairs.min()!, m, pairs.max()!))
        return m
    }

    /// Same music, different container and decode path: `.bee` through the Rust
    /// core versus the sibling FLAC/AIFF through AVFoundation.
    static func beeControl() {
        print("\n== F3 control — .bee vs sibling container (same audio) ==")
        let (rows, bee, _) = Corpus.scan()
        for b in bee {
            let stem = b.url.deletingPathExtension().lastPathComponent
            guard let sibling = rows.first(where: { $0.url.deletingPathExtension().lastPathComponent == stem })
            else { print("  \(b.label): no sibling in the corpus"); continue }
            do {
                let file = try BeeFile(path: b.url.path)
                let channels = file.floatPCM()
                guard !channels.isEmpty else { print("  \(b.label): .bee decoded to no channels"); continue }
                let n = channels[0].count
                var mono = [Float](repeating: 0, count: n)
                for ch in channels { for i in 0..<n { mono[i] += ch[i] } }
                let inv = 1 / Float(channels.count)
                for i in 0..<n { mono[i] *= inv }

                let (sMono, sSr) = try Audio.load(url: sibling.url)
                let x = try Analysis.analyse(mono: mono, sr: file.sampleRate, label: b.label + " [.bee]")
                let y = try Analysis.analyse(mono: sMono, sr: sSr, label: sibling.label + " [\(sibling.url.pathExtension)]")
                // A 0.000° distance alone would not establish sample-identity:
                // `Periods.estimate` returns bestLag/beatFrames with integer
                // bestLag, so two different signals can land on the same median.
                // The content hash is what earns that claim.
                let identical = Audio.contentHash(mono) == Audio.contentHash(sMono)
                print(String(format: "  %-28@ %.3f degrees   bpm %.2f / %.2f   samples %@",
                             b.label as NSString,
                             Octahedron.distance(x.deficitsDeg, y.deficitsDeg), x.bpm, y.bpm,
                             (identical ? "identical (SHA-256)" : "differ") as NSString))
            } catch {
                print("  \(b.label): \(error)")
            }
        }
    }

    // MARK: - F2

    static func f2(_ factors: [Double] = [0.8, 0.9, 1.1, 1.25]) {
        print("\n== F2 — tempo invariance under varispeed resample ==")
        print("  two variants per factor:")
        print("    fixed  — band edges left at Bands.six, as the spike prompt specifies")
        print("    scaled — band edges multiplied by the same factor, so each band tracks")
        print("             the same spectral content and a residual is extraction noise only")
        let (rows, _, _) = Corpus.scan()

        var fixedWorst = 0.0, scaledWorst = 0.0
        for row in rows {
            guard let (mono, sr) = try? Audio.load(url: row.url),
                  let base = try? Analysis.analyse(mono: mono, sr: sr, label: row.label)
            else { print("  \(row.label): base analysis failed"); continue }
            print("  \(row.label)  base bpm \(String(format: "%.2f", base.bpm))")

            for f in factors {
                let resampled = Analysis.varispeed(mono, factor: f)
                for scaledEdges in [false, true] {
                    let edges = scaledEdges ? Bands.scaled(Bands.six, by: f) : Bands.six
                    guard let v = try? Analysis.analyse(mono: resampled, sr: sr,
                                                        label: row.label, edges: edges) else {
                        print(String(format: "    x%.2f %@: analysis failed", f, scaledEdges ? "scaled" : "fixed "))
                        continue
                    }
                    // An octave flip in Tempo.estimateBPM rescales every period
                    // in beats by 2, which is an estimator artifact rather than
                    // evidence about the architecture. Flagged, not silently kept.
                    let ratio = v.bpm / (base.bpm * f)
                    let octaveFlip = abs(log2(ratio)) > 0.4
                    let maxDelta = zip(base.deficitsDeg, v.deficitsDeg).map { abs($0 - $1) }.max() ?? .nan
                    print(String(format: "    x%.2f %@  bpm %.2f (expected %.2f)  max|Δdeficit| %.3f deg%@",
                                 f, scaledEdges ? "scaled" : "fixed ", v.bpm, base.bpm * f, maxDelta,
                                 octaveFlip ? "   DISCARDED: bpm octave flip" : ""))
                    if !octaveFlip {
                        if scaledEdges { scaledWorst = max(scaledWorst, maxDelta) }
                        else { fixedWorst = max(fixedWorst, maxDelta) }
                    }
                }
            }
        }
        print(String(format: "\n  worst max|Δdeficit| over all kept trials: fixed edges %.3f deg, scaled edges %.3f deg",
                     fixedWorst, scaledWorst))
    }

    // MARK: - F4

    static func f4() {
        print("\n== F4 — validity domain of the 4π sum ==")
        print("""
          Geometric note before the numbers: six positive radii on ±x/±y/±z have
          the axis-aligned octahedron as their convex hull for every positive
          tuple. It is closed, genus 0 and cannot self-intersect, so Descartes
          gives exactly 4π everywhere in the positive orthant. There is no
          geometric boundary to find; the only boundary is where floating point
          stops resolving the angles. That is what is swept below.
        """)

        print("\n  one radius swept against five held at 1.0:")
        var firstBreak: Double? = nil
        for e in stride(from: -9.0, through: 9.0, by: 1.0) {
            let r = pow(10.0, e)
            let residual = abs(Octahedron.residualOnly(radii: [r, 1, 1, 1, 1, 1]))
            let ok = residual <= 1e-6
            print(String(format: "    ratio 1e%+03.0f   |residual| %.3e   %@", e, residual, ok ? "ok" : "BREAKS 1e-6"))
            if !ok, firstBreak == nil { firstBreak = r }
        }

        print("\n  random six-tuples, log-uniform over a widening ratio span:")
        var generator = SystemRandomNumberGenerator()
        for span in [1.0, 2.0, 3.0, 4.0, 6.0, 8.0] {
            var worst = 0.0
            for _ in 0..<2000 {
                let radii = (0..<6).map { _ in pow(10.0, Double.random(in: -span/2...span/2, using: &generator)) }
                worst = max(worst, abs(Octahedron.residualOnly(radii: radii)))
            }
            print(String(format: "    max ratio 1e%.0f   worst |residual| over 2000 tuples %.3e   %@",
                         span, worst, worst <= 1e-6 ? "ok" : "BREAKS 1e-6"))
        }
        if let b = firstBreak {
            print(String(format: "\n  first single-axis ratio to break 1e-6: %.0e", b))
        } else {
            print("\n  no swept ratio broke the 1e-6 tolerance")
        }
    }
}
