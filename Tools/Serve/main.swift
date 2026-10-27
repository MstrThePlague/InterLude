import Foundation
import InterLudeCore
import InterLudeApple

Platform.install(.apple)

// serve <serviceId> [delaySeconds] [port]  — runs a headless session for testing with ffmpeg, curl or a player.
let a = CommandLine.arguments
let cat = try Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json"))
guard a.count >= 2, let st = cat.station(a[1]) else { print("usage: serve <serviceId> [delaySeconds] [port]"); exit(2) }
var settings = SessionSettings(station: st, profile: StationProfile.load(st))
if a.count >= 3, let d = Double(a[2]) { settings.delaySeconds = d }
// AMBIENCE=ocean (or stream, birds) plays that sound over bulletins instead of silence.
if let name = ProcessInfo.processInfo.environment["AMBIENCE"] { settings.ambience = URL(fileURLWithPath: "Resources/Ambience/\(name).m4a") }
// REPLAY=2026-10-18T08:28:00Z plays from that broadcast time instead of live, skipping bulletins.
if let r = ProcessInfo.processInfo.environment["REPLAY"], let t = ISO8601DateFormatter().date(from: r) {
    // VERSION=m0032tkh plays that BBC Sounds version, broadcast at REPLAY, on demand. OFFSET=1680 starts 28 minutes in.
    let env = ProcessInfo.processInfo.environment
    settings.replay = Programme(id: "serve", title: "Replay from \(r)", subtitle: nil, start: t, end: t.addingTimeInterval(3600), imageURL: nil,
                                versionId: env["VERSION"])
    settings.onDemand = env["VERSION"] != nil
    settings.startOffset = env["OFFSET"].flatMap(Double.init) ?? 0
}
let port = a.count >= 4 ? UInt16(a[3]) ?? 8642 : 8642
let token = "test"
let session = PlayerSession(catalogue: cat, settings: settings, token: token,
    cacheRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("InterLudeServe"),
    eventLog: URL(fileURLWithPath: "recordings/serve-events.jsonl"))
let server = LocalServer(port: port) { req in
    let prefix = "/\(token)/"
    guard req.path.hasPrefix(prefix) else { return .notFound }
    return await session.respond(to: String(req.path.dropFirst(prefix.count)))
}
try server.start()
print("starting session (\(Int(settings.delaySeconds))s delay)...")
try await session.start()
print("serving http://127.0.0.1:\(port)/\(token)/live.m3u8  LAN: \(LocalServer.lanAddress() ?? "?")")
while true {
    try await Task.sleep(for: .seconds(ProcessInfo.processInfo.environment["REPLAY"] == nil ? 30 : 10))
    let s = await session.status()
    if let r = s.replay {
        let f = ISO8601DateFormatter()
        print("replay: heard=\(f.string(from: r.heard)) analysed=\(f.string(from: r.analysedThrough)) skips=\(r.skipCount) (\(Int(r.skippedSeconds)) s) news=\(r.news.map { "\(f.string(from: $0.lowerBound))+\(Int($0.upperBound.timeIntervalSince($0.lowerBound)))s" }) muted=\(s.muted) behind=\(Int(s.delaySeconds))s")
        continue
    }
    print("status: muted=\(s.muted) now=\(s.nowPlaying.map { "\($0.artist) - \($0.title ?? "")" } ?? "-") blocks=\(s.recentBlocks.count) notices=\(s.notices.suffix(2))")
}
