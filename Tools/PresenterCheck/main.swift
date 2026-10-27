import Foundation
import InterLudeCore
import InterLudeApple

Platform.install(.apple)

// presenter-check <recordingDir> <scores.csv> <start,end> [<start,end> ...]
// Learns the presenter's voice from speech away from bulletin slots, then shows how presenter-like each part of
// each muted block is. Low numbers sound like the presenter; high numbers sound like someone else.
let a = CommandLine.arguments
let dir = URL(fileURLWithPath: a[1])
let blocks: [(Double, Double)] = a.dropFirst(3).compactMap { p in let x = p.split(separator: ",").compactMap { Double($0) }; return x.count == 2 ? (x[0], x[1]) : nil }
let parts = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
let first = Int(parts[0])!, last = Int(parts[1])!
let t0 = HLS.startTime(ofIndex: first).timeIntervalSince1970
var frames: [[Float]] = []
var mono: [Float] = []
for i in first...last {
    if let d = try? Data(contentsOf: dir.appendingPathComponent("\(i).ts")), let info = TS.parse(d), let b = try? Decode.pcm(frames: info.frames) {
        mono += IdentFeatures.mono(b)
    } else { mono += [Float](repeating: 0, count: 307_200) }
    let usable = (mono.count - IdentFeatures.fftSize) / IdentFeatures.hop * IdentFeatures.hop
    if usable > 0 { frames += IdentFeatures.extract(Array(mono[0..<(usable + IdentFeatures.fftSize - IdentFeatures.hop)])); mono.removeFirst(usable) }
}
let fps = 48000.0 / Double(IdentFeatures.hop)
let ceps = frames.map { VoicePrint.cepstra($0) }

// Speech windows from the classifier.
var speechAt: [(Double, Bool)] = []
for l in try String(contentsOfFile: a[2], encoding: .utf8).split(separator: "\n").dropFirst() {
    let f = l.split(separator: ","); guard f.count >= 5, let st = Double(f[1]), let off = Double(f[2]), let sp = Double(f[3]), let mu = Double(f[4]) else { continue }
    speechAt.append((st + off, sp >= 0.6 && mu < 0.5))
}
@MainActor func isSpeech(_ t: Double) -> Bool { speechAt.last(where: { $0.0 <= t && t < $0.0 + 3 })?.1 ?? false }
func nearSlot(_ t: Double) -> Bool {
    let m = t.truncatingRemainder(dividingBy: 1800) / 60      // minutes past :00 or :30
    return m < 6 || m > 29
}
var training: [[Float]] = []
for (i, c) in ceps.enumerated() {
    let t = t0 + Double(i) / fps
    if isSpeech(t) && !nearSlot(t) && !blocks.contains(where: { t >= $0.0 - 30 && t <= $0.1 + 30 }) { training.append(c) }
}
var model = VoicePrint(training)
print("presenter model from \(Int(Double(training.count) / fps)) s of speech away from bulletins")
if let n = ProcessInfo.processInfo.environment["NEWS"]?.split(separator: ",").compactMap({ Double($0) }), n.count == 2 {
    // Model the newsreader instead, from a stretch known to be the bulletin.
    let i0 = Int((n[0] - t0) * fps), i1 = Int((n[1] - t0) * fps)
    model = VoicePrint(Array(ceps[i0..<i1]))
    print("newsreader model from \(Int(n[1] - n[0])) s; low numbers now mean the newsreader")
}

let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
for (bs, be) in blocks {
    print("\nblock \(f.string(from: Date(timeIntervalSince1970: bs))) to \(f.string(from: Date(timeIntervalSince1970: be))) (\(Int(be - bs)) s); 3 s steps, distance from the presenter's voice:")
    var t = bs - 9
    while t < be + 9 {
        let i0 = Int((t - t0) * fps), i1 = Int((t + 3 - t0) * fps)
        let chunk = Array(ceps[max(0, i0)..<min(ceps.count, i1)])
        let d = model.distance(chunk)
        let tag = t < bs ? " (before)" : (t >= be ? " (after)" : "")
        print("  \(f.string(from: Date(timeIntervalSince1970: t))) \(String(format: "%+4.0f", t - bs))  \(String(format: "%4.2f", d))  \(String(repeating: "#", count: max(0, Int((d - 0.5) * 30))))\(tag)")
        t += 3
    }
}
