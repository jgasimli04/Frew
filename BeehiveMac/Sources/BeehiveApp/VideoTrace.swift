import AVFoundation
import SwiftUI
import Vision

/// Neural trace of the playing inspiration clip (BEEDECK_ROADMAP T10).
///
/// Vision's `VNDetectContoursRequest` (the OS schedules it onto the ANE/GPU)
/// traces the object outlines in the current video frame. The contours are
/// split into five strata by scale — the biggest shapes belong to the sub
/// bus, fine detail to the hi bus — so each EQ band literally owns a layer
/// of the picture. A new trace is taken once per beat (the θ quarter-bar
/// grid, the same grid SYNC locks to), so the traced set changes ON the
/// beat; between beats the live band levels animate each stratum's stroke.
@MainActor
final class VideoTraceEngine: ObservableObject {
    /// Five stratum path-groups (sub, low, mid, hiMid, hi), normalized 0..1,
    /// y flipped to screen orientation. Replaced wholesale once per beat.
    @Published private(set) var strata: [[SwiftUI.Path]] = Array(repeating: [], count: 5)
    /// Last trace's wall-clock cost — the number the T10 DoD watches.
    @Published private(set) var latencyMs: Double = 0

    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var busy = false
    private var lastBeat = Int.min

    /// Called when the beat index changes. Single-flight; skips silently if
    /// the previous trace is still running or no fresh frame is available.
    func sample(item: AVPlayerItem?, beat: Int) {
        guard let item else {
            if !strata.allSatisfy(\.isEmpty) { strata = Array(repeating: [], count: 5) }
            return
        }
        if item !== attachedItem {
            if let old = attachedItem, let out = output { old.remove(out) }
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(out)
            attachedItem = item
            output = out
            return                              // buffers start flowing next beat
        }
        guard beat != lastBeat, !busy, let out = output else { return }
        let t = item.currentTime()
        guard out.hasNewPixelBuffer(forItemTime: t),
              let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        else { return }
        lastBeat = beat
        busy = true
        Task { [weak self] in
            let (traced, ms) = await Task.detached(priority: .userInitiated) {
                let t0 = CFAbsoluteTimeGetCurrent()
                let traced = Self.trace(buf)
                return (traced, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }.value
            guard let self else { return }
            self.busy = false
            if let traced {
                self.strata = traced
                self.latencyMs = ms
            }
        }
    }

    /// One Vision pass → contours grouped into five scale strata.
    nonisolated private static func trace(_ buf: CVPixelBuffer) -> [[SwiftUI.Path]]? {
        let req = VNDetectContoursRequest()
        req.maximumImageDimension = 512         // trace cost is bounded by this
        req.contrastAdjustment = 1.6
        let handler = VNImageRequestHandler(cvPixelBuffer: buf, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first
        else { return nil }

        // walk the full flattened contour list — on low-key footage every
        // shape nests inside one outer region, so topLevelContours alone
        // collapses to a single path (measured in `--tracetest`)
        var items: [(path: CGPath, area: CGFloat)] = []
        for k in 0..<obs.contourCount {
            guard let c = try? obs.contour(at: k) else { continue }
            let p = c.normalizedPath
            let bb = p.boundingBox
            let area = bb.width * bb.height
            // drop pixel noise and the frame-filling outer region
            if area > 0.0006, area < 0.94 { items.append((p, area)) }
        }
        items.sort { $0.area > $1.area }
        items = Array(items.prefix(60))                    // clutter cap
        var strata: [[SwiftUI.Path]] = Array(repeating: [], count: 5)
        guard !items.isEmpty else { return strata }

        // Vision paths are normalized with a bottom-left origin: flip to screen
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        let per = max(items.count / 5, 1)
        for (k, item) in items.enumerated() {
            let s = min(k / per, 4)                        // biggest → sub … finest → hi
            if let flipped = item.path.copy(using: &flip) {
                strata[s].append(SwiftUI.Path(flipped))
            }
        }
        return strata
    }
}

/// Draws the beat-locked trace, each stratum stroked by its own band's live
/// level: a band at zero erases its layer of the picture, a hot band burns
/// its outlines in — the EQ literally redraws the video's edges.
struct TraceOverlay: View {
    let strata: [[SwiftUI.Path]]
    let bands: [Float]                 // 5 live levels (deck taps or offline env)

    // per-stratum stroke hue: sub → amber … hi → white-cyan
    private static let hues: [Double] = [0.09, 0.93, 0.33, 0.52, 0.58]

    var body: some View {
        Canvas { ctx, size in
            let toView = CGAffineTransform(scaleX: size.width, y: size.height)
            for s in 0..<5 {
                let level = Double(bands[s])
                guard level > 0.05, !strata[s].isEmpty else { continue }
                let sat = s == 4 ? 0.15 : 0.75             // hi band traces near-white
                let col = Color(hue: Self.hues[s], saturation: sat, brightness: 1)
                    .opacity(0.10 + 0.65 * level)
                let widthPt = CGFloat(0.8 + 2.6 * level)
                for p in strata[s] {
                    ctx.stroke(p.applying(toView), with: .color(col),
                               style: StrokeStyle(lineWidth: widthPt,
                                                  lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
