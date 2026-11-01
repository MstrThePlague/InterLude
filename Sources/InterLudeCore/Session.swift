//  Session.swift
//  InterLudeCore
//
//  One playing session: it follows the station's playlist, analyses the audio about a minute ahead of the listener,
//  keeps the playout clock, and answers the player's requests with the station's segments or replacements. Live, a
//  muted bulletin is replaced segment for segment; in an earlier programme, bulletins are cut out. Everything the
//  detector decides is written to an event log, so every mute can be explained afterwards.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a session needs to know when it starts.
public struct SessionSettings: Sendable {
    public var station: Station
    /// [bit/s]
    public var bitrate = 320_000
    /// How far behind live to play [s].
    public var delaySeconds = 60.0
    public var muteNews = true
    /// A looping sound to play in place of muted bulletins; nil plays silence.
    public var ambience: URL?
    public var profile: StationProfile
    /// An earlier programme to play from its start, with bulletins skipped. Nil plays live.
    public var replay: Programme?
    /// Play `replay` from BBC Sounds rather than the live origin, which keeps only about 11 hours.
    public var onDemand = false
    /// How far into `replay` to start [s].
    public var startOffset = 0.0
    public init(station: Station, profile: StationProfile = StationProfile()) {
        self.station = station; self.profile = profile
        delaySeconds = profile.delaySeconds; muteNews = profile.muteNews
    }
}

/// The track the station's metadata says is playing, shown in the panel.
public struct NowPlaying: Sendable, Equatable {
    public var artist: String
    public var title: String?
    public var imageURL: URL?
    public init(artist: String, title: String?, imageURL: URL?) { self.artist = artist; self.title = title; self.imageURL = imageURL }
}

/// A snapshot of a session for the user interface, polled once a second.
public struct SessionStatus: Sendable {
    public enum State: Sendable, Equatable { case starting, playing, failed(String) }
    public var state: State = .starting
    /// How far behind live the listener is [s].
    public var delaySeconds = 0.0
    public var muteNews = true
    /// Whether the listener is hearing a replacement now.
    public var muted = false
    public var nowPlaying: NowPlaying?
    /// How long the listener has been in the current muted bulletin [s].
    public var muteElapsed: Double?
    /// How long until a bulletin the detector has already found reaches the listener and is muted [s].
    public var muteStartsIn: Double?
    /// Recent bulletins, newest first.
    public var recentBlocks: [NewsBlock] = []
    /// Things worth telling the listener about, oldest first. The list only grows within a session.
    public var notices: [String] = []
    /// The playout clock fell badly behind (for example after the Mac slept). The caller should start a new session.
    public var needsRestart = false
    public var learningJingle = false
    /// An on-demand programme has played to its end.
    public var finished = false
    /// The speech model for finding the newsreader: "checking", "ready" or "unavailable".
    public var speechModel = "unavailable"
    /// Set while an earlier programme is playing.
    public var replay: ReplayStatus?
    public init() {}
}

/// Where the listener is in an earlier programme, and what has been cut out of it.
public struct ReplayStatus: Sendable, Equatable {
    public var programme: Programme
    /// The broadcast time the listener is hearing.
    public var heard: Date
    /// How far ahead of the listener the analysis has got.
    public var analysedThrough: Date
    public var skipCount = 0
    /// [s]
    public var skippedSeconds = 0.0
    /// News cut out at the point the listener has just passed [s], shown for a few seconds after.
    public var justSkipped: Double?
    /// Bulletins found so far, as broadcast times.
    public var news: [ClosedRange<Date>] = []
    public init(programme: Programme, heard: Date, analysedThrough: Date) {
        self.programme = programme; self.heard = heard; self.analysedThrough = analysedThrough
    }
}

