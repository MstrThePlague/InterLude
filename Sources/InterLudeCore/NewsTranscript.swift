import Foundation
import AVFoundation
import Speech

/// A stretch of transcribed speech, in seconds from the start of the audio given.
public struct SpokenPhrase: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Finds the newsreader's opening and sign-off in a transcript. Newsroom wording is the same whoever presents the
/// show, for example "BBC News at 5.30. This is …" and "6 Music News. Your next update's at 6.30."
public enum NewsPhrases {
    static let openings = ["bbc news at", "this is bbc radio", "6 music news with", "six music news with"]
    /// Sign-offs seen: "6 Music News. Your next update's at 6.30", "That's 6 Music News, more at seven",
    /// "That's 6 Music News for tonight". The station's news name is only said again at the end, and only phrases
    /// 45 s or more into the bulletin are considered, so the presenter's "after the 6 Music News" never counts.
    static let signOffs = ["next update", "next news", "next bulletin", "updates at", "update is at", "next full news",
                           "more news at", "music news", "that's the news"]

    static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Joins consecutive phrases so wording split across results is still found, keeping each phrase's timing.
    static func windows(_ phrases: [SpokenPhrase], span: Int = 3) -> [(text: String, start: Double, end: Double, last: Int)] {
        phrases.indices.map { i in
            let j = min(phrases.count, i + span)
            let text = phrases[i..<j].map { normalise($0.text) }.joined(separator: " ")
            return (text, phrases[i].start, phrases[j - 1].end, j - 1)
        }
    }

    /// Start of the first opening phrase, if any.
    public static func opening(in phrases: [SpokenPhrase]) -> Double? {
        windows(phrases, span: 2).first(where: { w in openings.contains(where: { w.text.contains($0) }) })?.start
    }

    /// "6.30", "at 6 30", "7 o'clock", "six thirty" and the like.
    static func isTime(_ t: String) -> Bool {
        t.range(of: #"^(at )?(\d{1,2}( \d{2})?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)( (o'clock|thirty|am|pm))?$"#, options: .regularExpression) != nil
    }

    /// End of the sign-off: the phrase that mentions the next update, plus the time that follows it ("… at 6.30").
    /// Only phrases starting at or after `after` count, so the opening is never taken for a sign-off.
    public static func signOff(in phrases: [SpokenPhrase], after: Double = 0) -> Double? {
        for i in phrases.indices where phrases[i].start >= after {
            let here = normalise(phrases[i].text)
            var hit: Int?
            if signOffs.contains(where: { here.contains($0) }) { hit = i }
            else if i + 1 < phrases.count {
                let both = here + " " + normalise(phrases[i + 1].text)
                if signOffs.contains(where: { both.contains($0) }) { hit = i + 1 }
            }
            guard let h = hit else { continue }
            // Carry on over the rest of the sign-off: more sign-off wording or a time ("… your next update's at 6.30").
            var end = phrases[h].end
            var k = h + 1
            while k < phrases.count, phrases[k].start - end < 1.5 {
                let t = normalise(phrases[k].text)
                let pair = k + 1 < phrases.count ? t + " " + normalise(phrases[k + 1].text) : t
                if isTime(t) || signOffs.contains(where: { t.contains($0) }) { end = phrases[k].end; k += 1 }
                else if signOffs.contains(where: { pair.contains($0) }) { end = phrases[k + 1].end; k += 2 }
                else if ["your", "the", "and"].contains(t) { k += 1 }          // a fragment before the rest of the sign-off
                else { break }
            }
            return end
        }
        return nil
    }
}

/// On-device transcription with Apple's speech model (macOS 26 and later). Nothing leaves the Mac.
@available(macOS 26, *)
public actor NewsTranscriber {
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
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
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
