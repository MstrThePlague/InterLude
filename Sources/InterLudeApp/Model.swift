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

    // Settings
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    var bitrate: Int { didSet { UserDefaults.standard.set(bitrate, forKey: "bitrate") } }
    var keepAwake: Bool { didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateActivity() } }
    var startAtLogin: Bool = false

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
    var showRecent: Bool { didSet { UserDefaults.standard.set(showRecent, forKey: "showRecent") } }
    func jingleStatus(_ id: String) -> String {
        let p = profile(id)
        if !p.idents.isEmpty { return "Learned" }
        return p.candidates.isEmpty ? "Not learned yet" : "Learning: \(p.candidates.count) of 3"
    }
    var learnedNote: String? {
        let n = profile(selectedStationID).candidates.count
        let learned = !profile(selectedStationID).idents.isEmpty
        return learned ? "News jingle learned" : (n > 0 ? "Learning jingle: \(n) of 3" : nil)
    }
    var delayDescription: String { "About \(Int((status.delaySeconds / 5).rounded()) * 5) seconds" }
    var muteSubtitle: String {
        let p = profile(selectedStationID)
        if selectedStation?.kind == .speech { return "Off for speech stations, where talk is the programme." }
        if p.shadowMode { return "Shadow mode: bulletins are noted but not muted." }
        if !p.muteNews { return "Off. Bulletins will play." }
        return p.detector.identOnly ? "Mutes when the station's news jingle plays." : "Silences bulletins until the music returns."
    }
    var footerText: String { "\(delayDescription) behind live" }

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
    private let token: String

    var selectedStation: Station? { stations.first { $0.serviceId == selectedStationID } }
    var selectedOutput: Output { outputs.first { $0.id == selectedOutputID } ?? .thisMac }

    init() {
        let d = UserDefaults.standard
        selectedStationID = d.string(forKey: "station") ?? "bbc_6music"
        selectedOutputID = d.string(forKey: "output") ?? "mac"
        volume = d.object(forKey: "volume") as? Double ?? 0.7
        port = d.object(forKey: "port") as? Int ?? 8642
        bitrate = d.object(forKey: "bitrate") as? Int ?? 320_000
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        showWelcome = !d.bool(forKey: "welcomeDismissed")
        showRecent = d.bool(forKey: "showRecent")
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--token"), i + 1 < args.count { token = args[i + 1] }     // for testing
        else if let t = d.string(forKey: "token") { token = t } else {
            token = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            d.set(token, forKey: "token")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
        loadCatalogue()
        startDiscovery()
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
        case "casterror": errorText = "Cast connection lost. Kitchen B&W Speaker stopped responding."; castFailed = true
        case "upcoming": isPlaying = true; status.muteStartsIn = 38
        case "welcome": showWelcome = true
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
                }
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
        errorText = nil; stationFailed = false; castFailed = false; notifiedFailure = false
        isStarting = true; shownNotices = 0
        if !askedForNotifications {
            askedForNotifications = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        let output = selectedOutput
        var settings = SessionSettings(station: station, profile: profile(station.serviceId))
        settings.bitrate = bitrate
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

    func switchStation(to id: String) {
        selectedStationID = id
        if isPlaying || isStarting { Task { await tearDown(); isPlaying = false; isStarting = false; start() } }
    }

    private func ensureServer() throws {
        if server != nil { return }
        let t = token, h = holder
        let s = LocalServer(port: UInt16(port)) { path in
            let prefix = "/\(t)/"
            guard path.hasPrefix(prefix) else { return .notFound }
            return await h.respond(String(path.dropFirst(prefix.count)))
        }
        try s.start()
        server = s
    }

    private func playlistURL(host: String) -> URL { URL(string: "http://\(host):\(port)/\(token)/live.m3u8")! }

    private func startOutput(_ output: Output, station: Station) async throws {
        switch output {
        case .thisMac:
            let p = AVPlayer(url: playlistURL(host: "127.0.0.1"))
            p.automaticallyWaitsToMinimizeStalling = true
            p.volume = Float(volume); p.play(); player = p
        case .cast(let device):
            guard let ip = LocalServer.lanAddress() else { throw CastError.rejected("the Mac has no network address") }
            lastAddress = ip
            let c = DirectCastController(device: device)
            try await c.connect()
            try await c.load(url: playlistURL(host: ip), title: station.name)
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
        guard case .cast(let device) = selectedOutput else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, let ip = LocalServer.lanAddress(), ip != self.lastAddress, let c = self.cast, let st = self.selectedStation else { return }
                self.lastAddress = ip
                try? await c.load(url: self.playlistURL(host: ip), title: st.name)
                _ = device
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
                self.status = st
                if st.notices.count > self.shownNotices {
                    for n in st.notices[self.shownNotices...] where n.contains("longest mute") || n.contains("failed") { self.notify("InterLude", n) }
                    self.shownNotices = st.notices.count
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

    func thatWasNews() {
        Task {
            await session?.thatWasNews()
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
