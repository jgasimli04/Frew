import BeehiveKit
import SwiftUI

/// Energy spent ||F|| over time, with the top dynamic moments marked (m:ss) and
/// the playhead cursor. Drag anywhere to scrub.
struct EnergyView: View {
    let record: HelixRecord
    let peaks: [(time: Double, fmag: Double)]
    var playhead: Double          // fractional frame — glides at display rate
    var onScrub: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = record.nFrames
                guard n > 1 else { return }
                let fmax = max(record.fMag.max() ?? 1, 1e-6)
                let dur = record.meta.durationS

                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for i in stride(from: 0, to: n, by: max(1, n / Int(size.width.rounded()))) {
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    let y = size.height * (1 - CGFloat(record.fMag[i] / fmax))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [.orange.opacity(0.8), .orange.opacity(0.1)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                for p in peaks {
                    let x = size.width * CGFloat(p.time / max(dur, 1e-6))
                    var v = Path(); v.move(to: CGPoint(x: x, y: 0)); v.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(v, with: .color(.white.opacity(0.5)), lineWidth: 1)
                    ctx.draw(Text(mmss(p.time)).font(.caption2).foregroundColor(.white.opacity(0.8)),
                             at: CGPoint(x: x, y: 8))
                }

                // playhead
                let cf = min(max(playhead, 0), Double(n - 1))
                let cx = size.width * CGFloat(cf / Double(n - 1))
                var pl = Path(); pl.move(to: CGPoint(x: cx, y: 0)); pl.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(pl, with: .color(.cyan), lineWidth: 1.5)
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { val in
                onScrub(Double(val.location.x / max(geo.size.width, 1)))
            })
        }
    }
}

/// The "colour of the sound" over time: a hue strip dictated by timbre, with the
/// playhead cursor.
struct HueStripView: View {
    let record: HelixRecord
    var playhead: Double          // fractional frame — glides at display rate

    var body: some View {
        Canvas { ctx, size in
            let n = record.nFrames
            guard n > 0 else { return }
            let cols = Int(size.width.rounded())
            for c in 0..<max(cols, 1) {
                let i = min(n - 1, c * n / max(cols, 1))
                let col = Color(hue: Double(record.hue[i]),
                                saturation: Double(0.4 + 0.6 * record.sat[i]),
                                brightness: Double(0.25 + 0.75 * record.val[i]))
                let rect = CGRect(x: CGFloat(c), y: 0, width: 1.5, height: size.height)
                ctx.fill(Path(rect), with: .color(col))
            }
            if n > 1 {
                let cx = size.width * CGFloat(min(max(playhead, 0), Double(n - 1)) / Double(n - 1))
                var pl = Path(); pl.move(to: CGPoint(x: cx, y: 0)); pl.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(pl, with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

/// Taste profile: how similar other songs are to the selected one.
struct TasteView: View {
    let matches: [(name: String, score: Float)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TASTE MATCH (tonal shape + motion)").font(.caption).foregroundColor(.secondary)
            if matches.isEmpty {
                Text("encode more songs to compare").font(.caption2).foregroundColor(.secondary)
            }
            ForEach(matches, id: \.name) { m in
                HStack(spacing: 8) {
                    Text(m.name).font(.caption2).lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [.purple, .pink],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(max(0, min(1, m.score))))
                        }
                    }.frame(height: 12)
                    Text(String(format: "%.2f", m.score)).font(.caption2.monospaced())
                        .frame(width: 36)
                }
            }
        }
    }
}
