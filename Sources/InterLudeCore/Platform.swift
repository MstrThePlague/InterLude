//  Platform.swift
//  InterLudeCore
//
//  What InterLude needs from the operating system, behind protocols so the core builds wherever Swift does. Each
//  platform installs its implementations once at launch with `Platform.install`: Apple's frameworks on the Mac
//  (InterLudeApple), ffmpeg and open models on Linux (InterLudePortable and InterLudeML). Until then the core has
//  portable signal maths but no audio codecs, sound classifier or transcriber.

import Foundation

/// Decoded audio: one array of samples per channel, all the same length.
public struct PCMAudio: Sendable {
    public var channels: [[Float]]
    /// [Hz]
    public var sampleRate: Double
    public init(channels: [[Float]], sampleRate: Double) { self.channels = channels; self.sampleRate = sampleRate }
    /// Samples per channel.
    public var frameCount: Int { channels.first?.count ?? 0 }
    /// [s]
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// The first two channels averaged, or the only one.
    public var mono: [Float] {
        guard let left = channels.first else { return [] }
        guard channels.count > 1 else { return left }
        let right = channels[1]
        return (0..<min(left.count, right.count)).map { (left[$0] + right[$0]) * 0.5 }
    }
}

/// Decodes AAC and reads audio files.
public protocol AudioDecoding: Sendable {
    /// Decodes ADTS AAC frames, as a segment carries them, to PCM. Nil when there is nothing to decode.
    func decode(adts frames: [Data]) throws -> PCMAudio?
    /// Reads a whole audio file, such as an ambience loop.
    func read(contentsOf url: URL) throws -> PCMAudio
}

/// Encodes AAC-LC.
public protocol AACEncoding: Sendable {
    /// Encodes interleaved 48 kHz stereo samples as raw AAC-LC frames.
    ///
    /// - Parameters:
    ///   - pcm: Interleaved left and right samples.
    ///   - bitrate: Target bit rate [bit/s].
    /// - Returns: The frames, and the encoder's lead-in [samples]: output sample n carries input sample n − delay.
    func encode(_ pcm: [Float], bitrate: UInt32) throws -> (frames: [Data], delay: Int)
}

/// Scores audio for speech and music.
public protocol SoundClassifying: Sendable {
    /// Speech and music scores for `clips` played back to back, in 3 s windows with a 1.5 s hop.
    /// Times are from the start of the first clip [s].
    func classify(_ clips: [PCMAudio]) throws -> [SoundScore]
}

/// Transcribes speech, to hear the newsreader's opening and sign-off.
public protocol NewsTranscribing: Sendable {
    /// Makes sure the speech model is there, installing it if `install` allows.
    ///
    /// - Returns: Whether transcription is ready.
    func prepare(install: Bool) async -> Bool
    /// Transcribes one continuous stretch of mono audio.
    ///
    /// - Parameters:
    ///   - samples: The audio.
    ///   - sampleRate: [Hz]
    /// - Returns: Phrases timed from the first sample.
    func transcribe(samples: [Float], sampleRate: Double) async throws -> [SpokenPhrase]
}

/// A capability the installed platform doesn't have.
public enum PlatformError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let what): "\(what) isn't available on this platform." }
    }
}

/// The implementations in use. Read `Platform.current`; set it once at launch with `install`.
public struct Platform: Sendable {
    public var decoder: any AudioDecoding
    public var encoder: any AACEncoding
    /// Makes a classifier for one session. A platform may hand out the same shared instance every time.
    public var makeClassifier: @Sendable () -> any SoundClassifying
    /// Nil where there is no speech model; the newsreader's opening and sign-off are then never listened for.
    public var makeTranscriber: (@Sendable () -> any NewsTranscribing)?
    public var dsp: any DSPKernels

    public init(decoder: any AudioDecoding, encoder: any AACEncoding, makeClassifier: @escaping @Sendable () -> any SoundClassifying,
                makeTranscriber: (@Sendable () -> any NewsTranscribing)?, dsp: any DSPKernels) {
        self.decoder = decoder; self.encoder = encoder; self.makeClassifier = makeClassifier
        self.makeTranscriber = makeTranscriber; self.dsp = dsp
    }

    /// Portable maths only: enough for the detector, playout, schedule and jingle matching.
    public static let portable = Platform(decoder: Unavailable(), encoder: Unavailable(), makeClassifier: { Unavailable() },
                                          makeTranscriber: nil, dsp: PortableDSP())

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = portable

    /// Overrides the installed platform for the current task and its child tasks, so tests can use one platform
    /// without disturbing others running at the same time in the same process.
    @TaskLocal public static var scoped: Platform?

    /// The platform in use: the task's scoped one if set, otherwise the one installed.
    public static var current: Platform {
        if let scoped { return scoped }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    /// Makes `platform` the one in use for the whole process.
    public static func install(_ platform: Platform) {
        lock.lock(); defer { lock.unlock() }
        installed = platform
    }
}

/// Stands in for whatever a platform hasn't supplied, throwing `PlatformError.unavailable` when used.
struct Unavailable: AudioDecoding, AACEncoding, SoundClassifying {
    func decode(adts frames: [Data]) throws -> PCMAudio? { throw PlatformError.unavailable("Audio decoding") }
    func read(contentsOf url: URL) throws -> PCMAudio { throw PlatformError.unavailable("Audio decoding") }
    func encode(_ pcm: [Float], bitrate: UInt32) throws -> (frames: [Data], delay: Int) { throw PlatformError.unavailable("AAC encoding") }
    func classify(_ clips: [PCMAudio]) throws -> [SoundScore] { throw PlatformError.unavailable("Sound classification") }
}
