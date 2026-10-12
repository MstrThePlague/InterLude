import Testing
import Foundation
@testable import InterLudeCore

/// Synthetic timelines: 3 s windows every 1.5 s.
func samples(from start: Double, speech: Bool, seconds: Double, bed: Double = 0.1) -> [ScoreSample] {
    stride(from: start, to: start + seconds, by: 1.5).map {
        ScoreSample(time: $0, speech: speech ? 0.9 : 0.05, music: speech ? bed : 0.9)
    }
}
// 2026-10-12 05:30:00 UTC is a multiple of 3600*... use a base on the hour
let hour: Double = 1_791_781_200 - (1_791_781_200.truncatingRemainder(dividingBy: 3600))

@Test func opensAfterSustainedSpeechNearSlot() {
    var d = NewsDetector()
    for s in samples(from: hour + 30 * 60 - 60, speech: false, seconds: 60) { d.ingest(s) }
    for s in samples(from: hour + 30 * 60 + 5, speech: true, seconds: 15) { d.ingest(s) }
    #expect(d.openBlock == nil)                       // 15 s is not enough
    for s in samples(from: hour + 30 * 60 + 20, speech: true, seconds: 20) { d.ingest(s) }
    #expect(d.openBlock != nil)
    #expect(abs(d.openBlock!.start - (hour + 30 * 60 + 5)) < 0.01)
}

@Test func closesWhenMusicReturnsAndWidensToSegments() {
    var d = NewsDetector()
    for s in samples(from: hour + 30 * 60, speech: true, seconds: 150) { d.ingest(s) }
    for s in samples(from: hour + 30 * 60 + 150, speech: false, seconds: 30) { d.ingest(s) }
    let b = try! #require(d.blocks.first)
    #expect(b.end != nil && !b.doubtful)
    #expect(d.isNews(segmentStart: hour + 30 * 60 + 100))
    #expect(!d.isNews(segmentStart: hour + 30 * 60 + 200))
}

@Test func ignoresSpeechOutsideSlot() {
    var d = NewsDetector()
    for s in samples(from: hour + 15 * 60, speech: true, seconds: 120) { d.ingest(s) }
    #expect(d.blocks.isEmpty)
}

@Test func gapsUpTo8SecondsStayInBlock() {
    var d = NewsDetector()
    for s in samples(from: hour + 1800, speech: true, seconds: 30) { d.ingest(s) }
    for s in samples(from: hour + 1830, speech: false, seconds: 4) { d.ingest(s) }
    for s in samples(from: hour + 1834, speech: true, seconds: 30) { d.ingest(s) }
    #expect(d.openBlock != nil)
}

@Test func longestMuteClosesBlock() {
    var d = NewsDetector()
    for s in samples(from: hour + 1800, speech: true, seconds: 600) { d.ingest(s) }
    let b = try! #require(d.blocks.first)
    #expect(b.timedOut && b.end != nil)
}

@Test func notNewsClosesBlockAndRejudgesLaterAudio() {
    var d = NewsDetector()
    // Presenter chat from :26:00 is flagged only because the slot window is wide here.
    var cfg = DetectorConfig(); cfg.slotBeforeMinutes = 5
    d = NewsDetector(config: cfg)
    for s in samples(from: hour + 1800 - 120, speech: true, seconds: 100) { d.ingest(s) }   // already analysed, ahead of the listener
    #expect(d.openBlock != nil)
    d.rejectOpenBlock(at: hour + 1800 - 60)          // the listener has only reached -60 s
    #expect(d.blocks[0].falseStart)
    // The speech after -60 s carried on into the bulletin, so it counts again from that point.
    #expect(d.openBlock != nil && d.openBlock!.start >= hour + 1800 - 60)
    #expect(!d.isNews(segmentStart: hour + 1800 - 120))
    #expect(d.isNews(segmentStart: hour + 1800 - 20))
}

