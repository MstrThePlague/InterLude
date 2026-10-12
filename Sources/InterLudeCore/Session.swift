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
    public var recentBlocks: [NewsBlock] = []
    public var notices: [String] = []
    /// The playout clock fell badly behind (for example after the Mac slept). The caller should start a new session.
    public var needsRestart = false
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
        self.base = base
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
                updateIdents(chunkStart: HLS.startTime(ofIndex: firstNew).timeIntervalSince1970, buffers: buffers)
                logBlocks()
            }
            analysedThrough = chunkEnd
            i = chunkEnd + 1
        }
    }

    /// Extracts features over the new audio plus a little earlier context, stores them, and looks for known idents.
    private func updateIdents(chunkStart: Double, buffers: [AVAudioPCMBuffer]) {
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
                detector.identMatch(at: t0 + Double(m.offset) * IdentFeatures.frameSeconds, score: m.score)
            }
        }
    }

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
        // Save the audio from just before the bulletin starts (to catch the ident) as a candidate; three that agree become the reference.
        let slice = featureRing.filter { $0.time >= b.start - 4 && $0.time < b.start + 6 }.map(\.frame)
        if slice.count > 100 {
            settings.profile.candidates.append(slice)
            if settings.profile.candidates.count > 8 { settings.profile.candidates.removeFirst() }
            if let ref = IdentMatcher.promote(candidates: settings.profile.candidates, threshold: 0.8) {
                settings.profile.idents = [ref]
                notices.append("Learned a news ident for \(settings.station.name)")
            }
        }
        if let e = b.end { settings.profile.learn(start: b.start, end: e) }
        settings.profile.save(settings.station)
    }

    public func profile() -> StationProfile { settings.profile }

    public func markWrong(id: UUID) {
        detector.markFalseStart(id: id)
        if let b = detector.blocks.first(where: { $0.id == id }) { write(["event": "wrong", "block": blockJSON(b)]) }
    }

    public func status() -> SessionStatus {
        var s = SessionStatus()
        s.state = state; s.delaySeconds = settings.delaySeconds; s.muteNews = settings.muteNews; s.needsRestart = needsRestart
        if let p = playout {
            let playing = p.next - 1 - Playout.headStart
            s.muted = p.window.first(where: { $0.index == playing })?.source == .silence
            s.delaySeconds = Double(liveEdge - playing) * segmentDuration
            if s.muted {
                let heard = HLS.startTime(ofIndex: playing).timeIntervalSince1970
                if let b = detector.blocks.last(where: { !$0.falseStart && $0.start <= heard && ($0.end ?? .infinity) > heard }) { s.muteElapsed = heard - b.start }
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
