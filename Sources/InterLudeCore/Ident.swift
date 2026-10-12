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
    /// Frame-by-frame dot products of `a` against `b` (a.count x b.count, row major), computed with one matrix multiply.
    static func similarity(_ a: [[Float]], _ b: [[Float]]) -> [Float] {
        let d = a.first?.count ?? 0
        let fa = a.flatMap { $0 }, fb = b.flatMap { $0 }
        var bt = [Float](repeating: 0, count: fb.count)
        vDSP_mtrans(fb, 1, &bt, 1, vDSP_Length(d), vDSP_Length(b.count))
        var out = [Float](repeating: 0, count: a.count * b.count)
        vDSP_mmul(fa, 1, bt, 1, &out, 1, vDSP_Length(a.count), vDSP_Length(b.count), vDSP_Length(d))
        return out
    }

    /// Prefix sums of each frame's squared length, for the norm of any run of frames.
    static func energyPrefix(_ x: [[Float]]) -> [Float] {
        var p = [Float](repeating: 0, count: x.count + 1)
        for (i, f) in x.enumerated() { var e: Float = 0; vDSP_svesq(f, 1, &e, vDSP_Length(f.count)); p[i + 1] = p[i] + e }
        return p
    }

    /// Normalised correlation of `reference` against every offset of `stream`. Returns (frame offset, score) of the best match.
    public static func bestMatch(reference: [[Float]], in stream: [[Float]]) -> (offset: Int, score: Float)? {
        let l = reference.count, n = stream.count
        guard l > 0, n >= l, reference.first?.count == stream.first?.count else { return nil }
        let g = similarity(stream, reference)                 // n x l
        let ep = energyPrefix(stream), er = energyPrefix(reference)
        let refNorm = sqrt(er[l])
        guard refNorm > 0 else { return nil }
        var best: (Int, Float) = (0, -1)
        for o in 0...(n - l) {
            var dot: Float = 0
            for j in 0..<l { dot += g[(o + j) * l + j] }
            let norm = sqrt(ep[o + l] - ep[o])
            guard norm > 0 else { continue }
            let score = dot / (norm * refNorm)
            if score > best.1 { best = (o, score) }
        }
        return best
    }

    /// Average of several equal-length candidate feature sets.
    public static func average(_ sets: [[[Float]]]) -> [[Float]] {
        guard let n = sets.map(\.count).min(), n > 0, let w = sets.first?.first?.count else { return [] }
        return (0..<n).map { i in (0..<w).map { j in sets.reduce(0) { $0 + $1[i][j] } / Float(sets.count) } }
    }

    /// Length of a learned jingle reference.
    public static let referenceSeconds = 4.0
    /// The 6 Music news theme scored 0.81 to 0.89 at seven bulletins across four shows; nothing else in five
    /// hours of audio scored above 0.75.
    public static let defaultThreshold: Float = 0.78
    /// Muting starts this long before a match. Transcripts put the learned 6 Music stretch at the sung "Six Music",
    /// right after the presenter's handover, so a small margin is enough.
    public static let leadSeconds = 2.0

    /// Looks for a short stretch that recurs in at least three candidate windows, wherever it falls in each.
    /// Returns the average of the aligned stretches, or nil when no stretch is shared by three.
    /// Uses one similarity matrix per pair of windows, so any stretch can be compared at any offset cheaply.
    public static func promote(candidates: [[[Float]]], threshold: Float = defaultThreshold) -> IdentReference? {
        let w = Int(referenceSeconds / IdentFeatures.frameSeconds)
        let usable = candidates.filter { $0.count >= w }
        guard usable.count >= 3 else { return nil }
        let prefixes = usable.map(energyPrefix)
        var best: (count: Int, score: Float, ref: [[Float]])?
        for (bi, base) in usable.enumerated() {
            let positions = Array(stride(from: 0, through: base.count - w, by: 4))
            // For each position in the base: best (score, offset) in each other window.
            var hits = [[(score: Float, window: Int, offset: Int)]](repeating: [], count: positions.count)
            for (ci, c) in usable.enumerated() where ci != bi {
                let m = similarity(base, c)                        // base.count x c.count
                let nc = c.count
                for (pi, k) in positions.enumerated() {
                    let nb = sqrt(prefixes[bi][k + w] - prefixes[bi][k])
                    guard nb > 0 else { continue }
                    var top: (Float, Int) = (-1, 0)
                    for o in 0...(nc - w) {
                        var dot: Float = 0
                        var r = k * nc + o
                        for _ in 0..<w { dot += m[r]; r += nc + 1 }
                        let no = sqrt(prefixes[ci][o + w] - prefixes[ci][o])
                        guard no > 0 else { continue }
                        let sc = dot / (nb * no)
                        if sc > top.0 { top = (sc, o) }
                    }
                    if top.0 >= threshold { hits[pi].append((top.0, ci, top.1)) }
                }
            }
            for (pi, k) in positions.enumerated() where hits[pi].count >= 2 {
                let total = hits[pi].reduce(0) { $0 + $1.score }
                if best == nil || hits[pi].count + 1 > best!.count || (hits[pi].count + 1 == best!.count && total > best!.score) {
                    var aligned = [Array(base[k..<(k + w)])]
                    for h in hits[pi] { aligned.append(Array(usable[h.window][h.offset..<(h.offset + w)])) }
                    best = (aligned.count, total, average(aligned))
                }
            }
        }
        return best.map { IdentReference(features: $0.ref, threshold: threshold) }
    }
}
