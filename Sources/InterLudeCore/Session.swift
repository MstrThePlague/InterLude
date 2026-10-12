import Foundation
import AVFoundation

public struct SessionSettings: Sendable {
    public var station: Station
    public var bitrate = 320_000
    public var delaySeconds = 60.0
    public var muteNews = true
    public var profile: StationProfile
    public init(station: Station, profile: StationProfile = StationProfile()) {
        self.station = station; self.profile = profile
        delaySeconds = profile.delaySeconds; muteNews = profile.muteNews
    }
}

public struct NowPlaying: Sendable, Equatable {
    public var artist: String
    public var title: String?
    public var imageURL: URL?
    public init(artist: String, title: String?, imageURL: URL?) { self.artist = artist; self.title = title; self.imageURL = imageURL }
}

public struct SessionStatus: Sendable {
    public enum State: Sendable, Equatable { case starting, playing, failed(String) }
    public var state: State = .starting
    public var delaySeconds = 0.0
    public var muteNews = true
    public var muted = false
    public var nowPlaying: NowPlaying?
    /// Seconds the listener has been in the current muted bulletin, when muted.
    public var muteElapsed: Double?
    /// Seconds until a bulletin the detector has already found reaches the listener and is muted.
    public var muteStartsIn: Double?
    public var recentBlocks: [NewsBlock] = []
    public var notices: [String] = []
    /// The playout clock fell badly behind (for example after the Mac slept). The caller should start a new session.
    public var needsRestart = false
    public var learningJingle = false
    /// On-device speech model for finding the newsreader's sign-off: checking, installing, ready or unavailable.
    public var speechModel = "unavailable"
    public init() {}
}

