//  Ident.swift
//  InterLudeCore
//
//  Recognising a station's news theme. A theme is the same recording every time, so a simple spectral fingerprint and
//  normalised correlation find it reliably (0.99 on held-out bulletins, below 0.7 almost everywhere else). The theme
//  is learned without being told where it is: the audio around several bulletin starts is compared, and a stretch
//  that recurs in at least three of them is taken as the theme.

import Foundation

/// Log-band spectral fingerprints: 32 bands from 100 Hz to 8 kHz, one frame every 2048 samples (about 43 ms at 48 kHz).
public enum IdentFeatures {
    public static let bands = 32
    /// FFT length [samples].
    public static let fftSize = 4096
    /// Samples between frames.
    public static let hop = 2048
    /// Time between frames [s].
    public static let frameSeconds = Double(hop) / 48000
    /// The lowest and highest frequencies covered [Hz].
    static let lowHz = 100.0, highHz = 8000.0

    /// Fingerprints 48 kHz mono audio with the standard settings.
    public static func extract(_ samples: [Float]) -> [[Float]] { extract(samples, bands: bands, log2n: 12, hop: hop) }

    /// Fingerprints 48 kHz mono audio.
    ///
    /// - Parameters:
    ///   - samples: The audio.
    ///   - bands: Log-spaced bands per frame.
    ///   - log2n: The FFT length as a power of two.
    ///   - hop: Samples between frames.
    /// - Returns: One frame per hop: the log of each band's mean power, less the frame's mean, so loudness doesn't
    ///   matter.
    public static func extract(_ samples: [Float], bands: Int, log2n: Int, hop: Int) -> [[Float]] {
        let length = 1 << log2n, half = length / 2
        guard samples.count >= length else { return [] }
        let dsp = Platform.current.dsp
        let window = dsp.hannWindow(count: length)
        // FFT bin at each band edge, log spaced.
        let edges: [Int] = (0...bands).map { band in
            let hz = lowHz * pow(highHz / lowHz, Double(band) / Double(bands))
            return min(half - 1, Int(hz / 48000 * Double(length)))
        }
        var frames: [[Float]] = []
        var start = 0
        var frame = [Float](repeating: 0, count: length)
        while start + length <= samples.count {
            for i in 0..<length { frame[i] = samples[start + i] * window[i] }
            let power = dsp.powerSpectrum(frame, dropNyquist: false)
            var levels = [Float](repeating: 0, count: bands)
            for band in 0..<bands {
                let low = edges[band], high = max(edges[band + 1], low + 1)
                var sum: Float = 0
                for k in low..<high { sum += power[k] }
                levels[band] = log10(sum / Float(high - low) + 1e-3)
            }
            frames.append(levels)
            start += hop
        }
        return frames.map { levels in let mean = levels.reduce(0, +) / Float(levels.count); return levels.map { $0 - mean } }
    }
}

/// Comparing fingerprints, and learning a theme from bulletins without knowing in advance where it is.
public enum IdentMatcher {
    /// Length of a learned theme [s].
    public static let referenceSeconds = 4.0
    /// The score a match must reach. The 6 Music news theme scored 0.81 to 0.89 at seven bulletins across four
    /// shows; nothing else in five hours of audio scored above 0.75.
    public static let defaultThreshold: Float = 0.78
    /// How long before a match muting starts [s]. Transcripts put the learned 6 Music stretch at the sung "Six
    /// Music", right after the presenter's handover, so a small margin is enough.
    public static let leadSeconds = 2.0
    /// Frames between the positions tried in a candidate when learning a theme.
    static let promotionStride = 4

    /// Frame-by-frame dot products of `a` with `b`, computed as one matrix multiply.
    ///
    /// - Returns: An a.count × b.count matrix, row major.
    static func similarity(_ a: [[Float]], _ b: [[Float]]) -> [Float] {
        Platform.current.dsp.rowDots(a.flatMap { $0 }, b.flatMap { $0 }, width: a.first?.count ?? 0)
    }

    /// Prefix sums of each frame's squared length, so the norm of any run of frames costs one subtraction.
    static func energyPrefix(_ frames: [[Float]]) -> [Float] {
        var sums = [Float](repeating: 0, count: frames.count + 1)
        for (i, frame) in frames.enumerated() { sums[i + 1] = sums[i] + frame.reduce(0) { $0 + $1 * $1 } }
        return sums
    }

