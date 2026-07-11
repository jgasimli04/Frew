import CoreGraphics
import Foundation
import Vision

/// T10 DoD harness: measures the cost of one neural contour trace — the same
/// `VNDetectContoursRequest` configuration `VideoTraceEngine` runs once per
/// beat — on a synthetic 512² frame with objects at the five stratum scales.
/// Pass condition: contours found at every scale and the median trace fits
/// inside a beat with plenty to spare (< 50 ms; a beat at 174 bpm is 345 ms).
func tracetest() {
    print("— neural trace (T10) —")
    let W = 512
    guard let ctx = CGContext(data: nil, width: W, height: W,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        print("FAIL could not build test frame"); exit(1)
    }
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
    // objects across the five stratum scales: one big block, mid rectangles,
    // and a field of fine dots
    ctx.fill(CGRect(x: 40, y: 60, width: 260, height: 300))            // sub-scale
    for k in 0..<4 {                                                    // mid-scale
        ctx.fill(CGRect(x: 330 + (k % 2) * 80, y: 80 + (k / 2) * 120,
                        width: 56, height: 88))
    }
    for k in 0..<40 {                                                   // hi-scale
        ctx.fillEllipse(in: CGRect(x: 20 + (k % 10) * 48, y: 420 + (k / 10) * 20,
                                   width: 9, height: 9))
    }
    guard let img = ctx.makeImage() else { print("FAIL frame render"); exit(1) }

    var times: [Double] = []
    var contourCount = 0
    for _ in 0..<20 {
        let req = VNDetectContoursRequest()
        req.maximumImageDimension = 512
        req.contrastAdjustment = 1.6
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        let t0 = CFAbsoluteTimeGetCurrent()
        do { try handler.perform([req]) } catch {
            print("FAIL Vision: \(error)"); exit(1)
        }
        times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        contourCount = req.results?.first?.contourCount ?? 0
    }
    times.sort()
    let median = times[times.count / 2]
    print(String(format: "  contours: %d · median %.1f ms · worst %.1f ms (512², 20 runs)",
                 contourCount, median, times.last ?? 0))
    let pass = contourCount >= 45 && median < 50    // 1 block + 4 rects + 40 dots
    print(pass ? "  PASS trace inside the beat budget"
               : "  FAIL contours=\(contourCount) median=\(median)ms (want ≥45 under 50 ms)")
    exit(pass ? 0 : 1)
}
