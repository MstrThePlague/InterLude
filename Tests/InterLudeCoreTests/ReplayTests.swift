import Testing
import Foundation
@testable import InterLudeCore

@Test func replaySkipsNewsOnceTheAnalysisHasPassedIt() {
    var p = ReplayPlayout(start: 100)
    let news = 103..<110
    var listed: [ReplaySegment] = []
    for _ in 0..<8 { listed.append(p.tick(skipNews: true, frontier: 200) { news.contains($0) }) }
    #expect(listed.map(\.out) == Array(1...8))                       // output runs on without a gap
    #expect(listed.map(\.source) == [100, 101, 102, 110, 111, 112, 113, 114])
    #expect(listed.allSatisfy { !$0.silent })
    #expect(p.skips == [Skip(out: 4, from: 103, segments: 7)])
}

@Test func replayHoldsWithSilenceUntilTheEndOfTheNewsIsKnown() {
    var p = ReplayPlayout(start: 100)
    let news = 101..<106
    _ = p.tick(skipNews: true, frontier: 103) { news.contains($0) }
    let held = p.tick(skipNews: true, frontier: 103) { news.contains($0) }
    #expect(held.silent && held.source == 101)
    // The analysis moves on and finds the end: the rest of the bulletin is skipped.
    let next = p.tick(skipNews: true, frontier: 120) { news.contains($0) }
    #expect(!next.silent && next.source == 106)
    #expect(p.skips.first?.segments == 4)
}

@Test func replayPlaysNewsWhenSkippingIsOff() {
    var p = ReplayPlayout(start: 100)
    let s = (0..<4).map { _ in p.tick(skipNews: false, frontier: 200) { _ in true } }
    #expect(s.map(\.source) == [100, 101, 102, 103] && s.allSatisfy { !$0.silent })
    #expect(p.skips.isEmpty)
}

@Test func replayPlaysABlockLongerThanTheLongestSkip() {
    var p = ReplayPlayout(start: 100, maxSkipSeconds: 64)          // 10 segments
    let seg = p.tick(skipNews: true, frontier: 500) { _ in true }
    #expect(seg.source == 100 && !seg.silent)
    #expect(p.takeLog().first?.contains("longest skip") == true)
}

@Test func replayWindowSlides() {
    var p = ReplayPlayout(start: 1, windowSize: 6)
    for _ in 0..<10 { _ = p.tick(skipNews: true, frontier: 100) { _ in false } }
    #expect(p.window.map(\.out) == Array(5...10))
    #expect(p.mediaSequence == 5)
}

@Test func scheduleParsesBroadcastsAndFiltersToStarted() throws {
    let json = """
    {"data":[{"type":"inline_display_module","data":[
      {"type":"broadcast_summary","id":"a","start":"2026-10-17T07:00:00Z","end":"2026-10-17T09:00:00Z",
       "titles":{"primary":"Radcliffe and Maconie","secondary":"Music and chat"},"image_url":"https://x/{recipe}/p.jpg"},
      {"type":"broadcast_summary","id":"b","start":"2026-10-17T09:00:00Z","end":"2026-10-17T12:00:00Z",
       "titles":{"primary":"Later","secondary":""}}]}]}
    """
    let all = Schedule.parse(Data(json.utf8))
    #expect(all.count == 2)
    let a = try #require(all.first { $0.id == "a" })
    #expect(a.title == "Radcliffe and Maconie" && a.subtitle == "Music and chat")
    #expect(a.imageURL?.absoluteString == "https://x/480x480/p.jpg")
    #expect(all.first { $0.id == "b" }?.subtitle == nil)
    #expect(HLS.startTime(ofIndex: a.firstSegment) <= a.start && a.start.timeIntervalSince(HLS.startTime(ofIndex: a.firstSegment)) < segmentDuration)

    let now = ISO8601DateFormatter().date(from: "2026-10-17T08:00:00Z")!
    #expect(Schedule.filter(all, now: now).map(\.id) == ["a"])
    #expect(Schedule.isPlayable(a, now: now))
    #expect(!Schedule.isPlayable(a, now: now.addingTimeInterval(11 * 3600)))
}

@Test func newsreaderOpeningOpensABlockAfterTalkThatBeganOutsideTheSlot() {
    var d = NewsDetector()
    // The presenter talks from 07:27 straight into the 07:30 bulletin: the run began outside the slot.
    for s in samples(from: hour + 27 * 60, speech: true, seconds: 300) { d.ingest(s) }
    #expect(d.blocks.isEmpty)
    d.newsreaderOpening(at: hour + 30 * 60 + 2)
    let b = try! #require(d.openBlock)
    #expect(b.start == hour + 30 * 60 + 2 && b.anchoredOnIdent)
    d.endBlock(at: hour + 32 * 60 + 54, why: "newsreader signed off")
    #expect(d.isNews(segmentStart: hour + 31 * 60) && !d.isNews(segmentStart: hour + 33 * 60))
}

@Test func newsreaderOpeningAwayFromASlotIsIgnored() {
    var d = NewsDetector()
    d.newsreaderOpening(at: hour + 15 * 60)
    #expect(d.blocks.isEmpty)
}
