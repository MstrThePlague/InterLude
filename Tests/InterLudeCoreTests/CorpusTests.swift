//  CorpusTests.swift
//  InterLudeCoreTests
//
//  Holds the speech rule to the figures it reached over real recordings, so a change made for one station can't
//  quietly break another. Each recording in Tests/Corpus is the classifier's scores (numbers only, no audio) and the
//  bulletins as heard by ear. A change that does better should lower the figures here in the same commit.

import Testing
import Foundation
@testable import InterLudeCore

/// A labelled recording and the figures the speech rule reached on it.
struct CorpusCase: CustomTestStringConvertible, Sendable {
    var station: String
    var fullyMuted: Int
    /// [s]
    var worstAudible: Double
    var falseStarts: Int
    /// [s]
    var worstEdgeLoss: Double
    var testDescription: String { station }
}

let corpus = [
    // Radio 1, 2 November 2026 10:00 to 14:00 UTC: four Newsbeats, one of them the 15-minute one at 12:45.
    CorpusCase(station: "bbc_radio_one", fullyMuted: 4, worstAudible: 0, falseStarts: 2, worstEdgeLoss: 117.5),
    // Radio 3, the same hours: the one o'clock news.
    CorpusCase(station: "bbc_radio_three", fullyMuted: 1, worstAudible: 0, falseStarts: 5, worstEdgeLoss: 198.5),
]

@Test(arguments: corpus) func speechRuleHoldsOnRecordings(_ recording: CorpusCase) throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Corpus").standardized
    let catalogue = try Catalogue.load(from: folder.appendingPathComponent("../../Data/stations.json").standardized)
    let csv = try String(contentsOf: folder.appendingPathComponent("\(recording.station).csv"), encoding: .utf8)
    let labels = try JSONDecoder().decode([LabelledBulletin].self, from: Data(contentsOf: folder.appendingPathComponent("\(recording.station).labels.json")))
    let detector = Evaluation.replay(Evaluation.samples(csv: csv), longBulletins: catalogue.station(recording.station)?.longBulletins ?? [])
    let report = Evaluation.score(detector, labels: labels)
    #expect(report.bulletins == labels.count)
    #expect(report.fullyMuted >= recording.fullyMuted)
    #expect(report.worstAudible <= recording.worstAudible + 1)
    #expect(report.falseStarts <= recording.falseStarts)
    #expect(report.worstEdgeLoss <= recording.worstEdgeLoss + 1)
}
