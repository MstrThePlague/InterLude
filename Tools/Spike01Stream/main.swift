import Foundation

// Spike 0.1: fetch 6 Music playlists at 320 kbps and verify segment timing,
// rewind depth, HTTPS support and headers. Downloads ~10 minutes of segments.

struct Station: Decodable { let serviceId: String; let poolId: String }
struct Catalogue: Decodable { let urlTemplate: String; let stations: [Station] }

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "recordings/spike01")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let cat = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: URL(fileURLWithPath: "Data/stations.json")))
guard let st = cat.stations.first(where: { $0.serviceId == "bbc_6music" }) else { fatalError("no station") }

func url(_ scheme: String, norewind: Bool) -> URL {
    var s = cat.urlTemplate
        .replacingOccurrences(of: "{poolId}", with: st.poolId)
        .replacingOccurrences(of: "{serviceId}", with: st.serviceId)
        .replacingOccurrences(of: "{bitrate}", with: "320000")
    if !norewind { s = s.replacingOccurrences(of: ".norewind", with: "") }
    return URL(string: s.replacingOccurrences(of: "https", with: scheme))!
}

func get(_ u: URL) async throws -> (Data, HTTPURLResponse) {
    var r = URLRequest(url: u); r.timeoutInterval = 20
    let (d, resp) = try await URLSession.shared.data(for: r)
    return (d, resp as! HTTPURLResponse)
}

struct Playlist { var firstSeq = 0; var names: [String] = []; var programDate = "" }
func parse(_ d: Data) -> Playlist {
    var p = Playlist()
    for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
        if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { p.firstSeq = Int(line.dropFirst(22)) ?? 0 }
        else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") { p.programDate = String(line.dropFirst(25)) }
        else if !line.hasPrefix("#") { p.names.append(String(line)) }
    }
    return p
}

print("# Spike 0.1 results (\(Date()))")
for scheme in ["https", "http"] {
    do {
        let (d, r) = try await get(url(scheme, norewind: true))
        print("- \(scheme) live playlist: HTTP \(r.statusCode), \(d.count) bytes, content-type \(r.value(forHTTPHeaderField: "Content-Type") ?? "?")")
    } catch { print("- \(scheme) live playlist: FAILED \(error.localizedDescription)") }
}

let (liveData, liveResp) = try await get(url("https", norewind: true))
print("- live headers:", liveResp.allHeaderFields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "))
let live = parse(liveData)
print("- live window: \(live.names.count) segments, first \(live.firstSeq), program date \(live.programDate)")

// index -> wall clock
let unixOfFirst = Double(live.firstSeq) * 6.4
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let playlistDate = iso.date(from: live.programDate) ?? ISO8601DateFormatter().date(from: live.programDate)
print("- index*6.4 = \(Date(timeIntervalSince1970: unixOfFirst)); PROGRAM-DATE-TIME = \(live.programDate); diff = \(playlistDate.map { String(format: "%.2fs", $0.timeIntervalSince1970 - unixOfFirst) } ?? "?")")

let (rewData, _) = try await get(url("https", norewind: false))
let rew = parse(rewData)
print("- rewind playlist: \(rew.names.count) segments = \(String(format: "%.2f", Double(rew.names.count) * 6.4 / 3600)) hours, first \(rew.firstSeq)")

// Probe an old segment (outside the window) by lowering the index.
let prefix = live.names[0].components(separatedBy: "-").dropLast().joined(separator: "-")
let base = url("https", norewind: true).deletingLastPathComponent()
for hours in [6.0, 8.0, 11.0] {
    let idx = (live.firstSeq) - Int(hours * 3600 / 6.4)
    do {
        let (d, r) = try await get(base.appendingPathComponent("\(prefix)-\(idx).ts"))
        print("- segment \(hours)h old: HTTP \(r.statusCode), \(d.count) bytes")
    } catch { print("- segment \(hours)h old: FAILED") }
}

// Download 10 minutes ending a minute before live and join.
let count = Int(600 / 6.4)
let startIdx = live.firstSeq + live.names.count - 1 - 10 - count
var joined = Data()
var sizes: [Int] = []
var headerSample = ""
await withTaskGroup(of: (Int, Data?, String).self) { g in
    var next = 0, inflight = 0
    var results: [Int: Data] = [:]
    func add(_ i: Int) {
        let u = base.appendingPathComponent("\(prefix)-\(startIdx + i).ts")
        g.addTask { let r = try? await get(u); return (i, r?.0, r.map { "\($0.1.value(forHTTPHeaderField: "Content-Type") ?? "?")" } ?? "") }
    }
    while next < count && inflight < 4 { add(next); next += 1; inflight += 1 }
    while let (i, d, h) = await g.next() {
        inflight -= 1
        if let d { results[i] = d; if headerSample.isEmpty { headerSample = h } }
        if next < count { add(next); next += 1; inflight += 1 }
    }
    for i in 0..<count { if let d = results[i] { joined.append(d); sizes.append(d.count) } }
}
try joined.write(to: outDir.appendingPathComponent("joined.ts"))
let missing = count - sizes.count
print("- downloaded \(sizes.count)/\(count) segments (\(missing) missing), \(joined.count) bytes, mean \(sizes.reduce(0, +) / max(sizes.count, 1)) bytes/segment, segment content-type \(headerSample)")
print("- joined file: \(outDir.appendingPathComponent("joined.ts").path)")
