//  Ambience.swift
//  InterLudeCore
//
//  A looping background sound, such as waves or birdsong, played in place of a muted bulletin. The loop runs on the
//  stream's own clock, so consecutive muted segments join up without a seam however they are requested.

import Foundation

/// A sound to loop over muted bulletins, ready to encode segment by segment.
public struct Ambience: Sendable {
    /// What can play during a muted bulletin: silence, or one of the sounds in Resources/Ambience by file name.
    public static let choices: [(id: String, name: String)] = [
        ("silence", "Silence"), ("ocean", "Ocean waves"), ("stream", "Woodland stream"), ("birds", "Woodland birds"),
    ]
    /// Fade at the start of a run of muted segments [s].
    public static let fadeInSeconds = 3.0
    /// Fade at the end of a run of muted segments [s].
    public static let fadeOutSeconds = 4.0
    /// The only sample rate accepted, that of the stations' streams [Hz].
    static let sampleRate = 48_000
    /// Length of the crossfade that joins the loop's end to its start [s].
    static let crossfadeSeconds = 2
    /// AAC frames in one segment: 6.4 s of 1024-sample frames at 48 kHz.
    static let framesPerSegment = Int((segmentDuration * Double(sampleRate) / 1024).rounded())     // 300

    /// Interleaved 48 kHz stereo samples of one seamless loop.
    let loop: [Float]
    /// The platform encoder's lead-in [samples], measured when the sound is loaded, since Apple's and ffmpeg's differ.
    let encoderDelay: Int

    /// Loads a sound, sets it to a gentle level and blends its end into its start.
    ///
    /// - Parameters:
    ///   - url: A 48 kHz audio file, mono or stereo, at least eight seconds long.
    ///   - levelDB: The loudness to normalise to, as RMS [dBFS].
    public init(url: URL, levelDB: Float = -30) throws {
        encoderDelay = try Silence.encode([Float](repeating: 0, count: 4096)).delay
        let audio = try Platform.current.decoder.read(contentsOf: url)
        guard audio.sampleRate == Double(Self.sampleRate), let left = audio.channels.first else { throw AmbienceError.format }
        let right = audio.channels.count > 1 ? audio.channels[1] : left
        let sampleCount = audio.frameCount
        let crossfade = Self.crossfadeSeconds * Self.sampleRate
        guard sampleCount > 4 * crossfade else { throw AmbienceError.tooShort }

        // Normalise to a fixed RMS level, so every choice sits at the same volume.
        var sumOfSquares: Double = 0
        for i in 0..<sampleCount { sumOfSquares += Double(left[i] * left[i] + right[i] * right[i]) }
        let rms = Float((sumOfSquares / Double(2 * sampleCount)).squareRoot())
        let gain = rms > 0 ? powf(10, levelDB / 20) / rms : 0

        // The loop is the file's first n − crossfade samples. Its opening is an equal-power crossfade from the
        // file's last `crossfade` samples, so the end of one pass runs straight into the start of the next.
        let loopLength = sampleCount - crossfade
        var out = [Float](repeating: 0, count: loopLength * 2)
        for i in 0..<loopLength {
            var l = left[i], r = right[i]
            if i < crossfade {
                let t = Float(i) / Float(crossfade)
                let fadeIn = sinf(t * .pi / 2), fadeOut = cosf(t * .pi / 2)
                l = l * fadeIn + left[loopLength + i] * fadeOut
                r = r * fadeIn + right[loopLength + i] * fadeOut
            }
            out[2 * i] = max(-1, min(1, l * gain)); out[2 * i + 1] = max(-1, min(1, r * gain))
        }
        loop = out
    }

    /// Raw AAC frames to stand in for one segment.
    ///
    /// Each segment is encoded on its own with a few frames of lead-in and lead-out, so the frames at its edges match
    /// those of the neighbouring segments when they are encoded in turn.
    ///
    /// - Parameters:
    ///   - index: The segment's index, which places it on the stream's clock.
    ///   - fadeIn: Whether this segment starts a run of muted segments.
    ///   - fadeOut: Whether this segment ends a run, with the station's audio next.
    /// - Returns: `framesPerSegment` frames.
    public func frames(forSegment index: Int, fadeIn: Bool, fadeOut: Bool) throws -> [Data] {
        let count = Ambience.framesPerSegment, leadInFrames = 4, leadOutFrames = 4
        let rate = Double(Self.sampleRate)
        let loopSamples = loop.count / 2
        let segmentStart = index * count * 1024             // [samples] on the stream clock
        let segmentLength = count * 1024
        // The encoder delays its output by `encoderDelay` samples, so input starts that much later than the output
        // it becomes. Output frame `lead` is the segment's first.
        let lead = leadInFrames + (encoderDelay + 1023) / 1024
        let inputStart = segmentStart - lead * 1024 + encoderDelay
        let inputLength = (lead + count + leadOutFrames) * 1024
        var pcm = [Float](repeating: 0, count: inputLength * 2)
        let fadeInSamples = Ambience.fadeInSeconds * rate, fadeOutSamples = Ambience.fadeOutSeconds * rate
        for k in 0..<inputLength {
            let streamTime = inputStart + k                                 // [samples] on the stream clock
            let intoSegment = Double(streamTime - segmentStart)            // [samples]
            var gain = 1.0
            if fadeIn { gain = min(gain, max(0, min(1, intoSegment / fadeInSamples))) }
            if fadeOut { gain = min(gain, max(0, min(1, (Double(segmentLength) - intoSegment) / fadeOutSamples))) }
            guard gain > 0 else { continue }
            let eased = gain < 1 ? Float(0.5 - 0.5 * cos(gain * .pi)) : 1      // a smooth start and finish to each ramp
            let position = ((streamTime % loopSamples) + loopSamples) % loopSamples
            pcm[2 * k] = loop[2 * position] * eased; pcm[2 * k + 1] = loop[2 * position + 1] * eased
        }
        let encoded = try Silence.encode(pcm).frames
        guard encoded.count >= lead + count else { throw AmbienceError.encoder }
        return Array(encoded[lead..<(lead + count)])
    }
}

/// Why an ambient sound couldn't be used.
public enum AmbienceError: Error {
    /// The file isn't 48 kHz, or has no audio.
    case format
    /// The file is too short to loop smoothly.
    case tooShort
    /// The encoder returned fewer frames than asked for.
    case encoder
}
