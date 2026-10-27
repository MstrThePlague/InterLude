import Foundation
import AVFoundation
import Speech
import InterLudeCore

/// On-device transcription with Apple's speech model. Nothing leaves the Mac.
public actor NewsTranscriber: NewsTranscribing {
    public enum State: Sendable, Equatable { case unavailable, needsModel, installing, ready }
    public private(set) var state: State = .unavailable
    private var locale: Locale?

    public init() {}

    /// Checks for the British English model and installs it if missing. Returns whether transcription is ready.
    @discardableResult
    public func prepare(install: Bool = true) async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-GB")) else { state = .unavailable; return false }
        locale = loc
        let probe = SpeechTranscriber(locale: loc, preset: .timeIndexedTranscriptionWithAlternatives)
        if await AssetInventory.status(forModules: [probe]) == .installed { state = .ready; return true }
        guard install else { state = .needsModel; return false }
        state = .installing
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [probe]) { try await req.downloadAndInstall() }
            state = .ready
            return true
        } catch { state = .needsModel; return false }
    }

    /// Transcribes mono audio (one continuous stretch). Times are seconds from the first sample.
    public func transcribe(samples: [Float], sampleRate: Double = 48000) async throws -> [SpokenPhrase] {
        guard state == .ready, let locale, !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buf.floatChannelData?[0] else { return [] }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("il-stt-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: buf)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var out: [SpokenPhrase] = []
            for try await r in transcriber.results {
                out.append(SpokenPhrase(start: r.range.start.seconds, end: r.range.end.seconds, text: String(r.text.characters)))
            }
            return out
        }
        let file = try AVAudioFile(forReading: tmp)
        if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) }
        else { await analyzer.cancelAndFinishNow() }
        return try await collect.value
    }
}
