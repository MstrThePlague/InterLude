import Foundation
import AVFoundation
import InterLudeCore

// signoff-check <dir>:<blockStart>,<blockEnd> ...
// Transcribes each muted block (20 s before to 10 s after) and reports the newsreader's opening and sign-off.
@available(macOS 26, *)
func run() async throws {
    let stt = NewsTranscriber()
    guard await stt.prepare() else { print("speech model unavailable"); return }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
    for arg in CommandLine.arguments.dropFirst() {
        let p = arg.split(separator: ":"); let r = p[1].split(separator: ",").compactMap { Double($0) }
        let dir = URL(fileURLWithPath: String(p[0])), bs = r[0], be = r[1]
        let from = bs - 20, to = be + 10
        var mono: [Float] = []
        let i0 = Int(floor(from / segmentDuration)) + 1, i1 = Int(floor(to / segmentDuration)) + 1
        for i in i0...i1 {
            if let d = try? Data(contentsOf: dir.appendingPathComponent("\(i).ts")), let info = TS.parse(d), let b = try Decode.pcm(frames: info.frames) { mono += IdentFeatures.mono(b) }
        }
        let clipStart = HLS.startTime(ofIndex: i0).timeIntervalSince1970
        let t = Date()
        let phrases = try await stt.transcribe(samples: mono)
        let open = NewsPhrases.opening(in: phrases).map { clipStart + $0 }
        let sign = NewsPhrases.signOff(in: phrases, after: (bs - clipStart) + 45).map { clipStart + $0 }
        print("\nblock \(f.string(from: Date(timeIntervalSince1970: bs)))-\(f.string(from: Date(timeIntervalSince1970: be))) (\(Int(be - bs)) s), transcribed \(Int(to - from)) s in \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
        print("  opening:  " + (open.map { "\(f.string(from: Date(timeIntervalSince1970: $0)))  (\(String(format: "%+.0f", $0 - bs)) s from block start)" } ?? "not found"))
        print("  sign-off: " + (sign.map { "\(f.string(from: Date(timeIntervalSince1970: $0)))  (\(String(format: "%+.0f", $0 - be)) s from block end)" } ?? "not found"))
        if sign == nil || open == nil {
            for ph in phrases where clipStart + ph.start > be - 40 || clipStart + ph.start < bs + 30 { print(String(format: "    %+6.1f  ", clipStart + ph.start - bs) + ph.text) }
        }
    }
}
if #available(macOS 26, *) { try await run() }
