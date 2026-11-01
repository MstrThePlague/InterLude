//  DSP.swift
//  InterLudeCore
//
//  The signal maths the jingle matcher and the spectrum need, behind a protocol so the Mac can use Accelerate and
//  other platforms the plain Swift versions here. Results are scaled exactly as Accelerate's vDSP gives them, so a
//  jingle learned on one platform matches on the other.

import Foundation

/// The kernels the core needs from a vector library.
public protocol DSPKernels: Sendable {
    /// vDSP's normalised Hann window: sqrt(8/3) · 0.5 · (1 − cos(2πn / N)).
    func hannWindow(count: Int) -> [Float]
    /// The power spectrum of a real frame, as vDSP's packed real FFT gives it.
    ///
    /// - Parameters:
    ///   - frame: N samples, where N is a power of two.
    ///   - dropNyquist: Whether to leave the Nyquist term out of element 0.
    /// - Returns: N/2 values. Element k (0 < k < N/2) is |2·X_k|²; element 0 is |2·X_0|², plus |2·X_(N/2)|² unless
    ///   `dropNyquist`.
    func powerSpectrum(_ frame: [Float], dropNyquist: Bool) -> [Float]
    /// Dot products of every row of `a` with every row of `b`.
    ///
    /// - Parameters:
    ///   - a: Rows of `width` values, back to back.
    ///   - b: Rows of `width` values, back to back.
    ///   - width: The length of each row.
    /// - Returns: An (a.count / width) × (b.count / width) matrix, row major.
    func rowDots(_ a: [Float], _ b: [Float], width: Int) -> [Float]
}

/// Plain Swift versions of the kernels, for platforms without a vector library.
public final class PortableDSP: DSPKernels, @unchecked Sendable {
    private let lock = NSLock()
    /// cos and sin tables for each FFT length used so far.
    private var twiddles: [Int: (cos: [Float], sin: [Float])] = [:]

    public init() {}

    public func hannWindow(count: Int) -> [Float] {
        let scale = (8.0 / 3.0).squareRoot()
        return (0..<count).map { Float(scale * 0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(count)))) }
    }

    public func powerSpectrum(_ frame: [Float], dropNyquist: Bool) -> [Float] {
        let length = frame.count, half = length / 2
        precondition(length >= 2 && length & (length - 1) == 0, "FFT length must be a power of two")
        var real = frame, imaginary = [Float](repeating: 0, count: length)
        fft(&real, &imaginary)
        // vDSP's real FFT returns twice the true transform, hence the factor of four in the power.
        var power = [Float](repeating: 0, count: half)
        for k in 1..<half { power[k] = 4 * (real[k] * real[k] + imaginary[k] * imaginary[k]) }
        power[0] = 4 * real[0] * real[0] + (dropNyquist ? 0 : 4 * real[half] * real[half])
        return power
    }

    public func rowDots(_ a: [Float], _ b: [Float], width: Int) -> [Float] {
        guard width > 0 else { return [] }
        let rowsA = a.count / width, rowsB = b.count / width
        var out = [Float](repeating: 0, count: rowsA * rowsB)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in out.withUnsafeMutableBufferPointer { po in
            for i in 0..<rowsA {
                let rowA = i * width
                for j in 0..<rowsB {
                    let rowB = j * width
                    var sum: Float = 0
                    for k in 0..<width { sum += pa[rowA + k] * pb[rowB + k] }
                    po[i * rowsB + j] = sum
                }
            }
        } } }
        return out
    }

    /// cos and sin of 2πk / n for k below n / 2, computed once per length.
    private func table(_ n: Int) -> (cos: [Float], sin: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if let cached = twiddles[n] { return cached }
        let table = (cos: (0..<n / 2).map { Float(Foundation.cos(2 * Double.pi * Double($0) / Double(n))) },
                     sin: (0..<n / 2).map { Float(Foundation.sin(2 * Double.pi * Double($0) / Double(n))) })
        twiddles[n] = table
        return table
    }

    /// An in-place forward complex FFT: iterative radix 2, decimation in time.
    private func fft(_ real: inout [Float], _ imaginary: inout [Float]) {
        let n = real.count
        let (cosines, sines) = table(n)
        real.withUnsafeMutableBufferPointer { re in imaginary.withUnsafeMutableBufferPointer { im in
            // Put the input in bit-reversed order.
            var reversed = 0
            for k in 1..<n {
                var bit = n >> 1
                while reversed & bit != 0 { reversed ^= bit; bit >>= 1 }
                reversed |= bit
                if k < reversed { re.swapAt(k, reversed); im.swapAt(k, reversed) }
            }
            // Combine ever longer butterflies.
            var length = 2
            while length <= n {
                let step = n / length, half = length / 2
                var start = 0
                while start < n {
                    for k in 0..<half {
                        let wr = cosines[k * step], wi = -sines[k * step]
                        let top = start + k, bottom = top + half
                        let tr = re[bottom] * wr - im[bottom] * wi, ti = re[bottom] * wi + im[bottom] * wr
                        re[bottom] = re[top] - tr; im[bottom] = im[top] - ti
                        re[top] += tr; im[top] += ti
                    }
                    start += length
                }
                length <<= 1
            }
        } }
    }
}
