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
