import Testing
import Foundation
@testable import InterLudeCore

func syntheticPrototype() -> TSSegmentInfo {
    // PAT/PMT shaped like the BBC's: audio on PID 34, PMT on PID 32.
    func pkt(_ pid: Int, _ payload: [UInt8]) -> Data {
        var d = Data([0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10, 0x00]) + Data(payload)
        d.append(Data(repeating: 0xFF, count: 188 - d.count)); return d
    }
    let pat = pkt(0, [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0, 0x20, 0, 0, 0, 0])
    let pmt = pkt(32, [0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0, 0x22, 0xF0, 0x00, 0x0F, 0xE0, 0x22, 0xF0, 0x00, 0, 0, 0, 0])
    return TSSegmentInfo(audioPID: 34, frames: [], firstPTS: nil, patPacket: pat, pmtPacket: pmt)
}

@Test func silentSegmentRoundTrips() throws {
    let raw = try Silence.rawFrame()
    let frame = Silence.adts(raw: raw, like: nil)
    let seg = TS.build(frames: Array(repeating: frame, count: 300), startPTS: 2_323_604_384, prototype: syntheticPrototype(), patCC: 4, pmtCC: 4)
    #expect(seg.count % 188 == 0)
    let info = try #require(TS.parse(seg))
    #expect(info.audioPID == 34)
    #expect(info.frames.count == 300)
    #expect(info.firstPTS == 2_323_604_384)
    try seg.write(to: URL(fileURLWithPath: "/tmp/silent_test.ts"))
}

@Test func playlistParseAndSplit() {
    let text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:100\n#EXT-X-PROGRAM-DATE-TIME:2026-10-12T07:38:27.200000Z\n#EXTINF:6.4,\nbbc_6music-audio=320000-100.ts\n#EXTINF:6.4,\nbbc_6music-audio=320000-101.ts\n"
    let p = HLS.parse(Data(text.utf8))
    #expect(p.firstSequence == 100 && p.names.count == 2 && p.lastSequence == 101)
    #expect(HLS.splitName(p.names[0])?.index == 100)
    #expect(HLS.splitName(p.names[0])?.prefix == "bbc_6music-audio=320000-")
}

@Test func realSegmentIfPresent() throws {
    guard let d = FileManager.default.contents(atPath: "/tmp/seg0.ts") else { return }
    let info = try #require(TS.parse(d))
    print("REAL frames", info.frames.count, "pid", info.audioPID, "pts", info.firstPTS ?? -1, info.frames.prefix(3).map { $0.count })
}
