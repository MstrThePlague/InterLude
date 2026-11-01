//  SonosTests.swift
//  InterLudeCoreTests
//
//  Sonos: reading the household's topology, the SOAP messages, and the AAC stream speakers play.

import Testing
import Foundation
@testable import InterLudeCore

@Suite struct SonosTests {
    /// GetZoneGroupState's answer for a household of a grouped Kitchen and Lounge (Kitchen leading), a stereo pair in
    /// the Study whose second speaker is hidden, and a bridge, escaped as Sonos sends it.
    let topology: String = {
        let state = """
        <ZoneGroupState><ZoneGroups>\
        <ZoneGroup Coordinator="RINCON_B" ID="RINCON_B:1">\
        <ZoneGroupMember UUID="RINCON_A" Location="http://10.0.0.11:1400/xml/device_description.xml" ZoneName="Lounge"/>\
        <ZoneGroupMember UUID="RINCON_B" Location="http://10.0.0.12:1400/xml/device_description.xml" ZoneName="Kitchen &amp; Diner"/>\
        </ZoneGroup>\
        <ZoneGroup Coordinator="RINCON_C" ID="RINCON_C:2">\
        <ZoneGroupMember UUID="RINCON_C" Location="http://10.0.0.13:1400/xml/device_description.xml" ZoneName="Study">\
        <Satellite UUID="RINCON_S" Location="http://10.0.0.15:1400/xml/device_description.xml" ZoneName="Study"/>\
        </ZoneGroupMember>\
        <ZoneGroupMember UUID="RINCON_D" Location="http://10.0.0.14:1400/xml/device_description.xml" ZoneName="Study" Invisible="1"/>\
        </ZoneGroup>\
        <ZoneGroup Coordinator="RINCON_E" ID="RINCON_E:3">\
        <ZoneGroupMember UUID="RINCON_E" Location="http://10.0.0.16:1400/xml/device_description.xml" ZoneName="BRIDGE" IsZoneBridge="1"/>\
        </ZoneGroup>\
        </ZoneGroups></ZoneGroupState>
        """
        return "<s:Envelope><s:Body><u:GetZoneGroupStateResponse><ZoneGroupState>\(Sonos.escape(state))</ZoneGroupState>"
            + "</u:GetZoneGroupStateResponse></s:Body></s:Envelope>"
    }()

    @Test func readsTheHouseholdsGroups() {
        let groups = Sonos.parseTopology(topology)
        #expect(groups == [
            SonosGroup(id: "RINCON_B", rooms: ["Kitchen & Diner", "Lounge"], host: "10.0.0.12"),
            SonosGroup(id: "RINCON_C", rooms: ["Study"], host: "10.0.0.13"),
        ])
        #expect(groups[0].name == "Kitchen & Diner + 1")
        #expect(groups[0].isGroup && !groups[1].isGroup)
        #expect(groups[1].detail == "Sonos")
    }

    @Test func playsTheStreamAsARadioStation() {
        #expect(Sonos.radioURI(URL(string: "http://10.0.0.5:8642/stream/live.aac")!) == "x-rincon-mp3radio://10.0.0.5:8642/stream/live.aac")
        let soap = Sonos.envelope(.avTransport, "SetAVTransportURI",
                                  ["InstanceID": "0", "CurrentURIMetaData": Sonos.radioMetadata(title: "Radio 6 Music · Tom & Jo")])
        // The metadata is XML inside XML, so it is escaped twice over.
        #expect(soap.contains("&lt;dc:title&gt;Radio 6 Music · Tom &amp;amp; Jo&lt;/dc:title&gt;"))
        #expect(soap.contains("<InstanceID>0</InstanceID><CurrentURIMetaData>"))
        #expect(Sonos.errorCode("<s:Fault><detail><UPnPError><errorCode>714</errorCode></UPnPError></detail></s:Fault>") == 714)
    }

    /// The AAC stream starts the usual three segments behind the newest listed, sends each new one once, and ends
    /// with an earlier programme's playlist.
    @Test func aacStreamFollowsThePlaylist() async {
        final class Feed: @unchecked Sendable {
            let lock = NSLock()
            var polls = 0
            var fetched: [Int] = []
        }
        let feed = Feed()
        let stream = AACStream.frames(fetch: { path in
            if path == "live.m3u8" {
                // Five segments listed, then one more, then the end.
                let poll = feed.lock.withLock { feed.polls += 1; return feed.polls }
                var text = HLS.write(mediaSequence: 1, segments: Array(1...min(4 + poll, 6))) { "seg/\($0).ts" }
                if poll >= 2 { text += "#EXT-X-ENDLIST\n" }
                return HTTPResponse(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
            }
            feed.lock.withLock { feed.fetched.append(AACStream.index(of: path) ?? -1) }
            return HTTPResponse(contentType: "video/mp2t", body: Data(path.utf8))
        }, poll: .milliseconds(10), audio: { $0 })
        var chunks: [Data] = []
        for await c in stream { chunks.append(c) }
        #expect(feed.fetched == [3, 4, 5, 6])
        #expect(chunks.count == 4)
        #expect(chunks.map { String(decoding: $0, as: UTF8.self) } == ["seg/3.ts", "seg/4.ts", "seg/5.ts", "seg/6.ts"])
    }

    /// When the session the stream began with stops, the stream ends instead of waiting for another.
    @Test func aacStreamEndsWithItsSession() async {
        final class Polls: @unchecked Sendable { let lock = NSLock(); var count = 0 }
        let polls = Polls()
        let stream = AACStream.frames(fetch: { path in
            let n = polls.lock.withLock { polls.count += 1; return polls.count }
            if n > 2 { return AACStream.ended }
            let text = HLS.write(mediaSequence: 1, segments: [1]) { "seg/\($0).ts" }
            return path == "live.m3u8" ? HTTPResponse(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
                                      : HTTPResponse(contentType: "video/mp2t", body: Data(path.utf8))
        }, poll: .milliseconds(10), audio: { $0 })
        var chunks = 0
        for await _ in stream { chunks += 1 }
        #expect(chunks == 1)
        #expect(polls.lock.withLock { polls.count } == 3)
    }
}
