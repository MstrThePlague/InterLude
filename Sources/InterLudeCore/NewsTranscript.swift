//  NewsTranscript.swift
//  InterLudeCore
//
//  Finds the newsreader's opening and sign-off in a transcript of a bulletin. Newsroom wording is the same whoever
//  presents the show, for example "BBC News at 5.30. This is …" and "6 Music News. Your next update's at 6.30.",
//  so a short list of phrases, plus the station's own name for its news from `stations.json` (such as "Newsbeat"),
//  is enough to mark where a bulletin really starts and ends. A presenter's "here's the news" is a weaker sign, a
//  handover, which only counts near a slot and once speech carries on from it.

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
    /// Phrases that open a bulletin on any station. The station's news names open one too, unless they are a trail.
    /// "This is BBC Radio …" isn't one: presenters say it as a station ident, on Radio 3 at a quarter past.
    static let openings = ["bbc news at"]

    /// Phrases that close a bulletin on any station.
    ///
    /// Sign-offs heard include "6 Music News. Your next update's at 6.30", "That's 6 Music News, more at seven",
    /// "That's 6 Music News for tonight", "This is Newsbeat at 10.33" and "… on Newsbeat with Jordan at 12.45". A news
    /// name alone isn't one, since reports say "talking to Newsbeat"; it is after "that's" or "this is", or followed by
    /// a time. Callers only look well into the bulletin (`StationProfile.signOffSearchStart`), so the presenter's
    /// "after the 6 Music News" never counts.
    static let signOffs = ["next update", "next news", "next bulletin", "updates at", "update is at", "next full news",
                           "more news at", "that's the news", "that's the latest"]

    /// Words just before "news" or a news name that make it a trail for the bulletin rather than the bulletin, as in
    /// "after the news" or "before Newsbeat". "The", "this" and "our" are skipped over first.
    static let trailBefore = ["after", "before", "until", "till", "from", "about", "on", "of", "ahead of", "up to", "good", "bad",
                              "great", "fake", "some", "any", "more"]
    /// Words just after that make it a trail, or not news at all, as in "the news is next" or "news that …".
    static let trailAfter = ["is next", "next", "coming up", "is coming", "in a minute", "in a moment", "in a few", "shortly",
                             "soon", "later", "at the top", "on the hour", "that", "of", "about", "is that", "for you", "from"]

    /// Most phrases a sign-off's tail may be apart from the phrase before it [s].
    static let signOffGap = 1.5

    /// Lower case, with curly apostrophes straightened, commas and full stops removed and spaces collapsed.
    static func normalise(_ text: String) -> String {
        var text = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for mark in [",", ".", "?", "!", ";", ":", "\""] { text = text.replacingOccurrences(of: mark, with: " ") }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    /// Whether `term` is said in `text` other than as a trail, judging the words around it.
    ///
    /// - Parameters:
    ///   - term: Whole words to look for, normalised.
    ///   - text: Normalised text.
    ///   - before: Normalised text just before `text`, so a trail split across phrases is still seen.
    static func mentions(_ term: String, in text: String, before: String = "") -> Bool {
        let words = text.split(separator: " ").map(String.init), wanted = term.split(separator: " ").map(String.init)
        guard !wanted.isEmpty, words.count >= wanted.count else { return false }
        let earlier = before.split(separator: " ").map(String.init)
        for at in 0...(words.count - wanted.count) where Array(words[at..<at + wanted.count]) == wanted {
            var preceding = earlier + words[..<at]
            while let last = preceding.last, ["the", "this", "our"].contains(last) { preceding.removeLast() }
            let lastOne = preceding.last ?? "", lastTwo = preceding.suffix(2).joined(separator: " ")
            if lastOne == "latest" { return true }                  // "let's get the latest news from …"
            if trailBefore.contains(lastOne) || trailBefore.contains(lastTwo) { continue }
            let following = words[(at + wanted.count)...].joined(separator: " ") + " "
            if trailAfter.contains(where: { following.hasPrefix($0 + " ") }) { continue }
            return true
        }
        return false
    }

    /// The start of the first opening in `phrases`, or nil if there is none [s].
    ///
    /// - Parameters:
    ///   - phrases: The transcript.
    ///   - names: What the station calls its news, such as "newsbeat", from `Station.newsNames`.
    ///   - extra: The station's own openings, from `Station.openings`.
    public static func opening(in phrases: [SpokenPhrase], names: [String] = [], extra: [String] = []) -> Double? {
        let names = names.map(normalise), all = openings + extra.map(normalise)
        return windows(phrases, span: 2).enumerated().first(where: { index, window in
            let before = index > 0 ? normalise(phrases[index - 1].text) : ""
            return all.contains(where: { window.text.contains($0) }) || names.contains(where: { mentions($0, in: window.text, before: before) })
        })?.element.start
    }

    /// The start of the first handover to the news in `phrases`, such as "here's the news with …", or nil [s].
    ///
    /// Weaker than an opening, since presenters mention the news for other reasons; callers only use it near a slot,
    /// and only once speech has carried on from it.
    ///
    /// - Parameters:
    ///   - phrases: The transcript.
    ///   - names: What the station calls its news, from `Station.newsNames`.
    public static func handover(in phrases: [SpokenPhrase], names: [String] = []) -> Double? {
        let terms = ["news"] + names.map(normalise)
        return windows(phrases, span: 2).enumerated().first(where: { index, window in
            let before = index > 0 ? normalise(phrases[index - 1].text) : ""
            return terms.contains(where: { mentions($0, in: window.text, before: before) })
        })?.element.start
    }

    /// Whether `text` is a spoken time, such as "6.30", "at 6 30", "7 o'clock" or "six thirty".
    static func isTime(_ text: String) -> Bool {
        let pattern = #"^(at )?(\d{1,2}( \d{2})?|\d{3,4}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)( (o'clock|thirty|am|pm))?$"#
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
    ///   - names: What the station calls its news, such as "6 music news", from `Station.newsNames`.
    ///   - extra: The station's own sign-offs, from `Station.signOffs`.
    /// - Returns: The end of the sign-off [s], or nil if none was heard.
    public static func signOff(in phrases: [SpokenPhrase], after: Double = 0, names: [String] = [], extra: [String] = []) -> Double? {
        let names = names.map(normalise), signOffs = signOffs + extra.map(normalise)
        let time = #"(\d{1,4}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)( |$)"#
        func ends(_ text: String) -> Bool {
            signOffs.contains(where: { text.contains($0) }) || names.contains { name in
                text.contains("that's " + name) || text.contains("this is " + name + " ")
                    || text.range(of: NSRegularExpression.escapedPattern(for: name) + #"( with [a-z']+)? at "# + time, options: .regularExpression) != nil
            }
        }
        for index in phrases.indices where phrases[index].start >= after {
            // This phrase, or it joined with up to two after it, for wording split across results.
            var text = normalise(phrases[index].text), hit: Int?
            for last in index..<min(phrases.count, index + 3) {
                if last > index { text += " " + normalise(phrases[last].text) }
                if ends(text) { hit = last; break }
            }
            guard let hit else { continue }
            // Carry on over the rest of the sign-off: more sign-off wording, or a time.
            var end = phrases[hit].end
            var next = hit + 1
            while next < phrases.count, phrases[next].start - end < signOffGap {
                let text = normalise(phrases[next].text)
                let pair = next + 1 < phrases.count ? text + " " + normalise(phrases[next + 1].text) : text
                if isTime(text) || ends(text) { end = phrases[next].end; next += 1 }
                else if ends(pair) { end = phrases[next + 1].end; next += 2 }
                else if ["your", "the", "and"].contains(text) { next += 1 }      // a fragment before the rest of it
                else { break }
            }
            return end
        }
        return nil
    }
}
