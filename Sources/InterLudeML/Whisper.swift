//  Whisper.swift
//  InterLudeML
//
//  The Linux server's transcriber for the newsreader's opening and sign-off: whisper.cpp on the CPU. The Mac uses
//  Apple's speech model instead (InterLudeApple/NewsTranscriber.swift).

import Foundation
import CGGML
import CWhisper
import InterLudeCore

/// Transcribes the newsreader with whisper.cpp on the CPU, for the opening and sign-off phrases. Nothing leaves the
/// machine. The model is a ggml file such as ggml-base.en.bin from the whisper.cpp project.
public actor WhisperTranscriber: NewsTranscribing {
    private let modelPath: String
    private var context: ContextBox?
    /// whisper.cpp contexts are not safe to share between threads, and a call takes seconds, so calls run one at a
    /// time on their own thread rather than holding up the actor's.
    private let queue = DispatchQueue(label: "interlude.whisper")
    private let threads: Int32

    /// `threads` defaults to every core, up to eight: whisper is the slowest step in starting an earlier programme.
    public init(model: URL, threads: Int32 = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))) {
        modelPath = model.path; self.threads = threads
    }

    /// Loads the model if it is there. `install` is ignored: the model ships with the server.
    public func prepare(install: Bool) async -> Bool {
        if context != nil { return true }
        guard FileManager.default.fileExists(atPath: modelPath) else { return false }
        whisper_log_set({ _, _, _ in }, nil)        // whisper.cpp logs every load step to stderr otherwise
        ggml_backend_load_all()                     // builds that load their CPU backend as a plugin need this first
        var params = whisper_context_default_params()
        params.use_gpu = false
        context = whisper_init_from_file_with_params(modelPath, params).map(ContextBox.init)
        return context != nil
    }

    /// Transcribes one stretch of mono audio, resampled to the 16 kHz whisper expects. Under a second gives nothing.
    public func transcribe(samples: [Float], sampleRate: Double) async throws -> [SpokenPhrase] {
        guard let box = context else { throw PlatformError.unavailable("The whisper model") }
        let audio = Resample.to16k(samples, from: sampleRate)
        guard audio.count >= 16000 else { return [] }
        let threads = threads
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try Self.run(box.context, audio, threads: threads) }) }
        }
    }

    /// Runs whisper greedily in English, with no context carried over from earlier calls.
    private static func run(_ context: OpaquePointer, _ audio: [Float], threads: Int32) throws -> [SpokenPhrase] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.print_progress = false; params.print_realtime = false; params.print_timestamps = false; params.print_special = false
        params.no_context = true
        let status = english.withCString { language -> Int32 in
            params.language = language
            return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
        guard status == 0 else { throw PlatformError.unavailable("whisper.cpp (error \(status))") }
        return (0..<whisper_full_n_segments(context)).map { i in
            // Segment times are in hundredths of a second.
            SpokenPhrase(start: Double(whisper_full_get_segment_t0(context, i)) / 100, end: Double(whisper_full_get_segment_t1(context, i)) / 100,
                         text: whisper_full_get_segment_text(context, i).map { String(cString: $0) }?.trimmingCharacters(in: .whitespaces) ?? "")
        }
    }

    private static let english = "en"

    /// A whisper context, passed to the transcription queue. Only ever used there, one call at a time.
    private struct ContextBox: @unchecked Sendable {
        let context: OpaquePointer
        init(_ context: OpaquePointer) { self.context = context }
    }

    deinit { if let context { whisper_free(context.context) } }
}
