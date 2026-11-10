//  Model.swift
//  InterLude (the Mac app)
//
//  The Mac app's state and actions: the station and speaker chosen, the playing session, Earlier programmes,
//  settings, speaker discovery and the phone remote. The web app in the panel reads it through RemoteControl.swift.

import Foundation
import AVFoundation
import Network
import Observation
import ServiceManagement
import UserNotifications
import InterLudeCore
import InterLudeApple

/// Where the sound goes: this Mac, a Cast device or group, or a Sonos room or group.
enum Output: Hashable, Identifiable {
    case thisMac
    case cast(CastDevice)
    case sonos(SonosGroup)
    /// "mac", "cast:<id>" or "sonos:<id>", as saved in the settings and sent to the page.
    var id: String {
        switch self { case .thisMac: "mac"; case .cast(let device): "cast:" + device.id; case .sonos(let group): "sonos:" + group.id }
    }
    var isGroup: Bool {
        switch self { case .thisMac: false; case .cast(let device): device.isGroup; case .sonos(let group): group.isGroup }
    }
    var label: String {
        switch self {
        case .thisMac: "This Mac"
        case .cast(let device): device.name
        case .sonos(let group): group.name
        }
    }
    /// The model, or the rooms of a Sonos group.
    var detail: String? {
        switch self {
        case .thisMac: nil
        case .cast(let device): device.isGroup ? "Speaker group" : (device.model.isEmpty ? nil : device.model)
        case .sonos(let group): group.detail
        }
    }
    /// A speaker on the network, which plays the stream from the Mac's LAN address.
    var isSpeaker: Bool { if case .thisMac = self { false } else { true } }
}

/// Lets the long-lived HTTP server reach whichever session is current.
actor SessionHolder {
    var session: PlayerSession?
    func set(_ newSession: PlayerSession?) { session = newSession }
    /// Answers the player from the current session, or 404 if nothing plays.
    func respond(_ path: String) async -> HTTPResponse { await session?.respond(to: path) ?? .notFound }
    /// For a speaker's AAC stream: from the session it belongs to while that one plays. Until the first session is
    /// there (it is starting) the stream waits; once its session has gone, it ends.
    func respond(_ path: String, for binding: AACStream.Binding) async -> HTTPResponse {
        guard let current = session else { return binding.session == nil ? .notFound : AACStream.ended }
        if binding.session == nil { binding.session = current }
        return binding.session === current ? await current.respond(to: path) : AACStream.ended
    }
}

