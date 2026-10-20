import Foundation
import simd

/// Stage 2 — the octahedron and its angle deficits.
///
/// Six radii sit on the six axis directions in `axisOrder`. The eight faces
/// take one vertex from each axis pair, so every face is one octant's triangle
/// and the surface is closed. Deficit at a vertex is `2π − Σ(incident face
/// angles)`; each vertex is in four of the eight faces.
///
/// Descartes / discrete Gauss–Bonnet says the six deficits sum to exactly 4π
/// for a closed genus-0 triangulation. `deficits(radii:)` asserts that to 1e-6
/// and traps if it fails — that assertion is this spike's own correctness
/// check, and if it ever fires the geometry is being built wrong and every
/// other number in RESULTS.md is meaningless.
enum Octahedron {

    /// Which band drives which axis. Bands are assigned in frequency order to
    /// `+x, −x, +y, −y, +z, −z`, so each axis pair holds two adjacent bands.
    /// This is a free choice: it changes the numeric deficits but not whether
    /// they carry information, and it is held fixed across every track so the
    /// F3 distances are comparable.
    static let axisOrder: [SIMD3<Double>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
        SIMD3(0, 1, 0), SIMD3(0, -1, 0),
        SIMD3(0, 0, 1), SIMD3(0, 0, -1),
    ]

    /// The eight faces as vertex-index triples: one from {0,1}, one from {2,3},
    /// one from {4,5}.
    static let faces: [(Int, Int, Int)] = {
        var out: [(Int, Int, Int)] = []
        for i in [0, 1] { for j in [2, 3] { for k in [4, 5] { out.append((i, j, k)) } } }
        return out
    }()

    static func vertices(radii: [Double]) -> [SIMD3<Double>] {
        zip(axisOrder, radii).map { $0 * $1 }
    }

    /// Interior angle of triangle (a,b,c) at vertex `a`.
    private static func angle(at a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double {
        let u = b - a, v = c - a
        let lu = simd_length(u), lv = simd_length(v)
        guard lu > 0, lv > 0 else { return 0 }
        let cosine = simd_dot(u, v) / (lu * lv)
        return acos(min(max(cosine, -1), 1))
    }

    struct Result {
        /// Six deficits in radians, in `axisOrder` order.
        let radians: [Double]
        /// Same, in degrees — the unit RESULTS.md reports.
        var degrees: [Double] { radians.map { $0 * 180 / .pi } }
        /// `Σ deficits − 4π`, the Descartes residual.
        let residual: Double
    }

    /// Traps if the Descartes residual exceeds `tolerance`.
    @discardableResult
    static func deficits(radii: [Double], tolerance: Double = 1e-6) -> Result {
        precondition(radii.count == 6, "the octahedron takes exactly six radii")
        precondition(radii.allSatisfy { $0 > 0 }, "radii must be positive: \(radii)")
        let v = vertices(radii: radii)

        var sums = [Double](repeating: 0, count: 6)
        for (i, j, k) in faces {
            sums[i] += angle(at: v[i], v[j], v[k])
            sums[j] += angle(at: v[j], v[i], v[k])
            sums[k] += angle(at: v[k], v[i], v[j])
        }
        let deficits = sums.map { 2 * Double.pi - $0 }
        let residual = deficits.reduce(0, +) - 4 * Double.pi

        precondition(abs(residual) <= tolerance,
                     "Descartes residual \(residual) exceeds \(tolerance) for radii \(radii) — "
                     + "the polyhedron is not a closed genus-0 triangulation, so no other "
                     + "number in this run means anything.")
        return Result(radians: deficits, residual: residual)
    }

    /// Same computation with no assertion — F4 needs to observe the residual
    /// past the point where it breaks, which `deficits(radii:)` would trap on.
    static func residualOnly(radii: [Double]) -> Double {
        let v = vertices(radii: radii)
        var sums = [Double](repeating: 0, count: 6)
        for (i, j, k) in faces {
            sums[i] += angle(at: v[i], v[j], v[k])
            sums[j] += angle(at: v[j], v[i], v[k])
            sums[k] += angle(at: v[k], v[i], v[j])
        }
        return sums.map { 2 * Double.pi - $0 }.reduce(0, +) - 4 * Double.pi
    }

    /// Euclidean distance between two deficit vectors, in degrees.
    /// The vectors live on the hyperplane `Σ = 4π`, so this is a distance
    /// within a 5-dimensional affine subspace, not a 6-dimensional one.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
    }
}
