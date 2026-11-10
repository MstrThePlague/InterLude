//  Evaluation.swift
//  InterLudeCore
//
//  Replays the detector over a recording's classifier scores and measures it against bulletins labelled by ear. The
//  `evaluate` tool prints the result, and the tests hold the speech rule to the figures recorded in `Tests/Corpus`, so
//  a change that helps one station can't quietly break another.

import Foundation

/// How well the detector did over one labelled recording.
public struct EvaluationReport: Sendable, Equatable {
    public var bulletins = 0
    /// Bulletins with no more than 2 s of news left audible.
    public var fullyMuted = 0
    /// The most news left audible in any one bulletin [s].
    public var worstAudible = 0.0
    /// Blocks that matched no bulletin.
    public var falseStarts = 0
    /// The most music muted at a bulletin's start or end [s].
    public var worstEdgeLoss = 0.0
}

/// A bulletin as heard by ear.
public struct LabelledBulletin: Decodable, Sendable {
    /// ISO 8601, such as "2026-11-02T10:30:33Z".
    public var start: String
    public var end: String
}

public enum Evaluation {
    /// Reads a scores file from `classify`: a header, then index, segment start, offset, speech and music per line.
    public static func samples(csv: String) -> [ScoreSample] {
        csv.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: ",")
            guard fields.count >= 5, let segmentStart = Double(fields[1]), let offset = Double(fields[2]),
                  let speech = Double(fields[3]), let music = Double(fields[4]) else { return nil }
            return ScoreSample(time: segmentStart + offset, speech: speech, music: music)
        }
    }

    /// The detector after it has taken every sample.
    public static func replay(_ samples: [ScoreSample], config: DetectorConfig = DetectorConfig(), longBulletins: [LongBulletin] = []) -> NewsDetector {
        var detector = NewsDetector(config: config)
        detector.longBulletins = longBulletins
        for sample in samples { detector.ingest(sample) }
        return detector
    }

    /// Measures the detector's blocks against the labelled bulletins. Mutes cover whole segments, as in the player.
    public static func score(_ detector: NewsDetector, labels: [LabelledBulletin]) -> EvaluationReport {
        let iso = ISO8601DateFormatter()
        var report = EvaluationReport()
        var matched = Set<Int>()
        for label in labels {
            guard let start = iso.date(from: label.start)?.timeIntervalSince1970, let end = iso.date(from: label.end)?.timeIntervalSince1970 else { continue }
            report.bulletins += 1
            var audible = 0.0, time = start
            while time < end {
                let segment = floor(time / segmentDuration) * segmentDuration
                if !detector.isNews(segmentStart: segment) { audible += min(end, segment + segmentDuration) - time }
                time = segment + segmentDuration
            }
            report.worstAudible = max(report.worstAudible, audible)
            if audible <= 2 { report.fullyMuted += 1 }
            for (i, block) in detector.blocks.enumerated() where block.start < end && (block.end ?? end) > start {
                matched.insert(i)
                report.worstEdgeLoss = max(report.worstEdgeLoss, max(0, start - block.start) + max(0, (block.end ?? end) - end))
            }
        }
        report.falseStarts = detector.blocks.indices.filter { !matched.contains($0) }.count
        return report
    }
}
