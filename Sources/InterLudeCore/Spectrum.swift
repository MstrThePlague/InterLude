import Foundation

/// Turns audio into rows of bar heights (0...1) for the panel's backdrop.
public enum Spectrum {
    public static let bands = 28
    public static let fps = 30.0

    private static let fftSize = 4096
    private static let minHz = 50.0
    private static let maxHz = 16_000.0
    private static let floorDB: Float = -62
    private static let ceilingDB: Float = -14

    /// One row of `bands` heights per 1/`fps` second of `audio`.
    public static func frames(_ audio: PCMAudio) -> [[Float]] {
        let n = audio.frameCount, channels = audio.channels.count
        guard n > 0 else { return [] }
        let rate = audio.sampleRate
        var mono = [Float](repeating: 0, count: n)
        for c in audio.channels { for i in 0..<n { mono[i] += c[i] } }
        if channels > 1 { let k = 1 / Float(channels); for i in 0..<n { mono[i] *= k } }

        let size = fftSize
        let dsp = Platform.current.dsp
        let window = dsp.hannWindow(count: size)

        // Bin ranges for log-spaced bands, and a tilt that offsets the natural fall-off of music towards the treble.
        let binHz = rate / Double(size)
        let top = min(maxHz, rate * 0.45)
        var ranges: [Range<Int>] = [], tilt: [Float] = []
        for b in 0..<bands {
            let lo = minHz * pow(top / minHz, Double(b) / Double(bands))
            let hi = minHz * pow(top / minHz, Double(b + 1) / Double(bands))
            let first = min(size / 2 - 2, Int(lo / binHz))
            ranges.append(first..<max(first + 1, Int(hi / binHz)))
            tilt.append(Float(3 * log2(sqrt(lo * hi) / 1000)))
        }

        let half = size / 2
        var chunk = [Float](repeating: 0, count: size)
        let hop = Int(rate / fps)
        var out: [[Float]] = []
        var start = 0
        while start < n {
            let take = min(size, n - start)
            for i in 0..<take { chunk[i] = mono[start + i] * window[i] }
            for i in take..<size { chunk[i] = 0 }
            let power = dsp.powerSpectrum(chunk, dropNyquist: true)
            // The real FFT scales by 2, so a full-scale sine reads about 0 dB here.
            var row = [Float](repeating: 0, count: bands)
            for b in 0..<bands {
                var sum: Float = 0
                for k in ranges[b] { sum += power[k] }
                let mean = sum / Float(ranges[b].count)
                let db = 10 * log10(max(mean, 1e-12) / Float(half * half)) + tilt[b]
                row[b] = min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
            }
            out.append(row)
            start += hop
        }
        return out
    }
}

/// Bar heights for segments that have been (or are about to be) served to the player, looked up by playback time.
/// Written by the session, read every frame by the panel, so access is locked rather than actor-isolated.
public final class SpectrumTape: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Int: [[Float]]] = [:]
    private var claimed: Set<Int> = []
    private var first: Int?

    public init() {}

    /// Notes that the player asked for segment `i`. The first one it asks for is where playback time zero is.
    /// Returns true when the caller should analyse it.
    public func claim(_ i: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = i }
        return claimed.insert(i).inserted
    }

    public func record(_ i: Int, _ frames: [[Float]]) {
        lock.lock(); defer { lock.unlock() }
        rows[i] = frames
        if let newest = rows.keys.max() {
            for k in rows.keys where k < newest - 12 { rows[k] = nil }
            claimed = claimed.filter { $0 >= newest - 12 }
        }
    }

    /// Bar heights at `seconds` of player time, or nil when that stretch has not been analysed.
    public func bands(at seconds: Double) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let first, seconds >= 0 else { return nil }
        let whole = (seconds / segmentDuration).rounded(.down)
        guard let r = rows[first + Int(whole)], !r.isEmpty else { return nil }
        let k = Int((seconds - whole * segmentDuration) * Spectrum.fps)
        return r[min(k, r.count - 1)]
    }
}