@Test func notNewsStaysUnmutedWhenSpeechStops() {
    var cfg = DetectorConfig(); cfg.slotBeforeMinutes = 5
    var d = NewsDetector(config: cfg)
    for s in samples(from: hour + 1800 - 120, speech: true, seconds: 30) { d.ingest(s) }
    for s in samples(from: hour + 1800 - 90, speech: false, seconds: 60) { d.ingest(s) }
    d.rejectOpenBlock(at: hour + 1800 - 100)
    #expect(d.openBlock == nil)
    for s in samples(from: hour + 1800 - 30, speech: true, seconds: 15) { d.ingest(s) }
    #expect(d.openBlock == nil)
}

@Test func playoutRefreshPendingRemutes() {
    var p = Playout(liveEdge: 100, delaySeconds: 60)
    for _ in 0..<8 { _ = p.tick(muteNews: true) { _ in false } }
    p.refreshPending(from: 94) { $0 >= 95 }
    let m = Dictionary(uniqueKeysWithValues: p.window.map { ($0.index, $0.source) })
    #expect(m[93] == .station && m[94] == .station && m[95] == .silence && m[96] == .silence)
}

@Test func playoutKeepsConstantDelayAndWindow() {
    var p = Playout(liveEdge: 1000, delaySeconds: 60)
    #expect(p.next == 989)
    var out: [ListedSegment] = []
    for _ in 0..<20 { out.append(p.tick(muteNews: true) { _ in false }) }
    #expect(out.map(\.index) == Array(989..<1009))
    #expect(p.window.count == 6 && p.mediaSequence == 14)
}

@Test func playoutMutesNewsSegmentsThenReturns() {
    var p = Playout(liveEdge: 100, delaySeconds: 60)
    var srcs: [SegmentSource] = []
    for _ in 0..<10 { srcs.append(p.tick(muteNews: true) { (94...96).contains($0) }.source) }
    #expect(srcs.filter { $0 == .silence }.count == 3)
    #expect(srcs[5] == .silence && srcs[7] == .silence && srcs[8] == .station)
}

@Test func playoutStartsMutedInsideOpenBlock() {
    var p = Playout(liveEdge: 100, delaySeconds: 60)
    #expect(p.tick(muteNews: true) { _ in true }.source == .silence)
}

@Test func playoutLongestMuteLimit() {
    var p = Playout(liveEdge: 100, delaySeconds: 60, maxMuteSeconds: 32)
    let s = (0..<10).map { _ in p.tick(muteNews: true) { _ in true }.source }
    #expect(s.prefix(5).allSatisfy { $0 == .silence } && s[5] == .station)
    #expect(!p.log.isEmpty)
}

@Test func muteSwitchOffNeverMutes() {
    var p = Playout(liveEdge: 100, delaySeconds: 60)
    #expect(p.tick(muteNews: false) { _ in true }.source == .station)
}

@Test func silentSegmentsJoinRealOnesWithoutTimestampBreaks() throws {
    let dir = "/Users/ben/Documents/GitHub/InterLude/recordings/6music-a"
    guard let idx = try? String(contentsOfFile: dir + "/index.txt", encoding: .utf8) else { return }
    let first = Int(idx.split(separator: " ")[0])! + 200
    var out = Data()
    var proto: TSSegmentInfo?
    var frame: Data?
    for i in first..<(first + 12) {
        let d = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(i).ts"))
        let info = try #require(TS.parse(d))
        if proto == nil { proto = info; frame = Silence.adts(raw: try Silence.rawFrame(), like: info.frames[0]) }
        if (first + 4..<first + 8).contains(i) {
            let cc = (info.patPacket![3] & 0xF, info.pmtPacket![3] & 0xF)
            out.append(TS.build(frames: Array(repeating: frame!, count: 300), startPTS: info.firstPTS!, prototype: proto!, patCC: cc.0, pmtCC: cc.1))
        } else { out.append(d) }
    }
    try out.write(to: URL(fileURLWithPath: "/tmp/mix.ts"))
}

