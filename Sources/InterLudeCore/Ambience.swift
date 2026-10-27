import Foundation

/// A looping background sound, such as waves or birdsong, played in place of a muted bulletin.
/// The loop runs on the stream's own clock, so consecutive muted segments join up without a seam.
public struct Ambience: Sendable {
    /// Interleaved 48 kHz stereo samples of one seamless loop.
    let loop: [Float]
    public static let fadeInSeconds = 3.0
    public static let fadeOutSeconds = 4.0
    static let encoderDelay = (try? Silence.encode([Float](repeating: 0, count: 4096)).delay) ?? 2112
    static let framesPerSegment = Int((segmentDuration * 48000 / 1024).rounded())     // 300

    /// Loads a 48 kHz audio file, sets it to a gentle level and blends its end into its start.
    public init(url: URL, levelDB: Float = -30) throws {
        let audio = try Platform.current.decoder.read(contentsOf: url)
        guard audio.sampleRate == 48000, let left = audio.channels.first else { throw AmbienceError.format }
        let right = audio.channels.count > 1 ? audio.channels[1] : left
        let n = audio.frameCount
        let xfade = 2 * 48000
        guard n > 4 * xfade else { throw AmbienceError.tooShort }

        // Normalise to a fixed RMS level, so every choice sits at the same volume.
        var sum: Double = 0
        for i in 0..<n { let l = left[i], r = right[i]; sum += Double(l * l + r * r) }
        let rms = Float((sum / Double(2 * n)).squareRoot())
        let gain = rms > 0 ? powf(10, levelDB / 20) / rms : 0

        // The loop is the first n - xfade samples; its opening is a crossfade from the file's last xfade samples.
        let len = n - xfade
        var out = [Float](repeating: 0, count: len * 2)
        for i in 0..<len {
            var l = left[i], r = right[i]
            if i < xfade {
                let t = Float(i) / Float(xfade), a = sinf(t * .pi / 2), b = cosf(t * .pi / 2)
                l = l * a + left[len + i] * b
                r = r * a + right[len + i] * b
            }
            out[2 * i] = max(-1, min(1, l * gain)); out[2 * i + 1] = max(-1, min(1, r * gain))
        }
        loop = out
    }

    /// Raw AAC frames for segment `index`, faded in from its start and/or out to its end.
    /// Each segment is encoded on its own with a few frames of lead-in and lead-out, so frames at the joins match
    /// those of the neighbouring segments.
    public func frames(forSegment index: Int, fadeIn: Bool, fadeOut: Bool) throws -> [Data] {
        let count = Ambience.framesPerSegment, pre = 4, post = 4, rate = 48000.0
        let loopFrames = loop.count / 2
        let segStart = index * count * 1024                     // in samples on the stream clock
        let segLength = count * 1024
        // The encoder delays its output by `delay` samples. Wanted output frame `lead` starts the segment.
        let delay = Ambience.encoderDelay
        let lead = pre + (delay + 1023) / 1024
        let inputStart = segStart - lead * 1024 + delay
        let inputLength = (lead + count + post) * 1024
        var pcm = [Float](repeating: 0, count: inputLength * 2)
        let fadeInLen = Ambience.fadeInSeconds * rate, fadeOutLen = Ambience.fadeOutSeconds * rate
        for k in 0..<inputLength {
            let t = inputStart + k                              // stream clock
            let rel = Double(t - segStart)                      // position within the segment
            var g = 1.0
            if fadeIn { g = min(g, max(0, min(1, rel / fadeInLen))) }
            if fadeOut { g = min(g, max(0, min(1, (Double(segLength) - rel) / fadeOutLen))) }
            guard g > 0 else { continue }
            let g2 = g < 1 ? Float(0.5 - 0.5 * cos(g * .pi)) : 1   // smooth start and finish to each ramp
            let s = ((t % loopFrames) + loopFrames) % loopFrames
            pcm[2 * k] = loop[2 * s] * g2; pcm[2 * k + 1] = loop[2 * s + 1] * g2
        }
        let encoded = try Silence.encode(pcm).frames
        guard encoded.count >= lead + count else { throw AmbienceError.encoder }
        return Array(encoded[lead..<(lead + count)])
    }
}

public enum AmbienceError: Error { case format, tooShort, encoder }
