//  Spectrum.swift
//  InterLudeCore
//
//  Turns the audio served to the player into rows of bar heights for the panel's moving backdrop, and keeps them
//  in step with what the listener is hearing.

import Foundation

/// Bar heights from audio.
public enum Spectrum {
    /// Bars in a row.
    public static let bands = 28
    /// Rows per second of audio [Hz].
    public static let fps = 30.0

    /// FFT length [samples].
    private static let fftSize = 4096
    /// The lowest frequency shown [Hz].
    private static let minHz = 50.0
    /// The highest frequency shown, if the sample rate allows [Hz].
    private static let maxHz = 16_000.0
    /// The level shown as an empty bar [dB].
    private static let floorDB: Float = -62
    /// The level shown as a full bar [dB].
    private static let ceilingDB: Float = -14

    /// One row of `bands` heights from 0 to 1 for every 1/`fps` s of `audio`.
    public static func frames(_ audio: PCMAudio) -> [[Float]] {
        let sampleCount = audio.frameCount
        guard sampleCount > 0 else { return [] }
        let rate = audio.sampleRate
        let mono = audio.mono
        let dsp = Platform.current.dsp
        let window = dsp.hannWindow(count: fftSize)

        // Bin ranges for log-spaced bands, and a tilt that offsets music's natural fall-off towards the treble
        // (+3 dB per octave above 1 kHz).
        let binHz = rate / Double(fftSize)
        let top = min(maxHz, rate * 0.45)
        var ranges: [Range<Int>] = [], tilt: [Float] = []
        for band in 0..<bands {
            let low = minHz * pow(top / minHz, Double(band) / Double(bands))
            let high = minHz * pow(top / minHz, Double(band + 1) / Double(bands))
            let first = min(fftSize / 2 - 2, Int(low / binHz))
            ranges.append(first..<max(first + 1, Int(high / binHz)))
            tilt.append(Float(3 * log2(sqrt(low * high) / 1000)))
        }

        let half = fftSize / 2
        var chunk = [Float](repeating: 0, count: fftSize)
        let hop = Int(rate / fps)
        var rows: [[Float]] = []
        var start = 0
        while start < sampleCount {
            let take = min(fftSize, sampleCount - start)
            for i in 0..<take { chunk[i] = mono[start + i] * window[i] }
            for i in take..<fftSize { chunk[i] = 0 }
            let power = dsp.powerSpectrum(chunk, dropNyquist: true)
            // The real FFT scales by 2, so after dividing by half² a full-scale sine reads about 0 dB.
            var row = [Float](repeating: 0, count: bands)
            for band in 0..<bands {
                var sum: Float = 0
                for k in ranges[band] { sum += power[k] }
                let mean = sum / Float(ranges[band].count)
                let level = 10 * log10(max(mean, 1e-12) / Float(half * half)) + tilt[band]     // [dB]
                row[band] = min(1, max(0, (level - floorDB) / (ceilingDB - floorDB)))
            }
            rows.append(row)
            start += hop
        }
        return rows
    }
}

/// Bar heights for segments that have been, or are about to be, served to the player, looked up by playback time.
///
/// Written by the session and read every frame by the panel, so access is locked rather than actor-isolated.
public final class SpectrumTape: @unchecked Sendable {
    /// Segments kept behind the newest one recorded.
    private static let kept = 12
    private let lock = NSLock()
    private var rows: [Int: [[Float]]] = [:]
    private var claimed: Set<Int> = []
    /// The first segment the player asked for, which is playback time zero.
    private var first: Int?

    public init() {}

    /// Notes that the player asked for segment `index`.
    ///
    /// - Returns: True the first time, when the caller should analyse the segment and `record` it.
    public func claim(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = index }
        return claimed.insert(index).inserted
    }

    /// Stores a segment's rows, and forgets segments long since played.
    public func record(_ index: Int, _ frames: [[Float]]) {
        lock.lock(); defer { lock.unlock() }
        rows[index] = frames
        if let newest = rows.keys.max() {
            for old in rows.keys where old < newest - Self.kept { rows[old] = nil }
            claimed = claimed.filter { $0 >= newest - Self.kept }
        }
    }

    /// Bar heights at `seconds` of player time, or nil when that stretch has not been analysed.
    public func bands(at seconds: Double) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let first, seconds >= 0 else { return nil }
        let wholeSegments = (seconds / segmentDuration).rounded(.down)
        guard let segmentRows = rows[first + Int(wholeSegments)], !segmentRows.isEmpty else { return nil }
        let row = Int((seconds - wholeSegments * segmentDuration) * Spectrum.fps)
        return segmentRows[min(row, segmentRows.count - 1)]
    }
}
