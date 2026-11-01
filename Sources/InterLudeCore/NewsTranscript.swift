//  NewsTranscript.swift
//  InterLudeCore
//
//  Finds the newsreader's opening and sign-off in a transcript of a bulletin. Newsroom wording is the same whoever
//  presents the show, for example "BBC News at 5.30. This is …" and "6 Music News. Your next update's at 6.30.",
//  so a short list of phrases is enough to mark where a bulletin really starts and ends.

import Foundation

/// A stretch of transcribed speech.
public struct SpokenPhrase: Sendable, Equatable {
    /// Start, from the beginning of the audio transcribed [s].
    public var start: Double
    /// End, from the beginning of the audio transcribed [s].
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Recognises a newsreader's opening and sign-off.
public enum NewsPhrases {
    /// Phrases that open a bulletin.
    static let openings = ["bbc news at", "this is bbc radio", "6 music news with", "six music news with"]

    /// Phrases that close a bulletin.
    ///
    /// Sign-offs heard include "6 Music News. Your next update's at 6.30", "That's 6 Music News, more at seven" and
    /// "That's 6 Music News for tonight". The station's news name is only said again at the end, and callers only
    /// consider phrases 45 s or more into the bulletin, so the presenter's "after the 6 Music News" never counts.
    static let signOffs = ["next update", "next news", "next bulletin", "updates at", "update is at", "next full news",
                           "more news at", "music news", "that's the news"]

    /// Most phrases a sign-off's tail may be apart from the phrase before it [s].
    static let signOffGap = 1.5

    /// Lower case, with curly apostrophes straightened, commas and full stops removed and spaces collapsed.
    static func normalise(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Joins each phrase with the ones after it, so wording split across results is still found.
    ///
    /// - Parameters:
    ///   - phrases: The transcript.
    ///   - span: How many consecutive phrases each window joins.
    /// - Returns: One window per phrase: its normalised text, the time from its first phrase's start to its last
    ///   phrase's end, and the index of its last phrase.
    static func windows(_ phrases: [SpokenPhrase], span: Int = 3) -> [(text: String, start: Double, end: Double, last: Int)] {
        phrases.indices.map { first in
            let stop = min(phrases.count, first + span)
            let text = phrases[first..<stop].map { normalise($0.text) }.joined(separator: " ")
            return (text, phrases[first].start, phrases[stop - 1].end, stop - 1)
        }
    }

    /// The start of the first opening phrase in `phrases`, or nil if there is none [s].
    public static func opening(in phrases: [SpokenPhrase]) -> Double? {
        windows(phrases, span: 2).first(where: { window in openings.contains(where: { window.text.contains($0) }) })?.start
    }

    /// Whether `text` is a spoken time, such as "6.30", "at 6 30", "7 o'clock" or "six thirty".
    static func isTime(_ text: String) -> Bool {
        let pattern = #"^(at )?(\d{1,2}( \d{2})?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)( (o'clock|thirty|am|pm))?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Finds where the newsreader finished signing off.
    ///
    /// The sign-off is the phrase that mentions the next update, together with whatever completes it, such as the
    /// time in "… your next update's at 6.30".
    ///
    /// - Parameters:
    ///   - phrases: The transcript.
    ///   - after: Only phrases starting at or after this time count, so the opening is never taken for a sign-off [s].
    /// - Returns: The end of the sign-off [s], or nil if none was heard.
    public static func signOff(in phrases: [SpokenPhrase], after: Double = 0) -> Double? {
        for index in phrases.indices where phrases[index].start >= after {
            let here = normalise(phrases[index].text)
            var hit: Int?
            if signOffs.contains(where: { here.contains($0) }) { hit = index }
            else if index + 1 < phrases.count {
                let both = here + " " + normalise(phrases[index + 1].text)
                if signOffs.contains(where: { both.contains($0) }) { hit = index + 1 }
            }
            guard let hit else { continue }
            // Carry on over the rest of the sign-off: more sign-off wording, or a time.
            var end = phrases[hit].end
            var next = hit + 1
            while next < phrases.count, phrases[next].start - end < signOffGap {
                let text = normalise(phrases[next].text)
                let pair = next + 1 < phrases.count ? text + " " + normalise(phrases[next + 1].text) : text
                if isTime(text) || signOffs.contains(where: { text.contains($0) }) { end = phrases[next].end; next += 1 }
                else if signOffs.contains(where: { pair.contains($0) }) { end = phrases[next + 1].end; next += 2 }
                else if ["your", "the", "and"].contains(text) { next += 1 }      // a fragment before the rest of it
                else { break }
            }
            return end
        }
        return nil
    }
}
