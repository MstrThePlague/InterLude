//  Controller.swift
//  interlude-server
//
//  The server's counterpart of the Mac app's model: one session every browser shares, the speakers, the Earlier
//  list and the settings, all described to the web app as `RemoteState`.

import Foundation
import InterLudeCore
import InterLudeCast

/// What the server remembers between runs, in `settings.json` in the data directory. Per-station options live in
/// the station profiles, as on the Mac.
struct ServerSettings: Codable {
    /// The secret part of the app's address. Reset link replaces it.
    var token = RemoteRoutes.newToken()
    var station = "bbc_6music"
    /// "live" or "earlier".
    var mode = "live"
    /// [bit/s]
    var bitrate = 320_000
    /// The sound during bulletins, by its ID in `Ambience.choices`.
    var ambience = "silence"
    /// "browser", or "cast:" or "sonos:" and a speaker's ID.
    var speaker = "browser"
    /// The volume for speakers, from 0 to 1. Each browser keeps its own.
    var volume = 0.7

    init() {}

    /// Tolerant, so a hand-edited or older file keeps whatever it has right.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .token), value.count >= 16 { token = value }
        if let value = try? container.decode(String.self, forKey: .station) { station = value }
        if let value = try? container.decode(String.self, forKey: .mode), value == "live" || value == "earlier" { mode = value }
        if let value = try? container.decode(Int.self, forKey: .bitrate), value == 128_000 || value == 320_000 { bitrate = value }
        if let value = try? container.decode(String.self, forKey: .ambience), Ambience.choices.contains(where: { $0.id == value }) { ambience = value }
        if let value = try? container.decode(String.self, forKey: .speaker),
           value == "browser" || value.hasPrefix("cast:") || value.hasPrefix("sonos:") { speaker = value }
        if let value = try? container.decode(Double.self, forKey: .volume), (0...1).contains(value) { volume = value }
    }

    /// The saved settings, or defaults if there are none or they can't be read.
    static func load(_ url: URL) -> ServerSettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ServerSettings.self, from: $0) } ?? ServerSettings()
    }

    func save(_ url: URL) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The server's counterpart of the Mac app's AppModel: owns the one session every browser shares, the station and
