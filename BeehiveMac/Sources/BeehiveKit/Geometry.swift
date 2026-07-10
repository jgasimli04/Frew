import Foundation

/// Helix geometry: the corrected Frenet curvature/torsion closed forms.
/// Port of beehive/helix.py (note the omega^4 r0^2 term under the root -- the
/// typo this project fixed). Parametrised by n, so omega is the per-frame step.
public enum Geometry {

    public static func curvatureTorsion(omega: Double, r0: Double,
                                        h1: [Double], h2: [Double], h3: [Double])
        -> (kappa: [Double], tau: [Double]) {
        let n = h1.count
        var kappa = [Double](repeating: 0, count: n)
        var tau = [Double](repeating: 0, count: n)
        let w2 = omega * omega, w4 = w2 * w2, r2 = r0 * r0
        for i in 0..<n {
            let common = w4 * r2 + w2 * h1[i] * h1[i] + h2[i] * h2[i]
            let crossNorm = r0 * omega * (common).squareRoot()
            let speedSq = w2 * r2 + h1[i] * h1[i]
            kappa[i] = crossNorm / pow(speedSq, 1.5)
            tau[i] = omega * (w2 * h1[i] + h3[i]) / max(common, 1e-12)
        }
        return (kappa, tau)
    }
}

/// Numeric helpers mirroring numpy.gradient / cumsum on Double arrays.
public enum Num {

    /// Central-difference gradient (numpy.gradient: one-sided at the ends).
    public static func gradient(_ x: [Double]) -> [Double] {
        let n = x.count
        guard n > 1 else { return [Double](repeating: 0, count: n) }
        var g = [Double](repeating: 0, count: n)
        g[0] = x[1] - x[0]
        g[n - 1] = x[n - 1] - x[n - 2]
        for i in 1..<(n - 1) { g[i] = (x[i + 1] - x[i - 1]) / 2 }
        return g
    }

    public static func cumsum(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        var acc = 0.0
        for i in x.indices { acc += x[i]; out[i] = acc }
        return out
    }

    public static func std(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        let v = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)
        return v.squareRoot()
    }
}
