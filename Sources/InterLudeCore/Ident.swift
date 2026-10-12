import Foundation
import Accelerate
import AVFoundation

/// Log-band spectral features, 32 bands from 100 Hz to 8 kHz, one frame every 2048 samples (about 43 ms at 48 kHz).
public enum IdentFeatures {
    public static let bands = 32
    public static let fftSize = 4096
    public static let hop = 2048
    public static let frameSeconds = Double(hop) / 48000

    public static func extract(_ samples: [Float]) -> [[Float]] { extract(samples, bands: bands, log2n: 12, hop: hop) }

    public static func extract(_ samples: [Float], bands: Int, log2n: Int, hop: Int) -> [[Float]] {
        let fftSize = 1 << log2n
        guard samples.count >= fftSize, let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let n = fftSize, half = n / 2
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        // Band edges, log spaced
        let edges: [Int] = (0...bands).map { b in
            let f = 100.0 * pow(8000.0 / 100.0, Double(b) / Double(bands))
            return min(half - 1, Int(f / 48000 * Double(n)))
        }
        var out: [[Float]] = []
        var start = 0
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        while start + n <= samples.count {
            vDSP_vmul(Array(samples[start..<(start + n)]), 1, window, 1, &frame, 1, vDSP_Length(n))
            real.withUnsafeMutableBufferPointer { rp in imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                var mag = [Float](repeating: 0, count: half)
                vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(half))
                var bandsOut = [Float](repeating: 0, count: bands)
                for b in 0..<bands {
                    let lo = edges[b], hi = max(edges[b + 1], lo + 1)
                    var sum: Float = 0
                    vDSP_sve(Array(mag[lo..<hi]), 1, &sum, vDSP_Length(hi - lo))
                    bandsOut[b] = log10(sum / Float(hi - lo) + 1e-3)
                }
                out.append(bandsOut)
            } }
            start += hop
        }
        // Remove each frame's mean so loudness differences do not matter.
        return out.map { f in let m = f.reduce(0, +) / Float(f.count); return f.map { $0 - m } }
    }

    public static func mono(_ buf: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buf.floatChannelData else { return [] }
        let n = Int(buf.frameLength)
        var m = [Float](repeating: 0, count: n)
        if buf.format.channelCount > 1 {
            vDSP_vadd(ch[0], 1, ch[1], 1, &m, 1, vDSP_Length(n)); var h: Float = 0.5; vDSP_vsmul(m, 1, &h, &m, 1, vDSP_Length(n))
        } else { m = Array(UnsafeBufferPointer(start: ch[0], count: n)) }
        return m
    }
}

public enum IdentMatcher {
    /// Normalised correlation of `reference` against every offset of `stream`. Returns (frame offset, score) of the best match.
    public static func bestMatch(reference: [[Float]], in stream: [[Float]]) -> (offset: Int, score: Float)? {
        guard !reference.isEmpty, stream.count >= reference.count, let w = reference.first?.count else { return nil }
        let flatRef = reference.flatMap { $0 }
        var refNorm: Float = 0; vDSP_svesq(flatRef, 1, &refNorm, vDSP_Length(flatRef.count)); refNorm = sqrt(refNorm)
        guard refNorm > 0 else { return nil }
        var best: (Int, Float) = (0, -1)
        let flat = stream.flatMap { $0 }
        for off in 0...(stream.count - reference.count) {
            let seg = Array(flat[(off * w)..<((off + reference.count) * w)])
            var dot: Float = 0; vDSP_dotpr(seg, 1, flatRef, 1, &dot, vDSP_Length(seg.count))
            var n: Float = 0; vDSP_svesq(seg, 1, &n, vDSP_Length(seg.count)); n = sqrt(n)
            guard n > 0 else { continue }
            let score = dot / (n * refNorm)
            if score > best.1 { best = (off, score) }
        }
        return best
    }

    /// Average of several equal-length candidate feature sets.
    public static func average(_ sets: [[[Float]]]) -> [[Float]] {
        guard let n = sets.map(\.count).min(), n > 0, let w = sets.first?.first?.count else { return [] }
        return (0..<n).map { i in (0..<w).map { j in sets.reduce(0) { $0 + $1[i][j] } / Float(sets.count) } }
    }

    /// Length of a learned jingle reference.
    public static let referenceSeconds = 3.0
    /// Short references match unrelated audio more easily; 0.79 was the best chance score seen between
    /// unrelated 6 Music bulletin starts, so a match must beat this.
    public static let defaultThreshold: Float = 0.85

    /// Looks for a short stretch that recurs in at least three candidate windows, wherever it falls in each.
    /// Returns the average of the aligned stretches, or nil when no stretch is shared by three.
    public static func promote(candidates: [[[Float]]], threshold: Float = defaultThreshold) -> IdentReference? {
        guard candidates.count >= 3 else { return nil }
        let w = Int(referenceSeconds / IdentFeatures.frameSeconds)
        var best: (count: Int, score: Float, ref: [[Float]])?
        for (bi, base) in candidates.enumerated() where base.count >= w {
            var k = 0
            while k + w <= base.count {
                let piece = Array(base[k..<(k + w)])
                var aligned = [piece], total: Float = 0
                for (ci, c) in candidates.enumerated() where ci != bi {
                    if let m = bestMatch(reference: piece, in: c), m.score >= threshold, m.offset + w <= c.count {
                        aligned.append(Array(c[m.offset..<(m.offset + w)])); total += m.score
                    }
                }
                if aligned.count >= 3, best == nil || aligned.count > best!.count || (aligned.count == best!.count && total > best!.score) {
                    best = (aligned.count, total, average(aligned))
                }
                k += 4
            }
        }
        return best.map { IdentReference(features: $0.ref, threshold: threshold) }
    }
}
