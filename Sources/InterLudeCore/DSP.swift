import Foundation

/// The signal maths the jingle matcher and the spectrum need. Results are scaled as Accelerate's vDSP gives them,
/// so a learned jingle matches whichever implementation a platform uses.
public protocol DSPKernels: Sendable {
    /// vDSP's normalised Hann window: sqrt(8/3) * 0.5 * (1 - cos(2 pi n / N)).
    func hannWindow(count: Int) -> [Float]
    /// Power spectrum of a real frame whose length N is a power of two, as vDSP's packed real FFT gives it: element k
    /// (0 < k < N/2) is |2 X_k|^2, and element 0 is |2 X_0|^2 plus |2 X_(N/2)|^2 unless `dropNyquist`.
    func powerSpectrum(_ frame: [Float], dropNyquist: Bool) -> [Float]
    /// Dot products of every row of `a` with every row of `b`, rows `width` long: a.count / width by b.count / width,
    /// row major.
    func rowDots(_ a: [Float], _ b: [Float], width: Int) -> [Float]
}

/// Plain Swift versions, for platforms without a vector library.
public final class PortableDSP: DSPKernels, @unchecked Sendable {
    private let lock = NSLock()
    private var twiddles: [Int: (cos: [Float], sin: [Float])] = [:]

    public init() {}

    public func hannWindow(count n: Int) -> [Float] {
        let scale = (8.0 / 3.0).squareRoot()
        return (0..<n).map { Float(scale * 0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n)))) }
    }

    public func powerSpectrum(_ frame: [Float], dropNyquist: Bool) -> [Float] {
        let n = frame.count, half = n / 2
        precondition(n >= 2 && n & (n - 1) == 0, "FFT length must be a power of two")
        var re = frame, im = [Float](repeating: 0, count: n)
        fft(&re, &im)
        var out = [Float](repeating: 0, count: half)
        for k in 1..<half { out[k] = 4 * (re[k] * re[k] + im[k] * im[k]) }
        out[0] = 4 * re[0] * re[0] + (dropNyquist ? 0 : 4 * re[half] * re[half])
        return out
    }

    public func rowDots(_ a: [Float], _ b: [Float], width d: Int) -> [Float] {
        guard d > 0 else { return [] }
        let m = a.count / d, n = b.count / d
        var out = [Float](repeating: 0, count: m * n)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in out.withUnsafeMutableBufferPointer { po in
            for i in 0..<m {
                let ra = i * d
                for j in 0..<n {
                    let rb = j * d
                    var s: Float = 0
                    for k in 0..<d { s += pa[ra + k] * pb[rb + k] }
                    po[i * n + j] = s
                }
            }
        } } }
        return out
    }

    /// cos and sin of 2 pi k / n for k below n / 2, kept per length.
    private func table(_ n: Int) -> (cos: [Float], sin: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if let t = twiddles[n] { return t }
        let t = (cos: (0..<n / 2).map { Float(Foundation.cos(2 * Double.pi * Double($0) / Double(n))) },
                 sin: (0..<n / 2).map { Float(Foundation.sin(2 * Double.pi * Double($0) / Double(n))) })
        twiddles[n] = t
        return t
    }

    /// In-place forward complex FFT, iterative radix 2.
    private func fft(_ re: inout [Float], _ im: inout [Float]) {
        let n = re.count
        let (c, s) = table(n)
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
            var j = 0
            for k in 1..<n {
                var bit = n >> 1
                while j & bit != 0 { j ^= bit; bit >>= 1 }
                j |= bit
                if k < j { r.swapAt(k, j); i.swapAt(k, j) }
            }
            var len = 2
            while len <= n {
                let step = n / len, h = len / 2
                var start = 0
                while start < n {
                    for k in 0..<h {
                        let wr = c[k * step], wi = -s[k * step]
                        let a = start + k, b = a + h
                        let tr = r[b] * wr - i[b] * wi, ti = r[b] * wi + i[b] * wr
                        r[b] = r[a] - tr; i[b] = i[a] - ti
                        r[a] += tr; i[a] += ti
                    }
                    start += len
                }
                len <<= 1
            }
        } }
    }
}
