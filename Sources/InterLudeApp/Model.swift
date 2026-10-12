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
    var label: String {
        switch self {
        case .thisMac: "This Mac"
        case .cast(let d): d.isGroup ? "\(d.name) (group)" : d.name
        }
    }
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
    var statusLine: String {
        if let e = errorText { return e }
        if isStarting { return "Starting…" }
        guard isPlaying else { return "Stopped." }
        let p = profile(selectedStationID)
        let mute = p.shadowMode ? "Shadow mode: logging only." : ((p.muteNews && selectedStation?.kind != .speech) ? "News muting on." : "News muting off.")
        return "About \(Int((status.delaySeconds / 5).rounded()) * 5) seconds behind live. \(mute)"
    }
    var menuIcon: String { status.muted && isPlaying ? "speaker.slash.fill" : (isPlaying ? "dot.radiowaves.left.and.right" : "radio") }

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
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--token"), i + 1 < args.count { token = args[i + 1] }     // for testing
        else if let t = d.string(forKey: "token") { token = t } else {
            token = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            d.set(token, forKey: "token")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
        loadCatalogue()
        startDiscovery()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        if CommandLine.arguments.contains("--autoplay") { start() }
    }

    // MARK: Catalogue and profiles

    private func loadCatalogue() {
        let bundled = Bundle.main.url(forResource: "stations", withExtension: "json") ?? URL(fileURLWithPath: "Data/stations.json")
        do {
            let url = try Catalogue.editableURL(bundled: bundled)
            let c = try Catalogue.load(from: url)
            catalogue = c; stations = c.stations
            for s in c.stations { profiles[s.serviceId] = StationProfile.load(s) }
        } catch { errorText = "Could not read the station list: \(error.localizedDescription)" }
    }

    func profile(_ id: String) -> StationProfile { profiles[id] ?? StationProfile() }
    func updateProfile(_ id: String, _ f: (inout StationProfile) -> Void) {
        var p = profile(id); f(&p); profiles[id] = p
        if let s = stations.first(where: { $0.serviceId == id }) { p.save(s) }
        if isPlaying, id == selectedStationID { Task { await session?.setMuteNews(p.muteNews) } }
    }
    var orderedStations: [Station] {
        stations.sorted { (profile($0.serviceId).favourite ? 0 : 1, $0.name) < (profile($1.serviceId).favourite ? 0 : 1, $1.name) }
    }

    // MARK: Cast discovery

    private func startDiscovery() {
        let d = CastDiscovery(); d.start(); discovery = d
        Task { [weak self] in
            for await devices in d.updates {
                guard let self else { return }
                let casts = devices.map { Output.cast($0) }
                self.outputs = [.thisMac] + casts
            }
        }
    }

    // MARK: Playback

    func togglePlay() { if isPlaying || isStarting { stop() } else { start() } }

    func start() {
        guard let catalogue, let station = selectedStation, !isStarting else { return }
        errorText = nil; isStarting = true; shownNotices = 0
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
                notify("Station stream failed", errorText ?? "")
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
        errorText = "\(title). \(body)"; notify(title, body); stop()
    }

    private func applyVolume() {
        player?.volume = Float(volume)
        if let c = cast { Task { await c.setVolume(volume) } }
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
                if case .failed(let m) = st.state { self.errorText = m; self.notify("Station stream failed", m) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func thatWasNews() { Task { await session?.thatWasNews(); if let id = session { _ = id }; refreshProfile() } }
    func notNews() { Task { await session?.notNews() } }
    func markWrong(_ id: UUID) { Task { await session?.markWrong(id: id) } }

    private func refreshProfile() {
        Task { if let p = await session?.profile() { profiles[selectedStationID] = p } }
    }

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