/// Everything the panel and Settings show, and the actions they take. One instance for the life of the app.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    // Catalogue and choices
    var stations: [Station] = []
    var profiles = ProfileBook()
    var selectedStationID: String { didSet { UserDefaults.standard.set(selectedStationID, forKey: "station") } }
    var outputs: [Output] = [.thisMac]
    var selectedOutputID: String { didSet { UserDefaults.standard.set(selectedOutputID, forKey: "output") } }
    /// From 0 to 1.
    var volume: Double { didSet { UserDefaults.standard.set(volume, forKey: "volume"); applyVolume() } }

    // Earlier programmes
    enum Mode: String { case live, earlier }
    /// Which the panel shows: Live, or the programmes to play from the start with the news skipped. Only the view
    /// changes: what plays carries on until something else is picked.
    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if mode == .earlier { loadSchedule() }
        }
    }
    var schedule = ScheduleBook()
    var programmes: [Programme] { schedule.programmes }
    /// The earlier programme last picked, which Play starts in Earlier.
    var replaying: Programme?
    /// Where each earlier programme was left.
    var bookmarks = ReplayBookmarks()
    /// How far into the earlier programme the session starting or playing began [s].
    private(set) var startOffset = 0.0
    /// While starting, how far the start has got, from 0 to 1.
    private(set) var startProgress: Double?
    /// What is playing or starting: its station, and the programme if it is an earlier one. Kept apart from `mode` and
    /// the station chosen, so Earlier can be browsed while live plays, and another station while either does.
    private(set) var source: (station: Station, replay: Programme?)?
    /// Which day's schedule the list shows: 0 is today, up to `OnDemand.days - 1` days back.
    var scheduleDay: Int {
        get { schedule.day }
        set { guard newValue != schedule.day else { return }; schedule.day = newValue; schedule.clear(); loadSchedule() }
    }
    var isReplay: Bool { (isPlaying || isStarting) && source?.replay != nil }
    /// The station playing or starting, or the one chosen when nothing is.
    var onAirStation: Station? { source?.station ?? selectedStation }
    /// Live is showing, but what plays is an earlier programme or another station browsed away from in Earlier.
    var offersLive: Bool {
        mode == .live && (isPlaying || isStarting) && (source.map { $0.replay != nil || $0.station.serviceId != selectedStationID } ?? false)
    }

    // Settings
    /// The local server's port. Takes effect after a relaunch, since the server keeps running between sessions.
    var port: Int {
        didSet {
            if !(1024...65535).contains(port) { port = min(max(port, 1024), 65535) }
            UserDefaults.standard.set(port, forKey: "port")
        }
    }
    /// [bit/s]
    var bitrate: Int { didSet { UserDefaults.standard.set(bitrate, forKey: "bitrate") } }
    var keepAwake: Bool { didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateActivity() } }
    /// What plays during muted bulletins: "silence" or the name of a sound in Resources/Ambience.
    var ambience: String {
        didSet {
            UserDefaults.standard.set(ambience, forKey: "ambience")
            let url = ambienceURL
            Task { await session?.setAmbience(url) }
        }
    }
    static let ambienceChoices = Ambience.choices
    /// The chosen sound's file, from the app bundle or, when run with `swift run`, the checkout.
    var ambienceURL: URL? {
        guard ambience != "silence" else { return nil }
        return Bundle.main.url(forResource: ambience, withExtension: "m4a", subdirectory: "Ambience")
            ?? URL(fileURLWithPath: "Resources/Ambience/\(ambience).m4a")
    }
    var startAtLogin: Bool = false

    // Phone remote
    /// Serves a remote-control page to phones on the same network or tailnet, at an address carrying `remoteToken`.
    var remoteEnabled: Bool {
        didSet {
            guard remoteEnabled != oldValue else { return }
            UserDefaults.standard.set(remoteEnabled, forKey: "remoteEnabled")
            if remoteEnabled { enableRemote() } else { disableRemote() }
        }
    }
    /// Kept between launches, so a phone's bookmark keeps working until the link is reset.
    private(set) var remoteToken: String
    /// The Mac's host for the remote (its Tailscale name if Tailscale is up, else the LAN address), followed while the remote is on.
    private(set) var remoteAddress: String?
    private(set) var remoteError: String?
    /// Whether the remote's link goes over Tailscale rather than the LAN.
    var remoteOnTailscale: Bool {
        remoteAddress.map { $0.hasSuffix(".ts.net") || Tailnet.isTailscale($0) } ?? false
    }
    /// The phone remote's link, while it is on and the Mac has an address.
    var remoteURL: URL? {
        guard remoteEnabled, let host = remoteAddress, let port = server?.port else { return nil }
        return URL(string: "http://\(host):\(port)\(RemoteRoutes.pagePath(token: remoteToken))")
    }

    // State
    var isPlaying = false
    var isStarting = false
    var status = SessionStatus()
    var errorText: String?
    var stationFailed = false
    /// Offered with a Cast error: play on the Mac instead.
    var castFailed = false
    var discoveryState: DiscoveryState = .searching
    /// Still looking for speakers, done looking, or refused Local Network access.
    enum DiscoveryState { case searching, ready, denied }
    var showWelcome: Bool { didSet { UserDefaults.standard.set(!showWelcome, forKey: "welcomeDismissed") } }
    /// Set by `--demo=` for screenshots, so the first-run note stays out of the way.
    var demoHidesWelcome = false
    /// A short note on what InterLude knows about the station's news.
    var learnedNote: String? {
        let options = profile(onAirStation?.serviceId ?? selectedStationID)
        if status.learningJingle { return "Learning the news jingle…" }
        if status.speechModel == "checking" { return "Getting speech recognition ready…" }
        if !options.idents.isEmpty { return "Knows the news jingle" }
        return options.candidates.isEmpty ? nil : "Learning the news jingle"
    }
    /// The footer while something plays: how far behind live.
    var footerText: String { Wording.footer(delaySeconds: status.delaySeconds, replay: isReplay ? status.replay : nil) }

    /// The status badge.
    enum PlayState: String { case off, starting, live, earlier, muted, error }
    var playState: PlayState {
        if isStarting { return .starting }
        if isPlaying { return status.muted ? .muted : (isReplay ? .earlier : .live) }
        return errorText != nil ? .error : .off
    }
    /// The small line above the headline: the station while playing, otherwise whether it stopped.
    var statusCaption: String {
        isPlaying || isStarting ? (onAirStation?.name ?? "") : (errorText != nil ? "Stopped" : "Not playing")
    }
    /// The large line on the player.
    var headline: String {
        Wording.headline(chosen: selectedStation, onAir: onAirStation, starting: source?.replay, isStarting: isStarting, isPlaying: isPlaying, status: status)
    }
    /// The line under the headline.
    var subheadline: String {
        Wording.subheadline(starting: source?.replay, offset: startOffset, isStarting: isStarting, isPlaying: isPlaying, earlier: mode == .earlier,
                            status: status, output: selectedOutput.label, onAir: onAirStation)
    }
    /// The track's artwork while playing, or the programme's while starting one or browsing Earlier.
    var artworkURL: URL? {
        isPlaying ? status.nowPlaying?.imageURL : isStarting ? source?.replay?.imageURL : (mode == .earlier ? replaying?.imageURL : nil)
    }

    /// The menu bar icon's SF Symbol.
    var menuIcon: String {
        if isPlaying && status.muted { return "speaker.slash.fill" }
        if isPlaying || isStarting { return "dot.radiowaves.left.and.right" }
        if errorText != nil { return "exclamationmark.triangle" }
        return "radio"
    }

    private var catalogue: Catalogue?
    private let holder = SessionHolder()
    private var server: LocalServer?
    private var session: PlayerSession?
    /// The session being started, for its progress and for settings changed meanwhile.
    private var startingSession: PlayerSession?
    private var player: AVPlayer?
    private var cast: (any CastController)?
    private var castEvents: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var discovery: CastDiscovery?
    private var sonosDiscovery: SonosDiscovery?
    private var castDevices: [CastDevice] = []
    private var sonosGroups: [SonosGroup] = []
    private var sonosHosts: [String] = []
    /// Counts questions to Sonos, so an answer a newer question overtook is ignored.
    private var sonosAsks = 0
    /// Set while taking a volume from the speaker, so it isn't sent straight back.
    private var volumeFromSpeaker = false
    /// Keeps the Mac awake while playing.
    private var activity: NSObjectProtocol?
    /// Watches for the Mac's address changing while a speaker plays.
    private var pathMonitor: NWPathMonitor?
    /// The address the speaker was given.
    private var lastAddress: String?
    /// Session notices already passed on as notifications.
    private var shownNotices = 0
    private var notifiedFailure = false
    private var askedForNotifications = false
    private var volumeTask: Task<Void, Never>?
    private var remoteMonitor: NWPathMonitor?
    /// Prefixes every stream address the local server answers. Kept between launches, so a speaker playing
    /// across a relaunch still reaches it.
    private let token: String
    /// The panel's own address carries this, new each launch, and it is answered only on loopback.
    private let panelToken = RemoteRoutes.newToken()
    /// Why the panel can't show, if the local server couldn't start.
    private(set) var serverError: String?
    /// The web app as the panel shows it, from this Mac's own server.
    var panelURL: URL? {
        guard let p = server?.port else { return nil }
        return URL(string: "http://127.0.0.1:\(p)\(RemoteRoutes.pagePath(token: panelToken, prefix: RemoteRoutes.panelPrefix))")
    }

    var selectedStation: Station? { stations.first { $0.serviceId == selectedStationID } }
    var selectedOutput: Output { outputs.first { $0.id == selectedOutputID } ?? .thisMac }

    init() {
        let d = UserDefaults.standard
        selectedStationID = d.string(forKey: "station") ?? "bbc_6music"
        selectedOutputID = d.string(forKey: "output") ?? "mac"
        volume = d.object(forKey: "volume") as? Double ?? 0.7
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .live
        port = d.object(forKey: "port") as? Int ?? 8642
        // `--port` uses another port for this run only, for trying a build beside the installed app.
        if let i = CommandLine.arguments.firstIndex(of: "--port"), i + 1 < CommandLine.arguments.count,
           let p = Int(CommandLine.arguments[i + 1]), (1024...65535).contains(p) { port = p }
        bitrate = d.object(forKey: "bitrate") as? Int ?? 320_000
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        ambience = d.string(forKey: "ambience") ?? "silence"
        showWelcome = !d.bool(forKey: "welcomeDismissed")
        remoteEnabled = d.bool(forKey: "remoteEnabled")
        let savedRemoteToken = d.string(forKey: "remoteToken") ?? RemoteRoutes.newToken()
        d.set(savedRemoteToken, forKey: "remoteToken"); remoteToken = savedRemoteToken
        if let saved = d.string(forKey: "token") { token = saved } else {
            token = RemoteRoutes.newToken()
            d.set(token, forKey: "token")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
        // The panel is the web app, served by the same server as the stream, so it starts with the app.
        do { try ensureServer() } catch {
            serverError = "InterLude couldn't start its local server on port \(port): \(error.localizedDescription)"
        }
        loadCatalogue()
        startDiscovery()
        if mode == .earlier { loadSchedule() }
        if remoteEnabled { enableRemote() }
        if let demoArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo=") }) { demo(String(demoArgument.dropFirst(7))) }
    }

    /// Fills the panel with sample state, for the README's screenshots and design checks. Nothing is played.
    ///
    /// - Parameter kind: Which state to show, from `--demo=<kind>`.
    private func demo(_ kind: String) {
        demoHidesWelcome = kind != "welcome"
        selectedStationID = "bbc_6music"
        status.delaySeconds = 64
        let now = Date().timeIntervalSince1970
        status.nowPlaying = NowPlaying(artist: "Nilüfer Yanya", title: "Stabilise",
                                       imageURL: URL(string: "https://ichef.bbci.co.uk/images/ic/480x480/p0d71jpt.jpg"))
        let bulletin = NewsBlock(start: now - 3600, end: now - 3340, evidence: "demo")
        var mistake = NewsBlock(start: now - 1900, end: now - 1880, evidence: "demo"); mistake.falseStart = true; mistake.doubtful = true
        status.recentBlocks = [mistake, bulletin]
        switch kind {
        case "muted": isPlaying = true; status.muted = true; status.muteElapsed = 83; showRecentDemo()
        case "error": errorText = "Radio 6 Music: HTTP 404. The pool ID (81827798) has probably changed."; stationFailed = true
        case "casterror": errorText = "Cast connection lost. Kitchen speaker stopped responding."; castFailed = true
        case "upcoming": isPlaying = true; status.muteStartsIn = 38
        case "welcome": showWelcome = true
        case "earlier": mode = .earlier
        case "earlier-past": mode = .earlier; scheduleDay = 3
        case "replay":
            mode = .earlier; isPlaying = true
            let start = Date(timeIntervalSince1970: (now / 3600).rounded(.down) * 3600 - 3600)
            let programme = Programme(id: "demo", title: "Radcliffe and Maconie", subtitle: "Music, chat and Isobel Campbell",
                                      start: start, end: start.addingTimeInterval(7200),
                                      imageURL: URL(string: "https://ichef.bbci.co.uk/images/ic/480x480/p0lxz91z.jpg"))
            replaying = programme
            if let station = selectedStation { source = (station, programme) }
            var progress = ReplayStatus(programme: programme, heard: start.addingTimeInterval(2400), analysedThrough: start.addingTimeInterval(3000))
            progress.skipCount = 2; progress.skippedSeconds = 371; progress.justSkipped = 188
            progress.news = [start.addingTimeInterval(-20)...start.addingTimeInterval(163), start.addingTimeInterval(1790)...start.addingTimeInterval(1978)]
            status.replay = progress
            status.delaySeconds = Date().timeIntervalSince(progress.heard)
            status.nowPlaying = NowPlaying(artist: programme.subtitle ?? "", title: programme.title, imageURL: programme.imageURL)
        case "starting": isStarting = true
        case "stopped": break
        default: isPlaying = true
        }
    }

    private func showRecentDemo() { status.recentBlocks.insert(NewsBlock(start: Date().timeIntervalSince1970 - 83, evidence: "demo"), at: 0) }

    // MARK: Catalogue and profiles

    /// Loads the station list and starts watching it for edits.
    private func loadCatalogue() {
        let bundled = Bundle.main.url(forResource: "stations", withExtension: "json") ?? URL(fileURLWithPath: "Data/stations.json")
        do {
            use(try Catalogue.loadEditable(bundled: bundled))
            watchCatalogue(bundled: bundled)
        } catch { errorText = "Could not read the station list: \(error.localizedDescription)" }
    }

    /// Reads the station list again whenever it, or the bundled one, changes, so an edit takes effect without a relaunch.
    private func watchCatalogue(bundled: URL) {
        guard let file = try? Catalogue.editableURL(bundled: bundled) else { return }
        Task { [weak self] in
            var last = FileStamp.of([file, bundled])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let now = FileStamp.of([file, bundled])
                guard now != last else { continue }
                last = now
                guard let self else { return }
                do { self.use(try Catalogue.loadEditable(bundled: bundled)) }
                catch { self.errorText = "The station list changed but couldn't be read, so the old one stays: \(error.localizedDescription)" }
            }
        }
    }

    /// Takes a station list. What plays carries on, unless its stream's address changed or it was removed.
    private func use(_ newCatalogue: Catalogue) {
        let old = catalogue
        catalogue = newCatalogue; stations = newCatalogue.stations
        profiles.load(newCatalogue.stations)
        if selectedStation == nil, let first = newCatalogue.stations.first {
            selectedStationID = first.serviceId
            replaying = nil; schedule.clear()
            if mode == .earlier { loadSchedule() }
        }
        guard let playing = source, let old else { return }
        guard let updated = newCatalogue.station(playing.station.serviceId) else {
            stop(); errorText = "\(playing.station.name) was removed from the station list."; return
        }
        source = (updated, playing.replay)
        if newCatalogue.playlistURL(updated) != old.playlistURL(playing.station) { restart() }
    }

    func profile(_ id: String) -> StationProfile { profiles.profile(id) }

    /// Changes a station's profile as saved, and passes it to the session if that station plays.
    func updateProfile(_ id: String, _ change: (inout StationProfile) -> Void) {
        guard let station = stations.first(where: { $0.serviceId == id }) else { return }
        let updated = profiles.update(station, change)
        if id == source?.station.serviceId, let live = session ?? startingSession { Task { await live.applyProfile(updated) } }
    }

    // MARK: Cast discovery

    /// Follows Cast devices and Sonos speakers as they come and go.
    private func startDiscovery() {
        let castDiscovery = CastDiscovery(); castDiscovery.start(); discovery = castDiscovery
        Task { [weak self] in
            for await devices in castDiscovery.updates {
                guard let self else { return }
                self.castDevices = devices
                self.updateOutputs()
                self.discoveryState = .ready
            }
        }
        let sonos = SonosDiscovery(); sonos.start(); sonosDiscovery = sonos
        Task { [weak self] in
            for await hosts in sonos.updates {
                guard let self else { return }
                self.sonosHosts = hosts
                await self.refreshSonos()
            }
        }
        // Rooms are grouped and ungrouped in the Sonos app, so ask again now and then.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.refreshSonos()
            }
        }
        Task { [weak self] in
            for await denied in castDiscovery.permission {
                guard let self else { return }
                if denied { self.discoveryState = .denied }
            }
        }
        // If nothing turns up, stop showing "Searching" after a while.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if let self, self.discoveryState == .searching { self.discoveryState = .ready }
        }
    }

    /// Speakers named with `defaults write org.benbull.InterLude sonosHosts 192.168.1.60`, for a Sonos on another
    /// network whose Bonjour announcements don't reach the Mac. One is enough: it describes the whole household.
    private var manualSonosHosts: [String] {
        (UserDefaults.standard.string(forKey: "sonosHosts") ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    /// Asks a Sonos speaker for the household's rooms and groups.
    private func refreshSonos() async {
        sonosAsks += 1
        let ask = sonosAsks, hosts = Array(Set(sonosHosts + manualSonosHosts)).sorted()
        let groups = hosts.isEmpty ? [] : await Sonos.groups(hosts: hosts)
        guard ask == sonosAsks, groups != sonosGroups else { return }      // skip an answer a newer question overtook
        sonosGroups = groups
        updateOutputs()
        if !groups.isEmpty { discoveryState = .ready }
    }

    private func updateOutputs() {
        outputs = [.thisMac] + castDevices.map { Output.cast($0) } + sonosGroups.map { Output.sonos($0) }
    }

    // MARK: Playback

    func togglePlay() { if isPlaying || isStarting { stop() } else { start() } }

    /// Starts what the panel shows: the chosen station live, or in Earlier the programme picked (the first playable
    /// one if none was).
    func start() { start(nil) }

    /// - Parameters:
    ///   - what: What to start; nil for what the panel shows.
    ///   - offset: How far into an earlier programme to start [s]; nil carries on from where it was left.
    private func start(_ what: (station: Station, replay: Programme?)?, offset: Double? = nil) {
        guard let catalogue, !isStarting else { return }
        let station: Station, replay: Programme?
        if let what { (station, replay) = (catalogue.station(what.station.serviceId) ?? what.station, what.replay) }
        else {
            guard let chosen = selectedStation else { return }
            if mode == .earlier && replaying == nil {
                guard let first = programmes.first(where: \.canPlay) else { loadSchedule(); return }
                replaying = first
            }
            (station, replay) = (chosen, mode == .earlier ? replaying : nil)
        }
        source = (station, replay)
        errorText = nil; stationFailed = false; castFailed = false; notifiedFailure = false
        isStarting = true; shownNotices = 0
        if !askedForNotifications {
            askedForNotifications = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        let output = selectedOutput
        var settings = SessionSettings(station: station, profile: profile(station.serviceId))
        settings.bitrate = bitrate
        settings.ambience = ambienceURL
        startOffset = 0
        if let programme = replay {
            settings.replay = programme
            settings.onDemand = !Schedule.isPlayable(programme)
            startOffset = offset ?? bookmarks.offset(for: programme)
            settings.startOffset = startOffset
        }
        startProgress = 0
        Task {
            do {
                let cacheRoot = try AppPaths.cacheDirectory()
                let events = try AppPaths.supportDirectory().appendingPathComponent("events.jsonl")
                let newSession = PlayerSession(catalogue: catalogue, settings: settings, token: token, cacheRoot: cacheRoot, eventLog: events)
                try ensureServer()
                await holder.set(newSession)
                startingSession = newSession
                followStart(newSession)
                try await newSession.start()
                startingSession = nil; startProgress = nil
                session = newSession
                try await startOutput(output, station: station)
                isPlaying = true; isStarting = false
                updateActivity(); startTimer(); watchNetwork()
            } catch {
                startingSession = nil; startProgress = nil
                isStarting = false; isPlaying = false; source = nil
                errorText = friendly(error, station: station)
                if error is CastError || output.isSpeaker && !(error is FetchError) { castFailed = true } else { stationFailed = true }
                await tearDown()
            }
        }
    }

    /// Follows the progress of a session starting, twice a second, for the bar under the starting note.
    private func followStart(_ starting: PlayerSession) {
        Task { [weak self] in
            while let self, self.startingSession === starting {
                if let progress = await starting.status().startProgress { self.startProgress = progress }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Starts what was playing again, whichever view is showing, an earlier programme from where it had got to.
    func restart() {
        let what = source
        Task { await tearDown(); isPlaying = false; isStarting = false; start(what) }
    }

    /// Stops playing and lets any speaker go.
    func stop() {
        isPlaying = false; isStarting = false; source = nil
        Task { await tearDown() }
    }

    /// Plays the earlier programme playing, or picked, from `offset` [s].
    func play(from offset: Double) {
        guard let programme = (isReplay ? source?.replay : nil) ?? replaying, let station = source?.station ?? selectedStation else { return }
        Task {
            await tearDown(); isPlaying = false; isStarting = false
            bookmarks.forget(programme)
            start((station, programme), offset: offset)
        }
    }

    /// Stops the session, the player and any speaker, and forgets the status.
    private func tearDown() async {
        timer?.cancel(); timer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        castEvents?.cancel(); castEvents = nil
        player?.pause(); player = nil
        if let c = cast { await c.stop(); cast = nil }
        if let progress = status.replay { bookmarks.remember(progress) }
        startingSession = nil; startProgress = nil
        await session?.stop(); session = nil
        await holder.set(nil)
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        status = SessionStatus()
    }

    /// Changes where the sound goes. While playing, the stream carries on and only the output changes.
    func switchOutput(to id: String) {
        guard id != selectedOutputID else { return }
        selectedOutputID = id
        guard isPlaying, let station = source?.station else { return }
        let output = selectedOutput
        Task {
            await stopOutput()
            do {
                isStarting = true
                try await startOutput(output, station: station)
                isStarting = false
                watchNetwork()
            } catch {
                isStarting = false
                errorText = friendly(error, station: station); castFailed = true
                stop()
            }
        }
    }

    /// After a Cast failure: carry on playing on this Mac.
    func playOnThisMac() {
        errorText = nil; castFailed = false
        selectedOutputID = Output.thisMac.id
        if !isPlaying { start() }
    }

    /// Stops the sound where it is going, leaving the session running.
    private func stopOutput() async {
        castEvents?.cancel(); castEvents = nil
        player?.pause(); player = nil
        if let c = cast { await c.stop(); cast = nil }
        pathMonitor?.cancel(); pathMonitor = nil
    }

    /// Plays a station live from wherever things stand: stopped, playing another station, or playing an earlier
    /// programme. The panel's "live instead" button and the phone remote's station list and Play button use it.
    func playLive(_ id: String) {
        guard stations.contains(where: { $0.serviceId == id }) else { return }
        let active = isPlaying || isStarting
        if mode == .live && id == selectedStationID && active && !offersLive { return }
        if !active { mode = .live; selectedStationID = id; start(); return }
        Task {
            await tearDown(); isPlaying = false; isStarting = false; source = nil
            mode = .live; selectedStationID = id; start()
        }
    }

    /// In Earlier, shows the station's programmes and leaves what plays alone; in Live, plays the station.
    func switchStation(to id: String) {
        if mode == .earlier {
            guard id != selectedStationID else { return }
            selectedStationID = id
            replaying = nil; schedule.clear()
            loadSchedule(); return
        }
        if isPlaying || isStarting { playLive(id) } else { selectedStationID = id }
    }

    // MARK: Earlier programmes

    /// Reads the selected station's schedule for the chosen day. Kept for five minutes per station and day.
    func loadSchedule(force: Bool = false) {
        let id = selectedStationID, day = schedule.day
        guard schedule.begin(station: id, force: force) else { return }
        Task {
            switch await ScheduleBook.fetch(station: id, day: day) {
            case .success(let list): schedule.loaded(list, station: id, day: day, current: selectedStationID)
            case .failure(let error): schedule.failed(ScheduleBook.problem(error), station: id, day: day, current: selectedStationID)
            }
        }
    }

    /// Plays an earlier programme of the chosen station from its start, stopping whatever is playing.
    func play(_ programme: Programme) {
        guard programme.canPlay, let station = selectedStation else { return }
        replaying = programme
        if isPlaying || isStarting {
            Task { await tearDown(); isPlaying = false; isStarting = false; start((station, programme)) }
        } else { start((station, programme)) }
    }

    /// Starts the local server, if it isn't running. It answers the stream under `/<token>/`, and everything else
    /// (the panel and the phone remote) through `respondToRemote`.
    private func ensureServer() throws {
        if server != nil { return }
        let streamToken = token, sessions = holder
        let newServer = LocalServer(port: UInt16(port)) { [weak self] req in
            let prefix = "/\(streamToken)/"
            if req.path.hasPrefix(prefix) {
                let relative = String(req.path.dropFirst(prefix.count))
                if relative == AACStream.path {
                    // With nothing playing, this is the speaker's own Play button: start for it.
                    if await sessions.session == nil, await self?.startFromSpeaker() != true { return .notFound }
                    let binding = AACStream.Binding()
                    return AACStream.response { await sessions.respond($0, for: binding) }
                }
                return await sessions.respond(relative)
            }
            return await self?.respondToRemote(req) ?? .notFound
        }
        try newServer.start()
        server = newServer
    }

    /// Where `output` fetches the stream: the playlist, or for Sonos, which can't play HLS, the AAC stream.
    private func playlistURL(host: String, for output: Output? = nil) throws -> URL {
        let name = if case .sonos = output ?? selectedOutput { AACStream.path } else { "live.m3u8" }
        guard let url = URL(string: "http://\(host):\(port)/\(token)/\(name)") else { throw CastError.rejected("bad playlist address") }
        return url
    }

    /// Starts the sound on `output`: AVPlayer for this Mac, or the speaker's controller.
    private func startOutput(_ output: Output, station: Station) async throws {
        switch output {
        case .thisMac:
            let newPlayer = AVPlayer(url: try playlistURL(host: "127.0.0.1"))
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            newPlayer.volume = Float(volume); newPlayer.play(); player = newPlayer
        case .cast, .sonos:
            guard let ip = LocalServer.lanAddress() else { throw CastError.rejected("the Mac has no network address") }
            lastAddress = ip
            let controller: any CastController
            switch output {
            case .cast(let device): controller = DirectCastController(device: device)
            case .sonos(let group): controller = SonosController(group: group)
            case .thisMac: return
            }
            let name = output.label
            try await controller.connect()
            let url = try playlistURL(host: ip, for: output)
            if let sonos = controller as? SonosController, await sonos.adopt(url: url) {
                // Its own Play button asked for the stream, so it is playing already, at its own volume.
            } else {
                try await controller.load(url: url, title: castTitle(station))
                await controller.setVolume(volume)
            }
            cast = controller
            castEvents = Task { [weak self] in
                for await event in controller.events {
                    guard let self else { return }
                    switch event {
                    case .lost: self.castProblem("Speaker connection lost", "\(name) stopped responding.")
                    case .takenOver: self.castProblem("Another app took over", "\(name) is now playing something else.")
                    // Paused or stopped on the speaker itself: stop, as Stop here would. Its Play button starts it again.
                    case .stoppedOnDevice: if self.isPlaying { self.stop() }
                    case .volume(let level): self.volumeFromSpeaker = true; self.volume = level; self.volumeFromSpeaker = false
                    case .loadFailed(let reason): self.castProblem("The speaker refused the stream", reason)
                    }
                }
            }
        }
    }

    /// What the speaker's own app shows.
    private func castTitle(_ station: Station) -> String {
        if let programme = source?.replay { return "\(programme.title) · \(station.name)" }
        return station.name
    }

    /// Reports a speaker's failure as an error and a notification, and stops.
    private func castProblem(_ title: String, _ body: String) {
        guard isPlaying else { return }
        errorText = "\(title). \(body)"; castFailed = true
        notify(title, body); stop()
    }

    /// Asked for the AAC stream with nothing playing: the chosen Sonos speaker's own Play button. Starts what Play
    /// here would. False if the speaker isn't the one chosen.
    func startFromSpeaker() -> Bool {
        guard case .sonos = selectedOutput else { return false }
        if !isPlaying && !isStarting { start() }
        return true
    }

    private func applyVolume() {
        player?.volume = Float(volume)
        guard let controller = cast, !volumeFromSpeaker else { return }
        // Dragging the slider would send dozens of messages a second; send the latest after a short pause.
        volumeTask?.cancel()
        let level = volume
        volumeTask = Task { try? await Task.sleep(for: .milliseconds(120)); if !Task.isCancelled { await controller.setVolume(level) } }
    }

    /// Keeps the Mac from idle sleep while playing, if asked to.
    private func updateActivity() {
        if keepAwake && isPlaying {
            if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Playing radio") }
        } else if let running = activity { ProcessInfo.processInfo.endActivity(running); activity = nil }
    }

    /// Gives the speaker the stream's new address if the Mac's address changes.
    private func watchNetwork() {
        guard selectedOutput.isSpeaker else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, let ip = LocalServer.lanAddress(), ip != self.lastAddress,
                      let controller = self.cast, let station = self.source?.station else { return }
                self.lastAddress = ip
                if let url = try? self.playlistURL(host: ip) { try? await controller.load(url: url, title: self.castTitle(station)) }
            }
        }
        monitor.start(queue: .main); pathMonitor = monitor
    }

    // MARK: Status

    /// Reads the session's status once a second, and acts on what it says.
    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let current = self.session else { return }
                let latest = await current.status()
                // The session saves what it learns, so read the profile again when that may have changed.
                if latest.recentBlocks.count != self.status.recentBlocks.count || latest.recentBlocks.first?.end != self.status.recentBlocks.first?.end
                    || latest.learningJingle != self.status.learningJingle,
                   let station = self.source?.station {
                    self.profiles.reload(station)
                }
                self.status = latest
                if latest.notices.count > self.shownNotices {
                    for notice in latest.notices[self.shownNotices...] where notice.contains("longest mute") || notice.contains("failed") {
                        self.notify("InterLude", notice)
                    }
                    self.shownNotices = latest.notices.count
                }
                if latest.finished {
                    if let programme = latest.replay?.programme { self.bookmarks.forget(programme) }
                    self.notify("InterLude", "\(latest.replay?.programme.title ?? "The programme") has finished.")
                    self.stop(); return
                }
                if latest.needsRestart {
                    self.notify("InterLude", "Playback was interrupted, so it is starting again.")
                    self.restart(); return
                }
                if case .failed(let message) = latest.state {
                    self.errorText = message
                    if !self.notifiedFailure { self.notifiedFailure = true; self.notify("Station stream failed", message) }
                } else if self.notifiedFailure {
                    self.notifiedFailure = false; self.errorText = nil      // the stream recovered
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func newsGotThrough() {
        Task {
            await session?.newsGotThrough()
            if let station = onAirStation { profiles.reload(station) }
        }
    }
    func notNews() { Task { await session?.notNews() } }
    /// Drops the jingle in the session playing too, so it isn't saved again after the next bulletin.
    func forgetJingleInSession() { if let live = session ?? startingSession { Task { await live.forgetJingle() } } }
    func markWrong(_ id: UUID) { Task { await session?.markWrong(id: id) } }

    /// An error in words fit to show.
    private func friendly(_ error: Error, station: Station) -> String {
        if case FetchError.unhealthy(let message) = error { return message }
        if let castError = error as? CastError { return castError.localizedDescription }
        return "Could not start \(station.name): \(error.localizedDescription)"
    }

    /// Posts a notification at once.
    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Phone remote

    /// Starts the phone remote: makes sure the server runs, and follows the Mac's address.
    private func enableRemote() {
        remoteError = nil
        do { try ensureServer() } catch {
            remoteError = "Couldn't start the remote on port \(port): \(error.localizedDescription). Try another server port below, then quit and reopen InterLude."
            return
        }
        remoteAddress = LocalServer.tailscaleAddress() ?? LocalServer.lanAddress()
        refreshRemoteAddress()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshRemoteAddress() }
        }
        monitor.start(queue: .main); remoteMonitor = monitor
    }

    /// Finds the remote's host off the main thread, since the Tailscale name needs a DNS lookup.
    private func refreshRemoteAddress() {
        Task.detached { [weak self] in
            let host = Self.remoteHost()
            await MainActor.run { self?.remoteAddress = host }
        }
    }

    /// The Tailscale name, or failing that the Tailscale address, so the remote works anywhere on the tailnet;
    /// otherwise the LAN address.
    nonisolated private static func remoteHost() -> String? {
        LocalServer.tailscaleName() ?? LocalServer.tailscaleAddress() ?? LocalServer.lanAddress()
    }

    private func disableRemote() {
        remoteMonitor?.cancel(); remoteMonitor = nil
        remoteError = nil
    }

    /// A new address for the remote. Phones with the old one see that it has stopped working.
    func resetRemoteLink() {
        remoteToken = RemoteRoutes.newToken()
        UserDefaults.standard.set(remoteToken, forKey: "remoteToken")
    }

    /// Answers the panel's page, only to this Mac, and the phone remote's, only while it is on.
    private func respondToRemote(_ req: HTTPRequest) -> HTTPResponse {
        if req.fromLoopback, let route = RemoteRoutes.route(req, token: panelToken, prefix: RemoteRoutes.panelPrefix) {
            return respond(to: route, panel: true)
        }
        guard remoteEnabled, let route = RemoteRoutes.route(req, token: remoteToken) else { return .notFound }
        return respond(to: route, panel: false)
    }

    private func respond(to route: RemoteRoute, panel: Bool) -> HTTPResponse {
        switch route {
        case .page:
            return panel ? RemoteRoutes.page(token: panelToken, prefix: RemoteRoutes.panelPrefix, files: Self.webFiles)
                         : RemoteRoutes.page(token: remoteToken, touchIcon: Self.remoteTouchIcon, files: Self.webFiles)
        case .asset(let name): return RemoteRoutes.asset(name, files: Self.webFiles)
        case .qr: return panel ? remoteQR() : .notFound
        case .manifest: return RemoteRoutes.manifest
        case .icon: return HTTPResponse(contentType: "image/png", body: Self.remoteIcon)
        case .state: return RemoteRoutes.json(remoteState(panel: panel))
        case .events: return .notFound      // the page polls the Mac instead
        case .command(let command): perform(command, panel: panel); return RemoteRoutes.json(remoteState(panel: panel))
        }
    }

    // MARK: Settings actions

    func setStartAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { errorText = error.localizedDescription }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// A temporary folder holding copies of the event log, station list and profiles, for Export diagnostics.
    func diagnosticsFolder() -> URL? {
        guard let support = try? AppPaths.supportDirectory() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InterLude-diagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Read and rewrite the files rather than copying them, which skipped files the app had written itself.
        func put(_ source: URL, as name: String) {
            if let data = try? Data(contentsOf: source) { try? data.write(to: folder.appendingPathComponent(name)) }
        }
        put(support.appendingPathComponent("events.jsonl"), as: "events.jsonl")
        put(support.appendingPathComponent("stations.json"), as: "stations.json")
        let profiles = support.appendingPathComponent("profiles")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [] {
            put(profiles.appendingPathComponent(file), as: "profile-\(file)")
        }
        return folder
    }
}
