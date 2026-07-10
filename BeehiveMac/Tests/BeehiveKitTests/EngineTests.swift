import XCTest
@testable import BeehiveKit

final class EngineTests: XCTestCase {

    // A pure sine's spectral centroid should sit at its frequency.
    func testCentroidOfSine() {
        let sr = 22050.0, n = 2048, f = 1000.0
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = Float(sin(2 * Double.pi * f * Double(i) / sr)) }
        let fft = RealFFT(n: n)
        let mag = fft.magnitude(frame, window: DSP.hann(n))
        let (hz, total) = Features.centroid(mag, freqs: DSP.rfftFreqs(n: n, sr: sr))
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(Double(hz), f, accuracy: 30, "centroid \(hz) should be near \(f) Hz")
    }

    // Static passage: F = 0 -> torsion 0, curvature 1/r0 (a flat circle).
    func testStaticLimitFrenet() {
        var meta = makeMeta(n: 200, r0: 1.0, omegaN: 0.04)
        meta.smoothFrames = 1
        let A = [Float](repeating: -12, count: 200)
        let I = [Float](repeating: 0, count: 200)
        let chroma = [[Float]](repeating: [Float](repeating: 1, count: 12), count: 200)
        let r = Engine.assemble(meta: meta, A: A, I: I, chroma: chroma,
                                engagement: [Float](repeating: 0, count: 200))
        for v in r.tau { XCTAssertEqual(v, 0, accuracy: 1e-9) }
        for v in r.kappa { XCTAssertEqual(v, 1.0 / meta.r0, accuracy: 1e-9) }
        XCTAssertEqual(r.fMag.max() ?? 1, 0, accuracy: 1e-12)
    }

    // Geometry invariants on a derived record.
    func testGeometryInvariants() {
        let meta = makeMeta(n: 64, r0: 1.3, omegaN: 0.1)
        let A = (0..<64).map { Float(-12 + 4 * sin(Double($0) * 0.3)) }
        let I = (0..<64).map { Float(2 * cos(Double($0) * 0.2)) }
        let chroma = (0..<64).map { i in (0..<12).map { Float(($0 + i) % 12) } }
        let r = Engine.assemble(meta: meta, A: A, I: I, chroma: chroma,
                                engagement: [Float](repeating: 0, count: 64))
        for i in 0..<64 {
            XCTAssertEqual(r.x[i] * r.x[i] + r.y[i] * r.y[i], meta.r0 * meta.r0, accuracy: 1e-9)
            XCTAssertEqual(r.z[i], r.h[i], accuracy: 1e-12)               // z == climb
            XCTAssertEqual(r.alpha[i], meta.omegaRadPerFrame * Double(i), accuracy: 1e-12)
            XCTAssert(r.hue[i] >= 0 && r.hue[i] < 1.0001)
        }
        for i in 1..<64 { XCTAssertGreaterThanOrEqual(r.h[i], r.h[i - 1] - 1e-9) }  // climb non-decreasing
    }

    private func makeMeta(n: Int, r0: Double, omegaN: Double) -> HelixMeta {
        HelixMeta(songId: "t", sourcePath: "t", contentHash: "0", createdAt: "t",
                  sr: 22050, nSamples: n * 1024, durationS: 1, nFFT: 2048, hop: 1024,
                  win: 2048, nFrames: n, bpm: 120, bpmConfidence: nil, bpmSource: "provided",
                  B: 4, omegaRadPerS: omegaN * 22050 / 1024, omegaRadPerFrame: omegaN,
                  r0: r0, fRef: 440, sigma: 0.5, floorDB: -80, wAmp: 1, wInt: 1, smoothFrames: 1)
    }
}
