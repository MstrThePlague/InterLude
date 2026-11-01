//  main.swift
//  record
//
//  Saves a stretch of a station's broadcast from the BBC's six-hour rewind window, for measuring detection offline.
//  Recordings are for personal testing and are kept out of git.
//
//  Usage: record <serviceId> <hoursAgoStart> <durationMinutes> <outDir>
//
//  Writes each segment as <index>.ts in <outDir>, and index.txt holding "<first index> <last index> <name prefix>",
//  which the other tools read. Run from the checkout, which holds Data/stations.json.

import Foundation
import InterLudeCore

let arguments = CommandLine.arguments
guard arguments.count >= 5, let hoursAgo = Double(arguments[2]), let minutes = Double(arguments[3]) else {
    print("usage: record <serviceId> <hoursAgoStart> <durationMinutes> <outDir>"); exit(2)
}
let catalogue = try Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json"))
guard let station = catalogue.station(arguments[1]) else { print("unknown station"); exit(2) }
let outDirectory = URL(fileURLWithPath: arguments[4])

// The rewind playlist lists every segment in the six-hour window.
let (playlist, base) = try await PlaylistClient().fetch(catalogue: catalogue, station: station, bitrate: 320_000, norewind: false)
guard let name = playlist.names.first, let (prefix, _) = HLS.splitName(name) else { print("bad playlist"); exit(1) }
let first = max(playlist.firstSequence, playlist.lastSequence - Int(hoursAgo * 3600 / segmentDuration))
let last = min(playlist.lastSequence, first + Int(minutes * 60 / segmentDuration))

let store = SegmentStore(directory: outDirectory, base: base, prefix: prefix)
var saved = 0
try await withThrowingTaskGroup(of: Void.self) { group in
    for index in first...last { group.addTask { _ = try await store.segment(index) } }
    for try await _ in group { saved += 1; if saved % 100 == 0 { print("\(saved)/\(last - first + 1)") } }
}
try "\(first) \(last) \(prefix)\n".write(to: outDirectory.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
print("saved \(last - first + 1) segments, \(HLS.startTime(ofIndex: first)) to \(HLS.startTime(ofIndex: last + 1))")
