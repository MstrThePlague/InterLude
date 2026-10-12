import Foundation
import AVFoundation
import InterLudeCore

let env = ProcessInfo.processInfo.environment
let BANDS = Int(env["BANDS"] ?? "") ?? IdentFeatures.bands
let LOG2N = Int(env["LOG2N"] ?? "") ?? 12
let HOP = Int(env["HOP"] ?? "") ?? IdentFeatures.hop

// ident-check <dir>:<unixStart>[,<unixStart>...] ...
// Cuts the audio around each bulletin start, checks whether the clips share a jingle, then scans every
// recording with the learned reference and reports matches, so false matches away from bulletins show up.

func features(dir: URL) throws -> (t0: Double, frames: [[Float]]) {
    let parts = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
    let first = Int(parts[0])!, last = Int(parts[1])!
    var out: [[Float]] = []
    var mono: [Float] = []
    var consumed = 0            // samples already turned into frames
    for i in first...last {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(i).ts")), let info = TS.parse(d),
              let b = try? Decode.pcm(frames: info.frames) else {
            mono += [Float](repeating: 0, count: 307_200); continue
        }
        mono += IdentFeatures.mono(b)
        // Extract whole hops, keep the tail for the next segment.
        let usable = (mono.count - (1 << LOG2N)) / HOP * HOP
        if usable > 0 {
            out += IdentFeatures.extract(Array(mono[0..<(usable + (1 << LOG2N) - HOP)]), bands: BANDS, log2n: LOG2N, hop: HOP)
            mono.removeFirst(usable); consumed += usable
        }
    }
    return (HLS.startTime(ofIndex: first).timeIntervalSince1970, out)
}

let fps = 48000.0 / Double(HOP)
var recs: [(name: String, t0: Double, f: [[Float]], starts: [Double])] = []
for arg in CommandLine.arguments.dropFirst() {
    let p = arg.split(separator: ":")
    let dir = URL(fileURLWithPath: String(p[0]))
    let starts = p.count > 1 ? p[1].split(separator: ",").compactMap { Double($0) } : []
    let (t0, f) = try features(dir: dir)
    recs.append((dir.lastPathComponent, t0, f, starts))
    print("\(dir.lastPathComponent): \(f.count) frames, \(starts.count) bulletins")
}

if ProcessInfo.processInfo.environment["EXPLORE"] != nil {
    // For each pair of bulletins: the best-matching 6 s stretch of A within 40 s around B's start.
    var clips: [(String, [[Float]])] = []
    for r in recs { for s in r.starts {
        let a = max(0, Int((s - 25 - r.t0) * fps)), b = min(r.f.count, Int((s + 15 - r.t0) * fps))
        clips.append((ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: s)), Array(r.f[a..<b])))
    } }
    let w = Int((Double(env["WIN"] ?? "6") ?? 6) * fps)
    for i in clips.indices { for j in clips.indices where j > i {
        var best: (Float, Int, Int) = (-1, 0, 0)
        var k = 0
        while k + w <= clips[i].1.count {
            if let m = IdentMatcher.bestMatch(reference: Array(clips[i].1[k..<(k + w)]), in: clips[j].1), m.score > best.0 { best = (m.score, k, m.offset) }
            k += max(1, Int(fps / 4))
        }
        print(String(format: "%@ vs %@: best %.2f at %+.1f s and %+.1f s from the starts", clips[i].0, clips[j].0, best.0,
                     Double(best.1) / fps - 25, Double(best.2) / fps - 25))
    } }
    exit(0)
}

// Candidates: 20 s before to 10 s after each start, as the app saves them.
var cands: [[[Float]]] = []
for r in recs { for s in r.starts {
    let a = Int((s - 20 - r.t0) * fps), b = Int((s + 10 - r.t0) * fps)
    if a >= 0 && b <= r.f.count { cands.append(Array(r.f[a..<b])) }
} }
print("\n\(cands.count) candidates")
guard let ref = IdentMatcher.promote(candidates: cands) else { print("\nno reference: candidates do not agree"); exit(0) }
print("\nreference: \(ref.features.count) frames from agreeing candidates")

// Scan every recording.
let iso = ISO8601DateFormatter()
for r in recs {
    var scores: [(Double, Float)] = []
    var k = 0
    let n = ref.features.count
    let flatRef = ref.features
    while k + n <= r.f.count {
        let window = Array(r.f[k..<min(r.f.count, k + n + 47)])
        if let m = IdentMatcher.bestMatch(reference: flatRef, in: window) { scores.append((r.t0 + Double(k + m.offset) / fps, m.score)) }
        k += 47          // about 2 s steps
    }
    let hits = scores.filter { $0.1 >= ref.threshold }
    var merged: [(Double, Float)] = []
    for h in hits { if let l = merged.last, h.0 - l.0 < 10 { if h.1 > l.1 { merged[merged.count - 1] = h } } else { merged.append(h) } }
    let sorted = scores.map(\.1).sorted()
    print("\n\(r.name): matches >= \(ref.threshold):")
    for (t, s) in merged { print("  \(iso.string(from: Date(timeIntervalSince1970: t)))  \(String(format: "%.2f", s))") }
    if !sorted.isEmpty { print(String(format: "  scores elsewhere: median %.2f, 99th percentile %.2f", sorted[sorted.count / 2], sorted[sorted.count * 99 / 100])) }
}