@Test func identMatcherFindsEmbeddedClip() {
    // A tone sweep embedded in noise should be found at the right offset.
    func sweep(_ n: Int) -> [Float] { (0..<n).map { i in sin(Float(i) * (0.02 + 0.00002 * Float(i)).truncatingRemainder(dividingBy: 1.5)) } }
    var rng = SystemRandomNumberGenerator()
    func noise(_ n: Int) -> [Float] { (0..<n).map { _ in Float.random(in: -0.3...0.3, using: &rng) } }
    let clip = sweep(48000 * 3)
    let stream = noise(48000 * 4) + clip + noise(48000 * 4)
    let ref = IdentFeatures.extract(clip)
    let feats = IdentFeatures.extract(stream)
    let m = IdentMatcher.bestMatch(reference: ref, in: feats)
    #expect(m != nil && m!.score > 0.8)
    let expected = 48000 * 4 / IdentFeatures.hop
    #expect(abs(m!.offset - expected) <= 2)
}

@Test func castMessageRoundTrips() throws {
    let framed = CastWire.encode(source: "sender-0", destination: "receiver-0", namespace: "urn:x-cast:com.google.cast.tp.connection", payload: "{\"type\":\"CONNECT\"}")
    let len = Int(framed[0]) << 24 | Int(framed[1]) << 16 | Int(framed[2]) << 8 | Int(framed[3])
    #expect(len == framed.count - 4)
    let m = try #require(CastWire.decode(Array(framed.dropFirst(4))))
    #expect(m.source == "sender-0" && m.destination == "receiver-0" && m.payload == "{\"type\":\"CONNECT\"}")
    #expect(m.namespace.hasSuffix("tp.connection"))
    // Known wire bytes: version=0, then source string field 2.
    #expect(Array(framed[4..<8]) == [0x08, 0x00, 0x12, 0x08])
}

@Test func identOnlyIgnoresSpeechButMutesOnIdent() {
    var cfg = DetectorConfig(); cfg.identOnly = true
    var d = NewsDetector(config: cfg)
    for s in samples(from: hour + 1800, speech: true, seconds: 60) { d.ingest(s) }
    #expect(d.blocks.isEmpty)
    d.identMatch(at: hour + 1860, score: 0.9)
    #expect(d.openBlock != nil)
    for s in samples(from: hour + 1860, speech: true, seconds: 100) { d.ingest(s) }
    for s in samples(from: hour + 1960, speech: false, seconds: 30) { d.ingest(s) }
    #expect(d.openBlock == nil && d.blocks.count == 1)
}

@Test func slotWindowIsNarrowAndAsymmetric() {
    let d = NewsDetector()
    #expect(d.inSlot(hour + 1800 + 30))        // 30 s after
    #expect(d.inSlot(hour + 1800 - 50))        // 50 s before
    #expect(d.inSlot(hour + 3600 + 150))       // 2.5 min after the hour
    #expect(!d.inSlot(hour + 1800 - 240))      // 4 min before: a presenter over a song
    #expect(!d.inSlot(hour + 1800 + 240))
}

@Test func oldProfilesStillDecode() throws {
    let old = #"{"speechThreshold":0.7,"slotWindowMinutes":4,"slotMinutes":[0,30]}"#
    let c = try JSONDecoder().decode(DetectorConfig.self, from: Data(old.utf8))
    #expect(c.speechThreshold == 0.7 && c.slotAfterMinutes == 3 && c.maxMuteSeconds == 480)
}

@Test func newsHeardUsesSpeechTheListenerHasReached() {
    var d = NewsDetector()
    for s in samples(from: hour + 1800, speech: true, seconds: 120) { d.ingest(s) }          // the bulletin
    for s in samples(from: hour + 1920, speech: false, seconds: 60) { d.ingest(s) }
    for s in samples(from: hour + 1980, speech: true, seconds: 15) { d.ingest(s) }           // later chat, already analysed
    let b = d.markNewsHeard(listenerTime: hour + 1850)
    #expect(b != nil && abs(b!.start - (hour + 1800)) < 0.01)
    let later = d.markNewsHeard(listenerTime: hour + 2000)     // prefers the long run over the short one
    #expect(later != nil && abs(later!.start - (hour + 1800)) < 0.01)
}
