import Foundation
import InterLudeCore
import InterLudeCast

/// What the server remembers between runs, in `settings.json` in the data directory. Per-station options live in
/// the station profiles, as on the Mac.
struct ServerSettings: Codable {
    /// The secret part of the app's address. Reset link replaces it.
    var token = RemoteRoutes.newToken()
    var station = "bbc_6music"
    var mode = "live"
    var bitrate = 320_000
    var ambience = "silence"
    /// "browser", or "cast:" and a speaker's ID.
    var speaker = "browser"
    /// The volume for Cast speakers. Each browser keeps its own.
    var volume = 0.7

    init() {}

    /// Tolerant, so a hand-edited or older file keeps whatever it has right.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let t = try? c.decode(String.self, forKey: .token), t.count >= 16 { token = t }
        if let s = try? c.decode(String.self, forKey: .station) { station = s }
        if let m = try? c.decode(String.self, forKey: .mode), m == "live" || m == "earlier" { mode = m }
        if let b = try? c.decode(Int.self, forKey: .bitrate), b == 128_000 || b == 320_000 { bitrate = b }
        if let a = try? c.decode(String.self, forKey: .ambience), Ambience.choices.contains(where: { $0.id == a }) { ambience = a }
        if let s = try? c.decode(String.self, forKey: .speaker), s == "browser" || s.hasPrefix("cast:") { speaker = s }
        if let v = try? c.decode(Double.self, forKey: .volume), (0...1).contains(v) { volume = v }
    }

    static func load(_ url: URL) -> ServerSettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ServerSettings.self, from: $0) } ?? ServerSettings()
    }

    func save(_ url: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: url, options: .atomic)
    }
}

