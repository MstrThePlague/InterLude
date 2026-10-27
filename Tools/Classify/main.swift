import Foundation
import InterLudeCore
import InterLudeApple

Platform.install(.apple)

// classify <recordingDir> <outCsv>
// Decodes every segment in index order and writes per-window speech and music scores:
// index,segment_start_unix,offset_in_segment,speech,music
let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: classify <recordingDir> <outCsv>"); exit(2) }
let dir = URL(fileURLWithPath: a[1])
let parts = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
let first = Int(parts[0])!, last = Int(parts[1])!
let block = 50
var csv = "index,segment_start_unix,offset_in_segment,speech,music\n"
let clf = AppleSoundClassifier()
var missing = 0, windows = 0
var prev: PCMAudio?
var blockStart = first
while blockStart <= last {
    let blockEnd = min(blockStart + block - 1, last)
    var buffers: [PCMAudio] = [], indices: [Int] = []
    let ctx = prev.map { [$0] } ?? []
    buffers += ctx
    let ctxSeconds = ctx.first?.duration ?? 0
    for i in blockStart...blockEnd {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(i).ts")), let info = TS.parse(d), !info.frames.isEmpty,
              let buf = try? Decode.pcm(frames: info.frames) else { missing += 1; continue }
        buffers.append(buf); indices.append(i); prev = buf
    }
    if blockStart == first { print("dbg frames", buffers.map { $0.frameCount }.prefix(5), buffers.count, buffers[0].sampleRate) }
    let scores = try clf.classify(buffers)
    if blockStart == first { print("dbg scores", scores.count, scores.prefix(4).map { $0.time }) }
    var starts: [(Double, Int)] = []; var t = ctxSeconds
    for (k, b) in buffers.dropFirst(ctx.count).enumerated() { starts.append((t, indices[k])); t += b.duration }
    var k = 0
    for s in scores.sorted(by: { $0.time < $1.time }) where s.time >= ctxSeconds && !starts.isEmpty {
        while k + 1 < starts.count && starts[k + 1].0 <= s.time { k += 1 }
        let (st, idx) = starts[k]
        csv += "\(idx),\(String(format: "%.1f", HLS.startTime(ofIndex: idx).timeIntervalSince1970)),\(String(format: "%.2f", s.time - st)),\(String(format: "%.3f", s.speech)),\(String(format: "%.3f", s.music))\n"
        windows += 1
    }
    print("\(blockEnd - first)/\(last - first)"); fflush(stdout)
    blockStart = blockEnd + 1
}
try csv.write(toFile: a[2], atomically: true, encoding: .utf8)
print("wrote \(windows) windows, \(missing) segments missing")
