//  Analysis.swift
//  InterLudeCore
//
//  The classifier's output, and decoding a segment for analysis with whichever decoder the platform installed.

import Foundation

/// One classifier result: a window of audio with speech and music scores.
public struct SoundScore: Sendable, Codable {
    /// The window's start, from the start of the audio classified [s].
    public var time: Double
    /// [s]
    public var duration: Double
    /// Confidence that the window is speech, from 0 to 1.
    public var speech: Double
    /// Confidence that the window is music, from 0 to 1.
    public var music: Double
    public init(time: Double, duration: Double, speech: Double, music: Double) {
        self.time = time; self.duration = duration; self.speech = speech; self.music = music
    }
}

/// Decoding for analysis.
public enum Decode {
    /// Decodes a segment's ADTS AAC frames to PCM with the platform's decoder. Nil when there is nothing to decode.
    public static func pcm(frames: [Data]) throws -> PCMAudio? { try Platform.current.decoder.decode(adts: frames) }
}