/// One playing session: ingest, analysis, the playout clock, and the responses the local server gives.
public actor PlayerSession {
    /// The secret part of the session's addresses, which the caller routes on.
    public let token: String
    /// What the player is being served, as bar heights by playback time, for the panel's backdrop.
    public nonisolated let tape = SpectrumTape()
    private let catalogue: Catalogue
    private var settings: SessionSettings
    private var store: SegmentStore?
    private var playout: Playout?
    private var replay: ReplayPlayout?
    /// What each recently listed output segment of an earlier programme carries, so it can be served when asked for.
    private var replayServed: [Int: ReplaySegment] = [:]
    private var replayCache: [Int: Data] = [:]
    /// When the player fetched an episode's last segment.
    private var endServedAt: Date?
    private var detector: NewsDetector
    /// The newest segment the station lists, or the episode's last.
    private var liveEdge = 0
    /// The newest segment analysed.
    private var analysedThrough = 0
    /// The last segment analysed, given to the classifier as context so no window is cut short.
    private var lastAnalysisSegment: PCMAudio?
    private var base: URL?
    private var segmentPrefix: String?
    private var tasks: [Task<Void, Never>] = []
    private var running = false
    private var needsRestart = false

    // What is known about each segment, for building replacements with matching timestamps.
    private var ptsByIndex: [Int: Int64] = [:]
    private var continuityByIndex: [Int: (pat: UInt8, pmt: UInt8)] = [:]
    /// A real segment, whose PAT, PMT and audio PID replacements copy.
    private var prototype: TSSegmentInfo?
    private var silentFrame: Data?
    private var ambience: Ambience?
    /// Replacement segments already built, by index.
    private var silenceCache: [Int: Data] = [:]
    /// The newest segment the player has fetched.
    private var lastServed = 0
    /// Recent fingerprint frames, for learning the news theme from a bulletin's start.
    private var featureRing: [(time: Double, frame: [Float])] = []

    // Transcribing bulletins, to find the newsreader's opening and sign-off.
    private var transcriber: (any NewsTranscribing)?
    private var speechState = "unavailable"
    /// The last 30 s of mono audio analysed.
    private var monoTail: [Float] = []
    /// Audio of the bulletin being transcribed, from 20 s before its start.
    private var blockAudio: [Float] = []
    private var blockAudioStart: Double = 0
    private var blockAudioFor: UUID?
    private var transcribedThrough: Double = 0
    private var signedOff: Set<UUID> = []
    private var listenedTo: Set<UUID> = []
    /// The last 6 s of mono audio, as context for the next chunk's fingerprints.
    private var lastMono: [Float] = []

    // Earlier programmes: the last few minutes of audio, to listen for the newsreader at every slot.
    private var slotAudio: [Float] = []
    private var slotAudioEnd: Double = 0
    private var checkedSlots: Set<Int> = []

    /// Metadata as seen live, shown once the delay has passed.
    private var tracks: [(observedAt: Date, track: NowPlaying)] = []
    private var notices: [String] = []
    private var state: SessionStatus.State = .starting
    private let eventLog: URL?
    private let cacheRoot: URL

    /// The sample rate of the stations' audio [Hz].
    static let sampleRate = 48_000.0

    /// - Parameters:
    ///   - catalogue: The station list, for building playlist URLs.
    ///   - settings: What to play and how.
    ///   - token: The secret part of the session's addresses.
    ///   - cacheRoot: Where downloaded segments go, in a folder per station.
    ///   - eventLog: The JSON Lines file decisions are appended to, or nil for none.
    public init(catalogue: Catalogue, settings: SessionSettings, token: String, cacheRoot: URL, eventLog: URL?) {
        self.catalogue = catalogue; self.settings = settings; self.token = token
        self.cacheRoot = cacheRoot; self.eventLog = eventLog
        detector = NewsDetector(config: settings.profile.detector)
    }

    // MARK: Lifecycle

    /// Fetches enough audio to fill the delay, analyses it, and starts listing segments.
    public func start() async throws {
        let directory = cacheRoot.appendingPathComponent(settings.station.serviceId, isDirectory: true)
        let store: SegmentStore
        if settings.onDemand, let programme = settings.replay {
            // The episode's segments are put on the broadcast clock (segment 1 at the programme's first segment), so
            // the detector's slot times, the playout and the log all work as they do for the live origin.
            guard let versionId = programme.versionId else { throw FetchError.unhealthy("\(programme.title) isn't available on demand.") }
            let episode = try await OnDemand.resolve(versionId: versionId, bitrate: settings.bitrate)
            liveEdge = programme.firstSegment + episode.count - 1
            store = SegmentStore(directory: directory, base: episode.base, prefix: episode.prefix, offset: programme.firstSegment - episode.first)
        } else {
            let (playlist, base) = try await PlaylistClient().fetch(catalogue: catalogue, station: settings.station, bitrate: settings.bitrate)
            guard let name = playlist.names.first, let (prefix, _) = HLS.splitName(name) else { throw FetchError.unhealthy("Unreadable playlist") }
            self.base = base; self.segmentPrefix = prefix
            liveEdge = playlist.lastSequence
            store = SegmentStore(directory: directory, base: base, prefix: prefix)
        }
        loadAmbience()
        await store.clear()
        self.store = store
        if let programme = settings.replay {
            try await startReplay(programme, store: store)
        } else {
            try await startLive(store: store)
        }
        if !settings.onDemand { tasks.append(Task { await self.pollLoop() }) }
        tasks.append(Task { await self.emitLoop() })
        if settings.replay == nil { tasks.append(Task { await self.metadataLoop() }) } else { tasks.append(Task { await self.aheadLoop() }) }
        if settings.muteNews && settings.profile.idents.isEmpty && !settings.onDemand {
            tasks.append(Task(priority: .utility) { await self.learnJingleFromRewind() })
        }
        if settings.station.kind == .music, transcriber == nil, let make = Platform.current.makeTranscriber {
            let speech = make()
            transcriber = speech
            speechState = "checking"
            tasks.append(Task(priority: .utility) {
                let ready = await speech.prepare(install: true)
                self.setSpeechState(ready ? "ready" : "unavailable")
            })
        }
    }

    /// Starts live playback: fetches from two minutes before the first segment listed up to the live edge, and
    /// analyses it all before listing anything.
    private func startLive(store: SegmentStore) async throws {
        var live = Playout(liveEdge: liveEdge, delaySeconds: settings.delaySeconds, maxMuteSeconds: settings.profile.detector.maxMuteSeconds)
        let from = live.next - 20
        analysedThrough = from - 1
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in from...liveEdge { group.addTask { _ = try await store.segment(index) } }
            try await group.waitForAll()
        }
        await analyse(upTo: liveEdge)
        try Task.checkCancellation()
        for _ in 0..<live.windowSize { await tick(&live) }
        playout = live
        running = true
        state = .playing
    }

    // MARK: Earlier programmes

    /// Segments of analysis kept ahead of the listener in an earlier programme (about ten minutes), so a bulletin's
    /// end is known before the listener reaches its start.
    static let replayAhead = 90
    /// A segment's verdict is final once the analysis is this many segments past it (the theme, the newsreader's
    /// opening and the 45 s release rule all settle within that).
    static let replaySettle = 10

    /// Plays `programme` from its start.
    ///
    /// The analysis starts two minutes earlier, as live, and gets about four minutes ahead before the first segment
    /// is listed, so a bulletin at the top of the programme is skipped from the start.
    private func startReplay(_ programme: Programme, store: SegmentStore) async throws {
        let first = programme.firstSegment + max(0, Int(settings.startOffset / segmentDuration))
        guard first <= liveEdge else { throw FetchError.unhealthy("\(programme.title) hasn't started yet.") }
        // An episode has no audio before its start, so its analysis starts there.
        let from = settings.onDemand ? max(programme.firstSegment, first - 20) : first - 20
        let to = min(liveEdge, first + 40)
        do { _ = try await store.segment(from); _ = try await store.segment(first) }
        catch {
            throw FetchError.unhealthy(settings.onDemand ? "\(programme.title) couldn't be fetched on demand."
                                                         : "\(programme.title) is no longer available. The BBC keeps about the last 11 hours.")
        }
        analysedThrough = from - 1
        await withTaskGroup(of: Void.self) { group in
            for index in from...to { group.addTask { _ = try? await store.segment(index) } }
        }
        if settings.station.kind == .music, let make = Platform.current.makeTranscriber {
            // Ready the transcriber first when its model is already installed, so the first bulletin's sign-off is heard.
            let speech = make()
            if await speech.prepare(install: false) { transcriber = speech; speechState = "ready" }
        }
        replay = ReplayPlayout(start: first, maxSkipSeconds: settings.profile.detector.maxMuteSeconds)
        await analyse(upTo: to)
        try Task.checkCancellation()
        guard var listing = replay else { return }
        for _ in 0..<listing.windowSize { await tickReplay(&listing) }
        replay = listing
        running = true
        state = .playing
        write(["event": "replayStart", "programme": programme.id, "start": programme.start.timeIntervalSince1970, "station": settings.station.serviceId])
    }

    /// Keeps the analysis about ten minutes ahead of the listener in an earlier programme, faster than real time.
    private func aheadLoop() async {
        while !Task.isCancelled && running {
            guard let store, let listing = replay else { return }
            let target = min(liveEdge, listing.source + Self.replayAhead)
            if analysedThrough >= target { try? await Task.sleep(for: .seconds(2)); continue }
            let from = analysedThrough + 1, to = min(target, analysedThrough + 10)
            await withTaskGroup(of: Void.self) { group in
                for index in from...to { group.addTask { _ = try? await store.segment(index) } }
            }
            await analyse(upTo: to)
            await store.evict(below: listing.source - 30, above: Int.max)
        }
    }

    /// Whether an on-demand episode has listed its last segment.
    private func reachedEnd(_ listing: ReplayPlayout) -> Bool { settings.onDemand && listing.source > liveEdge }

    /// Lists the next segment of an earlier programme.
    private func tickReplay(_ listing: inout ReplayPlayout) async {
        if reachedEnd(listing) { return }
        let detector = detector
        let skip = settings.muteNews && !settings.profile.shadowMode
        // At the end of an episode there is nothing more to analyse, so every verdict is final.
        let frontier = settings.onDemand && analysedThrough >= liveEdge ? liveEdge
                     : min(analysedThrough - Self.replaySettle, liveEdge - Self.replaySettle)
        let segment = listing.tick(skipNews: skip, frontier: frontier) { detector.isNews(segmentStart: HLS.startTime(ofIndex: $0).timeIntervalSince1970) }
        if let store, !segment.silent, !(await store.has(segment.source)) { _ = try? await store.segment(segment.source) }
        if let cut = listing.skips.last, cut.out == segment.out {
            write(["event": "skip", "from": cut.from, "segments": cut.segments, "station": settings.station.serviceId])
        }
        replayServed[segment.out] = segment
        replayServed = replayServed.filter { $0.key > segment.out - 30 }
        notices.append(contentsOf: listing.takeLog())
    }

    /// The station segment the listener is hearing: live, a delay behind the edge; in an earlier programme, whatever
    /// the output segment they are on carries.
    private func listenerIndex() -> Int? {
        if let listing = replay {
            let out = listing.nextOut - 1 - Playout.headStart
            return replayServed[out]?.source ?? listing.window.first?.source ?? settings.replay?.firstSegment
        }
        if let live = playout { return live.next - 1 - Playout.headStart }
        return settings.replay?.firstSegment
    }

    /// An output segment of an earlier programme: the station segment it carries (or silence), with timestamps that
    /// run on continuously across skipped news.
    private func replaySegmentData(_ out: Int) async -> Data? {
        if let cached = replayCache[out] { return cached }
        guard let segment = replayServed[out], let prototype else { return nil }
        var frames: [Data]? = nil
        if !segment.silent, let data = await store?.cached(segment.source), let info = TS.parse(data), !info.frames.isEmpty { frames = info.frames }
        if frames == nil { frames = silentFrames() }
        guard let frames else { return nil }
        let pts = (Int64(out) * Int64(segmentDuration * 90_000) + 900_000) & TS.ptsMask
        let data = TS.build(frames: frames, startPTS: pts, prototype: prototype, patCC: UInt8(out & 0xF), pmtCC: UInt8(out & 0xF))
        replayCache[out] = data
        replayCache = replayCache.filter { $0.key > out - 12 }
        return data
    }

    /// Stops every loop. The session can't be started again.
    public func stop() {
        running = false
        tasks.forEach { $0.cancel() }; tasks = []
        state = .starting
    }

    // MARK: Loops

    /// Reads the station's playlist every 3 s, fetches and analyses new segments, and forgets old ones.
    private func pollLoop() async {
        let client = PlaylistClient()
        var failures = 0
        while !Task.isCancelled && running {
            try? await Task.sleep(for: .seconds(3))
            guard let store else { continue }
            do {
                let (playlist, _) = try await client.fetch(catalogue: catalogue, station: settings.station, bitrate: settings.bitrate)
                failures = 0
                if case .failed = state { state = .playing }
                if replay != nil { liveEdge = max(liveEdge, playlist.lastSequence); continue }
                if playlist.lastSequence > liveEdge {
                    let previousEdge = liveEdge
                    liveEdge = playlist.lastSequence
                    await withTaskGroup(of: Void.self) { group in
                        for index in (previousEdge + 1)...liveEdge { group.addTask { _ = try? await store.segment(index) } }
                    }
                    await analyse(upTo: liveEdge)
                    if let live = playout {
                        await store.evict(below: live.next - 30, above: liveEdge + 5)
                        forgetSegments(before: live.next - 60)
                    }
                }
            } catch {
                failures += 1
                if failures == 3 { notices.append("Station stream failed: \(error.localizedDescription)"); state = .failed("Station stream failed") }
                try? await Task.sleep(for: .seconds(min(30, Double(failures * 3))))
            }
        }
    }

    /// Lists one segment every 6.4 s, on a monotonic clock.
    private func emitLoop() async {
        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(segmentDuration)
        while !Task.isCancelled && running {
            try? await clock.sleep(until: deadline)
            if clock.now > deadline + .seconds(20) {
                // Woke from sleep: starting again is cleaner than racing to catch up.
                needsRestart = true; deadline = clock.now + .seconds(segmentDuration); continue
            }
            deadline += .seconds(segmentDuration)
            if var listing = replay { await tickReplay(&listing); replay = listing; continue }
            guard var live = playout else { continue }
            await tick(&live)
            playout = live
        }
    }

    /// Lists the next live segment, fetching it first if it isn't on disk yet.
    private func tick(_ live: inout Playout) async {
        let index = live.next
        if let store, !(await store.has(index)) { _ = try? await store.segment(index) }
        let have = await store?.has(index) ?? false
        let detector = detector
        let mute = settings.muteNews && !settings.profile.shadowMode
        // A segment that could not be downloaded is replaced too, rather than leaving a hole in the playlist.
        let segment = live.tick(muteNews: mute) { !have || detector.isNews(segmentStart: HLS.startTime(ofIndex: $0).timeIntervalSince1970) }
        notices.append(contentsOf: live.takeLog())
        if !have && segment.source == .silence { notices.append("Segment \(index) missing; served as silence") }
    }

    /// Polls the BBC's track metadata every 30 s for the now-playing line. Display only: the detector doesn't use it.
    private func metadataLoop() async {
        guard let url = URL(string: "https://rms.api.bbc.co.uk/v2/services/\(settings.station.serviceId)/segments/latest?limit=3") else { return }
        var backoff = 30.0                                  // [s]
        while !Task.isCancelled && running {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["data"] as? [[String: Any]],
                   let current = items.first(where: { ($0["offset"] as? [String: Any])?["now_playing"] as? Bool == true }),
                   let titles = current["titles"] as? [String: Any], let artist = titles["primary"] as? String {
                    let image = (current["image_url"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "{recipe}", with: "480x480")) }
                    let track = NowPlaying(artist: artist, title: titles["secondary"] as? String, imageURL: image)
                    if tracks.last?.track != track { tracks.append((Date(), track)); if tracks.count > 50 { tracks.removeFirst() } }
                }
                backoff = 30
            } catch { backoff = min(backoff * 2, 300) }
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    // MARK: Analysis

    /// Classifies new segments in chunks of up to ten, with the previous segment as context so no window is cut
    /// short, then lets the theme matcher and the transcriber look at the same audio.
    private func analyse(upTo end: Int) async {
        guard let store else { return }
        var index = analysedThrough + 1
        let classifier = Platform.current.makeClassifier()
        // A start that has been given up on (another programme chosen) stops analysing here, so it doesn't hold up
        // the next one.
        while index <= end && !Task.isCancelled {
            let chunkEnd = min(index + 9, end)
            var buffers: [PCMAudio] = [], indices: [Int] = []
            let context = lastAnalysisSegment.map { [$0] } ?? []
            for k in index...chunkEnd {
                guard let data = await store.cached(k), let info = TS.parse(data), !info.frames.isEmpty else { continue }
                remember(index: k, info: info)
                if let audio = try? Decode.pcm(frames: info.frames) { buffers.append(audio); indices.append(k) }
            }
            if let firstNew = indices.first {
                let scores = (try? classifier.classify(context + buffers)) ?? []
                let contextSeconds = context.first?.duration ?? 0
                let chunkStart = HLS.startTime(ofIndex: firstNew).timeIntervalSince1970
                let clipStart = chunkStart - contextSeconds
                for score in scores.sorted(by: { $0.time < $1.time }) where score.time >= contextSeconds - 0.001 {
                    detector.ingest(ScoreSample(time: clipStart + score.time, duration: score.duration, speech: score.speech, music: score.music))
                }
                lastAnalysisSegment = buffers.last
                let newMono = updateIdents(chunkStart: chunkStart, buffers: buffers)
                logBlocks()
                rejudgePending()
                if replay != nil { await listenAtSlots(chunkStart: chunkStart, newMono: newMono) }
                await listenForNewsreader(chunkStart: chunkStart, newMono: newMono)
            }
            analysedThrough = chunkEnd
            index = chunkEnd + 1
        }
    }

    /// Fingerprints the new audio, with a little earlier audio as context, keeps the frames for learning, and looks
    /// for the known news theme.
    ///
    /// - Returns: The chunk's new audio as mono.
    @discardableResult
    private func updateIdents(chunkStart: Double, buffers: [PCMAudio]) -> [Float] {
        let context = lastMono
        var mono = context
        for buffer in buffers { mono += buffer.mono }
        lastMono = Array(mono.suffix(Int(Self.sampleRate) * 6))
        let firstFrameTime = chunkStart - Double(context.count) / Self.sampleRate
        let frames = IdentFeatures.extract(mono)
        for (i, frame) in frames.enumerated() {
            let time = firstFrameTime + Double(i) * IdentFeatures.frameSeconds
            if time >= chunkStart - 0.001 { featureRing.append((time, frame)) }
        }
        if featureRing.count > 20_000 { featureRing.removeFirst(featureRing.count - 20_000) }
        for reference in settings.profile.idents {
            if let match = IdentMatcher.bestMatch(reference: reference.features, in: frames), match.score >= reference.threshold {
                detector.identMatch(at: firstFrameTime + Double(match.offset) * IdentFeatures.frameSeconds - IdentMatcher.leadSeconds, score: match.score)
            }
        }
        return Array(mono.dropFirst(context.count))
    }

    /// While a bulletin is being muted, transcribes its latest audio and looks for the newsreader's opening (when the
    /// theme is not known) and sign-off. The sign-off ends the block there, so the presenter's talk afterwards plays.
    private func listenForNewsreader(chunkStart: Double, newMono: [Float]) async {
        let rate = Self.sampleRate
        monoTail += newMono
        if monoTail.count > Int(30 * rate) { monoTail.removeFirst(monoTail.count - Int(30 * rate)) }
        let chunkEnd = chunkStart + Double(newMono.count) / rate
        let tailStart = chunkEnd - Double(monoTail.count) / rate
        guard let speech = transcriber, speechState == "ready", let heard = listenerIndex() else { return }
        let listener = HLS.startTime(ofIndex: heard).timeIntervalSince1970
        guard let block = detector.blocks.last(where: { !$0.falseStart && !signedOff.contains($0.id) && ($0.isOpen || ($0.end ?? 0) > listener) }) else {
            blockAudioFor = nil; blockAudio = []; return
        }
        if blockAudioFor != block.id {
            blockAudioFor = block.id
            let from = max(tailStart, block.start - 20)
            blockAudio = Array(monoTail.dropFirst(Int((from - tailStart) * rate)))
            blockAudioStart = from
            transcribedThrough = from
        } else {
            blockAudio += newMono
        }
        if blockAudio.count > Int(480 * rate) { return }           // longer than any bulletin: leave it to the music rule
        let end = blockAudioStart + Double(blockAudio.count) / rate
        guard end - transcribedThrough >= 5 else { return }
        let from = max(blockAudioStart, transcribedThrough - 20)    // overlap, so phrases split across calls are kept
        let samples = Array(blockAudio.dropFirst(Int((from - blockAudioStart) * rate)))
        transcribedThrough = end
        guard let phrases = try? await speech.transcribe(samples: samples, sampleRate: rate), !phrases.isEmpty else { return }
        if !listenedTo.contains(block.id) {
            listenedTo.insert(block.id)
            write(["event": "transcribing", "block": block.id.uuidString, "phrases": phrases.count])
        }
        if !block.anchoredOnIdent, let opening = NewsPhrases.opening(in: phrases), from + opening < block.start + 90 {
            detector.anchorStart(at: from + opening - 3, why: "newsreader's opening heard")
        }
        // Speech alone opened this block. Once the station's theme is known, a bulletin shows it (or the newsreader's
        // opening) within about 41 s of the talk starting; by 45 s without either, this is the presenter talking. If
        // the theme turns up later after all, it opens a new block.
        if let current = detector.blocks.first(where: { $0.id == block.id }), current.isOpen, !current.anchoredOnIdent,
           !settings.profile.idents.isEmpty, end >= current.start + 45 {
            detector.rejectOpenBlock(at: current.start, why: "no news theme or newsreader heard: presenter talk")
            write(["event": "released", "block": block.id.uuidString])
        }
        if let signOff = NewsPhrases.signOff(in: phrases, after: block.start + 45 - from) {
            detector.endBlock(at: from + signOff + 0.3, why: "newsreader signed off")
            signedOff.insert(block.id)
            write(["event": "signOff", "block": block.id.uuidString, "at": from + signOff])
        }
        logBlocks()
        rejudgePending()
    }

    /// In an earlier programme the analysis is minutes ahead of the listener, so it can afford to transcribe around
    /// every bulletin slot, from a minute before to two minutes after, and open a block where the newsreader's opening
    /// is heard. Live, there isn't that much time in hand.
    private func listenAtSlots(chunkStart: Double, newMono: [Float]) async {
        let rate = Self.sampleRate, before = 60.0, after = 120.0
        if abs(chunkStart - slotAudioEnd) > 1 { slotAudio = [] }      // a gap: start again
        slotAudio += newMono
        slotAudioEnd = chunkStart + Double(newMono.count) / rate
        let keep = Int((before + after + 20) * rate)
        if slotAudio.count > keep { slotAudio.removeFirst(slotAudio.count - keep) }
        guard let speech = transcriber, speechState == "ready" else { return }
        let audioStart = slotAudioEnd - Double(slotAudio.count) / rate
        var hour = ((audioStart - after) / 3600).rounded(.down) * 3600
        while hour <= slotAudioEnd {
            for minute in settings.profile.detector.slotMinutes {
                let slot = hour + Double(minute) * 60
                guard slot + after <= slotAudioEnd, slot - before >= audioStart - 1, !checkedSlots.contains(Int(slot)) else { continue }
                checkedSlots.insert(Int(slot))
                let from = max(audioStart, slot - before)
                let samples = Array(slotAudio.dropFirst(Int((from - audioStart) * rate)).prefix(Int((slot + after - from) * rate)))
                guard let phrases = try? await speech.transcribe(samples: samples, sampleRate: rate),
                      let opening = NewsPhrases.opening(in: phrases) else { continue }
                detector.newsreaderOpening(at: from + opening - 3)
                write(["event": "slotOpening", "slot": slot, "at": from + opening])
                // A short bulletin can be over within the window: then its sign-off is in this transcript too.
                if let signOff = NewsPhrases.signOff(in: phrases, after: opening + 45),
                   let block = detector.blocks.last(where: { !$0.falseStart && abs($0.start - (from + opening - 3)) < 1 }) {
                    detector.endBlock(at: from + signOff + 0.3, why: "newsreader signed off")
                    signedOff.insert(block.id)
                    write(["event": "signOff", "block": block.id.uuidString, "at": from + signOff])
                }
                logBlocks()
            }
            hour += 3600
        }
    }

    /// Makes the segments already listed but not yet fetched follow the latest view of the timeline, for example
    /// when the news theme moves a block's start.
    private func rejudgePending() {
        guard replay == nil, var live = playout else { return }
        let detector = detector, mute = settings.muteNews && !settings.profile.shadowMode
        let before = live.window
        live.refreshPending(from: lastServed + 1) { mute && detector.isNews(segmentStart: HLS.startTime(ofIndex: $0).timeIntervalSince1970) }
        if live.window != before { silenceCache = silenceCache.filter { $0.key <= lastServed } }
        playout = live
    }

    private func setSpeechState(_ newState: String) { speechState = newState }

    /// Drops per-segment details the player can no longer ask for.
    private func forgetSegments(before index: Int) {
        ptsByIndex = ptsByIndex.filter { $0.key >= index }
        continuityByIndex = continuityByIndex.filter { $0.key >= index }
    }

    /// Notes what a replacement for this segment needs to copy: its timestamp, its continuity counters, and, once,
    /// a prototype segment and a silent frame shaped like the station's.
    private func remember(index: Int, info: TSSegmentInfo) {
        if let pts = info.firstPTS { ptsByIndex[index] = pts }
        let pat = info.patPacket.map { $0[3] & 0x0F } ?? 0, pmt = info.pmtPacket.map { $0[3] & 0x0F } ?? 0
        continuityByIndex[index] = (pat, pmt)
        if prototype == nil, info.patPacket != nil, info.pmtPacket != nil { prototype = info }
        if silentFrame == nil, let first = info.frames.first, let raw = try? Silence.rawFrame() { silentFrame = Silence.adts(raw: raw, like: first) }
    }

    /// A segment's worth of silent frames, once the station's frame shape is known.
    private func silentFrames() -> [Data]? {
        silentFrame.map { Array(repeating: $0, count: Ambience.framesPerSegment) }
    }

    // MARK: Event log

    /// Whether each block was open when last logged, so each change is logged once.
    private var loggedState: [UUID: Bool] = [:]

    /// Logs blocks that have opened or closed, and learns from bulletins that ran their normal course.
    private func logBlocks() {
        for block in detector.blocks where loggedState[block.id] != block.isOpen {
            loggedState[block.id] = block.isOpen
            write(["event": block.isOpen ? "open" : "close", "block": blockJSON(block)])
            // A bulletin that ran its normal course (music returned, sensible length) teaches the jingle too.
            if !block.isOpen && !block.falseStart && !block.timedOut && !block.doubtful && !block.evidence.hasPrefix("marked") { learn(from: block) }
        }
    }

    private func blockJSON(_ block: NewsBlock) -> [String: Any] {
        ["id": block.id.uuidString, "start": block.start, "end": block.end as Any? ?? NSNull(), "evidence": block.evidence,
         "doubtful": block.doubtful, "timedOut": block.timedOut, "falseStart": block.falseStart, "station": settings.station.serviceId]
    }

    /// Appends one JSON line to the event log.
    ///
    /// When the log passes 5 MB it is renamed to `events.1.jsonl`, replacing the previous one, and a new log is
    /// started.
    private func write(_ event: [String: Any]) {
        guard let url = eventLog else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            let previous = url.deletingPathExtension().appendingPathExtension("1.jsonl")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        var stamped = event; stamped["loggedAt"] = Date().timeIntervalSince1970
        guard let line = try? JSONSerialization.data(withJSONObject: stamped) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); handle.write(Data("\n".utf8)); try? handle.close()
        }
    }

    // MARK: Controls

    /// Changes the sound played during bulletins, from the next segment the player fetches.
    public func setAmbience(_ url: URL?) {
        settings.ambience = url
        loadAmbience()
        silenceCache = silenceCache.filter { $0.key <= lastServed }
    }

    private func loadAmbience() {
        ambience = nil
        guard let url = settings.ambience else { return }
        do { ambience = try Ambience(url: url) }
        catch { notices.append("Could not load the sound for bulletins (\(url.lastPathComponent)); muting with silence") }
    }

    /// Changes options that take effect at once, without a restart.
    public func setLiveOptions(muteNews: Bool, shadowMode: Bool) {
        settings.muteNews = muteNews; settings.profile.shadowMode = shadowMode
    }

    /// "Not news": unmutes from the next segment the player fetches, then judges what follows again.
    public func notNews() {
        let first = replay != nil ? (replayServed[lastServed + 1]?.source ?? (listenerIndex() ?? 0) + 1) : lastServed + 1
        detector.rejectOpenBlock(at: HLS.startTime(ofIndex: first).timeIntervalSince1970)
        rejudgePending()
        if let block = detector.blocks.last(where: \.falseStart) { write(["event": "falseStart", "block": blockJSON(block)]) }
        logBlocks()
    }

    /// "News got through": the bulletin the listener just heard was not muted. Learns from it.
    public func newsGotThrough() {
        guard let heard = listenerIndex() else { return }
        let listener = HLS.startTime(ofIndex: heard).timeIntervalSince1970
        guard let block = detector.markNewsHeard(listenerTime: listener) else { notices.append("No speech to mark as news"); return }
        write(["event": "marked", "listenerTime": listener, "block": blockJSON(block)])
        learn(from: block)
    }

    /// Saves the audio around a bulletin's start as a jingle candidate, and the bulletin's time and length.
    ///
    /// The news theme has been seen 11 to 41 s after the speech starts, so the window runs from 10 s before to 60 s
    /// after.
    private func learn(from block: NewsBlock) {
        if let end = block.end { settings.profile.learn(start: block.start, end: end) }
        let slice = featureRing.filter { $0.time >= block.start - 10 && $0.time < block.start + 60 }.map(\.frame)
        if slice.count > 1000 {
            settings.profile.candidates.append(slice)
            settings.profile.candidateSources.append(block.id.uuidString)
            while settings.profile.candidates.count > StationProfile.maxCandidates {
                settings.profile.candidates.removeFirst(); settings.profile.candidateSources.removeFirst()
            }
            promoteIdent()
        }
        saveLearning()
        write(["event": "candidate", "block": block.id.uuidString, "candidates": settings.profile.candidates.count,
               "identLearned": !settings.profile.idents.isEmpty])
    }

    /// Looks for a shared theme among the candidates off the actor, since it takes a few seconds, then adopts it.
    private func promoteIdent() {
        let candidates = settings.profile.candidates
        Task.detached(priority: .utility) { [weak self] in
            let reference = IdentMatcher.promote(candidates: candidates)
            await self?.adoptIdent(reference, source: "recent bulletins", keepExisting: true)
        }
    }

    /// Uses a newly learned theme.
    ///
    /// - Parameters:
    ///   - reference: The theme, or nil if none was found.
    ///   - source: Where it was learned, for the notice and the log.
    ///   - keepExisting: Whether to keep the current theme when none was found.
    private func adoptIdent(_ reference: IdentReference?, source: String, keepExisting: Bool) {
        let had = !settings.profile.idents.isEmpty
        if let reference { settings.profile.idents = [reference] } else if !keepExisting { settings.profile.idents = [] }
        if !had, reference != nil {
            notices.append("Learned the news jingle for \(settings.station.name) from \(source)")
            write(["event": "identLearned", "source": source])
        }
        saveLearning()
    }

    // MARK: Learning the jingle from the BBC's rewind window

    public private(set) var learningJingle = false

    /// Looks at the 150 s after each of the last eight bulletin slots in the BBC's six-hour rewind window, and learns
    /// the news theme if at least three share it. About 50 MB of downloads, once per station.
    private func learnJingleFromRewind() async {
        guard settings.station.kind == .music, settings.profile.idents.isEmpty, let base, let prefix = segmentPrefix else { return }
        learningJingle = true
        defer { learningJingle = false }
        let live = HLS.startTime(ofIndex: liveEdge).timeIntervalSince1970
        let window = 5.5 * 3600                             // within the six-hour rewind, with a margin [s]
        var slots: [Double] = []
        var hour = (live / 3600).rounded(.down) * 3600
        while slots.count < 8 && hour > live - window {
            for minute in settings.profile.detector.slotMinutes.sorted(by: >) {
                let slot = hour + Double(minute) * 60
                if slot + 160 < live && slot > live - window && slots.count < 8 { slots.append(slot) }
            }
            hour -= 3600
        }
        guard slots.count >= 3 else { return }
        let directory = cacheRoot.appendingPathComponent("rewind-\(settings.station.serviceId)", isDirectory: true)
        let rewind = SegmentStore(directory: directory, base: base, prefix: prefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let silentSegment = [Float](repeating: 0, count: samplesPerSegment)
        var windows: [[[Float]]] = []
        for slot in slots {
            if Task.isCancelled || !running { return }
            let first = Int(floor(slot / segmentDuration)) + 1, last = Int(floor((slot + 150) / segmentDuration)) + 1
            var mono: [Float] = []
            for index in first...last {
                // A segment that can't be had is filled with silence, so the timing of the rest holds.
                guard let data = try? await rewind.segment(index) else { mono += silentSegment; continue }
                let decoded: [Float]? = await Task.detached(priority: .utility) {
                    guard let info = TS.parse(data), let audio = try? Decode.pcm(frames: info.frames) else { return nil }
                    return audio.mono
                }.value
                mono += decoded ?? silentSegment
            }
            let skip = Int(max(0, slot - HLS.startTime(ofIndex: first).timeIntervalSince1970) * Self.sampleRate)
            let clip = Array(mono.dropFirst(skip))
            windows.append(await Task.detached(priority: .utility) { IdentFeatures.extract(clip) }.value)
        }
        let reference = await Task.detached(priority: .utility) { IdentMatcher.promote(candidates: windows) }.value
        adoptIdent(reference, source: "the last few hours", keepExisting: true)
        write(["event": "rewindLearning", "slots": slots.count, "learned": reference != nil])
    }

    /// Saves only what was learned, on top of the file, so settings changed meanwhile in the app are kept.
    private func saveLearning() {
        var onDisk = StationProfile.load(settings.station)
        onDisk.candidates = settings.profile.candidates; onDisk.candidateSources = settings.profile.candidateSources
        onDisk.idents = settings.profile.idents
        onDisk.startMinuteHistogram = settings.profile.startMinuteHistogram; onDisk.bulletinSeconds = settings.profile.bulletinSeconds
        onDisk.detector.minBulletinSeconds = settings.profile.detector.minBulletinSeconds
        onDisk.detector.maxBulletinSeconds = settings.profile.detector.maxBulletinSeconds
        onDisk.save(settings.station)
    }

    /// "Wasn't news" on a recent block: kept in the log as a mistake, and no longer used to learn the theme.
    public func markWrong(id: UUID) {
        detector.markFalseStart(id: id)
        if let block = detector.blocks.first(where: { $0.id == id }) { write(["event": "wrong", "block": blockJSON(block)]) }
        // Withdraw the jingle candidate this block gave, if any.
        if let index = settings.profile.candidateSources.firstIndex(of: id.uuidString) {
            settings.profile.candidates.remove(at: index); settings.profile.candidateSources.remove(at: index)
            promoteIdent(); saveLearning()
        }
    }

    /// A snapshot of the session for the user interface.
    public func status() -> SessionStatus {
        var status = SessionStatus()
        status.state = state; status.delaySeconds = settings.delaySeconds; status.muteNews = settings.muteNews
        status.needsRestart = needsRestart; status.learningJingle = learningJingle; status.speechModel = speechState
        let muting = settings.muteNews && !settings.profile.shadowMode
        if let listing = replay, let programme = settings.replay {
            let out = listing.nextOut - 1 - Playout.headStart
            let segment = replayServed[out]
            let playing = segment?.source ?? programme.firstSegment
            let heard = HLS.startTime(ofIndex: playing).timeIntervalSince1970
            status.muted = segment?.silent ?? false
            status.delaySeconds = settings.onDemand ? Date().timeIntervalSince1970 - heard : Double(liveEdge - playing) * segmentDuration
            // The player starts on a segment about three behind the newest it has fetched, so it plays on that long.
            status.finished = endServedAt.map { Date().timeIntervalSince($0) > Double(Playout.headStart) * segmentDuration + 2 } ?? false
            let analysedEnd = HLS.startTime(ofIndex: analysedThrough + 1)
            var progress = ReplayStatus(programme: programme, heard: Date(timeIntervalSince1970: heard), analysedThrough: analysedEnd)
            let passed = listing.skips.filter { $0.out <= out }
            progress.skipCount = passed.count
            progress.skippedSeconds = passed.reduce(0) { $0 + $1.seconds }
            if let cut = passed.last, out - cut.out < 2 { progress.justSkipped = cut.seconds }
            progress.news = detector.blocks.filter { !$0.falseStart && ($0.end ?? .infinity) > programme.start.timeIntervalSince1970 - 60 }
                .map { Date(timeIntervalSince1970: $0.start)...Date(timeIntervalSince1970: $0.end ?? analysedEnd.timeIntervalSince1970) }
            status.replay = progress
            if status.muted, let block = detector.blocks.last(where: { !$0.falseStart && $0.start <= heard && ($0.end ?? .infinity) > heard }) {
                status.muteElapsed = heard - block.start
            } else if muting, let block = detector.blocks.last(where: { !$0.falseStart && $0.start > heard }) {
                status.muteStartsIn = max(0, floor(block.start / segmentDuration) * segmentDuration - heard)
            }
            status.nowPlaying = NowPlaying(artist: programme.subtitle ?? settings.station.name, title: programme.title, imageURL: programme.imageURL)
            status.recentBlocks = Array(detector.blocks.filter { $0.start >= programme.start.timeIntervalSince1970 - 60 && $0.start <= heard }
                .suffix(8).reversed())
            status.notices = notices
            return status
        }
        if let live = playout {
            let playing = live.next - 1 - Playout.headStart
            status.muted = live.window.first(where: { $0.index == playing })?.source == .silence
            status.delaySeconds = Double(liveEdge - playing) * segmentDuration
            let heard = HLS.startTime(ofIndex: playing).timeIntervalSince1970
            if status.muted {
                if let block = detector.blocks.last(where: { !$0.falseStart && $0.start <= heard && ($0.end ?? .infinity) > heard }) {
                    status.muteElapsed = heard - block.start
                }
            } else if muting, let block = detector.blocks.last(where: { !$0.falseStart && $0.start > heard }) {
                // Mutes start on a segment boundary, so count down to the start of the segment the block starts in.
                status.muteStartsIn = max(0, floor(block.start / segmentDuration) * segmentDuration - heard)
            }
        }
        let shownFrom = Date().addingTimeInterval(-settings.delaySeconds)
        status.nowPlaying = tracks.last(where: { $0.observedAt <= shownFrom })?.track
        status.recentBlocks = Array(detector.blocks.suffix(8).reversed())
        status.notices = notices
        return status
    }

    // MARK: Serving

    /// Answers a request from the player.
    ///
    /// - Parameter relative: The path after the session's prefix: `live.m3u8` or `seg/<index>.ts`.
    /// - Returns: The playlist or segment, or 404 for anything else.
    public func respond(to relative: String) async -> HTTPResponse {
        if relative == "live.m3u8" {
            let text: String
            if let listing = replay {
                text = HLS.write(mediaSequence: listing.mediaSequence, segments: listing.window.map(\.out)) { "seg/\($0).ts" }
                    + (reachedEnd(listing) ? "#EXT-X-ENDLIST\n" : "")
            } else if let live = playout {
                text = HLS.write(mediaSequence: live.mediaSequence, segments: live.window.map(\.index)) { "seg/\($0).ts" }
            } else { return .notFound }
            return HTTPResponse(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8), noCache: true)
        }
        guard let index = AACStream.index(of: relative) else { return .notFound }
        lastServed = max(lastServed, index)
        var body: Data?
        if let listing = replay {
            body = await replaySegmentData(index)
            if reachedEnd(listing), index == listing.window.last?.out, endServedAt == nil { endServedAt = Date() }
        } else if playout?.window.first(where: { $0.index == index })?.source == .silence, let replacement = mutedSegment(index) {
            body = replacement
        } else if let data = await store?.cached(index) {
            body = data
        } else {
            body = replacementSegment(index, frames: silentFrames())
        }
        guard let body else { return .notFound }
        if tape.claim(index) {
            let tape = tape
            Task.detached(priority: .utility) {
                guard let info = TS.parse(body), let audio = try? Decode.pcm(frames: info.frames) else { return }
                tape.record(index, Spectrum.frames(audio))
            }
        }
        return HTTPResponse(contentType: "video/mp2t", body: body)
    }

    /// The segment heard in place of muted segment `index`: the chosen ambience, or silence.
    ///
    /// Ambience fades in at the start of a muted run and out at its end, judged from the neighbouring segments in the
    /// playlist.
    private func mutedSegment(_ index: Int) -> Data? {
        if let cached = silenceCache[index] { return cached }
        var frames = silentFrames()
        if let ambience, let like = prototype?.frames.first {
            let window = playout?.window ?? []
            let before = window.first { $0.index == index - 1 }?.source, after = window.first { $0.index == index + 1 }?.source
            if let raw = try? ambience.frames(forSegment: index, fadeIn: before != .silence, fadeOut: after == .station) {
                frames = raw.map { Silence.adts(raw: $0, like: like) }
            }
        }
        guard let data = replacementSegment(index, frames: frames) else { return nil }
        silenceCache[index] = data
        if silenceCache.count > 200, let oldest = silenceCache.keys.min() { silenceCache.removeValue(forKey: oldest) }
        return data
    }

    /// Builds a segment from `frames` that carries the timestamps of segment `index`, which it replaces.
    ///
    /// The timestamp comes from the segment itself if it was seen, otherwise from a neighbour or any known segment,
    /// counting 6.4 s per segment.
    private func replacementSegment(_ index: Int, frames: [Data]?) -> Data? {
        guard let prototype, let frames else { return nil }
        let step = Int64(segmentDuration * 90_000)          // [ticks of the 90 kHz clock]
        let pts: Int64
        if let known = ptsByIndex[index] { pts = known }
        else if let before = ptsByIndex[index - 1] { pts = (before + step) & TS.ptsMask }
        else if let after = ptsByIndex[index + 1] { pts = (after - step) & TS.ptsMask }
        else if let any = ptsByIndex.first { pts = (any.value + Int64(index - any.key) * step) & TS.ptsMask }
        else { return nil }
        let counters = continuityByIndex[index]
            ?? continuityByIndex[index - 1].map { (pat: ($0.pat + 1) & 0xF, pmt: ($0.pmt + 1) & 0xF) }
            ?? (pat: 0, pmt: 0)
        return TS.build(frames: frames, startPTS: pts, prototype: prototype, patCC: counters.pat, pmtCC: counters.pmt)
    }
}
