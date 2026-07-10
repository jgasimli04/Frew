import BeehiveKit
import SwiftUI

// MARK: - formatting

private func f(_ x: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", x) }
private func sgn(_ x: Double, _ d: Int = 3) -> String { (x >= 0 ? "+" : "") + f(x, d) }
private func bytesStr(_ b: Int) -> String {
    b >= (1 << 20) ? String(format: "%.2f MiB", Double(b) / Double(1 << 20)) : "\(b / 1024) KiB"
}
// chroma bin 0 = A (fRef = 440), ascending by semitone
private let pitchNames = ["A", "A♯", "B", "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯"]

// MARK: - small reusable pieces

private struct Row: View {
    let label: String
    let value: String
    var accent: Color = .primary
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption.monospaced()).foregroundColor(accent)
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                if let s = subtitle {
                    Text(s).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            content
        }
    }
}

private struct MiniBar: View {
    let fraction: Double
    var tint: Color = .orange
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: g.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }.frame(height: 5)
    }
}

private struct ChromaBars: View {
    let chroma: [Float]
    var body: some View {
        let mx = max(chroma.max() ?? 1, 1e-6)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<12, id: \.self) { k in
                VStack(spacing: 2) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(hue: Double(k) / 12, saturation: 0.7, brightness: 0.95))
                        .frame(height: max(2, 34 * CGFloat(chroma[k] / mx)))
                    Text(pitchNames[k]).font(.system(size: 7)).foregroundColor(.secondary)
                }
            }
        }.frame(height: 50, alignment: .bottom)
    }
}

// MARK: - DERIVE: the per-frame derivation chain, made literal

struct DeriveView: View {
    let record: HelixRecord
    let cursor: Int

    var body: some View {
        let r = record
        let i = min(max(cursor, 0), max(r.nFrames - 1, 0))
        let fMax = max(r.fMag.max() ?? 1, 1e-6)
        let hMax = max(r.h.last ?? 1, 1e-6)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DERIVE").font(.caption.weight(.bold)).foregroundColor(.cyan)
                Spacer()
                Text("frame \(i) / \(max(r.nFrames - 1, 0))")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            Text("t \(mmsscs(r.t[i]))   ·   α \(f(r.alpha[i], 2)) rad   ·   bar \(f(r.alpha[i] / (2 * Double.pi), 2))")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)

            InfoSection(title: "STATE", subtitle: "s(n) = (A, I)") {
                Row(label: "amplitude A", value: "\(f(Double(r.A[i]), 1)) dB")
                Row(label: "interval I", value: "\(sgn(Double(r.I[i]), 2)) st")
            }
            InfoSection(title: "FORCE", subtitle: "F = ds/dn") {
                Row(label: "dA/dn", value: sgn(r.dA[i]))
                Row(label: "dI/dn", value: sgn(r.dI[i]))
                Row(label: "‖F(n)‖", value: f(r.fMag[i]), accent: .orange)
                MiniBar(fraction: r.fMag[i] / fMax, tint: .orange)
            }
            InfoSection(title: "CLIMB", subtitle: "h = ∫‖F‖ dn") {
                Row(label: "height h", value: f(r.h[i], 2), accent: .green)
                MiniBar(fraction: r.h[i] / hMax, tint: .green)
                Row(label: "of completion", value: "\(Int((r.h[i] / hMax * 100).rounded()))%")
            }
            InfoSection(title: "GEOMETRY", subtitle: "Frenet–Serret") {
                Row(label: "curvature κ", value: f(r.kappa[i], 4))
                Row(label: "torsion τ", value: f(r.tau[i], 4))
            }
            InfoSection(title: "COLOUR", subtitle: "chroma → hue") {
                ChromaBars(chroma: r.chroma[i])
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hue: Double(r.hue[i]),
                                    saturation: Double(0.4 + 0.6 * r.sat[i]),
                                    brightness: Double(0.3 + 0.7 * r.val[i])))
                        .frame(width: 28, height: 18)
                    Text("hue \(f(Double(r.hue[i]), 2)) · sat \(f(Double(r.sat[i]), 2)) · val \(f(Double(r.val[i]), 2))")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - ANALYZE: whole-song stats, headlined by the compression win

struct AnalyzeView: View {
    let record: HelixRecord
    let peaks: [Double]

    var body: some View {
        let r = record
        let cr = r.compressionReport()

        VStack(alignment: .leading, spacing: 14) {
            Text("ANALYZE").font(.caption.weight(.bold)).foregroundColor(.pink)

            InfoSection(title: "SIGNAL") {
                Row(label: "duration", value: mmss(r.meta.durationS))
                Row(label: "frames", value: "\(r.nFrames)")
                Row(label: "sample rate", value: "\(Int(r.meta.sr)) Hz")
            }
            InfoSection(title: "TEMPO", subtitle: "ω = 2π·bpm/(60·B)") {
                let conf = r.meta.bpmConfidence.map { String(format: " · conf %.2f", $0) } ?? ""
                Row(label: "tempo", value: "\(f(r.meta.bpm, 1)) bpm")
                Row(label: "source", value: "\(r.meta.bpmSource)\(conf)")
                Row(label: "ω", value: "\(f(r.meta.omegaRadPerS, 3)) rad/s")
                Row(label: "bar", value: "\(r.meta.B) beats")
            }
            InfoSection(title: "COMPLETION", subtitle: "largest climb h") {
                Row(label: "h_max", value: f(r.h.last ?? 0, 1), accent: .green)
            }
            InfoSection(title: "COMPRESSION", subtitle: "vs dense STFT") {
                Row(label: "stored state", value: bytesStr(cr.stored))
                Row(label: "dense STFT", value: bytesStr(cr.stft))
                HStack {
                    Spacer()
                    Text("\(cr.ratioStored)× lighter")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(LinearGradient(colors: [.cyan, .green],
                                                        startPoint: .leading, endPoint: .trailing))
                    Spacer()
                }.padding(.top, 2)
            }
            if !peaks.isEmpty {
                InfoSection(title: "PEAKS", subtitle: "top dynamic moments") {
                    Text(peaks.map(mmss).joined(separator: " · "))
                        .font(.caption2.monospaced()).foregroundColor(.orange)
                }
            }
        }
    }
}