/// One playing session: ingest, analysis, playout clock, and the responses the local server gives.
public actor PlayerSession {
    public let token: String
    private let catalogue: Catalogue
    private var settings: SessionSettings
    private var store: SegmentStore?
    private var playout: Playout?
    private var detector: NewsDetector
    private var liveEdge = 0
    private var analysedThrough = 0
    private var lastAnalysisSegment: AVAudioPCMBuffer?
    private var base: URL?
    private var segmentPrefix: String?
    private var tasks: [Task<Void, Never>] = []
    private var running = false
    private var needsRestart = false

    private var ptsByIndex: [Int: Int64] = [:]
    private var ccByIndex: [Int: (UInt8, UInt8)] = [:]
    private var prototype: TSSegmentInfo?
    private var silentFrame: Data?
    private var silenceCache: [Int: Data] = [:]
    private var lastServed = 0
    private var featureRing: [(time: Double, frame: [Float])] = []
    // Transcription of muted blocks, to find the newsreader's opening and sign-off (macOS 26 and later).
    private var transcriber: AnyObject?
    private var speechState = "unavailable"
    private var monoTail: [Float] = []                  // the last 30 s of audio analysed
    private var blockAudio: [Float] = []
    private var blockAudioStart: Double = 0
    private var blockAudioFor: UUID?
    private var transcribedThrough: Double = 0
    private var signedOff: Set<UUID> = []
    private var listenedTo: Set<UUID> = []
    private var lastMono: [Float] = []

    private var tracks: [(observedAt: Date, track: NowPlaying)] = []
    private var notices: [String] = []
    private var state: SessionStatus.State = .starting
    private let eventLog: URL?
    private let cacheRoot: URL

    public init(catalogue: Catalogue, settings: SessionSettings, token: String, cacheRoot: URL, eventLog: URL?) {
        self.catalogue = catalogue; self.settings = settings; self.token = token
        self.cacheRoot = cacheRoot; self.eventLog = eventLog
        detector = NewsDetector(config: settings.profile.detector)
    }

    // MARK: Lifecycle

    public func start() async throws {
        let client = PlaylistClient()
        let (pl, base) = try await client.fetch(catalogue: catalogue, station: settings.station, bitrate: settings.bitrate)
        guard let name = pl.names.first, let (prefix, _) = HLS.splitName(name) else { throw FetchError.unhealthy("Unreadable playlist") }
        self.base = base; self.segmentPrefix = prefix
        liveEdge = pl.lastSequence
        let dir = cacheRoot.appendingPathComponent(settings.station.serviceId, isDirectory: true)
        let store = SegmentStore(directory: dir, base: base, prefix: prefix)
        await store.clear()
        self.store = store
        var p = Playout(liveEdge: liveEdge, delaySeconds: settings.delaySeconds, maxMuteSeconds: settings.profile.detector.maxMuteSeconds)
        let first = p.next
        // Fetch from two minutes before the first listed segment up to the live edge, then analyse before starting.
        let from = first - 20
        analysedThrough = from - 1
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in from...liveEdge { g.addTask { _ = try await store.segment(i) } }
            try await g.waitForAll()
        }
        await analyse(upTo: liveEdge)
        for _ in 0..<6 { await tick(&p) }
        playout = p
        running = true
        state = .playing
        tasks.append(Task { await self.pollLoop() })
        tasks.append(Task { await self.emitLoop() })
        tasks.append(Task { await self.metadataLoop() })
        if settings.muteNews && settings.profile.idents.isEmpty { tasks.append(Task(priority: .utility) { await self.learnJingleFromRewind() }) }
        if #available(macOS 26, *), settings.station.kind == .music {
            let stt = NewsTranscriber()
            transcriber = stt
            speechState = "checking"
            tasks.append(Task(priority: .utility) {
                let ok = await stt.prepare(install: true)
                await self.setSpeechState(ok ? "ready" : "unavailable")
            })
        }
    }

    public func stop() {
        running = false
        tasks.forEach { $0.cancel() }; tasks = []
        state = .starting
    }

    // MARK: Loops

    private func pollLoop() async {
        let client = PlaylistClient()
        var failures = 0
        while !Task.isCancelled && running {
            try? await Task.sleep(for: .seconds(3))
            guard let store else { continue }
            do {
                let (pl, _) = try await client.fetch(catalogue: catalogue, station: settings.station, bitrate: settings.bitrate)
                failures = 0
                if case .failed = state { state = .playing }
                if pl.lastSequence > liveEdge {
                    let newEdge = pl.lastSequence
                    let old = liveEdge
                    liveEdge = newEdge
                    await withTaskGroup(of: Void.self) { g in
                        for i in (old + 1)...newEdge { g.addTask { _ = try? await store.segment(i) } }
                    }
                    await analyse(upTo: newEdge)
                    if let p = playout { await store.evict(below: p.next - 30, above: newEdge + 5) }
                }
            } catch {
                failures += 1
                if failures == 3 { notices.append("Station stream failed: \(error.localizedDescription)"); state = .failed("Station stream failed") }
                try? await Task.sleep(for: .seconds(min(30, Double(failures * 3))))
            }
        }
    }

    private func emitLoop() async {
        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(segmentDuration)
        while !Task.isCancelled && running {
            try? await clock.sleep(until: deadline)
            if clock.now > deadline + .seconds(20) {       // woke from sleep: restarting is cleaner than racing to catch up
                needsRestart = true; deadline = clock.now + .seconds(segmentDuration); continue
            }
            deadline += .seconds(segmentDuration)
            guard var p = playout else { continue }
            await tick(&p)
            playout = p
        }
    }

    private func tick(_ p: inout Playout) async {
        let idx = p.next
        if let store, !(await store.has(idx)) { _ = try? await store.segment(idx) }
        let have = await store?.has(idx) ?? false
        let det = detector
        let mute = settings.muteNews && !settings.profile.shadowMode
        let seg = p.tick(muteNews: mute) { !have || det.isNews(segmentStart: HLS.startTime(ofIndex: $0).timeIntervalSince1970) }
        if !p.log.isEmpty { notices.append(contentsOf: p.log); p = p.clearingLog() }
        if !have && seg.source == .silence { notices.append("Segment \(idx) missing; served as silence") }
        _ = seg
    }

    private func metadataLoop() async {
        let url = URL(string: "https://rms.api.bbc.co.uk/v2/services/\(settings.station.serviceId)/segments/latest?limit=3")!
        var backoff = 30.0
        while !Task.isCancelled && running {
            do {
                let (d, _) = try await URLSession.shared.data(from: url)
                if let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let arr = o["data"] as? [[String: Any]],
                   let cur = arr.first(where: { ($0["offset"] as? [String: Any])?["now_playing"] as? Bool == true }),
                   let t = cur["titles"] as? [String: Any], let artist = t["primary"] as? String {
                    let title = t["secondary"] as? String
                    let img = (cur["image_url"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "{recipe}", with: "480x480")) }
                    let np = NowPlaying(artist: artist, title: title, imageURL: img)
                    if tracks.last?.track != np { tracks.append((Date(), np)); if tracks.count > 50 { tracks.removeFirst() } }
                }
                backoff = 30
            } catch { backoff = min(backoff * 2, 300) }
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    // MARK: Analysis

    private func analyse(upTo end: Int) async {
        guard let store else { return }
        var i = analysedThrough + 1
        let clf = ClipClassifier()
        while i <= end {
            let chunkEnd = min(i + 9, end)
            var buffers: [AVAudioPCMBuffer] = [], indices: [Int] = []
            let ctx = lastAnalysisSegment.map { [$0] } ?? []
            for k in i...chunkEnd {
                guard let d = await store.cached(k), let info = TS.parse(d), !info.frames.isEmpty else { continue }
                remember(index: k, info: info)
                if let b = try? Decode.pcm(frames: info.frames) { buffers.append(b); indices.append(k) }
            }
            if let firstNew = indices.first {
                let scores = (try? clf.classify(ctx + buffers)) ?? []
                let ctxSeconds = ctx.first.map { Double($0.frameLength) / $0.format.sampleRate } ?? 0
                let clipStart = HLS.startTime(ofIndex: firstNew).timeIntervalSince1970 - ctxSeconds
                for s in scores.sorted(by: { $0.time < $1.time }) where s.time >= ctxSeconds - 0.001 {
                    detector.ingest(ScoreSample(time: clipStart + s.time, duration: s.duration, speech: s.speech, music: s.music))
                }
                lastAnalysisSegment = buffers.last
                let chunkStart = HLS.startTime(ofIndex: firstNew).timeIntervalSince1970
                let newMono = updateIdents(chunkStart: chunkStart, buffers: buffers)
                logBlocks()
                rejudgePending()
                await listenForNewsreader(chunkStart: chunkStart, newMono: newMono)
            }
            analysedThrough = chunkEnd
            i = chunkEnd + 1
        }
    }

    /// Extracts features over the new audio plus a little earlier context, stores them, and looks for known idents.
    @discardableResult
    private func updateIdents(chunkStart: Double, buffers: [AVAudioPCMBuffer]) -> [Float] {
        let ctx = lastMono
        var mono = ctx
        for b in buffers { mono += IdentFeatures.mono(b) }
        lastMono = Array(mono.suffix(48000 * 6))
        let t0 = chunkStart - Double(ctx.count) / 48000
        let frames = IdentFeatures.extract(mono)
        for (i, f) in frames.enumerated() {
            let t = t0 + Double(i) * IdentFeatures.frameSeconds
            if t >= chunkStart - 0.001 { featureRing.append((t, f)) }
        }
        if featureRing.count > 20_000 { featureRing.removeFirst(featureRing.count - 20_000) }
        for ref in settings.profile.idents {
            if let m = IdentMatcher.bestMatch(reference: ref.features, in: frames), m.score >= ref.threshold {
                detector.identMatch(at: t0 + Double(m.offset) * IdentFeatures.frameSeconds - IdentMatcher.leadSeconds, score: m.score)
            }
        }
        return Array(mono.dropFirst(ctx.count))
    }

    /// While a bulletin is being muted, transcribes its latest audio and looks for the newsreader's opening (when the
    /// theme is not known) and sign-off. The sign-off ends the block there, so the presenter's talk afterwards plays.
    private func listenForNewsreader(chunkStart: Double, newMono: [Float]) async {
        let rate = 48000.0
        monoTail += newMono
        if monoTail.count > Int(30 * rate) { monoTail.removeFirst(monoTail.count - Int(30 * rate)) }
        let chunkEnd = chunkStart + Double(newMono.count) / rate
        let tailStart = chunkEnd - Double(monoTail.count) / rate
        guard #available(macOS 26, *), let stt = transcriber as? NewsTranscriber, speechState == "ready", let p = playout else { return }
        let listener = HLS.startTime(ofIndex: p.next - 1 - Playout.headStart).timeIntervalSince1970
        guard let b = detector.blocks.last(where: { !$0.falseStart && !signedOff.contains($0.id) && ($0.isOpen || ($0.end ?? 0) > listener) }) else {
            blockAudioFor = nil; blockAudio = []; return
        }
        if blockAudioFor != b.id {
            blockAudioFor = b.id
            let from = max(tailStart, b.start - 20)
            blockAudio = Array(monoTail.dropFirst(Int((from - tailStart) * rate)))
            blockAudioStart = from
            transcribedThrough = from
        } else {
            blockAudio += newMono
        }
        if blockAudio.count > Int(480 * rate) { return }                 // longer than any bulletin: leave it to the music rule
        let end = blockAudioStart + Double(blockAudio.count) / rate
        guard end - transcribedThrough >= 5 else { return }
        let from = max(blockAudioStart, transcribedThrough - 20)          // overlap, so phrases split across calls are kept
        let samples = Array(blockAudio.dropFirst(Int((from - blockAudioStart) * rate)))
        transcribedThrough = end
        guard let phrases = try? await stt.transcribe(samples: samples, sampleRate: rate), !phrases.isEmpty else { return }
        if !listenedTo.contains(b.id) { listenedTo.insert(b.id); write(["event": "transcribing", "block": b.id.uuidString, "phrases": phrases.count]) }
        if !b.anchoredOnIdent, let o = NewsPhrases.opening(in: phrases), from + o < b.start + 90 {
            detector.anchorStart(at: from + o - 3, why: "newsreader's opening heard")
        }
        // Speech alone opened this block. Once the station's theme is known, a bulletin shows it (or the newsreader's
        // opening) within about 41 s of the talk starting; by 45 s without either, this is the presenter talking.
        // If the theme turns up later after all, it opens a new block.
        if let cur = detector.blocks.first(where: { $0.id == b.id }), cur.isOpen, !cur.anchoredOnIdent,
           !settings.profile.idents.isEmpty, end >= cur.start + 45 {
            detector.rejectOpenBlock(at: cur.start, why: "no news theme or newsreader heard: presenter talk")
            write(["event": "released", "block": b.id.uuidString])
        }
        if let e = NewsPhrases.signOff(in: phrases, after: b.start + 45 - from) {
            detector.endBlock(at: from + e + 0.3, why: "newsreader signed off")
            signedOff.insert(b.id)
            write(["event": "signOff", "block": b.id.uuidString, "at": from + e])
        }
        logBlocks()
        rejudgePending()
    }

    /// Segments already listed but not yet fetched follow the latest view of the timeline
    /// (for example when the news theme moves a block's start).
    private func rejudgePending() {
        guard var p = playout else { return }
        let det = detector, mute = settings.muteNews && !settings.profile.shadowMode
        let before = p.window
        p.refreshPending(from: lastServed + 1) { mute && det.isNews(segmentStart: HLS.startTime(ofIndex: $0).timeIntervalSince1970) }
        if p.window != before { silenceCache = silenceCache.filter { $0.key <= lastServed } }
        playout = p
    }

    private func setSpeechState(_ s: String) { speechState = s }

    private func remember(index: Int, info: TSSegmentInfo) {
        if let pts = info.firstPTS { ptsByIndex[index] = pts }
        let pat = info.patPacket.map { $0[3] & 0x0F } ?? 0, pmt = info.pmtPacket.map { $0[3] & 0x0F } ?? 0
        ccByIndex[index] = (pat, pmt)
        if prototype == nil, info.patPacket != nil, info.pmtPacket != nil { prototype = info }
        if silentFrame == nil, let f = info.frames.first, let raw = try? Silence.rawFrame() { silentFrame = Silence.adts(raw: raw, like: f) }
    }

    // MARK: Event log

    private var loggedState: [UUID: Bool] = [:]
    private func logBlocks() {
        for b in detector.blocks where loggedState[b.id] != b.isOpen {
            loggedState[b.id] = b.isOpen
            write(["event": b.isOpen ? "open" : "close", "block": blockJSON(b)])
            // A bulletin that ran its normal course (music returned, sensible length) teaches the jingle too.
            if !b.isOpen && !b.falseStart && !b.timedOut && !b.doubtful && !b.evidence.hasPrefix("marked") { learn(from: b) }
        }
    }
    private func blockJSON(_ b: NewsBlock) -> [String: Any] {
        ["id": b.id.uuidString, "start": b.start, "end": b.end as Any? ?? NSNull(), "evidence": b.evidence, "doubtful": b.doubtful,
         "timedOut": b.timedOut, "falseStart": b.falseStart, "station": settings.station.serviceId]
    }
    private func write(_ o: [String: Any]) {
        guard let url = eventLog else { return }
        var o = o; o["loggedAt"] = Date().timeIntervalSince1970
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); h.write(Data("\n".utf8)); try? h.close() }
    }

    // MARK: Controls

    public func setMuteNews(_ on: Bool) { settings.muteNews = on }

    /// Options that take effect at once, without a restart.
    public func setLiveOptions(muteNews: Bool, shadowMode: Bool) {
        settings.muteNews = muteNews; settings.profile.shadowMode = shadowMode
    }

    /// "Not news": unmute from the next segment the player fetches, then judge what follows again.
    public func notNews() {
        let first = lastServed + 1
        detector.rejectOpenBlock(at: HLS.startTime(ofIndex: first).timeIntervalSince1970)
        let det = detector
        playout?.refreshPending(from: first) { det.isNews(segmentStart: HLS.startTime(ofIndex: $0).timeIntervalSince1970) }
        silenceCache = silenceCache.filter { $0.key < first }
        if let b = detector.blocks.last(where: \.falseStart) { write(["event": "falseStart", "block": blockJSON(b)]) }
        logBlocks()
    }

    /// "That was news": the most recent speech block is marked as news.
    public func thatWasNews() {
        guard let p = playout else { return }
        let listener = HLS.startTime(ofIndex: p.next - 1 - Playout.headStart).timeIntervalSince1970
        guard let b = detector.markNewsHeard(listenerTime: listener) else { notices.append("No speech to mark as news"); return }
        write(["event": "marked", "listenerTime": listener, "block": blockJSON(b)])
        learn(from: b)
    }

    /// Saves the audio around a bulletin's start as a jingle candidate, and the bulletin's time and length.
    /// The news theme has been seen 11 to 41 s after the speech starts, so the window runs from 10 s before to 60 s after.
    private func learn(from b: NewsBlock) {
        if let e = b.end { settings.profile.learn(start: b.start, end: e) }
        let slice = featureRing.filter { $0.time >= b.start - 10 && $0.time < b.start + 60 }.map(\.frame)
        if slice.count > 1000 {
            settings.profile.candidates.append(slice)
            settings.profile.candidateSources.append(b.id.uuidString)
            while settings.profile.candidates.count > 8 { settings.profile.candidates.removeFirst(); settings.profile.candidateSources.removeFirst() }
            promoteIdent()
        }
        saveLearning()
        write(["event": "candidate", "block": b.id.uuidString, "candidates": settings.profile.candidates.count, "identLearned": !settings.profile.idents.isEmpty])
    }

    /// Runs promotion off the actor (it takes a few seconds), then adopts the result.
    private func promoteIdent() {
        let cands = settings.profile.candidates
        Task.detached(priority: .utility) { [weak self] in
            let ref = IdentMatcher.promote(candidates: cands)
            await self?.adoptIdent(ref, source: "recent bulletins", keepExisting: true)
        }
    }

    private func adoptIdent(_ ref: IdentReference?, source: String, keepExisting: Bool) {
        let had = !settings.profile.idents.isEmpty
        if let ref { settings.profile.idents = [ref] } else if !keepExisting { settings.profile.idents = [] }
        if !had, ref != nil {
            notices.append("Learned the news jingle for \(settings.station.name) from \(source)")
            write(["event": "identLearned", "source": source])
        }
        saveLearning()
    }

    // MARK: Learning the jingle from the BBC's rewind window

    public private(set) var learningJingle = false

    /// Looks at the 150 s after each of the last eight bulletin slots, from the BBC's six hour window,
    /// and learns the news theme if at least three share it. About 50 MB of downloads, once per station.
    private func learnJingleFromRewind() async {
        guard settings.station.kind == .music, settings.profile.idents.isEmpty, let base, let prefix = segmentPrefix else { return }
        learningJingle = true
        defer { learningJingle = false }
        let live = HLS.startTime(ofIndex: liveEdge).timeIntervalSince1970
        var slots: [Double] = []
        var hour = (live / 3600).rounded(.down) * 3600
        while slots.count < 8 && hour > live - 5.5 * 3600 {
            for m in settings.profile.detector.slotMinutes.sorted(by: >) {
                let t = hour + Double(m) * 60
                if t + 160 < live && t > live - 5.5 * 3600 && slots.count < 8 { slots.append(t) }
            }
            hour -= 3600
        }
        guard slots.count >= 3 else { return }
        let dir = cacheRoot.appendingPathComponent("rewind-\(settings.station.serviceId)", isDirectory: true)
        let store = SegmentStore(directory: dir, base: base, prefix: prefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        var windows: [[[Float]]] = []
        for t in slots {
            if Task.isCancelled || !running { return }
            let first = Int(floor(t / segmentDuration)) + 1, last = Int(floor((t + 150) / segmentDuration)) + 1
            var mono: [Float] = []
            for i in first...last {
                guard let d = try? await store.segment(i) else { mono += [Float](repeating: 0, count: 307_200); continue }
                let decoded: [Float]? = await Task.detached(priority: .utility) {
                    guard let info = TS.parse(d), let b = try? Decode.pcm(frames: info.frames) else { return nil }
                    return IdentFeatures.mono(b)
                }.value
                mono += decoded ?? [Float](repeating: 0, count: 307_200)
            }
            let skip = Int(max(0, t - HLS.startTime(ofIndex: first).timeIntervalSince1970) * 48000)
            let clip = Array(mono.dropFirst(skip))
            windows.append(await Task.detached(priority: .utility) { IdentFeatures.extract(clip) }.value)
        }
        let ref = await Task.detached(priority: .utility) { IdentMatcher.promote(candidates: windows) }.value
        adoptIdent(ref, source: "the last few hours", keepExisting: true)
        write(["event": "rewindLearning", "slots": slots.count, "learned": ref != nil])
    }

    /// Save only what was learned, on top of the file, so settings changed meanwhile in the app are kept.
    private func saveLearning() {
        var disk = StationProfile.load(settings.station)
        disk.candidates = settings.profile.candidates; disk.candidateSources = settings.profile.candidateSources
        disk.idents = settings.profile.idents
        disk.startMinuteHistogram = settings.profile.startMinuteHistogram; disk.bulletinSeconds = settings.profile.bulletinSeconds
        disk.detector.minBulletinSeconds = settings.profile.detector.minBulletinSeconds
        disk.detector.maxBulletinSeconds = settings.profile.detector.maxBulletinSeconds
        disk.save(settings.station)
    }

    public func profile() -> StationProfile { settings.profile }

    public func markWrong(id: UUID) {
        detector.markFalseStart(id: id)
        if let b = detector.blocks.first(where: { $0.id == id }) { write(["event": "wrong", "block": blockJSON(b)]) }
        // Withdraw the jingle candidate this block gave, if any.
        if let i = settings.profile.candidateSources.firstIndex(of: id.uuidString) {
            settings.profile.candidates.remove(at: i); settings.profile.candidateSources.remove(at: i)
            promoteIdent(); saveLearning()
        }
    }

    public func status() -> SessionStatus {
        var s = SessionStatus()
        s.state = state; s.delaySeconds = settings.delaySeconds; s.muteNews = settings.muteNews; s.needsRestart = needsRestart; s.learningJingle = learningJingle; s.speechModel = speechState
        if let p = playout {
            let playing = p.next - 1 - Playout.headStart
            s.muted = p.window.first(where: { $0.index == playing })?.source == .silence
            s.delaySeconds = Double(liveEdge - playing) * segmentDuration
            let heard = HLS.startTime(ofIndex: playing).timeIntervalSince1970
            if s.muted {
                if let b = detector.blocks.last(where: { !$0.falseStart && $0.start <= heard && ($0.end ?? .infinity) > heard }) { s.muteElapsed = heard - b.start }
            } else if settings.muteNews && !settings.profile.shadowMode,
                      let b = detector.blocks.last(where: { !$0.falseStart && $0.start > heard }) {
                // Mutes start on a segment boundary, so round the countdown to the segment the block starts in.
                let segStart = floor(b.start / segmentDuration) * segmentDuration
                s.muteStartsIn = max(0, segStart - heard)
            }
        }
        let at = Date().addingTimeInterval(-settings.delaySeconds)
        s.nowPlaying = tracks.last(where: { $0.observedAt <= at })?.track
        s.recentBlocks = Array(detector.blocks.filter { !$0.isOpen || $0.start > 0 }.suffix(8).reversed())
        s.notices = notices
        return s
    }

    // MARK: Serving

    public func respond(to relative: String) async -> HTTPResponse {
        if relative == "live.m3u8" {
            guard let p = playout else { return .notFound }
            let text = HLS.write(mediaSequence: p.mediaSequence, segments: p.window.map(\.index)) { "seg/\($0).ts" }
            return HTTPResponse(contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8), noCache: true)
        }
        if relative == "diagnostics" {
            var out = "event log: \(eventLog?.path ?? "none")\n"
            if let u = eventLog, let t = try? String(contentsOf: u, encoding: .utf8) { out += t } else { out += "(event log missing or unreadable)\n" }
            out += "\nnotices: \(notices)\nblocks in memory: \(detector.blocks.count)\n"
            return HTTPResponse(contentType: "text/plain", body: Data(out.utf8), noCache: true)
        }
        if relative == "health" {
            let st = status()
            let o: [String: Any] = ["delay": st.delaySeconds, "muted": st.muted, "muteNews": st.muteNews, "playhead": (playout?.next ?? 0) - 1, "lastServed": lastServed, "liveEdge": liveEdge]
            return HTTPResponse(contentType: "application/json", body: (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
        }
        if relative.hasPrefix("seg/"), relative.hasSuffix(".ts"), let i = Int(relative.dropFirst(4).dropLast(3)) {
            lastServed = max(lastServed, i)
            let listed = playout?.window.first(where: { $0.index == i })
            if listed?.source == .silence, let d = await silentSegment(i) {
                return HTTPResponse(contentType: "video/mp2t", body: d)
            }
            if let d = await store?.cached(i) { return HTTPResponse(contentType: "video/mp2t", body: d) }
            if let d = await silentSegment(i) { return HTTPResponse(contentType: "video/mp2t", body: d) }
        }
        return .notFound
    }

    /// Silence that carries the timestamps of the segment it replaces.
    private func silentSegment(_ i: Int) async -> Data? {
        if let d = silenceCache[i] { return d }
        guard let proto = prototype, let frame = silentFrame else { return nil }
        let step = Int64(segmentDuration * 90_000)
        let mask: Int64 = 0x1_FFFF_FFFF
        let pts: Int64
        if let p = ptsByIndex[i] { pts = p }
        else if let p = ptsByIndex[i - 1] { pts = (p + step) & mask }
        else if let p = ptsByIndex[i + 1] { pts = (p - step) & mask }
        else if let any = ptsByIndex.first { pts = (any.value + Int64(i - any.key) * step) & mask }
        else { return nil }
        let cc = ccByIndex[i] ?? ccByIndex[i - 1].map { (($0.0 + 1) & 0xF, ($0.1 + 1) & 0xF) } ?? (0, 0)
        let d = TS.build(frames: Array(repeating: frame, count: 300), startPTS: pts, prototype: proto, patCC: cc.0, pmtCC: cc.1)
        silenceCache[i] = d
        if silenceCache.count > 200 { silenceCache.removeValue(forKey: silenceCache.keys.min()!) }
        return d
    }
}
