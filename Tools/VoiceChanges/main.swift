import Foundation
import Accelerate
import InterLudeCore
import InterLudeApple

Platform.install(.apple)

// voice-changes <recordingDir> <blockStartUnix> <blockEndUnix>
// Prints, for each second from 30 s before the block to 20 s after, how different the voice character is in the
// 8 s before and after it. Peaks suggest a change of speaker (presenter to newsreader and back).
let a = CommandLine.arguments
guard a.count >= 4, let bs = Double(a[2]), let be = Double(a[3]) else { print("usage: voice-changes <dir> <start> <end>"); exit(2) }
let dir = URL(fileURLWithPath: a[1])
let parts = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
let first = Int(parts[0])!, last = Int(parts[1])!
var mono: [Float] = []
let t0 = HLS.startTime(ofIndex: first).timeIntervalSince1970
for i in first...last {
    guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(i).ts")), let info = TS.parse(d), let b = try? Decode.pcm(frames: info.frames) else {
        mono += [Float](repeating: 0, count: 307_200); continue
    }
    mono += IdentFeatures.mono(b)
}
let fps = 48000.0 / Double(IdentFeatures.hop)
let frames = IdentFeatures.extract(mono)
// Cepstra: DCT of the log bands, coefficients 1...12 (the overall level, c0, is left out).
let nb = IdentFeatures.bands
let ceps: [[Float]] = frames.map { f in
    (1...12).map { k in
        var s: Float = 0
        for (n, v) in f.enumerated() { s += v * cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(nb)) }
        return s
    }
}
// Per-dimension spread over the whole range, for normalising.
var mean = [Float](repeating: 0, count: 12), sd = [Float](repeating: 0, count: 12)
for c in ceps { for k in 0..<12 { mean[k] += c[k] } }
for k in 0..<12 { mean[k] /= Float(ceps.count) }
for c in ceps { for k in 0..<12 { sd[k] += (c[k] - mean[k]) * (c[k] - mean[k]) } }
for k in 0..<12 { sd[k] = sqrt(sd[k] / Float(ceps.count)) + 1e-6 }

func avg(_ from: Double, _ to: Double) -> [Float]? {
    let i0 = max(0, Int((from - t0) * fps)), i1 = min(ceps.count, Int((to - t0) * fps))
    guard i1 > i0 + 10 else { return nil }
    var m = [Float](repeating: 0, count: 12)
    for i in i0..<i1 { for k in 0..<12 { m[k] += ceps[i][k] } }
    return m.map { $0 / Float(i1 - i0) }
}
let w = 8.0
let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
var t = bs - 30
var rows: [(Double, Float)] = []
while t <= be + 20 {
    if let l = avg(t - w, t), let r = avg(t, t + w) {
        var d: Float = 0
        for k in 0..<12 { let z = (l[k] - r[k]) / sd[k]; d += z * z }
        rows.append((t, sqrt(d)))
    }
    t += 1
}
let mx = rows.map(\.1).max() ?? 1
for (t, d) in rows {
    let mark = abs(t - bs) < 0.5 ? " <- block start" : (abs(t - be) < 0.5 ? " <- block end" : "")
    print("\(f.string(from: Date(timeIntervalSince1970: t)))  \(String(format: "%+5.0f", t - bs))  \(String(repeating: "#", count: Int(d / mx * 50)))\(mark)")
}
