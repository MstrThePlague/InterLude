import Foundation

// What InterLude needs from the operating system, behind protocols so the core builds wherever Swift does.
// Each platform installs its implementations once at launch with `Platform.install`. Until then the core has
// portable signal maths but no audio codecs, sound classifier or transcriber.

/// Decoded audio: one array of samples per channel, all the same length.
public struct PCMAudio: Sendable {
    public var channels: [[Float]]
    public var sampleRate: Double
    public init(channels: [[Float]], sampleRate: Double) { self.channels = channels; self.sampleRate = sampleRate }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

public protocol AudioDecoding: Sendable {
    /// Decodes ADTS AAC frames, as a segment carries them, to PCM. Nil when there is nothing to decode.
    func decode(adts frames: [Data]) throws -> PCMAudio?
    /// Reads a whole audio file, such as an ambience loop.
    func read(contentsOf url: URL) throws -> PCMAudio
}

public protocol AACEncoding: Sendable {
    /// Encodes interleaved 48 kHz stereo samples as raw AAC-LC frames. `delay` is the encoder's lead-in in samples:
    /// output sample n carries input sample n - delay.
    func encode(_ pcm: [Float], bitrate: UInt32) throws -> (frames: [Data], delay: Int)
}

public protocol SoundClassifying: Sendable {
    /// Speech and music scores for `clips` played back to back, in 3 s windows with a 1.5 s hop.
    /// Times are seconds from the start of the first clip.
    func classify(_ clips: [PCMAudio]) throws -> [SoundScore]
}

public protocol NewsTranscribing: Sendable {
    /// Makes sure the speech model is there, installing it if allowed. Returns whether transcription is ready.
    func prepare(install: Bool) async -> Bool
    /// Transcribes mono audio (one continuous stretch). Times are seconds from the first sample.
    func transcribe(samples: [Float], sampleRate: Double) async throws -> [SpokenPhrase]
}

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

    public static var current: Platform {
        if let scoped { return scoped }
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    public static func install(_ p: Platform) {
        lock.lock(); defer { lock.unlock() }
        installed = p
    }
}

/// Stands in for whatever a platform hasn't supplied.
struct Unavailable: AudioDecoding, AACEncoding, SoundClassifying {
    func decode(adts frames: [Data]) throws -> PCMAudio? { throw PlatformError.unavailable("Audio decoding") }
    func read(contentsOf url: URL) throws -> PCMAudio { throw PlatformError.unavailable("Audio decoding") }
    func encode(_ pcm: [Float], bitrate: UInt32) throws -> (frames: [Data], delay: Int) { throw PlatformError.unavailable("AAC encoding") }
    func classify(_ clips: [PCMAudio]) throws -> [SoundScore] { throw PlatformError.unavailable("Sound classification") }
}
