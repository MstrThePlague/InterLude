import Foundation

/// One classifier result: a window of audio with speech and music scores.
public struct SoundScore: Sendable, Codable {
    public var time: Double      // seconds from the start of the stream (window start)
    public var duration: Double
    public var speech: Double
    public var music: Double
    public init(time: Double, duration: Double, speech: Double, music: Double) {
        self.time = time; self.duration = duration; self.speech = speech; self.music = music
    }
}

/// Decodes a segment's ADTS AAC frames to PCM with the platform's decoder.
public enum Decode {
    public static func pcm(frames: [Data]) throws -> PCMAudio? { try Platform.current.decoder.decode(adts: frames) }
}
