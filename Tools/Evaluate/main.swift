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

import Foundation
import InterLudeCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: evaluate <scores.csv> [labels.json] [profile.json]"); exit(2) }
var config = DetectorConfig()
if arguments.count >= 4, let data = FileManager.default.contents(atPath: arguments[3]) {
    config = try JSONDecoder().decode(DetectorConfig.self, from: data)
}
var detector = NewsDetector(config: config)
// STATION=<serviceId> uses that station's long bulletins from Data/stations.json.
if let id = ProcessInfo.processInfo.environment["STATION"],
   let station = try? Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json")).station(id) {
    detector.longBulletins = station.longBulletins ?? []
}
for line in try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n").dropFirst() {
    let fields = line.split(separator: ",")
    guard fields.count >= 5, let segmentStart = Double(fields[1]), let offset = Double(fields[2]),
          let speech = Double(fields[3]), let music = Double(fields[4]) else { continue }
    detector.ingest(ScoreSample(time: segmentStart + offset, speech: speech, music: music))
}

let iso = ISO8601DateFormatter()
let timestamp = { (time: Double) in iso.string(from: Date(timeIntervalSince1970: time)) }
print("detected \(detector.blocks.count) blocks")
for block in detector.blocks {
    let length = Int((block.end ?? block.start) - block.start)
    print("  \(timestamp(block.start)) -> \(block.end.map(timestamp) ?? "open")  \(length)s\(block.doubtful ? "  DOUBTFUL" : "")\(block.timedOut ? "  TIMED OUT" : "")")
}

if arguments.count >= 3 {
    struct Label: Decodable { var start: String; var end: String }
    let labels = try JSONDecoder().decode([Label].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    var fullyMuted = 0
    var worstAudible = 0.0                  // [s]
    var worstEdgeLoss = 0.0                 // [s]
    var matched = Set<Int>()
    for label in labels {
        guard let start = iso.date(from: label.start)?.timeIntervalSince1970, let end = iso.date(from: label.end)?.timeIntervalSince1970 else { continue }
        // Mutes cover whole segments, as in the player.
        var audible = 0.0, time = start
        while time < end {
            let segment = floor(time / segmentDuration) * segmentDuration
            if !detector.isNews(segmentStart: segment) { audible += min(end, segment + segmentDuration) - time }
            time = segment + segmentDuration
        }
        worstAudible = max(worstAudible, audible)
        if audible <= 2 { fullyMuted += 1 }
        for (i, block) in detector.blocks.enumerated() where block.start < end && (block.end ?? end) > start {
            matched.insert(i)
            worstEdgeLoss = max(worstEdgeLoss, max(0, start - block.start) + max(0, (block.end ?? end) - end))
        }
    }
    let falseStarts = detector.blocks.indices.filter { !matched.contains($0) }.count
    let percent = labels.isEmpty ? 0 : 100 * Double(fullyMuted) / Double(labels.count)
    print(String(format: "bulletins fully muted: %d/%d (%.0f%%)", fullyMuted, labels.count, percent))
    print(String(format: "worst news audible in a bulletin: %.1fs; false starts: %d; worst music lost at an edge: %.1fs",
                 worstAudible, falseStarts, worstEdgeLoss))
}
