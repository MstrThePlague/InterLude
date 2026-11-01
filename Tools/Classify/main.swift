//  main.swift
//  classify
//
//  Scores a recording for speech and music, window by window, as the app does while playing.
//
//  Usage: classify <recordingDir> <outCsv>
//
//  <recordingDir> is a folder made by `record`. Segments are decoded in index order and classified in blocks of 50,
//  each with the previous segment as context, so no window is cut short at a block's edge. The CSV has the columns
//  index, segment_start_unix, offset_in_segment, speech, music.
//
//  Environment:
//    CLASSIFIER=yamnet:<dir>   score with YAMNet from <dir> (as interlude-server does) instead of Apple's classifier
//    YAMNET_RAW=1              leave YAMNet's scores uncalibrated, for scripts/yamnet/calibrate.py

import Foundation
import InterLudeCore
import InterLudeApple
import InterLudeML

Platform.install(.apple)

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { print("usage: classify <recordingDir> <outCsv>"); exit(2) }
let directory = URL(fileURLWithPath: arguments[1])
let index = try String(contentsOf: directory.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
let first = Int(index[0])!, last = Int(index[1])!
let blockSize = 50
let environment = ProcessInfo.processInfo.environment
let choice = environment["CLASSIFIER"] ?? "apple"
let classifier: any SoundClassifying = choice.hasPrefix("yamnet:")
    ? try YAMNetClassifier(directory: URL(fileURLWithPath: String(choice.dropFirst(7))), calibrated: environment["YAMNET_RAW"] == nil)
    : AppleSoundClassifier()

var csv = "index,segment_start_unix,offset_in_segment,speech,music\n"
var missing = 0, windows = 0
var previous: PCMAudio?
var blockStart = first
while blockStart <= last {
    let blockEnd = min(blockStart + blockSize - 1, last)
    let context = previous.map { [$0] } ?? []
    var buffers = context, indices: [Int] = []
    let contextSeconds = context.first?.duration ?? 0
    for segment in blockStart...blockEnd {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(segment).ts")), let info = TS.parse(data),
              !info.frames.isEmpty, let audio = try? Decode.pcm(frames: info.frames) else { missing += 1; continue }
        buffers.append(audio); indices.append(segment); previous = audio
    }
    let scores = try classifier.classify(buffers)
    // Where each new segment starts within the classified audio, to attribute each window to its segment.
    var starts: [(time: Double, index: Int)] = []
    var time = contextSeconds
    for (k, audio) in buffers.dropFirst(context.count).enumerated() { starts.append((time, indices[k])); time += audio.duration }
    var current = 0
    for score in scores.sorted(by: { $0.time < $1.time }) where score.time >= contextSeconds && !starts.isEmpty {
        while current + 1 < starts.count && starts[current + 1].time <= score.time { current += 1 }
        let (segmentTime, segment) = starts[current]
        csv += "\(segment),\(String(format: "%.1f", HLS.startTime(ofIndex: segment).timeIntervalSince1970)),"
            + "\(String(format: "%.2f", score.time - segmentTime)),\(String(format: "%.3f", score.speech)),\(String(format: "%.3f", score.music))\n"
        windows += 1
    }
    print("\(blockEnd - first)/\(last - first)"); fflush(stdout)
    blockStart = blockEnd + 1
}
try csv.write(toFile: arguments[2], atomically: true, encoding: .utf8)
print("wrote \(windows) windows, \(missing) segments missing")
