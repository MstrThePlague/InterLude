import Foundation
import Testing
@testable import InterLudeCast

/// A response as a Chromecast sends it: PTR to its instance, SRV to its host, TXT with its name, A with its address,
/// with names compressed.
@Test func mdnsReadsACastAnswer() {
    var m: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 3]
    let service = MDNS.encodeName("_googlecast._tcp.local")
    let serviceAt = m.count
    func ptr(_ offset: Int) -> [UInt8] { [0xC0 | UInt8(offset >> 8), UInt8(offset & 0xFF)] }
    func rr(_ name: [UInt8], _ type: UInt16, _ data: [UInt8]) -> [UInt8] {
        name + [UInt8(type >> 8), UInt8(type & 0xFF), 0x80, 1, 0, 0, 0, 120, UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data
    }
    // Answer: PTR _googlecast._tcp.local -> Kitchen-abc._googlecast._tcp.local
    let instanceData = [UInt8(11)] + Array("Kitchen-abc".utf8) + ptr(serviceAt)
    m += rr(service, 12, instanceData)
    let instanceAt = m.count - instanceData.count
    // Additional: SRV, TXT, A
    let host = MDNS.encodeName("abc.local")
    m += rr(ptr(instanceAt), 33, [0, 0, 0, 0, 0x1F, 0x49] + host)
    let hostAt = m.count - host.count
    let txt = ["id=abc", "md=Chromecast Audio", "fn=Kitchen"].flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
    m += rr(ptr(instanceAt), 16, txt)
    m += rr(ptr(hostAt), 1, [192, 168, 1, 50])

    let speakers = MDNS.speakers(from: MDNS.parse(m))
    #expect(speakers == [CastSpeaker(id: "Kitchen-abc", name: "Kitchen", model: "Chromecast Audio", host: "192.168.1.50", port: 8009)])
    #expect(speakers.first?.isGroup == false)
}

@Test func mdnsIgnoresTruncatedPackets() {
    #expect(MDNS.parse([0, 0, 0x84, 0, 0, 0, 0, 1]).isEmpty)
    #expect(MDNS.parse([0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 5, 0x61]).isEmpty)
}

/// Looks for real speakers on this network, when asked to with INTERLUDE_LIVE_CAST=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["INTERLUDE_LIVE_CAST"] == "1"))
func mdnsFindsSpeakersHere() {
    let found = MDNS.browseCast(timeout: 3)
    print("found", found.map { "\($0.name) [\($0.model)] \($0.host):\($0.port)" })
    #expect(!found.isEmpty)
}

/// A speaker's records as an announcement or answer carries them.
private func announcement(_ id: String, _ service: String, host: String, address: String) -> [MDNS.Record] {
    let instance = "\(id).\(service)"
    return [.ptr(name: service, target: instance), .srv(name: instance, target: host, port: 8009),
            .txt(name: instance, values: ["fn": id]), .a(name: host, address: address)]
}

@Test func mdnsReadsAGoodbye() {
    // A PTR answer with a time to live of zero.
    var m: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0]
    let instance = [UInt8(7)] + Array("Kitchen".utf8) + MDNS.encodeName("_googlecast._tcp.local")
    m += MDNS.encodeName("_googlecast._tcp.local") + [0, 12, 0x80, 1, 0, 0, 0, 0, 0, UInt8(instance.count)] + instance
    #expect(MDNS.parse(m) == [.goodbye(name: "_googlecast._tcp.local", target: "Kitchen._googlecast._tcp.local")])
}

@Test func mdnsCacheFollowsSpeakersComingAndGoing() {
    var cache = MDNSCache(lifetime: 75)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let cast = MDNS.service, sonos = MDNS.sonosService
    cache.add(announcement("Kitchen", cast, host: "k.local", address: "192.168.1.40")
              + announcement("Lounge", cast, host: "l.local", address: "192.168.1.41")
              + announcement("RINCON_1@Roam", sonos, host: "r.local", address: "192.168.1.30"), at: t0)
    #expect(MDNS.speakers(from: cache.records).map(\.name) == ["Kitchen", "Lounge"])
    #expect(MDNS.instances(of: sonos, from: cache.records).map(\.host) == ["192.168.1.30"])

    // Kitchen says goodbye: gone at once.
    cache.add([.goodbye(name: cast, target: "Kitchen.\(cast)")], at: t0 + 5)
    #expect(MDNS.speakers(from: cache.records).map(\.name) == ["Lounge"])

    // The Roam moves to a new address: the newer one wins straight away.
    cache.add(announcement("RINCON_1@Roam", sonos, host: "r.local", address: "192.168.1.31"), at: t0 + 10)
    #expect(MDNS.instances(of: sonos, from: cache.records).map(\.host) == ["192.168.1.31"])

    // Lounge is unplugged and stops answering; the Roam keeps answering. Lounge is forgotten after the lifetime.
    cache.add(announcement("RINCON_1@Roam", sonos, host: "r.local", address: "192.168.1.31"), at: t0 + 70)
    cache.expire(t0 + 74)
    #expect(MDNS.speakers(from: cache.records).map(\.name) == ["Lounge"])
    cache.expire(t0 + 76)
    #expect(MDNS.speakers(from: cache.records).isEmpty)
    #expect(MDNS.instances(of: sonos, from: cache.records).map(\.host) == ["192.168.1.31"])
}

/// Watches for real speakers on this network, when asked to with INTERLUDE_LIVE_CAST=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["INTERLUDE_LIVE_CAST"] == "1"))
func mdnsWatcherFindsSpeakersHere() async {
    let w = MDNSWatcher()
    w.start()
    defer { w.stop() }
    var first: MDNSWatcher.Found?
    for await f in w.updates { first = f; break }
    print("cast", first?.cast.map(\.name) ?? [], "sonos", first?.sonos ?? [])
    #expect(!(first?.cast.isEmpty ?? true) || !(first?.sonos.isEmpty ?? true))
}
