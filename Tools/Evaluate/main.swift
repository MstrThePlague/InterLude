import Foundation
import InterLudeCore

// evaluate <scores.csv> [labels.json] [profile.json]
// labels.json: [{"start":"2026-10-12T05:30:46Z","end":"2026-10-12T05:34:36Z"}, ...]
let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: evaluate <scores.csv> [labels.json] [profile.json]"); exit(2) }
var config = DetectorConfig()
if a.count >= 4, let d = FileManager.default.contents(atPath: a[3]) { config = try JSONDecoder().decode(DetectorConfig.self, from: d) }
var det = NewsDetector(config: config)
let lines = try String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n").dropFirst()
for l in lines {
    let f = l.split(separator: ",")
    guard f.count >= 5, let st = Double(f[1]), let off = Double(f[2]), let sp = Double(f[3]), let mu = Double(f[4]) else { continue }
    det.ingest(ScoreSample(time: st + off, speech: sp, music: mu))
}
let iso = ISO8601DateFormatter()
func fmt(_ t: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t)) }
print("detected \(det.blocks.count) blocks")
for b in det.blocks { print("  \(fmt(b.start)) -> \(b.end.map(fmt) ?? "open")  \(Int((b.end ?? b.start) - b.start))s\(b.doubtful ? "  DOUBTFUL" : "")\(b.timedOut ? "  TIMED OUT" : "")") }

if a.count >= 3 {
    struct Label: Decodable { var start: String; var end: String }
    let labels = try JSONDecoder().decode([Label].self, from: Data(contentsOf: URL(fileURLWithPath: a[2])))
    var fully = 0, newsAudible = 0.0, edgeLoss = 0.0
    var matched = Set<Int>()
    for l in labels {
        guard let ls = iso.date(from: l.start)?.timeIntervalSince1970, let le = iso.date(from: l.end)?.timeIntervalSince1970 else { continue }
        // Mute coverage is by whole segments, as in the player.
        var uncovered = 0.0, t = ls
        while t < le {
            let seg = floor(t / segmentDuration) * segmentDuration
            if !det.isNews(segmentStart: seg) { uncovered += min(le, seg + segmentDuration) - t }
            t = seg + segmentDuration
        }
        newsAudible = max(newsAudible, uncovered)
        if uncovered <= 2 { fully += 1 }
        for (i, b) in det.blocks.enumerated() where b.start < le && (b.end ?? le) > ls {
            matched.insert(i)
            edgeLoss = max(edgeLoss, max(0, ls - b.start) + max(0, (b.end ?? le) - le))
        }
    }
    let falseStarts = det.blocks.indices.filter { !matched.contains($0) }.count
    print(String(format: "bulletins fully muted: %d/%d (%.0f%%)", fully, labels.count, labels.isEmpty ? 0 : 100 * Double(fully) / Double(labels.count)))
    print(String(format: "worst news audible in a bulletin: %.1fs; false starts: %d; worst music lost at an edge: %.1fs", newsAudible, falseStarts, edgeLoss))
}
