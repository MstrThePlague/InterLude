import Foundation
import AVFoundation
import Network
import Observation
import ServiceManagement
import UserNotifications
import InterLudeCore
import InterLudeApple

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
    /// Which the panel shows: Live, or the programmes to play from the start with the news skipped. Only the view
    /// changes: what plays carries on until something else is picked.
    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if mode == .earlier { loadSchedule() }
        }
    }
    var programmes: [Programme] = []
    enum ScheduleState: Equatable { case idle, loading, failed(String) }
    var scheduleState: ScheduleState = .idle
    /// The earlier programme last picked, which Play starts in Earlier.
    var replaying: Programme?
    /// What is playing or starting: its station, and the programme if it is an earlier one. Kept apart from `mode` and
    /// the station chosen, so Earlier can be browsed while live plays, and another station while either does.
    private(set) var source: (station: Station, replay: Programme?)?
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
    var remoteURL: URL? {
        guard remoteEnabled, let ip = remoteAddress, let p = server?.port else { return nil }
        return URL(string: "http://\(ip):\(p)\(RemoteRoutes.pagePath(token: remoteToken))")
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
    enum DiscoveryState { case searching, ready, denied }
    var showWelcome: Bool { didSet { UserDefaults.standard.set(!showWelcome, forKey: "welcomeDismissed") } }
    var demoHidesWelcome = false
    var learnedNote: String? {
        let p = profile(onAirStation?.serviceId ?? selectedStationID)
        if status.learningJingle { return "Learning the news jingle…" }
        if status.speechModel == "checking" { return "Getting speech recognition ready…" }
        if !p.idents.isEmpty { return "Knows the news jingle" }
        return p.candidates.isEmpty ? nil : "Learning the news jingle"
    }
    var delayDescription: String { "About \(Int((status.delaySeconds / 5).rounded()) * 5) seconds" }
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
        isPlaying || isStarting ? (onAirStation?.name ?? "") : (errorText != nil ? "Stopped" : "Not playing")
    }
    var headline: String {
        if isStarting, let p = source?.replay { return p.title }
        guard isPlaying else { return selectedStation?.name ?? "InterLude" }
        if status.muted { return "News muted" }
        return status.nowPlaying?.title ?? status.nowPlaying?.artist ?? onAirStation?.name ?? "Playing"
    }
    var subheadline: String {
        if isStarting, let p = source?.replay {
            return "Starting from \(p.start.formatted(date: .omitted, time: .shortened))…"
        }
        if isStarting { return "Starting about a minute behind live…" }
        guard isPlaying else {
            if mode == .earlier { return "Pick a programme to play from its start" }
            return "Ready to play on \(selectedOutput.label)"
        }
        if status.muted { return "Sound returns when the music does" }
        if let np = status.nowPlaying, np.title != nil { return np.artist }
        return "On \(selectedOutput.label)"
    }
    var artworkURL: URL? {
        isPlaying ? status.nowPlaying?.imageURL : isStarting ? source?.replay?.imageURL : (mode == .earlier ? replaying?.imageURL : nil)
    }

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
        // The panel is the web app, served by the same server as the stream, so it starts with the app.
        do { try ensureServer() } catch {
            serverError = "InterLude couldn't start its local server on port \(port): \(error.localizedDescription)"
        }
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
            if let st = selectedStation { source = (st, prog) }
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
    private func use(_ c: Catalogue) {
        let old = catalogue
        catalogue = c; stations = c.stations
        for s in c.stations where profiles[s.serviceId] == nil { profiles[s.serviceId] = StationProfile.load(s) }
        if selectedStation == nil, let first = c.stations.first {
            selectedStationID = first.serviceId
            replaying = nil; programmes = []
            if mode == .earlier { loadSchedule() }
        }
        guard let src = source, let old else { return }
        guard let now = c.station(src.station.serviceId) else {
            stop(); errorText = "\(src.station.name) was removed from the station list."; return
        }
        source = (now, src.replay)
        if c.playlistURL(now) != old.playlistURL(src.station) { restart() }
    }

    func profile(_ id: String) -> StationProfile { profiles[id] ?? StationProfile() }
    func updateProfile(_ id: String, _ f: (inout StationProfile) -> Void) {
        var p = profile(id); f(&p); profiles[id] = p
        if let s = stations.first(where: { $0.serviceId == id }) { p.save(s) }
        if isPlaying, id == source?.station.serviceId { Task { await session?.setLiveOptions(muteNews: p.muteNews, shadowMode: p.shadowMode) } }
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

    /// Starts what the panel shows: the chosen station live, or in Earlier the programme picked (the first playable
    /// one if none was).
    func start() { start(nil) }

    private func start(_ what: (station: Station, replay: Programme?)?) {
        guard let catalogue, !isStarting else { return }
        let station: Station, replay: Programme?
        if let what { (station, replay) = (catalogue.station(what.station.serviceId) ?? what.station, what.replay) }
        else {
            guard let st = selectedStation else { return }
            if mode == .earlier && replaying == nil {
                guard let p = programmes.first(where: { Self.canPlay($0) }) else { loadSchedule(); return }
                replaying = p
            }
            (station, replay) = (st, mode == .earlier ? replaying : nil)
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
        if let p = replay {
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
                isStarting = false; isPlaying = false; source = nil
                errorText = friendly(error, station: station)
                if error is CastError || output.isCast && !(error is FetchError) { castFailed = true } else { stationFailed = true }
                await tearDown()
            }
        }
    }

    /// Starts what was playing again, whichever view is showing.
    func restart() {
        let what = source
        Task { await tearDown(); isPlaying = false; isStarting = false; start(what) }
    }

    func stop() {
        isPlaying = false; isStarting = false; source = nil
        Task { await tearDown() }
    }

    private func tearDown() async {
        timer?.cancel(); timer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        castEvents?.cancel(); castEvents = nil
        player?.pause(); player = nil
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
            replaying = nil; programmes = []
            loadSchedule(); return
        }
        if isPlaying || isStarting { playLive(id) } else { selectedStationID = id }
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

    /// Plays an earlier programme of the chosen station from its start, stopping whatever is playing.
    func play(_ p: Programme) {
        guard Self.canPlay(p), let st = selectedStation else { return }
        replaying = p
        if isPlaying || isStarting { Task { await tearDown(); isPlaying = false; isStarting = false; start((st, p)) } } else { start((st, p)) }
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
        case .cast(let device):
            guard let ip = LocalServer.lanAddress() else { throw CastError.rejected("the Mac has no network address") }
            lastAddress = ip
            let c = DirectCastController(device: device)
            try await c.connect()
            try await c.load(url: try playlistURL(host: ip), title: settingsTitle(station))
            await c.setVolume(volume)
            cast = c
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
        if let p = source?.replay { return "\(p.title) · \(station.name)" }
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
                guard let self, self.isPlaying, let ip = LocalServer.lanAddress(), ip != self.lastAddress, let c = self.cast, let st = self.source?.station else { return }
                self.lastAddress = ip
                if let url = try? self.playlistURL(host: ip) { try? await c.load(url: url, title: self.settingsTitle(st)) }
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
                   let station = self.source?.station {
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
            if let st = onAirStation { profiles[st.serviceId] = StationProfile.load(st) }
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
        remoteAddress = LocalServer.tailscaleAddress() ?? LocalServer.lanAddress()
        refreshRemoteAddress()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshRemoteAddress() }
        }
        m.start(queue: .main); remoteMonitor = m
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

    /// The panel's page, only to this Mac, and the phone remote's, only while it is on.
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
        case .command(let c): perform(c, panel: panel); return RemoteRoutes.json(remoteState(panel: panel))
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
