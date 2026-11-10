//  CoordinatorTests.swift
//  InterLudeCoreTests
//
//  What the Mac and the server share: settings reaching a session that is playing, forgetting the jingle for good,
//  profiles saved without losing what was learned, resuming and seeking in Earlier, the note on stations still being
//  learned, the bulletins listed to the listener, starting without waiting, and station wording.

import Testing
import Foundation
@testable import InterLudeCore

/// These read and write profiles, so they run one at a time in a folder of their own.
@Suite(.serialized) struct ProfileFileTests {
    let station = Station(name: "Test FM", serviceId: "test_fm", poolId: "1", kind: .music)

    /// Runs `body` with InterLude's files in a new temporary folder.
    private func inFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        AppPaths.root = folder
        defer { AppPaths.root = nil; try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    private func session(_ profile: StationProfile, cache: URL) -> PlayerSession {
        PlayerSession(catalogue: Catalogue(urlTemplate: "https://example/{poolId}/{serviceId}", stations: [station]),
                      settings: SessionSettings(station: station, profile: profile), token: "t", cacheRoot: cache, eventLog: nil)
    }

    private var theme: IdentReference { IdentReference(features: Array(repeating: Array(repeating: 0.5, count: IdentFeatures.bands), count: 20)) }

    @Test func forgettingTheJingleMidSessionStaysForgotten() async throws {
        try await inFolder { folder in
            var profile = StationProfile(); profile.idents = [theme]
            profile.save(station)
            let playing = session(profile, cache: folder)
            var book = ProfileBook()
            book.update(station) { RemoteSetting.forgetJingle.profileChange?(&$0) }
            await playing.forgetJingle()
            // A bulletin closes and the session saves what it learned.
            await playing.learn(from: NewsBlock(start: hour + 1800, end: hour + 1980, evidence: "test"))
            #expect(StationProfile.load(station).idents.isEmpty)
        }
    }

    @Test func settingsChangedWhilePlayingReachTheSession() async throws {
        try await inFolder { folder in
            let playing = session(StationProfile(), cache: folder)
            var book = ProfileBook()
            var updated = book.update(station) { RemoteSetting.jingleOnly(true).profileChange?(&$0) }
            updated = book.update(station) { RemoteSetting.maxMute(12).profileChange?(&$0) }
            updated = book.update(station) { RemoteSetting.slots([15, 45]).profileChange?(&$0) }
            updated = book.update(station) { RemoteSetting.muteNews(false).profileChange?(&$0) }
            await playing.applyProfile(updated)
            let config = await playing.detectorConfig
            #expect(config.identOnly && config.maxMuteSeconds == 720 && config.slotMinutes == [15, 45])
            #expect(await playing.status().muteNews == false)
        }
    }

    @Test func savingSettingsKeepsWhatTheSessionLearned() async throws {
        try await inFolder { _ in
            var book = ProfileBook()
            book.load([station])                         // an old copy, from before the session learned anything
            var learned = StationProfile.load(station)
            learned.bulletinSeconds = [180, 190, 200]
            learned.save(station)                         // as the session's saveLearning does
            book.update(station) { $0.favourite = true }
            let saved = StationProfile.load(station)
            #expect(saved.favourite && saved.bulletinSeconds == [180, 190, 200])
        }
    }
}

@Test func startMutingLeavesShadowModeAndUsesTheJingleIfKnown() {
    var profile = StationProfile(); profile.shadowMode = true; profile.detector.identOnly = true
    RemoteSetting.startMuting(&profile)
    #expect(!profile.shadowMode && !profile.detector.identOnly)       // no jingle: the speech rule the listener checked
    profile.shadowMode = true
    profile.idents = [IdentReference(features: [[0]])]
    RemoteSetting.startMuting(&profile)
    #expect(!profile.shadowMode && profile.detector.identOnly)
}

@Test func stationsStillBeingLearnedSayWhatTheyHaveFound() {
    var station = Station(name: "Radio 2", serviceId: "bbc_radio_two", poolId: "1", kind: .music)
    station.untested = true
    var profile = StationProfile.fresh(for: station)
    let found = [NewsBlock(start: hour + 1800, end: hour + 1980), NewsBlock(start: hour, end: hour + 170)]
    let first = RemoteState.LearningItem.describe(station: station, profile: profile, blocks: Array(found.prefix(1)))
    #expect(first?.canStartMuting == false && first?.found.count == 1)
    #expect(RemoteState.LearningItem.describe(station: station, profile: profile, blocks: found)?.canStartMuting == true)
    var open = NewsBlock(start: hour + 3600); open.falseStart = false
    #expect(RemoteState.LearningItem.describe(station: station, profile: profile, blocks: [open] + Array(found.prefix(1)))?.canStartMuting == false)
    profile.shadowMode = false
    #expect(RemoteState.LearningItem.describe(station: station, profile: profile, blocks: found) == nil)
    station.untested = nil
    #expect(RemoteState.LearningItem.describe(station: station, profile: StationProfile.fresh(for: station), blocks: found) == nil)
}

@Test func earlierProgrammesResumeWhereTheyWereLeft() {
    let start = Date(timeIntervalSince1970: hour)
    let programme = Programme(id: "p1", title: "Show", subtitle: nil, start: start, end: start.addingTimeInterval(7200), imageURL: nil)
    var bookmarks = ReplayBookmarks()
    #expect(bookmarks.offset(for: programme) == 0)
    bookmarks.remember(ReplayStatus(programme: programme, heard: start.addingTimeInterval(1234), analysedThrough: start.addingTimeInterval(1800)))
    #expect(bookmarks.offset(for: programme) == 1229)
    bookmarks.remember(ReplayStatus(programme: programme, heard: start.addingTimeInterval(7190), analysedThrough: start.addingTimeInterval(7200)))
    #expect(bookmarks.offset(for: programme) == 0)                  // heard to the end
    #expect(ReplayBookmarks.offset(at: 0.5, in: programme) == 3600)
    #expect(ReplayBookmarks.offset(at: 1, in: programme) == 7140)   // kept clear of the very end
    #expect(Wording.playStarts(programme, at: 1229).hasPrefix("Play resumes Show at 20:29"))
}

@Test func onlyBulletinsTheListenerHasReachedAreListed() {
    var released = NewsBlock(start: hour + 100, end: hour + 145); released.falseStart = true
    released.evidence = "speech near a slot; closed: no news theme or newsreader heard: presenter talk, 45s"
    var rejected = NewsBlock(start: hour + 200, end: hour + 230); rejected.falseStart = true
    rejected.evidence = "speech near a slot; closed: rejected by user, 30s"
    let muted = NewsBlock(start: hour + 300, end: hour + 480)
    let ahead = NewsBlock(start: hour + 600)
    let listed = PlayerSession.heardBlocks([released, rejected, muted, ahead], heard: hour + 500)
    #expect(listed.map(\.id) == [muted.id, rejected.id])
    var detector = NewsDetector()
    for s in samples(from: hour + 30 * 60 + 5, speech: true, seconds: 40) { detector.ingest(s) }
    for s in samples(from: hour + 30 * 60 + 45, speech: false, seconds: 30) { detector.ingest(s) }
    let id = try! #require(detector.blocks.first?.id)
    detector.markFalseStart(id: id)
    #expect(detector.blocks[0].correctedByHand)
}

@Test func startsAtOnceOnlyWellAwayFromSlots() {
    let detector = NewsDetector()                                   // slots at :00 and :30
    let quiet = hour + 12 * 60                                      // 12 minutes past
    #expect(PlayerSession.quietStart(listener: quiet, edge: quiet + 60, detector: detector, longestBulletin: 360))
    // A bulletin at :00 could still be running at 4 minutes past.
    #expect(!PlayerSession.quietStart(listener: hour + 4 * 60, edge: hour + 5 * 60, detector: detector, longestBulletin: 360))
    // The analysis would reach :30 at 28 minutes past.
    #expect(!PlayerSession.quietStart(listener: hour + 27 * 60, edge: hour + 28 * 60, detector: detector, longestBulletin: 360))
    // Newsbeat's 15 minutes from 12:45 UK time is still running at 12:56.
    var radio1 = NewsDetector(); radio1.longBulletins = [LongBulletin(at: "12:45", minutes: 15)]
    let winter: Double = 1_793_623_500                              // 2026-11-02 12:45 UTC, 12:45 in the UK
    let longest = radio1.maxMute(forBlockAt: winter + 60)
    #expect(!PlayerSession.quietStart(listener: winter + 11 * 60, edge: winter + 12 * 60, detector: radio1, longestBulletin: longest))
    var anywhere = NewsDetector(); anywhere.config.requireSlot = false
    #expect(!PlayerSession.quietStart(listener: quiet, edge: quiet + 60, detector: anywhere, longestBulletin: 360))
}

@Test func stationsCanAddTheirOwnWording() {
    let phrases = [SpokenPhrase(start: 30, end: 33, text: "Newyddion Radio Cymru."), SpokenPhrase(start: 150, end: 153, text: "Mwy am ddau o'r gloch.")]
    #expect(NewsPhrases.opening(in: phrases) == nil)
    #expect(NewsPhrases.opening(in: phrases, extra: ["newyddion radio cymru"]) == 30)
    #expect(NewsPhrases.signOff(in: phrases, after: 60, extra: ["mwy am"]) == 153)
}

@Test func untestedIncludesRadioCymru2() throws {
    let catalogue = try Catalogue.load(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Data/stations.json").standardized)
    #expect(try #require(catalogue.station("bbc_radio_cymru_2")).untested == true)
}

@Test func earlierCommandsRoute() {
    func route(_ target: String) -> RemoteRoute? { RemoteRoutes.route(HTTPRequest(requestLine: "POST \(target) HTTP/1.1")!, token: "abc") }
    #expect(route("/remote/abc/api/seek?f=0.25") == .command(.seek(0.25)))
    #expect(route("/remote/abc/api/seek?f=7") == .command(.seek(1)))
    #expect(route("/remote/abc/api/seek?f=nan") == nil)
    #expect(route("/remote/abc/api/startover") == .command(.startOver))
    #expect(route("/remote/abc/api/startmuting") == .command(.startMuting))
}

@Test func theScheduleIsKeptForFiveMinutes() {
    var book = ScheduleBook()
    let first = book.begin(station: "a")
    #expect(first)
    book.loaded([Programme(id: "x", title: "X", subtitle: nil, start: Date(), end: Date(), imageURL: nil)], station: "a", day: 0, current: "a")
    let cached = book.begin(station: "a"), forced = book.begin(station: "a", force: true), other = book.begin(station: "b")
    #expect(!cached && forced && other)
    book.loaded([], station: "a", day: 0, current: "b")             // overtaken by another station
    #expect(book.programmes.count == 1 && book.loading)
}

@Test func aBulletinOpenedAheadOfTheAnalysisDoesNotStop() {
    // Seen on the server: while an earlier programme started, a bulletin opened on the news theme a few seconds after
    // the point the analysis had reached, and building its range for the progress bar stopped the program.
    let start = Date(timeIntervalSince1970: hour)
    let open = NewsBlock(start: hour + 130)
    let ranges = PlayerSession.newsRanges([open, NewsBlock(start: hour + 10, end: hour + 70)], from: start,
                                          analysedThrough: start.addingTimeInterval(120))
    #expect(ranges.count == 2 && ranges[0].lowerBound == ranges[0].upperBound)
    #expect(ranges[1].upperBound == start.addingTimeInterval(70))
}