/// The server's counterpart of the Mac app's AppModel: owns the one session every browser shares, the station and
/// Earlier choices, and the settings, and describes them all as the remote's state.
actor Controller {
    private let catalogue: Catalogue
    private var profiles: [String: StationProfile] = [:]
    private var settings: ServerSettings
    private let settingsURL: URL
    /// Whether a sound classifier is installed, without which no bulletin can be recognised.
    private let detects: Bool
    /// Where the sounds for muted bulletins are, named by their IDs in `Ambience.choices`.
    private let ambienceDirectory: URL
    /// Keeps the live session running whether or not anyone listens, for a shadow week beside the Mac.
    private let keepRunning: Bool
    /// How a Cast device reaches the stream: this machine's LAN address and port.
    private let castBase: String?
    private var speakers: [CastSpeaker] = []
    private var searched = false
    private var cast: CastClient?
    private var castEvents: Task<Void, Never>?

    private var session: PlayerSession?
    private var starting: Task<PlayerSession, Error>?
    /// Counts sessions started and stopped, so a slow start that has been overtaken is thrown away.
    private var generation = 0
    private var streamID = 0
    private var status = SessionStatus()
    private var errorText: String?
    private var lastRequest = Date()
    private var watcher: Task<Void, Never>?

    // Earlier programmes, as on the Mac.
    private var programmes: [Programme] = []
    private var scheduleDay = 0
    private var scheduleLoading = false
    private var scheduleProblem: String?
    private var scheduleFor: (station: String, day: Int, at: Date)?
    private var replaying: Programme?

    /// A session stops after this long with no requests for its stream.
    static let idleLimit: TimeInterval = 600
    static let newsNote = "This server has no speech model, so it can't recognise bulletins and news plays. These settings are kept for when it does."

    init(catalogue: Catalogue, settingsURL: URL, detects: Bool, ambienceDirectory: URL, keepRunning: Bool = false, castBase: String?) {
        self.catalogue = catalogue; self.settingsURL = settingsURL; self.detects = detects; self.ambienceDirectory = ambienceDirectory
        self.keepRunning = keepRunning; self.castBase = castBase
        var s = ServerSettings.load(settingsURL)
        if catalogue.station(s.station) == nil { s.station = catalogue.stations.first?.serviceId ?? s.station }
        settings = s
        s.save(settingsURL)
        for st in catalogue.stations { profiles[st.serviceId] = StationProfile.load(st) }
        if s.mode == "earlier" { Task { await self.loadSchedule() } }
        if keepRunning { Task { await self.keepAlive() } }
        Task { await self.discover() }
    }

    // MARK: Speakers

    /// Looks for Cast speakers now and every two minutes.
    private func discover() async {
        while !Task.isCancelled {
            let found = await Task.detached { MDNS.browseCast(timeout: 3) }.value
            if found != speakers || !searched { log("Cast speakers: \(found.isEmpty ? "none found" : found.map(\.name).joined(separator: ", "))") }
            speakers = found; searched = true
            try? await Task.sleep(for: .seconds(120))
        }
    }

    private var chosenSpeaker: CastSpeaker? {
        guard settings.speaker.hasPrefix("cast:") else { return nil }
        let id = String(settings.speaker.dropFirst(5))
        return speakers.first { $0.id == id }
    }

    /// Plays the session's stream on the chosen speaker.
    private func startCast() async {
        guard let sp = chosenSpeaker, session != nil else { return }
        guard let base = castBase, let url = URL(string: "\(base)/stream/live.m3u8") else {
            errorText = "Can't cast: this server's network address isn't known. Start it with --cast-host."; return
        }
        await stopCast()
        let c = CastClient(speaker: sp)
        cast = c
        do {
            try await c.connect()
            try await c.load(url: url, title: castTitle)
            await c.setVolume(settings.volume)
            log("casting to \(sp.name)")
        } catch {
            guard cast === c else { return }
            castProblem("Couldn't play on \(sp.name): \(error.localizedDescription)")
            return
        }
        castEvents = Task { [weak self] in
            for await e in c.events {
                guard let self else { return }
                switch e {
                case .lost: await self.castProblem("Cast connection lost: \(sp.name) stopped responding.")
                case .takenOver: await self.castProblem("Another app took over \(sp.name).")
                case .loadFailed(let m): await self.castProblem("\(sp.name) refused the stream: \(m)")
                }
            }
        }
    }

    private func stopCast() async {
        castEvents?.cancel(); castEvents = nil
        let c = cast; cast = nil
        await c?.stop()
    }

    private func castProblem(_ message: String) {
        guard cast != nil else { return }
        errorText = message
        log(message)
        Task { await self.stopCast() }
    }

    private var castTitle: String {
        if isEarlier, let p = replaying { return "\(p.title) · \(selectedStation?.name ?? "")" }
        return selectedStation?.name ?? "InterLude"
    }

    /// With keepRunning, starts the live session and starts it again within a minute whenever it stops.
    private func keepAlive() async {
        while !Task.isCancelled {
            if session == nil && starting == nil && !isEarlier { start() }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    var token: String { settings.token }
    private var selectedStation: Station? { catalogue.station(settings.station) }
    private var isPlaying: Bool { session != nil }
    private var isStarting: Bool { starting != nil }
    private var isEarlier: Bool { settings.mode == "earlier" }
    private func profile(_ id: String) -> StationProfile { profiles[id] ?? StationProfile() }

    private func updateProfile(_ id: String, _ change: (inout StationProfile) -> Void) {
        var p = profile(id); change(&p); profiles[id] = p
        if let st = catalogue.station(id) { p.save(st) }
    }

    private func saveSettings() { settings.save(settingsURL) }

    static func canPlay(_ p: Programme) -> Bool { Schedule.isPlayable(p) || OnDemand.isAvailable(p) }

    // MARK: Stream

    /// Answers the player's requests under /stream/: only the playlist and its segments, never the session's
    /// diagnostics, since these addresses carry no token. Starts the session if it isn't running.
    func stream(_ relative: String) async -> HTTPResponse {
        guard relative == "live.m3u8" || (relative.hasPrefix("seg/") && relative.hasSuffix(".ts")) else { return .notFound }
        lastRequest = Date()
        if let session { return await session.respond(to: relative) }
        // A browser asks for the stream as it sends Play, so give that command a moment to choose what starts.
        for _ in 0..<30 where session == nil && starting == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if let session { return await session.respond(to: relative) }
        guard let t = starting ?? start() else {
            return HTTPResponse(status: 503, contentType: "text/plain", body: Data("Nothing to play.\n".utf8), noCache: true)
        }
        do { return try await t.value.respond(to: relative) }
        catch { return HTTPResponse(status: 503, contentType: "text/plain", body: Data("\(friendly(error))\n".utf8), noCache: true) }
    }

    // MARK: Playback

    /// Starts a session for the current choice: the station live, or in Earlier the programme picked (the first
    /// playable one if none was). Returns the start in progress, or nil if there is nothing to play.
    @discardableResult
    private func start() -> Task<PlayerSession, Error>? {
        if let starting { return starting }
        guard session == nil, let station = selectedStation else { return nil }
        if isEarlier && replaying == nil {
            guard let p = programmes.first(where: Self.canPlay) else { loadSchedule(); return nil }
            replaying = p
        }
        errorText = nil
        var s = SessionSettings(station: station, profile: profile(station.serviceId))
        s.bitrate = settings.bitrate
        s.ambience = ambienceURL
        if !detects { s.muteNews = false }
        if isEarlier, let p = replaying { s.replay = p; s.onDemand = !Schedule.isPlayable(p) }
        generation += 1
        let gen = generation, catalogue = catalogue, sessionSettings = s
        let t = Task { () throws -> PlayerSession in
            let ps = PlayerSession(catalogue: catalogue, settings: sessionSettings, token: "stream", cacheRoot: try AppPaths.cacheDirectory(),
                                   eventLog: try AppPaths.supportDirectory().appendingPathComponent("events.jsonl"))
            try await ps.start()
            return ps
        }
        starting = t
        lastRequest = Date()
        log(isEarlier ? "starting \(replaying?.title ?? "") on \(station.name)" : "starting \(station.name), \(Int(s.delaySeconds)) s behind live")
        Task { await self.started(t, generation: gen) }
        return t
    }

    private func started(_ t: Task<PlayerSession, Error>, generation gen: Int) async {
        do {
            let s = try await t.value
            guard gen == generation else { await s.stop(); return }
            session = s; starting = nil; streamID = gen
            watch(s)
            await startCast()
        } catch {
            guard gen == generation else { return }
            starting = nil
            errorText = friendly(error)
            log("couldn't start: \(errorText ?? "")")
        }
    }

    private func stop(_ reason: String? = nil) async {
        await stopCast()
        generation += 1
        starting?.cancel()          // a session still starting stops its analysis rather than finishing unheard
        starting = nil
        watcher?.cancel(); watcher = nil
        let s = session
        session = nil
        status = SessionStatus()
        if let s { await s.stop(); log("stopped\(reason.map { ": \($0)" } ?? "")") }
    }

    private func restart() async {
        await stop()
        start()
    }

    /// Follows the session once a second, as the Mac's status timer does, and stops it when nobody is listening.
    private func watch(_ s: PlayerSession) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.tick(s) == false { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One look at the session. False when the watch should end.
    private func tick(_ s: PlayerSession) async -> Bool {
        guard session === s else { return false }
        let st = await s.status()
        if st.recentBlocks.count != status.recentBlocks.count || st.learningJingle != status.learningJingle, let station = selectedStation {
            profiles[station.serviceId] = StationProfile.load(station)
        }
        status = st
        if st.finished { await stop("\(st.replay?.programme.title ?? "the programme") finished"); return false }
        if st.needsRestart { log("playback was interrupted, starting again"); await restart(); return false }
        if case .failed(let m) = st.state { errorText = m } else if errorText != nil { errorText = nil }
        if !keepRunning && Date().timeIntervalSince(lastRequest) > Self.idleLimit {
            await stop("no requests for \(Int(Self.idleLimit / 60)) minutes"); return false
        }
        return true
    }

    private func friendly(_ e: Error) -> String {
        if case FetchError.unhealthy(let m) = e { return m }
        return "Could not start \(selectedStation?.name ?? "the station"): \(e.localizedDescription)"
    }

    // MARK: Earlier programmes

    /// Reads the station's schedule for the chosen day, kept for five minutes per station and day.
    private func loadSchedule(force: Bool = false) {
        let id = settings.station, day = scheduleDay
        if !force, let f = scheduleFor, f.station == id, f.day == day, Date().timeIntervalSince(f.at) < 300, !programmes.isEmpty { return }
        scheduleLoading = true; scheduleProblem = nil
        Task {
            do {
                let list = try await OnDemand.day(serviceId: id, daysAgo: day)
                self.scheduleLoaded(list, station: id, day: day)
            } catch {
                self.scheduleFailed("Couldn't get the schedule: \(error.localizedDescription)", station: id, day: day)
            }
        }
    }

    private func scheduleLoaded(_ list: [Programme], station: String, day: Int) {
        guard station == settings.station, day == scheduleDay else { return }
        programmes = list; scheduleFor = (station, day, Date()); scheduleLoading = false
    }

    private func scheduleFailed(_ message: String, station: String, day: Int) {
        guard station == settings.station, day == scheduleDay else { return }
        scheduleLoading = false; scheduleProblem = message
    }

    // MARK: Commands

    func perform(_ c: RemoteCommand) async {
        let active = isPlaying || isStarting
        switch c {
        case .toggle: if active { await stop() } else { start() }
        case .play: if !active { start() }
        case .station(let id):
            guard catalogue.station(id) != nil else { return }
            if isEarlier {
                guard id != settings.station else { return }
                settings.station = id; saveSettings()
                replaying = nil; programmes = []
                await stop(); loadSchedule()
            } else {
                if id == settings.station && active { return }
                settings.station = id; saveSettings()
                await stop(); start()
            }
        case .speaker(let id):
            guard id == "browser" || (id.hasPrefix("cast:") && speakers.contains { "cast:" + $0.id == id }), id != settings.speaker else { return }
            settings.speaker = id; saveSettings()
            await stopCast()
            if session != nil { await startCast() }
        case .volume(let v):
            settings.volume = v; saveSettings()
            await cast?.setVolume(v)
        case .notNews: await session?.notNews()
        case .newsGotThrough:
            await session?.newsGotThrough()
            if let st = selectedStation { profiles[st.serviceId] = StationProfile.load(st) }
        case .earlier(let on):
            let mode = on ? "earlier" : "live"
            guard mode != settings.mode else { return }
            settings.mode = mode; saveSettings()
            await stop()
            if on { loadSchedule() }
        case .day(let d):
            guard isEarlier, d != scheduleDay else { return }
            scheduleDay = d; programmes = []
            loadSchedule()
        case .reloadSchedule: if isEarlier { loadSchedule(force: true) }
        case .programme(let id):
            guard isEarlier, let p = programmes.first(where: { $0.id == id }), Self.canPlay(p) else { return }
            replaying = p
            await stop(); start()
        case .setting(let s): await apply(s)
        case .resetLink:
            settings.token = RemoteRoutes.newToken(); saveSettings()
            log("link reset; the app is now at \(RemoteRoutes.pagePath(token: settings.token, prefix: RemoteRoutes.appPrefix))")
        }
    }

    private func apply(_ s: RemoteSetting) async {
        let id = settings.station
        let active = isPlaying || isStarting
        switch s {
        case .delay(let d):
            updateProfile(id) { $0.delaySeconds = d }
            if active && !isEarlier { await restart() }
        case .muteNews(let on): updateProfile(id) { $0.muteNews = on }; await applyLiveOptions()
        case .jingleOnly(let on): updateProfile(id) { $0.detector.identOnly = on }
        case .shadowMode(let on): updateProfile(id) { $0.shadowMode = on }; await applyLiveOptions()
        case .forgetJingle: updateProfile(id) { $0.idents = []; $0.candidates = []; $0.candidateSources = [] }
        case .bitrate(let b):
            guard b != settings.bitrate else { return }
            settings.bitrate = b; saveSettings()
            if active { await restart() }
        case .ambience(let a):
            settings.ambience = a; saveSettings()
            await session?.setAmbience(ambienceURL)
        }
    }

    /// The chosen sound during muted bulletins, or nil for silence or a missing file.
    private var ambienceURL: URL? {
        guard settings.ambience != "silence" else { return nil }
        let u = ambienceDirectory.appendingPathComponent("\(settings.ambience).m4a")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Passes the station's mute options to a running session, as the Mac does.
    private func applyLiveOptions() async {
        guard detects, let st = selectedStation else { return }
        let p = profile(st.serviceId)
        await session?.setLiveOptions(muteNews: p.muteNews, shadowMode: p.shadowMode)
    }

    // MARK: State

    func state() -> RemoteState {
        var s = RemoteState()
        let station = selectedStation
        let playing = isPlaying, startingNow = isStarting, replay = isEarlier && (playing || startingNow)
        s.state = startingNow ? "starting" : playing ? (status.muted ? "muted" : (replay ? "earlier" : "live")) : (errorText != nil ? "error" : "off")
        s.stationName = playing || startingNow ? (station?.name ?? "") : (errorText != nil ? "Stopped" : "Not playing")
        s.headline = headline(station)
        s.subheadline = subheadline(station)
        if isEarlier && !playing && !startingNow, let p = replaying, Self.canPlay(p) {
            s.subheadline = "Play starts \(p.title) from \(p.start.formatted(date: .omitted, time: .shortened))"
        }
        s.artwork = (playing ? status.nowPlaying?.imageURL : (isEarlier ? replaying?.imageURL : nil))?.absoluteString
        s.error = errorText
        s.playing = playing || startingNow
        s.muted = playing && status.muted
        s.muteElapsed = status.muteElapsed
        s.muteStartsIn = status.muteStartsIn
        s.justSkipped = status.replay?.justSkipped
        s.canCorrect = detects && playing && station?.kind != .speech
        if playing {
            s.footer = replay ? status.replay.map { "Started at \($0.programme.start.formatted(date: .omitted, time: .shortened)) · \(Self.duration(status.delaySeconds)) behind live" }
                              : "About \(Int((status.delaySeconds / 5).rounded()) * 5) seconds behind live"
        }
        s.station = settings.station
        s.speaker = settings.speaker
        s.volume = settings.volume
        let favourites = catalogue.stations.filter { profile($0.serviceId).favourite }
        s.stations = (favourites + catalogue.stations.filter { !profile($0.serviceId).favourite }).map {
            .init(id: $0.serviceId, name: $0.name, short: $0.short, colour: $0.colour, group: $0.group, favourite: profile($0.serviceId).favourite)
        }
        let single = speakers.filter { !$0.isGroup }, groups = speakers.filter(\.isGroup)
        s.speakers = [.init(id: "browser", name: "This browser", detail: nil, kind: "browser")]
            + single.map { .init(id: "cast:" + $0.id, name: $0.name, detail: $0.model.isEmpty ? nil : $0.model, kind: "speaker") }
            + groups.map { .init(id: "cast:" + $0.id, name: $0.name, detail: "Speaker group", kind: "group") }
        if settings.speaker.hasPrefix("cast:"), chosenSpeaker == nil {
            // A speaker chosen before but not seen since: keep showing it, so the choice isn't silently lost.
            s.speakers.append(.init(id: settings.speaker, name: "Speaker not found", detail: nil, kind: "speaker"))
        }
        if !searched { s.speakerNote = "Looking for speakers…" }
        else if speakers.isEmpty {
            s.speakerNote = "No Chromecast speakers found. The server needs to see multicast DNS from the speakers' network."
        }
        s.mode = settings.mode
        if isEarlier { s.earlier = earlier(station) }
        if replay, let r = status.replay { s.replay = replayItem(r) }
        s.stream = "/stream/live.m3u8"
        s.streamID = playing ? streamID : nil
        s.settings = settingsItem(station)
        return s
    }

    private func headline(_ station: Station?) -> String {
        if isStarting, isEarlier, let p = replaying { return p.title }
        guard isPlaying else { return station?.name ?? "InterLude" }
        if status.muted { return "News muted" }
        return status.nowPlaying?.title ?? status.nowPlaying?.artist ?? station?.name ?? "Playing"
    }

    private func subheadline(_ station: Station?) -> String {
        if isStarting, isEarlier, let p = replaying { return "Starting from \(p.start.formatted(date: .omitted, time: .shortened))…" }
        if isStarting { return "Starting about a minute behind live…" }
        guard isPlaying else { return isEarlier ? "Pick a programme below" : "Ready to play" }
        if status.muted { return "Sound returns when the music does" }
        if let np = status.nowPlaying, np.title != nil { return np.artist }
        return station?.name ?? ""
    }

    private func earlier(_ station: Station?) -> RemoteState.EarlierItem {
        var e = RemoteState.EarlierItem()
        e.day = scheduleDay
        e.dayTitle = switch scheduleDay {
        case 0: "Today"
        case 1: "Yesterday"
        default: (Calendar.current.date(byAdding: .day, value: -scheduleDay, to: Date()) ?? Date()).formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
        e.loading = scheduleLoading && programmes.isEmpty
        if programmes.isEmpty { e.problem = scheduleProblem }
        let now = Date(), active = isPlaying || isStarting
        e.programmes = programmes.map { p in
            let playable = Self.canPlay(p), onNow = p.end > now, chosen = replaying?.id == p.id
            let length = Self.duration(p.end.timeIntervalSince(p.start))
            return .init(id: p.id, title: p.title, detail: playable ? (p.subtitle ?? length) : (onNow ? "On now" : "Not available"),
                         time: p.start.formatted(date: .omitted, time: .shortened), image: p.imageURL?.absoluteString,
                         playable: playable, onNow: onNow, chosen: chosen, playing: chosen && active)
        }
        return e
    }

    private func replayItem(_ r: ReplayStatus) -> RemoteState.ReplayItem {
        let p = r.programme
        let total = max(1, p.end.timeIntervalSince(p.start))
        func x(_ d: Date) -> Double { min(1, max(0, d.timeIntervalSince(p.start) / total)) }
        let skipped = r.skipCount > 0 ? "\(r.skipCount) bulletin\(r.skipCount == 1 ? "" : "s") skipped · \(Self.clock(r.skippedSeconds))" : nil
        return .init(heard: x(r.heard), analysed: x(r.analysedThrough), news: r.news.map { [x($0.lowerBound), x($0.upperBound)] },
                     position: "\(Self.clock(r.heard.timeIntervalSince(p.start))) of \(Self.duration(total))", skipped: skipped)
    }

    private func settingsItem(_ station: Station?) -> RemoteState.SettingsItem {
        let p = profile(settings.station)
        let jingle: String
        if !p.idents.isEmpty { jingle = "Learned" }
        else {
            switch p.candidates.count {
            case 0: jingle = "Not learned yet"
            case 1, 2: jingle = "Learning: \(p.candidates.count) bulletin\(p.candidates.count == 1 ? "" : "s") heard"
            default: jingle = "No shared jingle yet (\(p.candidates.count) bulletins)"
            }
        }
        return .init(stationName: station?.name ?? settings.station, delay: p.delaySeconds, muteNews: p.muteNews,
                     jingleOnly: p.detector.identOnly, shadowMode: p.shadowMode, jingle: jingle,
                     canForgetJingle: !p.idents.isEmpty || !p.candidates.isEmpty, newsNote: detects ? nil : Self.newsNote,
                     bitrate: settings.bitrate / 1000, ambience: settings.ambience,
                     ambienceChoices: Ambience.choices.map { [$0.id, $0.name] },
                     link: RemoteRoutes.pagePath(token: settings.token, prefix: RemoteRoutes.appPrefix))
    }

    /// The state as server-sent events: sent when it changes, checked every second, with a comment every 15 s so
    /// proxies keep the connection open.
    nonisolated func events() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                var last = Data(), quiet = 0
                // Sorted, so the same state always encodes the same and only changes are sent.
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                while !Task.isCancelled {
                    let json = (try? encoder.encode(await self.state())) ?? Data("{}".utf8)
                    if json != last {
                        continuation.yield("data: \(String(decoding: json, as: UTF8.self))\n\n")
                        last = json; quiet = 0
                    } else if quiet >= 15 {
                        continuation.yield(": ping\n\n"); quiet = 0
                    } else { quiet += 1 }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
