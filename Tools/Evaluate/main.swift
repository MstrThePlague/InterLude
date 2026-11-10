//  main.swift
//  evaluate
//
//  Replays the speech rule over a recording's scores and, given the true bulletin times, reports how well it did.
//
//  Usage: evaluate <scores.csv> [labels.json] [profile.json]
//
//  <scores.csv> comes from `classify`. labels.json lists the bulletins as heard by ear:
//      [{"start": "2026-10-12T05:30:46Z", "end": "2026-10-12T05:34:36Z"}, ...]
//  profile.json is a DetectorConfig to try in place of the defaults. STATION=<serviceId> adds that station's long
//  bulletins from Data/stations.json.
//
//  Reports each block detected, then, with labels: how many bulletins were fully muted, the most news left audible
//  in any bulletin, blocks that matched no bulletin (false starts), and the most music lost at a bulletin's edge.
//  The same measures run in the tests over the recordings in Tests/Corpus.

import Foundation
import InterLudeCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: evaluate <scores.csv> [labels.json] [profile.json]"); exit(2) }
var config = DetectorConfig()
if arguments.count >= 4, let data = FileManager.default.contents(atPath: arguments[3]) {
    config = try JSONDecoder().decode(DetectorConfig.self, from: data)
}
// STATION=<serviceId> uses that station's long bulletins from Data/stations.json.
let longBulletins = ProcessInfo.processInfo.environment["STATION"]
    .flatMap { try? Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json")).station($0) }?.longBulletins ?? []
let detector = Evaluation.replay(Evaluation.samples(csv: try String(contentsOfFile: arguments[1], encoding: .utf8)),
                                 config: config, longBulletins: longBulletins)

let iso = ISO8601DateFormatter()
let timestamp = { (time: Double) in iso.string(from: Date(timeIntervalSince1970: time)) }
print("detected \(detector.blocks.count) blocks")
for block in detector.blocks {
    let length = Int((block.end ?? block.start) - block.start)
    print("  \(timestamp(block.start)) -> \(block.end.map(timestamp) ?? "open")  \(length)s\(block.doubtful ? "  DOUBTFUL" : "")\(block.timedOut ? "  TIMED OUT" : "")")
}

if arguments.count >= 3 {
    let labels = try JSONDecoder().decode([LabelledBulletin].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let report = Evaluation.score(detector, labels: labels)
    let percent = report.bulletins == 0 ? 0 : 100 * Double(report.fullyMuted) / Double(report.bulletins)
    print(String(format: "bulletins fully muted: %d/%d (%.0f%%)", report.fullyMuted, report.bulletins, percent))
    print(String(format: "worst news audible in a bulletin: %.1fs; false starts: %d; worst music lost at an edge: %.1fs",
                 report.worstAudible, report.falseStarts, report.worstEdgeLoss))
}
