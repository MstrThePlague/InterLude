import Foundation
import InterLudeCore

// serve <serviceId> [delaySeconds] [port]  — runs a headless session for testing with ffmpeg, curl or a player.
let a = CommandLine.arguments
let cat = try Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json"))
guard a.count >= 2, let st = cat.station(a[1]) else { print("usage: serve <serviceId> [delaySeconds] [port]"); exit(2) }
var settings = SessionSettings(station: st, profile: StationProfile.load(st))
if a.count >= 3, let d = Double(a[2]) { settings.delaySeconds = d }
// AMBIENCE=ocean (or stream, birds) plays that sound over bulletins instead of silence.
if let name = ProcessInfo.processInfo.environment["AMBIENCE"] { settings.ambience = URL(fileURLWithPath: "Resources/Ambience/\(name).m4a") }
let port = a.count >= 4 ? UInt16(a[3]) ?? 8642 : 8642
let token = "test"
let session = PlayerSession(catalogue: cat, settings: settings, token: token,
    cacheRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("InterLudeServe"),
    eventLog: URL(fileURLWithPath: "recordings/serve-events.jsonl"))
let server = LocalServer(port: port) { path in
    let prefix = "/\(token)/"
    guard path.hasPrefix(prefix) else { return .notFound }
    return await session.respond(to: String(path.dropFirst(prefix.count)))
}
try server.start()
print("starting session (\(Int(settings.delaySeconds))s delay)...")
try await session.start()
print("serving http://127.0.0.1:\(port)/\(token)/live.m3u8  LAN: \(LocalServer.lanAddress() ?? "?")")
while true {
    try await Task.sleep(for: .seconds(30))
    let s = await session.status()
    print("status: muted=\(s.muted) now=\(s.nowPlaying.map { "\($0.artist) - \($0.title ?? "")" } ?? "-") blocks=\(s.recentBlocks.count) notices=\(s.notices.suffix(2))")
}