/// Earlier choices, and the settings, and describes them all as the remote's state.
actor Controller {
    /// Replaced while running when the station list's file changes; see `use(_:)`.
    private var catalogue: Catalogue
    /// The web app's files' version, which open pages compare with their own.
    private var pageVersion: @Sendable () -> String? = { nil }
    private var profiles: [String: StationProfile] = [:]
    private var settings: ServerSettings
    private let settingsURL: URL
    /// Whether a sound classifier is installed, without which no bulletin can be recognised.
    private let detects: Bool
    /// Where the sounds for muted bulletins are, named by their IDs in `Ambience.choices`.
    private let ambienceDirectory: URL
    /// How a speaker reaches the stream: this machine's LAN address and port.
    private let castBase: String?
    /// Sonos speakers to ask about the household besides those multicast DNS finds, for a speaker on another VLAN.
    private let sonosHosts: [String]
    private var speakers: [CastSpeaker] = []
    private var sonosGroups: [SonosGroup] = []
    /// Sonos speakers' addresses as multicast DNS last found them.
    private var sonosFound: [String] = []
    /// Counts questions to Sonos, so an answer a newer question overtook is ignored.
    private var sonosAsks = 0
    /// Whether the first search has finished.
    private var searched = false
    private var cast: (any CastController)?
    private var castEvents: Task<Void, Never>?

    private var session: PlayerSession?
    private var starting: Task<PlayerSession, Error>?
    /// Counts sessions started and stopped, so a slow start that has been overtaken is thrown away.
    private var generation = 0
    private var streamID = 0
    private var status = SessionStatus()
    private var errorText: String?
    /// When a player last asked for the stream, for stopping when nobody listens.
    private var lastRequest = Date()
    private var watcher: Task<Void, Never>?

    // Earlier programmes, as on the Mac.
    private var programmes: [Programme] = []
    private var scheduleDay = 0
    private var scheduleLoading = false
    private var scheduleProblem: String?
    private var scheduleFor: (station: String, day: Int, at: Date)?
    /// The programme last picked in Earlier, which Play starts there.
    private var replaying: Programme?
    /// What the session playing or starting was started for: its station, and the programme if it is an earlier one.
    /// Kept apart from the Live / Earlier choice and the station being browsed, so either view can be looked through
    /// without stopping what plays.
    private var source: (station: Station, replay: Programme?)?

    /// A session stops after this long with no requests for its stream [s].
    static let idleLimit: TimeInterval = 600
    static let newsNote = "This server has no speech model, so it can't recognise bulletins and news plays. These settings are kept for when it does."

    /// - Parameters:
    ///   - catalogue: The station list.
    ///   - settingsURL: Where the settings are kept.
    ///   - detects: Whether a sound classifier is installed.
    ///   - ambienceDirectory: Where the sounds for muted bulletins are.
    ///   - castBase: How speakers reach this server, such as `http://192.168.1.50:8642`, or nil if unknown.
    ///   - sonosHosts: Sonos speakers to ask about the household besides those multicast DNS finds.
    init(catalogue: Catalogue, settingsURL: URL, detects: Bool, ambienceDirectory: URL, castBase: String?, sonosHosts: [String] = []) {
        self.catalogue = catalogue; self.settingsURL = settingsURL; self.detects = detects; self.ambienceDirectory = ambienceDirectory
        self.castBase = castBase; self.sonosHosts = sonosHosts
        var saved = ServerSettings.load(settingsURL)
        if catalogue.station(saved.station) == nil { saved.station = catalogue.stations.first?.serviceId ?? saved.station }
        settings = saved
        saved.save(settingsURL)
        for station in catalogue.stations { profiles[station.serviceId] = StationProfile.load(station) }
        if saved.mode == "earlier" { Task { await self.loadSchedule() } }
        Task { await self.discover() }
    }

    /// Sets how to read the web app's version.
    func setPageVersion(_ version: @escaping @Sendable () -> String?) { pageVersion = version }

    /// Takes a changed station list. What plays carries on, unless its stream's address changed or it was removed.
    func use(_ newCatalogue: Catalogue) async {
        let old = catalogue
        catalogue = newCatalogue
        for station in newCatalogue.stations where profiles[station.serviceId] == nil { profiles[station.serviceId] = StationProfile.load(station) }
        if newCatalogue.station(settings.station) == nil, let first = newCatalogue.stations.first {
            settings.station = first.serviceId; saveSettings()
            replaying = nil; programmes = []
            if isEarlier { loadSchedule() }
        }
        guard let playing = source else { return }
        guard let updated = newCatalogue.station(playing.station.serviceId) else {
            await stop("\(playing.station.name) was removed from the station list"); return
        }
        source = (updated, playing.replay)
        if newCatalogue.playlistURL(updated) != old.playlistURL(playing.station) {
            log("\(updated.name)'s stream address changed, starting it again")
            await restart()
        }
    }

    // MARK: Speakers

    /// Follows Cast and Sonos speakers as they join and leave the network. Sonos rooms are also grouped and ungrouped
    /// in the Sonos app without any announcement, so the household is asked about every 30 seconds as well.
    private func discover() async {
        let watcher = MDNSWatcher()
        watcher.start()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshSonos()
            }
        }
        for await found in watcher.updates {
            if found.cast != speakers || !searched {
                log("Cast speakers: \(found.cast.isEmpty ? "none found" : found.cast.map(\.name).joined(separator: ", "))")
            }
            speakers = found.cast
            sonosFound = found.sonos
            await refreshSonos()
        }
    }

    /// Asks a Sonos speaker, found or named with --sonos-host, for the household's rooms and groups.
    private func refreshSonos() async {
        sonosAsks += 1
        let ask = sonosAsks, hosts = Array(Set(sonosFound + sonosHosts)).sorted()
        let groups = hosts.isEmpty ? [] : await Sonos.groups(hosts: hosts)
        guard ask == sonosAsks else { return }      // a newer question was asked while this one waited
        if groups != sonosGroups || !searched {
            log("Sonos speakers: \(groups.isEmpty ? "none found" : groups.map(\.name).joined(separator: ", "))")
        }
        sonosGroups = groups; searched = true
    }

    /// The chosen speaker's controller, name and stream: Sonos can't play HLS, so it gets the AAC stream.
    private var chosenSpeaker: (controller: () -> any CastController, name: String, stream: String)? {
        if settings.speaker.hasPrefix("cast:") {
            let id = String(settings.speaker.dropFirst(5))
            return speakers.first { $0.id == id }.map { speaker in ({ CastClient(speaker: speaker) }, speaker.name, "live.m3u8") }
        }
        if settings.speaker.hasPrefix("sonos:") {
            let id = String(settings.speaker.dropFirst(6))
            return sonosGroups.first { $0.id == id }.map { group in ({ SonosController(group: group) }, group.name, AACStream.path) }
        }
        return nil
    }

    /// Plays the session's stream on the chosen speaker.
    private func startCast() async {
        guard let speaker = chosenSpeaker, session != nil else { return }
        guard let base = castBase, let url = URL(string: "\(base)/stream/\(speaker.stream)") else {
            errorText = "Can't play on a speaker: this server's network address isn't known. Start it with --cast-host."; return
        }
        await stopCast()
        let controller = speaker.controller()
        cast = controller
        do {
            try await controller.connect()
            if let sonos = controller as? SonosController, await sonos.adopt(url: url) {
                // Its own Play button asked for the stream, so it is playing already, at its own volume.
                log("playing on \(speaker.name), started from the speaker")
            } else {
                try await controller.load(url: url, title: castTitle)
                await controller.setVolume(settings.volume)
                log("playing on \(speaker.name)")
            }
        } catch {
            guard cast === controller else { return }
            castProblem("Couldn't play on \(speaker.name): \(error.localizedDescription)")
            return
        }
        let name = speaker.name
        castEvents = Task { [weak self] in
            for await event in controller.events {
                guard let self else { return }
                switch event {
                case .lost: await self.castProblem("Speaker connection lost: \(name) stopped responding.")
                case .takenOver: await self.castProblem("Another app took over \(name).")
                case .stoppedOnDevice: await self.speakerStopped(controller, name)
                case .volume(let level): await self.speakerVolume(controller, level)
                case .loadFailed(let reason): await self.castProblem("\(name) refused the stream: \(reason)")
                }
            }
        }
    }

    private func stopCast() async {
        castEvents?.cancel(); castEvents = nil
        let controller = cast; cast = nil
        await controller?.stop()
    }

    /// Paused or stopped on the speaker itself: stop, as Stop here would. Its Play button starts it again (`stream`).
    private func speakerStopped(_ controller: any CastController, _ name: String) async {
        guard cast === controller else { return }
        await stop("paused on \(name)")
    }

    /// The volume changed on the speaker itself, so the slider follows it.
    private func speakerVolume(_ controller: any CastController, _ level: Double) {
        guard cast === controller else { return }
        settings.volume = level; saveSettings()
    }

    /// Reports a speaker's failure and lets the speaker go. The session carries on for any browsers.
    private func castProblem(_ message: String) {
        guard cast != nil else { return }
        errorText = message
        log(message)
        Task { await self.stopCast() }
    }

    /// What the speaker's own app shows.
    private var castTitle: String {
        if let programme = source?.replay { return "\(programme.title) · \(playingStation?.name ?? "")" }
        return playingStation?.name ?? "InterLude"
    }

    /// The secret part of the app's address.
    var token: String { settings.token }
    private var selectedStation: Station? { catalogue.station(settings.station) }
    private var isPlaying: Bool { session != nil }
    private var isStarting: Bool { starting != nil }
    /// Whether the Earlier view is showing, which says nothing about what plays.
    private var isEarlier: Bool { settings.mode == "earlier" }
    /// Whether the session playing or starting is an earlier programme.
    private var isReplay: Bool { source?.replay != nil }
    /// Live is showing, but what plays is an earlier programme or another station, browsed away from in Earlier.
    private var offersLive: Bool { !isEarlier && source.map { $0.replay != nil || $0.station.serviceId != settings.station } ?? false }
    /// The station playing or starting, or the one chosen when nothing is.
    private var playingStation: Station? { source?.station ?? selectedStation }
    private func profile(_ id: String) -> StationProfile { profiles[id] ?? StationProfile() }

    /// Changes a station's profile and saves it.
    private func updateProfile(_ id: String, _ change: (inout StationProfile) -> Void) {
        var updated = profile(id); change(&updated); profiles[id] = updated
        if let station = catalogue.station(id) { updated.save(station) }
    }

    private func saveSettings() { settings.save(settingsURL) }

    // MARK: Stream

    /// Answers the player's requests under /stream/: only the playlist and its segments, never the session's
    /// diagnostics, since these addresses carry no token. Starts the session if it isn't running.
    func stream(_ relative: String) async -> HTTPResponse {
        // A speaker that can't play HLS reads the session's playlist as any player would, which also keeps the session
        // from stopping as idle. The stream belongs to the session playing when the speaker asked: once that one stops
        // it ends, rather than starting another and so playing on the speaker again.
        if relative == AACStream.path {
            // With nothing playing, this is the speaker's own Play button: start, and the speaker is taken over as it
            // is (`startCast`). Only the stream's first request can start anything.
            if session == nil, starting == nil, settings.speaker.hasPrefix("sonos:") { start() }
            guard session != nil || starting != nil else {
                return HTTPResponse(status: 503, contentType: "text/plain", body: Data("Nothing playing.\n".utf8))
            }
            lastRequest = Date()
            let binding = AACStream.Binding()
            return AACStream.response { [weak self] path in await self?.respond(path, for: binding) ?? AACStream.ended }
        }
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

    /// Answers a request from a speaker's AAC stream, from the session it belongs to while that one plays. Until
    /// the first session is there (it is starting) the stream waits; once its session has gone, it ends.
    private func respond(_ relative: String, for binding: AACStream.Binding) async -> HTTPResponse {
        guard let current = session else {
            return binding.session == nil ? HTTPResponse(status: 503, contentType: "text/plain", body: Data()) : AACStream.ended
        }
        if binding.session == nil { binding.session = current }
        guard binding.session === current else { return AACStream.ended }
        lastRequest = Date()
        return await current.respond(to: relative)
    }

    // MARK: Playback

    /// Starts a session for `what`, or for the current choice: the station live, or in Earlier the programme picked
    /// (the first playable one if none was). Returns the start in progress, or nil if there is nothing to play.
    @discardableResult
    private func start(_ what: (station: Station, replay: Programme?)? = nil) -> Task<PlayerSession, Error>? {
        if let starting { return starting }
        guard session == nil else { return nil }
        let station: Station, replay: Programme?
        if let what { (station, replay) = what }
        else {
            guard let st = selectedStation else { return nil }
            if isEarlier && replaying == nil {
                guard let first = programmes.first(where: \.canPlay) else { loadSchedule(); return nil }
                replaying = first
            }
            (station, replay) = (st, isEarlier ? replaying : nil)
        }
        source = (station, replay)
        errorText = nil
        var sessionSettings = SessionSettings(station: station, profile: profile(station.serviceId))
        sessionSettings.bitrate = settings.bitrate
        sessionSettings.ambience = ambienceURL
        if !detects { sessionSettings.muteNews = false }
        if let programme = replay { sessionSettings.replay = programme; sessionSettings.onDemand = !Schedule.isPlayable(programme) }
        generation += 1
        let thisGeneration = generation, catalogue = catalogue, frozenSettings = sessionSettings
        let task = Task { () throws -> PlayerSession in
            // The server's stream has no secret token: speakers must be able to fetch it, and `stream(_:)` serves only
            // the playlist and segments.
            let newSession = PlayerSession(catalogue: catalogue, settings: frozenSettings, token: "stream", cacheRoot: try AppPaths.cacheDirectory(),
                                           eventLog: try AppPaths.supportDirectory().appendingPathComponent("events.jsonl"))
            try await newSession.start()
            return newSession
        }
        starting = task
        lastRequest = Date()
        log(replay.map { "starting \($0.title) on \(station.name)" } ?? "starting \(station.name), \(Int(sessionSettings.delaySeconds)) s behind live")
        Task { await self.started(task, generation: thisGeneration) }
        return task
    }

    /// Takes a session that has finished starting, unless it has been overtaken by a newer start or a stop.
    private func started(_ task: Task<PlayerSession, Error>, generation startedAs: Int) async {
        do {
            let newSession = try await task.value
            guard startedAs == generation else { await newSession.stop(); return }
            session = newSession; starting = nil; streamID = startedAs
            watch(newSession)
            await startCast()
        } catch {
            guard startedAs == generation else { return }
            starting = nil
            errorText = friendly(error)
            source = nil
            log("couldn't start: \(errorText ?? "")")
        }
    }

    /// Stops the session and any speaker, logging `reason` if given.
    private func stop(_ reason: String? = nil) async {
        await stopCast()
        generation += 1
        starting?.cancel()          // a session still starting stops its analysis rather than finishing unheard
        starting = nil
        watcher?.cancel(); watcher = nil
        let stopping = session
        session = nil
        source = nil
        status = SessionStatus()
        if let stopping { await stopping.stop(); log("stopped\(reason.map { ": \($0)" } ?? "")") }
    }

    /// Starts what was playing again, whichever view is showing.
    private func restart() async {
        let what = source
        await stop()
        start(what)
    }

    /// Follows the session once a second, as the Mac's status timer does, and stops it when nobody is listening.
    private func watch(_ watched: PlayerSession) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.tick(watched) == false { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One look at the session. False when the watch should end.
    private func tick(_ watched: PlayerSession) async -> Bool {
        guard session === watched else { return false }
        let latest = await watched.status()
        // The session saves what it learns, so read the profile again when that may have changed.
        if latest.recentBlocks.count != status.recentBlocks.count || latest.learningJingle != status.learningJingle, let station = playingStation {
            profiles[station.serviceId] = StationProfile.load(station)
        }
        status = latest
        if latest.finished { await stop("\(latest.replay?.programme.title ?? "the programme") finished"); return false }
        if latest.needsRestart { log("playback was interrupted, starting again"); await restart(); return false }
        if case .failed(let message) = latest.state { errorText = message } else if errorText != nil { errorText = nil }
        if Date().timeIntervalSince(lastRequest) > Self.idleLimit {
            await stop("no requests for \(Int(Self.idleLimit / 60)) minutes"); return false
        }
        return true
    }

    /// An error in words fit to show.
    private func friendly(_ error: Error) -> String {
        if case FetchError.unhealthy(let message) = error { return message }
        return "Could not start \(playingStation?.name ?? "the station"): \(error.localizedDescription)"
    }

    // MARK: Earlier programmes

    /// Reads the station's schedule for the chosen day, kept for five minutes per station and day.
    private func loadSchedule(force: Bool = false) {
        let id = settings.station, day = scheduleDay
        if !force, let cached = scheduleFor, cached.station == id, cached.day == day, Date().timeIntervalSince(cached.at) < 300, !programmes.isEmpty { return }
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

    /// Does what the page asked. The Mac's own commands are ignored.
    func perform(_ command: RemoteCommand) async {
        let active = isPlaying || isStarting
        switch command {
        case .toggle: if active { await stop() } else { start() }
        case .play: if !active { start() }
        case .station(let id):
            guard catalogue.station(id) != nil else { return }
            if isEarlier {
                // Earlier shows the station's programmes, and whatever plays carries on until one is picked.
                guard id != settings.station else { return }
                settings.station = id; saveSettings()
                replaying = nil; programmes = []
                loadSchedule()
            } else {
                // Live plays the station, taking over from an earlier programme or another station browsed from.
                if id == settings.station && active && !offersLive { return }
                settings.station = id; saveSettings()
                await stop(); start()
            }
        case .speaker(let id):
            let known = id == "browser" || speakers.contains { "cast:" + $0.id == id } || sonosGroups.contains { "sonos:" + $0.id == id }
            guard known, id != settings.speaker else { return }
            settings.speaker = id; saveSettings()
            await stopCast()
            if session != nil { await startCast() }
        case .volume(let level):
            settings.volume = level; saveSettings()
            await cast?.setVolume(level)
        case .notNews: await session?.notNews()
        case .newsGotThrough:
            await session?.newsGotThrough()
            if let st = playingStation { profiles[st.serviceId] = StationProfile.load(st) }
        case .earlier(let on):
            let mode = on ? "earlier" : "live"
            guard mode != settings.mode else { return }
            // Only the view changes: what plays carries on until something else is picked.
            settings.mode = mode; saveSettings()
            if on { loadSchedule() }
        case .day(let day):
            guard isEarlier, day != scheduleDay else { return }
            scheduleDay = day; programmes = []
            loadSchedule()
        case .reloadSchedule: if isEarlier { loadSchedule(force: true) }
        case .programme(let id):
            guard isEarlier, let programme = programmes.first(where: { $0.id == id }), programme.canPlay else { return }
            replaying = programme
            await stop(); start()
        case .setting(let setting): await apply(setting)
        case .favourite(let id): if catalogue.station(id) != nil { updateProfile(id) { $0.favourite.toggle() } }
        case .wrong(let id): if let block = UUID(uuidString: id) { await session?.markWrong(id: block) }
        case .welcomed, .diagnostics, .quit: break      // the Mac's own
        case .resetLink:
            settings.token = RemoteRoutes.newToken(); saveSettings()
            log("link reset; the app is now at \(RemoteRoutes.pagePath(token: settings.token, prefix: RemoteRoutes.appPrefix))")
        }
    }

    /// Applies a change from the Settings sheet to the chosen station, restarting the session when it must.
    private func apply(_ setting: RemoteSetting) async {
        let id = settings.station
        let active = isPlaying || isStarting
        switch setting {
        case .delay(let seconds):
            updateProfile(id) { $0.delaySeconds = seconds }
            if active && !isReplay && source?.station.serviceId == id { await restart() }
        case .muteNews(let on): updateProfile(id) { $0.muteNews = on }; await applyLiveOptions()
        case .jingleOnly(let on): updateProfile(id) { $0.detector.identOnly = on }
        case .shadowMode(let on): updateProfile(id) { $0.shadowMode = on }; await applyLiveOptions()
        case .forgetJingle: updateProfile(id) { $0.idents = []; $0.candidates = []; $0.candidateSources = [] }
        case .bitrate(let bitrate):
            guard bitrate != settings.bitrate else { return }
            settings.bitrate = bitrate; saveSettings()
            if active { await restart() }
        case .ambience(let id):
            settings.ambience = id; saveSettings()
            await session?.setAmbience(ambienceURL)
        case .maxMute(let minutes): updateProfile(id) { $0.detector.maxMuteSeconds = minutes * 60 }
        case .slots(let minutes): updateProfile(id) { $0.detector.slotMinutes = minutes; $0.slotMinutesByHand = true }
        case .startAtLogin, .keepAwake, .port, .remote: break      // the Mac's own
        }
    }

    /// The chosen sound during muted bulletins, or nil for silence or a missing file.
    private var ambienceURL: URL? {
        guard settings.ambience != "silence" else { return nil }
        let file = ambienceDirectory.appendingPathComponent("\(settings.ambience).m4a")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Passes the station's mute options to a running session, as the Mac does.
    private func applyLiveOptions() async {
        guard detects, let station = playingStation else { return }
        let options = profile(station.serviceId)
        await session?.setLiveOptions(muteNews: options.muteNews, shadowMode: options.shadowMode)
    }

    // MARK: State

    /// Everything the web app shows.
    func state() -> RemoteState {
        var state = RemoteState()
        let station = playingStation
        let playing = isPlaying, startingNow = isStarting, replay = isReplay
        state.state = startingNow ? "starting" : playing ? (status.muted ? "muted" : (replay ? "earlier" : "live")) : (errorText != nil ? "error" : "off")
        state.stationName = playing || startingNow ? (station?.name ?? "") : (errorText != nil ? "Stopped" : "Not playing")
        state.headline = headline(station)
        state.subheadline = subheadline(station)
        if isEarlier && !playing && !startingNow, let programme = replaying, programme.canPlay {
            state.subheadline = "Play starts \(programme.title) from \(programme.start.formatted(date: .omitted, time: .shortened))"
        }
        state.artwork = (playing ? status.nowPlaying?.imageURL : startingNow ? source?.replay?.imageURL : (isEarlier ? replaying?.imageURL : nil))?.absoluteString
        state.error = errorText
        state.playing = playing || startingNow
        state.muted = playing && status.muted
        state.muteElapsed = status.muteElapsed
        state.muteStartsIn = status.muteStartsIn
        state.justSkipped = status.replay?.justSkipped
        state.canCorrect = detects && playing && station?.mutesNews == true
        if playing { state.footer = Wording.footer(delaySeconds: status.delaySeconds, replay: replay ? status.replay : nil) }
        state.station = settings.station
        state.speaker = settings.speaker
        state.volume = settings.volume
        let favourites = catalogue.stations.filter { profile($0.serviceId).favourite }
        state.stations = (favourites + catalogue.stations.filter { !profile($0.serviceId).favourite }).map {
            .init(id: $0.serviceId, name: $0.name, short: $0.short, colour: $0.colour, group: $0.group, favourite: profile($0.serviceId).favourite)
        }
        state.speakers = speakerItems()
        if !searched { state.speakerNote = "Looking for speakers…" }
        else if speakers.isEmpty && sonosGroups.isEmpty {
            state.speakerNote = "No Chromecast or Sonos speakers found. The server needs to see multicast DNS from the speakers' network, or a Sonos speaker's address in --sonos-host."
        }
        state.mode = settings.mode
        if isEarlier {
            state.earlier = .describe(day: scheduleDay, programmes: programmes, loading: scheduleLoading, problem: scheduleProblem,
                                      chosen: replaying, playing: source?.replay)
        }
        state.offerLive = offersLive
        if let id = source?.station.serviceId, id != settings.station { state.onAir = id }
        if replay, let progress = status.replay { state.replay = .describe(progress) }
        state.stream = "/stream/live.m3u8"
        state.streamID = playing ? streamID : nil
        state.settings = settingsItem(selectedStation)
        state.news = .describe(profile(settings.station), kind: selectedStation?.kind, hasNews: selectedStation?.news != false, earlier: replay || (isEarlier && !playing && !startingNow),
                               ambience: settings.ambience)
        if playing && !status.recentBlocks.isEmpty {
            state.recentTitle = replay ? "News in this programme" : "Recent mutes"
            state.recent = RemoteState.RecentItem.list(status.recentBlocks)
        }
        if errorText != nil && !playing && !startingNow { state.recover = ["retry"] }
        state.pageVersion = pageVersion()
        return state
    }

    /// This browser, then single speakers, then groups.
    private func speakerItems() -> [RemoteState.SpeakerItem] {
        let single = speakers.filter { !$0.isGroup }, groups = speakers.filter(\.isGroup)
        var items: [RemoteState.SpeakerItem] = [.init(id: "browser", name: "This browser", detail: nil, kind: "browser")]
            + single.map { .init(id: "cast:" + $0.id, name: $0.name, detail: $0.model.isEmpty ? nil : $0.model, kind: "speaker") }
            + sonosGroups.filter { !$0.isGroup }.map { .init(id: "sonos:" + $0.id, name: $0.name, detail: $0.detail, kind: "speaker") }
            + groups.map { .init(id: "cast:" + $0.id, name: $0.name, detail: "Speaker group", kind: "group") }
            + sonosGroups.filter(\.isGroup).map { .init(id: "sonos:" + $0.id, name: $0.name, detail: $0.detail, kind: "group") }
        if settings.speaker != "browser", chosenSpeaker == nil {
            // A speaker chosen before but not seen since: keep showing it, so the choice isn't silently lost.
            items.append(.init(id: settings.speaker, name: "Speaker not found", detail: nil, kind: "speaker"))
        }
        return items
    }

    /// The large line on the player.
    private func headline(_ station: Station?) -> String {
        if isStarting, let programme = source?.replay { return programme.title }
        guard isPlaying else { return station?.name ?? "InterLude" }
        if status.muted { return "News muted" }
        return status.nowPlaying?.title ?? status.nowPlaying?.artist ?? station?.name ?? "Playing"
    }

    /// The line under the headline.
    private func subheadline(_ station: Station?) -> String {
        if isStarting, let programme = source?.replay { return "Starting from \(programme.start.formatted(date: .omitted, time: .shortened))…" }
        if isStarting { return "Starting about a minute behind live…" }
        guard isPlaying else { return isEarlier ? "Pick a programme to play from its start" : "Ready to play" }
        if status.muted { return "Sound returns when the music does" }
        if let track = status.nowPlaying, track.title != nil { return track.artist }
        return station?.name ?? ""
    }

    /// The Settings sheet for the chosen station.
    private func settingsItem(_ station: Station?) -> RemoteState.SettingsItem {
        let options = profile(settings.station), music = station?.mutesNews == true
        return .init(stationName: station?.name ?? settings.station, delay: options.delaySeconds, muteNews: options.muteNews,
                     jingleOnly: options.detector.identOnly, shadowMode: options.shadowMode, jingle: options.jingleStatus,
                     canForgetJingle: !options.idents.isEmpty || !options.candidates.isEmpty, newsNote: detects ? nil : Self.newsNote,
                     bitrate: settings.bitrate / 1000, ambience: settings.ambience,
                     ambienceChoices: Ambience.choices.map { [$0.id, $0.name] },
                     link: RemoteRoutes.pagePath(token: settings.token, prefix: RemoteRoutes.appPrefix),
                     maxMute: music ? options.detector.maxMuteSeconds / 60 : nil,
                     slots: music ? options.detector.slotMinutes.map(String.init).joined(separator: ", ") : nil)
    }

    /// The state as server-sent events: sent when it changes, checked every second, with a comment every 15 s so
    /// proxies keep the connection open.
    nonisolated func events() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                var last = Data(), quietSeconds = 0
                // Sorted, so the same state always encodes the same and only changes are sent.
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                while !Task.isCancelled {
                    let json = (try? encoder.encode(await self.state())) ?? Data("{}".utf8)
                    if json != last {
                        continuation.yield("data: \(String(decoding: json, as: UTF8.self))\n\n")
                        last = json; quietSeconds = 0
                    } else if quietSeconds >= 15 {
                        continuation.yield(": ping\n\n"); quietSeconds = 0
                    } else { quietSeconds += 1 }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
