import Foundation
import InterLudeCore

// record <serviceId> <hoursAgoStart> <durationMinutes> <outDir>
// Saves segments from the BBC's 6 hour rewind window, plus an index file. For personal testing only.
let a = CommandLine.arguments
guard a.count >= 5, let startAgo = Double(a[2]), let minutes = Double(a[3]) else {
    print("usage: record <serviceId> <hoursAgoStart> <durationMinutes> <outDir>"); exit(2)
}
let cat = try Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json"))
guard let st = cat.station(a[1]) else { print("unknown station"); exit(2) }
let out = URL(fileURLWithPath: a[4])
let (pl, base) = try await PlaylistClient().fetch(catalogue: cat, station: st, bitrate: 320_000, norewind: false)
guard let name = pl.names.first, let (prefix, _) = HLS.splitName(name) else { print("bad playlist"); exit(1) }
let first = max(pl.firstSequence, pl.lastSequence - Int(startAgo * 3600 / segmentDuration))
let last = min(pl.lastSequence, first + Int(minutes * 60 / segmentDuration))
let store = SegmentStore(directory: out, base: base, prefix: prefix)
var done = 0
try await withThrowingTaskGroup(of: Void.self) { g in
    for i in first...last { g.addTask { _ = try await store.segment(i) } }
    for try await _ in g { done += 1; if done % 100 == 0 { print("\(done)/\(last - first + 1)") } }
}
try "\(first) \(last) \(prefix)\n".write(to: out.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
print("saved \(last - first + 1) segments, \(HLS.startTime(ofIndex: first)) to \(HLS.startTime(ofIndex: last + 1))")
