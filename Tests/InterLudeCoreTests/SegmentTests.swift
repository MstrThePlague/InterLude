import Testing
import Foundation
@testable import InterLudeCore

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

@Test func jingleCandidatesSurviveTheBinaryFile() {
    let a: [[Float]] = (0..<5).map { i in (0..<32).map { Float(i) * 0.5 - Float($0) / 7 } }
    let b: [[Float]] = [[1, -2, .pi], [0, 0, 0]]
    #expect(CandidateFile.decode(CandidateFile.encode([a, b])) == [a, b])
    #expect(CandidateFile.decode(Data([1, 0])) == [])               // truncated files read as empty, not a crash
}

@Test func profileJSONLeavesCandidatesOut() throws {
    var p = StationProfile()
    p.candidates = [[[1, 2, 3]]]
    let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
    #expect(!json.contains("\"candidates\""))
}
