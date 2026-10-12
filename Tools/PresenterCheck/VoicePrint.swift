import Foundation

/// A simple model of one voice: the mean and spread of cepstral coefficients over some speech.
struct VoicePrint {
    var mean: [Float]
    var sd: [Float]

    /// Cepstra 1...12 of a log-band frame (c0, the overall level, is left out).
    static func cepstra(_ frame: [Float]) -> [Float] {
        let n = frame.count
        return (1...12).map { k in
            var s: Float = 0
            for (i, v) in frame.enumerated() { s += v * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n)) }
            return s
        }
    }

    init(_ frames: [[Float]]) {
        let d = frames.first?.count ?? 12
        var m = [Float](repeating: 0, count: d), v = [Float](repeating: 0, count: d)
        for f in frames { for k in 0..<d { m[k] += f[k] } }
        let n = Float(max(1, frames.count))
        for k in 0..<d { m[k] /= n }
        for f in frames { for k in 0..<d { v[k] += (f[k] - m[k]) * (f[k] - m[k]) } }
        mean = m; sd = v.map { sqrt($0 / n) + 1e-4 }
    }

    /// How far a stretch of frames is from this voice: the distance of its average, per unit of spread.
    func distance(_ frames: [[Float]]) -> Double {
        guard !frames.isEmpty else { return .nan }
        var d: Float = 0
        for k in mean.indices {
            let avg = frames.reduce(0) { $0 + $1[k] } / Float(frames.count)
            let z = (avg - mean[k]) / sd[k]; d += z * z
        }
        return Double(sqrt(d / Float(mean.count)))
    }
}
