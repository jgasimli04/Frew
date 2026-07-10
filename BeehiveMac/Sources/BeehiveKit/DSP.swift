import Accelerate
import Foundation

/// Low-level DSP: Hann window + a real FFT magnitude, both on the chip's SIMD
/// units via Accelerate (vDSP). This is the "uses the hardware" part for the
/// analysis pipeline; the Neural Engine path is the chroma projection (see
/// ChromaCoreML.swift) since only the matmul maps to a neural op.
public enum DSP {

    /// numpy.hanning-compatible window: 0.5 - 0.5*cos(2*pi*k/(N-1)).
    public static func hann(_ n: Int) -> [Float] {
        guard n > 1 else { return [Float](repeating: 1, count: max(n, 0)) }
        var w = [Float](repeating: 0, count: n)
        let d = Float(n - 1)
        for k in 0..<n { w[k] = 0.5 - 0.5 * cos(2 * .pi * Float(k) / d) }
        return w
    }

    /// rfft bin centre frequencies for an n-point FFT at sample rate sr,
    /// for the n/2 bins we keep (0 ..< n/2).
    public static func rfftFreqs(n: Int, sr: Double) -> [Float] {
        (0..<(n / 2)).map { Float(Double($0) * sr / Double(n)) }
    }
}

/// Real FFT magnitude via Accelerate's packed real-to-complex transform.
/// Absolute scaling is irrelevant downstream (centroid is a ratio, chroma is
/// normalised), so we don't bother matching numpy's normalisation constant.
public final class RealFFT {
    private let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    public init(n: Int) {
        self.n = n
        self.half = n / 2
        self.log2n = vDSP_Length(log2(Double(n)).rounded())
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitude spectrum (half bins, indices 0..<n/2) of frame .* window.
    public func magnitude(_ frame: [Float], window: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: n)
        vDSP.multiply(frame, window, result: &windowed)

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cmplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cmplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        mags[0] = 0   // bin 0 packs DC+Nyquist; we drop DC for centroid/chroma anyway
        return mags
    }
}