    /// Normalised correlation of `reference` against every offset of `stream`.
    ///
    /// - Returns: The frame offset and score of the best match, or nil if `stream` is shorter than `reference` or
    ///   their frames differ in width.
    public static func bestMatch(reference: [[Float]], in stream: [[Float]]) -> (offset: Int, score: Float)? {
        let referenceLength = reference.count, streamLength = stream.count
        guard referenceLength > 0, streamLength >= referenceLength, reference.first?.count == stream.first?.count else { return nil }
        let dots = similarity(stream, reference)                      // streamLength × referenceLength
        let streamEnergy = energyPrefix(stream), referenceEnergy = energyPrefix(reference)
        let referenceNorm = sqrt(referenceEnergy[referenceLength])
        guard referenceNorm > 0 else { return nil }
        var best: (offset: Int, score: Float) = (0, -1)
        for offset in 0...(streamLength - referenceLength) {
            // Sum the diagonal of the dot-product matrix that lines the reference up at `offset`.
            var dot: Float = 0
            for j in 0..<referenceLength { dot += dots[(offset + j) * referenceLength + j] }
            let norm = sqrt(streamEnergy[offset + referenceLength] - streamEnergy[offset])
            guard norm > 0 else { continue }
            let score = dot / (norm * referenceNorm)
            if score > best.score { best = (offset, score) }
        }
        return best
    }

    /// The frame-by-frame average of several fingerprints, cut to the shortest.
    public static func average(_ sets: [[[Float]]]) -> [[Float]] {
        guard let length = sets.map(\.count).min(), length > 0, let width = sets.first?.first?.count else { return [] }
        return (0..<length).map { i in (0..<width).map { j in sets.reduce(0) { $0 + $1[i][j] } / Float(sets.count) } }
    }

    /// Looks for a short stretch that recurs in at least three candidate windows, wherever it falls in each.
    ///
    /// Every position in each candidate (in steps of `promotionStride` frames) is compared with every offset in every
    /// other candidate, using one similarity matrix per pair of candidates, so the search stays cheap.
    ///
    /// - Parameters:
    ///   - candidates: Fingerprints of the audio around recent bulletin starts.
    ///   - threshold: The score two stretches must reach to count as the same.
    /// - Returns: The average of the aligned stretches shared by the most candidates (at least three), or nil.
    public static func promote(candidates: [[[Float]]], threshold: Float = defaultThreshold) -> IdentReference? {
        let width = Int(referenceSeconds / IdentFeatures.frameSeconds)
        let usable = candidates.filter { $0.count >= width }
        guard usable.count >= 3 else { return nil }
        let energies = usable.map(energyPrefix)
        var best: (count: Int, score: Float, reference: [[Float]])?
        for (baseIndex, base) in usable.enumerated() {
            let positions = Array(stride(from: 0, through: base.count - width, by: promotionStride))
            // For each position in the base, the best match in each other candidate that reaches the threshold.
            var hits = [[(score: Float, candidate: Int, offset: Int)]](repeating: [], count: positions.count)
            for (otherIndex, other) in usable.enumerated() where otherIndex != baseIndex {
                let dots = similarity(base, other)                     // base.count × other.count
                let otherLength = other.count
                for (slot, position) in positions.enumerated() {
                    let baseNorm = sqrt(energies[baseIndex][position + width] - energies[baseIndex][position])
                    guard baseNorm > 0 else { continue }
                    var top: (score: Float, offset: Int) = (-1, 0)
                    for offset in 0...(otherLength - width) {
                        // Walk the diagonal from (position, offset).
                        var dot: Float = 0
                        var cell = position * otherLength + offset
                        for _ in 0..<width { dot += dots[cell]; cell += otherLength + 1 }
                        let otherNorm = sqrt(energies[otherIndex][offset + width] - energies[otherIndex][offset])
                        guard otherNorm > 0 else { continue }
                        let score = dot / (baseNorm * otherNorm)
                        if score > top.score { top = (score, offset) }
                    }
                    if top.score >= threshold { hits[slot].append((top.score, otherIndex, top.offset)) }
                }
            }
            for (slot, position) in positions.enumerated() where hits[slot].count >= 2 {
                let total = hits[slot].reduce(0) { $0 + $1.score }
                let count = hits[slot].count + 1                         // the base counts too
                if count > (best?.count ?? 0) || (count == best?.count && total > (best?.score ?? 0)) {
                    var aligned = [Array(base[position..<(position + width)])]
                    for hit in hits[slot] { aligned.append(Array(usable[hit.candidate][hit.offset..<(hit.offset + width)])) }
                    best = (aligned.count, total, average(aligned))
                }
            }
        }
        return best.map { IdentReference(features: $0.reference, threshold: threshold) }
    }
}
