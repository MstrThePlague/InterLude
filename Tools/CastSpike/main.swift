import Foundation
import InterLudeCore
import InterLudeApple

Platform.install(.apple)

// cast-spike list
// cast-spike play <deviceNameSubstring> <url> [seconds]    load a stream and report which hlsSegmentFormat worked
let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: cast-spike list | play <device> <url> [seconds]"); exit(2) }
let disc = CastDiscovery(); disc.start()
var devices: [CastDevice] = []
let deadline = Date().addingTimeInterval(6)
let task = Task { for await d in disc.updates { devices = d } }
while Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
task.cancel()
print("found \(devices.count) Cast service(s):")
for d in devices { print("  \(d.name)  [\(d.model)]\(d.isGroup ? "  GROUP" : "")") }
guard a[1] == "play", a.count >= 4 else { exit(0) }
guard let dev = devices.first(where: { $0.name.localizedCaseInsensitiveContains(a[2]) }) else { print("no such device"); exit(1) }
let c = DirectCastController(device: dev)
let ev = Task { for await e in c.events { print("event:", e) } }
print("connecting to \(dev.name)...")
try await c.connect()
print("receiver launched; loading \(a[3])")
try await c.load(url: URL(string: a[3])!, title: "InterLude spike")
print("LOAD accepted")
try await Task.sleep(for: .seconds(a.count >= 5 ? Double(a[4]) ?? 30 : 30))
await c.stop(); ev.cancel()
print("stopped")
