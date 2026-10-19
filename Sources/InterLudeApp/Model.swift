import Foundation
import AVFoundation
import Network
import Observation
import ServiceManagement
import UserNotifications
import InterLudeCore

enum Output: Hashable, Identifiable {
    case thisMac
    case cast(CastDevice)
    var id: String { switch self { case .thisMac: "mac"; case .cast(let d): "cast:" + d.id } }
    var icon: String {
        switch self {
        case .thisMac: "laptopcomputer"
        case .cast(let d): d.isGroup ? "hifispeaker.2" : "hifispeaker"
        }
    }
    var label: String {
        switch self {
        case .thisMac: "This Mac"
        case .cast(let d): d.name
        }
    }
    var detail: String? {
        switch self {
        case .thisMac: nil
        case .cast(let d): d.isGroup ? "Speaker group" : (d.model.isEmpty ? nil : d.model)
        }
    }
    var isCast: Bool { if case .cast = self { true } else { false } }
}

/// Lets the long-lived HTTP server reach whichever session is current.
actor SessionHolder {
    var session: PlayerSession?
    func set(_ s: PlayerSession?) { session = s }
    func respond(_ path: String) async -> HTTPResponse { await session?.respond(to: path) ?? .notFound }
}

/// Everything the panel and Settings show, and the actions they take. One instance for the life of the app.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    // Catalogue and choices
    var stations: [Station] = []
    var profiles: [String: StationProfile] = [:]
    var selectedStationID: String { didSet { UserDefaults.standard.set(selectedStationID, forKey: "station") } }
    var outputs: [Output] = [.thisMac]
    var selectedOutputID: String { didSet { UserDefaults.standard.set(selectedOutputID, forKey: "output") } }
    var volume: Double { didSet { UserDefaults.standard.set(volume, forKey: "volume"); applyVolume() } }

    // Earlier programmes
    enum Mode: String { case live, earlier }
    /// Live, or an earlier programme from the start with the news skipped. Changing it stops playback.
    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if isPlaying || isStarting { stop() }
            if mode == .earlier { loadSchedule() }
        }
    }
    var programmes: [Programme] = []
    enum ScheduleState: Equatable { case idle, loading, failed(String) }
    var scheduleState: ScheduleState = .idle
    /// The earlier programme chosen to play, and playing once `isPlaying`.
    var replaying: Programme?
    private var scheduleFor: (station: String, day: Int, at: Date)?
    /// Which day's schedule the list shows: 0 is today, up to `OnDemand.days - 1` days back.
    var scheduleDay = 0 {
        didSet { if scheduleDay != oldValue { programmes = []; loadSchedule() } }
    }
    /// Within the last 11 hours a programme plays from the live origin; before that, on demand.
    static func canPlay(_ p: Programme) -> Bool { Schedule.isPlayable(p) || OnDemand.isAvailable(p) }
    var scheduleDayTitle: String {
        switch scheduleDay {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            let d = Calendar.current.date(byAdding: .day, value: -scheduleDay, to: Date()) ?? Date()
            return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
    }
    var isReplay: Bool { mode == .earlier && (isPlaying || isStarting) }

    // Settings
    /// The local server's port. Takes effect after a relaunch, since the server keeps running between sessions.
    var port: Int {
        didSet {
            if !(1024...65535).contains(port) { port = min(max(port, 1024), 65535) }
            UserDefaults.standard.set(port, forKey: "port")
        }
    }
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
    static let ambienceChoices: [(id: String, name: String)] = [
        ("silence", "Silence"), ("ocean", "Ocean waves"), ("stream", "Woodland stream"), ("birds", "Woodland birds"),
    ]
    var ambienceURL: URL? {
        guard ambience != "silence" else { return nil }
        return Bundle.main.url(forResource: ambience, withExtension: "m4a", subdirectory: "Ambience")
            ?? URL(fileURLWithPath: "Resources/Ambience/\(ambience).m4a")
    }
    var startAtLogin: Bool = false

    // Phone remote
    /// Serves a remote-control page to phones on the same network, at an address carrying `remoteToken`.
    var remoteEnabled: Bool {
        didSet {
            guard remoteEnabled != oldValue else { return }
            UserDefaults.standard.set(remoteEnabled, forKey: "remoteEnabled")
            if remoteEnabled { enableRemote() } else { disableRemote() }
        }
    }
    /// Kept between launches, so a phone's bookmark keeps working until the link is reset.
    private(set) var remoteToken: String
    /// The Mac's address on the network, followed while the remote is on.
    private(set) var remoteAddress: String?
    private(set) var remoteError: String?
    var remoteURL: URL? {
        guard remoteEnabled, let ip = remoteAddress, let p = server?.port else { return nil }
        return URL(string: "http://\(ip):\(p)\(RemoteRoutes.pagePath(token: remoteToken))")
    }

    // State
    var isPlaying = false
    var isStarting = false
    /// Bar heights for what is being heard right now, from the Mac's player or the Cast device's reported position.
    /// Nil when neither is playing, where the backdrop falls back to its decorative animation.
    var spectrumSampler: (@MainActor () -> [Float]?)?
    var status = SessionStatus()
    var errorText: String?
    var stationFailed = false
    /// Offered with a Cast error: play on the Mac instead.
    var castFailed = false
    var discoveryState: DiscoveryState = .searching
    enum DiscoveryState { case searching, ready, denied }
    var showWelcome: Bool { didSet { UserDefaults.standard.set(!showWelcome, forKey: "welcomeDismissed") } }
    var demoHidesWelcome = false
    var showRecent: Bool { didSet { UserDefaults.standard.set(showRecent, forKey: "showRecent") } }
    func jingleStatus(_ id: String) -> String {
        let p = profile(id)
        if !p.idents.isEmpty { return "Learned" }
        switch p.candidates.count {
        case 0: return "Not learned yet"
        case 1, 2: return "Learning: \(p.candidates.count) bulletin\(p.candidates.count == 1 ? "" : "s") heard"
        default: return "No shared jingle yet (\(p.candidates.count) bulletins)"
        }
    }
    var learnedNote: String? {
        let p = profile(selectedStationID)
        if status.learningJingle { return "Learning the news jingle…" }
        if status.speechModel == "checking" { return "Getting speech recognition ready…" }
        if !p.idents.isEmpty { return "Knows the news jingle" }
        return p.candidates.isEmpty ? nil : "Learning the news jingle"
    }
    var delayDescription: String { "About \(Int((status.delaySeconds / 5).rounded()) * 5) seconds" }
    var muteSubtitle: String {
        let p = profile(selectedStationID)
        if selectedStation?.kind == .speech { return "Off for speech stations, where talk is the programme." }
        if p.shadowMode { return "Shadow mode: bulletins are noted but not muted." }
        if !p.muteNews { return "Off. Bulletins will play." }
        if mode == .earlier {
            if p.detector.identOnly && p.idents.isEmpty { return "Set to jingle only, but no jingle is learned yet, so nothing is skipped." }
            return "Cuts bulletins out, so the programme runs on without them."
        }
        if p.detector.identOnly {
            return p.idents.isEmpty ? "Set to jingle only, but no jingle is learned yet, so nothing is muted. Change this in Settings."
                                    : "Mutes when the station's news jingle plays."
        }
        if ambience == "silence" { return "Silences bulletins until the music returns." }
        let name = Self.ambienceChoices.first { $0.id == ambience }?.name.lowercased() ?? "a soothing sound"
        return "Plays \(name) over bulletins until the music returns."
    }
    var footerText: String {
        guard isReplay, let r = status.replay else { return "\(delayDescription) behind live" }
        return "Started at \(r.programme.start.formatted(date: .omitted, time: .shortened)) · \(Self.duration(status.delaySeconds)) behind live"
    }
    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    enum PlayState: String { case off, starting, live, earlier, muted, error }
    var playState: PlayState {
        if isStarting { return .starting }
        if isPlaying { return status.muted ? .muted : (isReplay ? .earlier : .live) }
        return errorText != nil ? .error : .off
    }
    /// The small line above the headline: the station while playing, otherwise whether it stopped.
    var statusCaption: String {
        isPlaying || isStarting ? (selectedStation?.name ?? "") : (errorText != nil ? "Stopped" : "Not playing")
    }
    var headline: String {
        if isStarting, mode == .earlier, let p = replaying { return p.title }
        guard isPlaying else { return selectedStation?.name ?? "InterLude" }
        if status.muted { return "News muted" }
        return status.nowPlaying?.title ?? status.nowPlaying?.artist ?? selectedStation?.name ?? "Playing"
    }
    var subheadline: String {
        if isStarting, mode == .earlier, let p = replaying {
            return "Starting from \(p.start.formatted(date: .omitted, time: .shortened))…"
        }
        if isStarting { return "Starting about a minute behind live…" }
        guard isPlaying else {
            if mode == .earlier { return "Pick a programme below" }
            return "Ready to play on \(selectedOutput.label)"
        }
        if status.muted { return "Sound returns when the music does" }
        if let np = status.nowPlaying, np.title != nil { return np.artist }
        return "On \(selectedOutput.label)"
    }
    var artworkURL: URL? { isPlaying ? status.nowPlaying?.imageURL : (mode == .earlier ? replaying?.imageURL : nil) }

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
    private var player: AVPlayer?
    private var cast: DirectCastController?
    private var castEvents: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var discovery: CastDiscovery?
    private var activity: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastAddress: String?
    private var shownNotices = 0
    private var notifiedFailure = false
    private var askedForNotifications = false
    private var volumeTask: Task<Void, Never>?
    private var remoteMonitor: NWPathMonitor?
    private let token: String

    var selectedStation: Station? { stations.first { $0.serviceId == selectedStationID } }
    var selectedOutput: Output { outputs.first { $0.id == selectedOutputID } ?? .thisMac }

    init() {
        let d = UserDefaults.standard
        selectedStationID = d.string(forKey: "station") ?? "bbc_6music"
        selectedOutputID = d.string(forKey: "output") ?? "mac"
        volume = d.object(forKey: "volume") as? Double ?? 0.7
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .live
        port = d.object(forKey: "port") as? Int ?? 8642
        bitrate = d.object(forKey: "bitrate") as? Int ?? 320_000
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        ambience = d.string(forKey: "ambience") ?? "silence"
        showWelcome = !d.bool(forKey: "welcomeDismissed")
        showRecent = d.bool(forKey: "showRecent")
        remoteEnabled = d.bool(forKey: "remoteEnabled")
        let rt = d.string(forKey: "remoteToken") ?? RemoteRoutes.newToken()
        d.set(rt, forKey: "remoteToken"); remoteToken = rt
        let args = CommandLine.arguments
        // The token prefixes every URL the local server answers. `--token` fixes it for scripted tests.
        if let i = args.firstIndex(of: "--token"), i + 1 < args.count { token = args[i + 1] }
        else if let t = d.string(forKey: "token") { token = t } else {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            d.set(token, forKey: "token")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
        loadCatalogue()
        startDiscovery()
        if mode == .earlier { loadSchedule() }
        if remoteEnabled { enableRemote() }
        if CommandLine.arguments.contains("--autoplay") { start() }
        if let d = CommandLine.arguments.first(where: { $0.hasPrefix("--demo=") }) { demo(String(d.dropFirst(7))) }
    }

    /// Fills the panel with sample state, for screenshots and design checks. Nothing is played.
    private func demo(_ kind: String) {
        demoHidesWelcome = kind != "welcome"
        selectedStationID = "bbc_6music"
        status.delaySeconds = 64
        let now = Date().timeIntervalSince1970
        status.nowPlaying = NowPlaying(artist: "Nilüfer Yanya", title: "Stabilise",
                                       imageURL: URL(string: "https://ichef.bbci.co.uk/images/ic/480x480/p0d71jpt.jpg"))
        var b1 = NewsBlock(start: now - 3600, end: now - 3340, evidence: "demo")
        b1.doubtful = false
        var b2 = NewsBlock(start: now - 1900, end: now - 1880, evidence: "demo"); b2.falseStart = true; b2.doubtful = true
        status.recentBlocks = [b2, b1]
        switch kind {
        case "muted": isPlaying = true; status.muted = true; status.muteElapsed = 83; showRecentDemo()
        case "error": errorText = "Radio 6 Music: HTTP 404. The pool ID (81827798) has probably changed."; stationFailed = true
        case "casterror": errorText = "Cast connection lost. Kitchen speaker stopped responding."; castFailed = true
        case "upcoming": isPlaying = true; status.muteStartsIn = 38
        case "welcome": showWelcome = true
        case "welcome-dismiss":      // closes the note after 3 s, to check the window shrinks
            demoHidesWelcome = false; showWelcome = true
            Task { try? await Task.sleep(for: .seconds(3)); demoHidesWelcome = true }
        case "earlier": mode = .earlier
        case "earlier-past": mode = .earlier; scheduleDay = 3
        case "replay":
            mode = .earlier; isPlaying = true
            let start = Date(timeIntervalSince1970: (now / 3600).rounded(.down) * 3600 - 3600)
            let prog = Programme(id: "demo", title: "Radcliffe and Maconie", subtitle: "Music, chat and Isobel Campbell",
                                 start: start, end: start.addingTimeInterval(7200), imageURL: URL(string: "https://ichef.bbci.co.uk/images/ic/480x480/p0lxz91z.jpg"))
            replaying = prog
            var r = ReplayStatus(programme: prog, heard: start.addingTimeInterval(2400), analysedThrough: start.addingTimeInterval(3000))
            r.skipCount = 2; r.skippedSeconds = 371; r.justSkipped = 188
            r.news = [start.addingTimeInterval(-20)...start.addingTimeInterval(163), start.addingTimeInterval(1790)...start.addingTimeInterval(1978)]
            status.replay = r
            status.delaySeconds = Date().timeIntervalSince(r.heard)
            status.nowPlaying = NowPlaying(artist: prog.subtitle!, title: prog.title, imageURL: prog.imageURL)
        case "starting": isStarting = true
        case "stopped": break
        default: isPlaying = true
        }
    }

    private func showRecentDemo() { status.recentBlocks.insert(NewsBlock(start: Date().timeIntervalSince1970 - 83, evidence: "demo"), at: 0) }

    // MARK: Catalogue and profiles

    private func loadCatalogue() {
        let bundled = Bundle.main.url(forResource: "stations", withExtension: "json") ?? URL(fileURLWithPath: "Data/stations.json")
        do {
            let url = try Catalogue.editableURL(bundled: bundled)
            var c = try Catalogue.load(from: url)
            // Copies made by older versions lack the badge fields: take them from the bundled list.
            if let b = try? Catalogue.load(from: bundled) {
                for i in c.stations.indices {
                    guard let m = b.station(c.stations[i].serviceId) else { continue }
                    if c.stations[i].short == nil { c.stations[i].short = m.short }
                    if c.stations[i].colour == nil { c.stations[i].colour = m.colour }
                    if c.stations[i].group == nil { c.stations[i].group = m.group }
                }
                // Stations added since the copy was made.
                let known = Set(c.stations.map(\.serviceId))
                c.stations += b.stations.filter { !known.contains($0.serviceId) }
            }
            catalogue = c; stations = c.stations
            for s in c.stations { profiles[s.serviceId] = StationProfile.load(s) }
        } catch { errorText = "Could not read the station list: \(error.localizedDescription)" }
    }

    func profile(_ id: String) -> StationProfile { profiles[id] ?? StationProfile() }
    func updateProfile(_ id: String, _ f: (inout StationProfile) -> Void) {
        var p = profile(id); f(&p); profiles[id] = p
        if let s = stations.first(where: { $0.serviceId == id }) { p.save(s) }
        if isPlaying, id == selectedStationID { Task { await session?.setLiveOptions(muteNews: p.muteNews, shadowMode: p.shadowMode) } }
    }
    var favouriteStations: [Station] { stations.filter { profile($0.serviceId).favourite } }
    var otherStations: [Station] { stations.filter { !profile($0.serviceId).favourite } }
    /// Non-favourite stations under their group headings, in the order the groups first appear.
    var otherStationGroups: [(name: String?, stations: [Station])] {
        var groups: [(name: String?, stations: [Station])] = []
        for s in otherStations {
            if let i = groups.firstIndex(where: { $0.name == s.group }) { groups[i].stations.append(s) } else { groups.append((s.group, [s])) }
        }
        return groups
    }
    var orderedStations: [Station] { favouriteStations + otherStations }

    // MARK: Cast discovery

    private func startDiscovery() {
        let d = CastDiscovery(); d.start(); discovery = d
        Task { [weak self] in
            for await devices in d.updates {
                guard let self else { return }
                self.outputs = [.thisMac] + devices.map { Output.cast($0) }
                self.discoveryState = .ready
            }
        }
        Task { [weak self] in
            for await denied in d.permission {
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

    // MARK: Playback

    func togglePlay() { if isPlaying || isStarting { stop() } else { start() } }

    func start() {
        guard let catalogue, let station = selectedStation, !isStarting else { return }
        if mode == .earlier && replaying == nil {
            guard let p = programmes.first(where: { Self.canPlay($0) }) else { loadSchedule(); return }
            replaying = p
        }
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
        if mode == .earlier, let p = replaying {
            settings.replay = p
            settings.onDemand = !Schedule.isPlayable(p)
        }
        Task {
            do {
                let cacheRoot = try AppPaths.cacheDirectory()
                let events = try AppPaths.supportDirectory().appendingPathComponent("events.jsonl")
                let s = PlayerSession(catalogue: catalogue, settings: settings, token: token, cacheRoot: cacheRoot, eventLog: events)
                try ensureServer()
                await holder.set(s)
                try await s.start()
                session = s
                try await startOutput(output, station: station)
                isPlaying = true; isStarting = false
                updateActivity(); startTimer(); watchNetwork()
            } catch {
                isStarting = false; isPlaying = false
                errorText = friendly(error, station: station)
                if error is CastError || output.isCast && !(error is FetchError) { castFailed = true } else { stationFailed = true }
                await tearDown()
            }
        }
    }

    func restart() {
        Task { await tearDown(); isPlaying = false; isStarting = false; start() }
    }

    func stop() {
        isPlaying = false; isStarting = false
        Task { await tearDown() }
    }

    private func tearDown() async {
        timer?.cancel(); timer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        castEvents?.cancel(); castEvents = nil
        player?.pause(); player = nil; spectrumSampler = nil
        if let c = cast { await c.stop(); cast = nil }
        await session?.stop(); session = nil
        await holder.set(nil)
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        status = SessionStatus()
    }

    /// Changes where the sound goes. While playing, the stream carries on and only the output changes.
    func switchOutput(to id: String) {
        guard id != selectedOutputID else { return }
        selectedOutputID = id
        guard isPlaying, let station = selectedStation else { return }
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

    private func stopOutput() async {
        castEvents?.cancel(); castEvents = nil
        player?.pause(); player = nil
        if let c = cast { await c.stop(); cast = nil }
        pathMonitor?.cancel(); pathMonitor = nil
    }

    /// Plays a station live from wherever things stand: stopped, playing another station, or playing an earlier
    /// programme. The phone remote's station list and Play button use it.
    func playLive(_ id: String) {
        guard stations.contains(where: { $0.serviceId == id }) else { return }
        let active = isPlaying || isStarting
        if mode == .live && id == selectedStationID && active { return }
        if mode == .live && !active { selectedStationID = id; start(); return }
        Task {
            if active { await tearDown(); isPlaying = false; isStarting = false }
            mode = .live; selectedStationID = id; start()
        }
    }

    func switchStation(to id: String) {
        selectedStationID = id
        if mode == .earlier {
            replaying = nil; programmes = []
            if isPlaying || isStarting { stop() }
            loadSchedule(); return
        }
        if isPlaying || isStarting { Task { await tearDown(); isPlaying = false; isStarting = false; start() } }
    }

    // MARK: Earlier programmes

    /// Reads the selected station's schedule for the chosen day. Kept for five minutes per station and day.
    func loadSchedule(force: Bool = false) {
        let id = selectedStationID, day = scheduleDay
        if !force, let f = scheduleFor, f.station == id, f.day == day, Date().timeIntervalSince(f.at) < 300, !programmes.isEmpty { return }
        scheduleState = .loading
        Task {
            do {
                let list = try await OnDemand.day(serviceId: id, daysAgo: day)
                guard id == selectedStationID, day == scheduleDay else { return }
                programmes = list; scheduleFor = (id, day, Date()); scheduleState = .idle
            } catch {
                guard id == selectedStationID, day == scheduleDay else { return }
                scheduleState = .failed("Couldn't get the schedule: \(error.localizedDescription)")
            }
        }
    }

    /// Plays an earlier programme from its start, stopping whatever is playing.
    func play(_ p: Programme) {
        guard Self.canPlay(p) else { return }
        replaying = p
        if isPlaying || isStarting { Task { await tearDown(); isPlaying = false; isStarting = false; start() } } else { start() }
    }

    private func ensureServer() throws {
        if server != nil { return }
        let t = token, h = holder
        let s = LocalServer(port: UInt16(port)) { [weak self] req in
            let prefix = "/\(t)/"
            if req.path.hasPrefix(prefix) { return await h.respond(String(req.path.dropFirst(prefix.count))) }
            return await self?.respondToRemote(req) ?? .notFound
        }
        try s.start()
        server = s
    }

    private func playlistURL(host: String) throws -> URL {
        guard let u = URL(string: "http://\(host):\(port)/\(token)/live.m3u8") else { throw CastError.rejected("bad playlist address") }
        return u
    }

    private func startOutput(_ output: Output, station: Station) async throws {
        switch output {
        case .thisMac:
            let p = AVPlayer(url: try playlistURL(host: "127.0.0.1"))
            p.automaticallyWaitsToMinimizeStalling = true
            p.volume = Float(volume); p.play(); player = p
            if let tape = session?.tape {
                spectrumSampler = { [weak p] in
                    guard let p else { return nil }
                    let t = p.currentTime().seconds
                    return t.isFinite ? tape.bands(at: t) : nil
                }
            }
        case .cast(let device):
            guard let ip = LocalServer.lanAddress() else { throw CastError.rejected("the Mac has no network address") }
            lastAddress = ip
            let c = DirectCastController(device: device)
            try await c.connect()
            try await c.load(url: try playlistURL(host: ip), title: settingsTitle(station))
            await c.setVolume(volume)
            cast = c
            if let tape = session?.tape {
                spectrumSampler = { [weak c] in c?.playbackSeconds.flatMap { tape.bands(at: $0) } }
            }
            castEvents = Task { [weak self] in
                for await e in c.events {
                    guard let self else { return }
                    switch e {
                    case .lost: self.castProblem("Cast connection lost", "\(device.name) stopped responding.")
                    case .takenOver: self.castProblem("Another app took over", "\(device.name) is now playing something else.")
                    case .loadFailed(let m): self.castProblem("Cast refused the stream", m)
                    }
                }
            }
        }
    }

    private func settingsTitle(_ station: Station) -> String {
        if mode == .earlier, let p = replaying { return "\(p.title) · \(station.name)" }
        return station.name
    }

    private func castProblem(_ title: String, _ body: String) {
        guard isPlaying else { return }
        errorText = "\(title). \(body)"; castFailed = true
        notify(title, body); stop()
    }

    private func applyVolume() {
        player?.volume = Float(volume)
        guard let c = cast else { return }
        // Dragging the slider would send dozens of messages a second; send the latest after a short pause.
        volumeTask?.cancel()
        let v = volume
        volumeTask = Task { try? await Task.sleep(for: .milliseconds(120)); if !Task.isCancelled { await c.setVolume(v) } }
    }

    private func updateActivity() {
        if keepAwake && isPlaying {
            if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Playing radio") }
        } else if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    /// Reload the stream on the Cast device if the Mac's address changes.
    private func watchNetwork() {
        guard selectedOutput.isCast else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, let ip = LocalServer.lanAddress(), ip != self.lastAddress, let c = self.cast, let st = self.selectedStation else { return }
                self.lastAddress = ip
                if let url = try? self.playlistURL(host: ip) { try? await c.load(url: url, title: st.name) }
            }
        }
        m.start(queue: .main); pathMonitor = m
    }

    // MARK: Status

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let s = self.session else { return }
                let st = await s.status()
                if st.recentBlocks.count != self.status.recentBlocks.count || st.recentBlocks.first?.end != self.status.recentBlocks.first?.end
                    || st.learningJingle != self.status.learningJingle,
                   let station = self.selectedStation {
                    self.profiles[station.serviceId] = StationProfile.load(station)
                }
                self.status = st
                if st.notices.count > self.shownNotices {
                    for n in st.notices[self.shownNotices...] where n.contains("longest mute") || n.contains("failed") { self.notify("InterLude", n) }
                    self.shownNotices = st.notices.count
                }
                if st.finished {
                    self.notify("InterLude", "\(st.replay?.programme.title ?? "The programme") has finished.")
                    self.stop(); return
                }
                if st.needsRestart {
                    self.notify("InterLude", "Playback was interrupted, so it is starting again.")
                    self.restart(); return
                }
                if case .failed(let m) = st.state {
                    self.errorText = m
                    if !self.notifiedFailure { self.notifiedFailure = true; self.notify("Station stream failed", m) }
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
            profiles[selectedStationID] = selectedStation.map { StationProfile.load($0) } ?? profile(selectedStationID)
        }
    }
    func restartToApply() { if isPlaying { restart() } }
    func notNews() { Task { await session?.notNews() } }
    func markWrong(_ id: UUID) { Task { await session?.markWrong(id: id) } }

    private func friendly(_ e: Error, station: Station) -> String {
        if case FetchError.unhealthy(let m) = e { return m }
        if let c = e as? CastError { return c.localizedDescription }
        return "Could not start \(station.name): \(e.localizedDescription)"
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Phone remote

    private func enableRemote() {
        remoteError = nil
        do { try ensureServer() } catch {
            remoteError = "Couldn't start the remote on port \(port): \(error.localizedDescription). Try another server port below, then quit and reopen InterLude."
            return
        }
        remoteAddress = LocalServer.lanAddress()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.remoteAddress = LocalServer.lanAddress() }
        }
        m.start(queue: .main); remoteMonitor = m
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

    private func respondToRemote(_ req: HTTPRequest) -> HTTPResponse {
        guard remoteEnabled, let route = RemoteRoutes.route(req, token: remoteToken) else { return .notFound }
        switch route {
        case .page: return RemoteRoutes.page(token: remoteToken)
        case .manifest: return RemoteRoutes.manifest
        case .icon: return HTTPResponse(contentType: "image/png", body: Self.remoteIcon)
        case .state: return RemoteRoutes.json(remoteState())
        case .command(let c): perform(c); return RemoteRoutes.json(remoteState())
        }
    }

    // MARK: Settings actions

    func setStartAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { errorText = error.localizedDescription }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    func diagnosticsFolder() -> URL? {
        guard let support = try? AppPaths.supportDirectory() else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("InterLude-diagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Read and rewrite the files rather than copying them, which skipped files the app had written itself.
        func put(_ src: URL, as name: String) {
            if let d = try? Data(contentsOf: src) { try? d.write(to: tmp.appendingPathComponent(name)) }
        }
        put(support.appendingPathComponent("events.jsonl"), as: "events.jsonl")
        put(support.appendingPathComponent("stations.json"), as: "stations.json")
        let profiles = support.appendingPathComponent("profiles")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [] {
            put(profiles.appendingPathComponent(f), as: "profile-\(f)")
        }
        return tmp
    }
}
