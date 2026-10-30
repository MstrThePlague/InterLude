import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import InterLudeCore
import InterLudeApple

/// What the web app shows and does, in the Mac's own panel (`panel`) and on the phone remote. The page is served by
/// the local server from `webFiles`.
extension AppModel {
    /// The web app: from a `web` folder in Application Support if one is there, for trying changes without a rebuild,
    /// otherwise the app's own copy (or the checkout's, when run with `swift run`).
    static let webFiles = WebFiles(folders: [
        try? AppPaths.supportDirectory().appendingPathComponent("web", isDirectory: true),
        Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true),
        URL(fileURLWithPath: "Web", isDirectory: true),
    ].compactMap { $0 })

    func remoteState(panel: Bool = false) -> RemoteState {
        var s = RemoteState()
        s.state = playState.rawValue
        s.stationName = statusCaption
        s.headline = headline
        s.subheadline = subheadline
        // In Earlier, the remote's Play button replays the programme last picked, or plays live if none was.
        if mode == .earlier && !isPlaying && !isStarting, let p = replaying, Self.canPlay(p) {
            s.subheadline = "Play starts \(p.title) from \(p.start.formatted(date: .omitted, time: .shortened))"
        }
        s.artwork = artworkURL?.absoluteString
        s.error = errorText
        s.playing = isPlaying || isStarting
        s.volume = volume
        s.muted = isPlaying && status.muted
        s.muteElapsed = status.muteElapsed
        s.muteStartsIn = status.muteStartsIn
        s.justSkipped = status.replay?.justSkipped
        s.canCorrect = isPlaying && onAirStation?.kind != .speech
        s.note = learnedNote
        s.footer = isPlaying ? footerText : nil
        s.station = selectedStationID
        if let id = source?.station.serviceId, id != selectedStationID { s.onAir = id }
        s.offerLive = offersLive
        s.speaker = selectedOutputID
        s.stations = orderedStations.map {
            .init(id: $0.serviceId, name: $0.name, short: $0.short, colour: $0.colour, group: $0.group, favourite: profile($0.serviceId).favourite)
        }
        let speakers = outputs.filter { if case .cast(let d) = $0 { !d.isGroup } else { false } }
        let groups = outputs.filter { if case .cast(let d) = $0 { d.isGroup } else { false } }
        s.speakers = ([Output.thisMac] + speakers + groups).map { o in
            let kind = switch o { case .thisMac: "mac"; case .cast(let d): d.isGroup ? "group" : "speaker" }
            return .init(id: o.id, name: o.label, detail: o.detail, kind: kind)
        }
        switch discoveryState {
        case .searching: s.speakerNote = "Looking for speakers…"
        case .denied: s.speakerNote = "To find speakers, allow Local Network for InterLude on the Mac in System Settings › Privacy & Security."
        case .ready: if speakers.isEmpty && groups.isEmpty { s.speakerNote = "No Chromecast speakers found." }
        }
        s.mode = mode.rawValue
        s.pageVersion = Self.webFiles.version
        if mode == .earlier { s.earlier = remoteEarlier() }
        if isReplay, let r = status.replay { s.replay = remoteReplay(r) }
        s.news = .describe(profile(selectedStationID), kind: selectedStation?.kind, earlier: isReplay || (mode == .earlier && !isPlaying && !isStarting),
                           ambience: ambience)
        if isPlaying && !status.recentBlocks.isEmpty {
            s.recentTitle = isReplay ? "News in this programme" : "Recent mutes"
            s.recent = RemoteState.RecentItem.list(status.recentBlocks)
        }
        if errorText != nil && !isPlaying && !isStarting {
            s.recover = (castFailed ? ["here"] : []) + (castFailed || stationFailed ? ["retry"] : [])
        }
        s.welcome = panel && showWelcome && !demoHidesWelcome
        s.settings = remoteSettings(panel: panel)
        return s
    }

    /// Settings for the chosen station. The phone remote gets the shared ones; the panel also gets the Mac's own and
    /// the phone remote's link, which a phone could otherwise reset from under itself.
    private func remoteSettings(panel: Bool) -> RemoteState.SettingsItem {
        let st = selectedStation, p = profile(selectedStationID), music = st?.kind == .music
        let link = panel ? remoteURL?.absoluteString ?? "" : ""
        var item = RemoteState.SettingsItem(
            stationName: st?.name ?? selectedStationID, delay: p.delaySeconds, muteNews: p.muteNews, jingleOnly: p.detector.identOnly,
            shadowMode: p.shadowMode, jingle: p.jingleStatus, canForgetJingle: !p.idents.isEmpty || !p.candidates.isEmpty, newsNote: nil,
            bitrate: bitrate / 1000, ambience: ambience, ambienceChoices: Self.ambienceChoices.map { [$0.id, $0.name] }, link: link,
            qr: link.isEmpty ? nil : "qr.png", maxMute: music ? p.detector.maxMuteSeconds / 60 : nil,
            slots: music ? p.detector.slotMinutes.map(String.init).joined(separator: ", ") : nil)
        if panel {
            let note: String?
            if !remoteEnabled { note = nil }
            else if let e = remoteError { note = e }
            else if remoteURL == nil { note = "Connect this Mac to Wi-Fi or Ethernet to use the remote." }
            else if remoteOnTailscale { note = "The link uses Tailscale, so the phone needs Tailscale on. The Mac must be awake with InterLude open." }
            else { note = "The phone needs to be on the same Wi-Fi as this Mac, and the Mac awake with InterLude open." }
            item.mac = .init(startAtLogin: startAtLogin, keepAwake: keepAwake, port: port, remote: remoteEnabled, remoteNote: note)
        }
        return item
    }

    /// The phone remote's link as a QR code.
    func remoteQR() -> HTTPResponse {
        guard let url = remoteURL, let img = qrImage(for: url.absoluteString), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return .notFound }
        return HTTPResponse(contentType: "image/png", body: png, noCache: true)
    }

    /// The day's programmes as the panel's list shows them.
    private func remoteEarlier() -> RemoteState.EarlierItem {
        var e = RemoteState.EarlierItem()
        e.day = scheduleDay
        e.dayTitle = scheduleDayTitle
        switch scheduleState {
        case .loading: e.loading = programmes.isEmpty
        case .failed(let m): if programmes.isEmpty { e.problem = m }
        case .idle: break
        }
        let now = Date(), playingID = isReplay ? source?.replay?.id : nil
        e.programmes = programmes.map { p in
            let playable = Self.canPlay(p), onNow = p.end > now, chosen = replaying?.id == p.id
            let length = Self.duration(p.end.timeIntervalSince(p.start))
            return .init(id: p.id, title: p.title, detail: playable ? (p.subtitle ?? length) : (onNow ? "On now" : "Not available"),
                         time: p.start.formatted(date: .omitted, time: .shortened), image: p.imageURL?.absoluteString,
                         playable: playable, onNow: onNow, chosen: chosen, playing: playingID == p.id)
        }
        return e
    }

    /// How far into the programme the listener is, as the panel's progress bar shows it.
    private func remoteReplay(_ r: ReplayStatus) -> RemoteState.ReplayItem {
        let p = r.programme
        let total = max(1, p.end.timeIntervalSince(p.start))
        func x(_ d: Date) -> Double { min(1, max(0, d.timeIntervalSince(p.start) / total)) }
        let skipped = r.skipCount > 0 ? "\(r.skipCount) bulletin\(r.skipCount == 1 ? "" : "s") skipped · \(clock(r.skippedSeconds))" : nil
        return .init(heard: x(r.heard), analysed: x(r.analysedThrough), news: r.news.map { [x($0.lowerBound), x($0.upperBound)] },
                     position: "\(clock(r.heard.timeIntervalSince(p.start))) of \(Self.duration(total))", skipped: skipped)
    }

    /// Does what the page asked. A phone can't change the Mac's own settings, save diagnostics, quit, or reset its link.
    func perform(_ c: RemoteCommand, panel: Bool = false) {
        if !panel { if c.macOnly || c == .resetLink { return } }
        switch c {
        case .toggle:
            if isPlaying || isStarting { stop() }
            else if mode == .earlier, let p = replaying, Self.canPlay(p) { play(p) }
            else { playLive(selectedStationID) }
        case .play: if !isPlaying && !isStarting { perform(.toggle) }
        case .station(let id):
            // In Earlier a station shows its schedule, as on the Mac; in Live it plays.
            if mode == .earlier { if stations.contains(where: { $0.serviceId == id }) { switchStation(to: id) } }
            else { playLive(id) }
        case .speaker(let id): if outputs.contains(where: { $0.id == id }) { switchOutput(to: id) }
        case .volume(let v): volume = v
        case .notNews: if isPlaying { notNews() }
        case .newsGotThrough: if isPlaying { newsGotThrough() }
        case .earlier(let on): mode = on ? .earlier : .live
        case .day(let d): if mode == .earlier { scheduleDay = d }
        case .reloadSchedule: if mode == .earlier { loadSchedule(force: true) }
        case .programme(let id): if mode == .earlier, let p = programmes.first(where: { $0.id == id }) { play(p) }
        case .setting(let s): apply(s)
        case .resetLink: resetRemoteLink()
        case .favourite(let id): if stations.contains(where: { $0.serviceId == id }) { updateProfile(id) { $0.favourite.toggle() } }
        case .wrong(let id): if let u = UUID(uuidString: id) { markWrong(u) }
        case .welcomed: showWelcome = false
        case .diagnostics: exportDiagnostics()
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    private func apply(_ s: RemoteSetting) {
        let id = selectedStationID
        switch s {
        case .delay(let d):
            updateProfile(id) { $0.delaySeconds = d }
            if isPlaying && !isReplay && source?.station.serviceId == id { restart() }
        case .muteNews(let on): updateProfile(id) { $0.muteNews = on }
        case .jingleOnly(let on): updateProfile(id) { $0.detector.identOnly = on }
        case .shadowMode(let on): updateProfile(id) { $0.shadowMode = on }
        case .forgetJingle: updateProfile(id) { $0.idents = []; $0.candidates = []; $0.candidateSources = [] }
        case .bitrate(let b):
            guard b != bitrate else { return }
            bitrate = b
            if isPlaying { restart() }
        case .ambience(let a): ambience = a
        case .maxMute(let m): updateProfile(id) { $0.detector.maxMuteSeconds = m * 60 }
        case .slots(let mins): updateProfile(id) { $0.detector.slotMinutes = mins }
        case .startAtLogin(let on): setStartAtLogin(on)
        case .keepAwake(let on): keepAwake = on
        case .port(let p): port = p
        case .remote(let on): remoteEnabled = on
        }
    }

    /// Asks where to save a zip of the event log, station list and profiles.
    func exportDiagnostics() {
        guard let folder = diagnosticsFolder() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "InterLude-diagnostics.zip"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &err) { zip in
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: zip, to: dest)
        }
    }

    /// The app icon as a 512 px PNG for the manifest and `icon.png`.
    static let remoteIcon = remoteIconPNG(side: 512)
    /// The 180 px Home Screen icon. iOS 27 ignores a fetched apple-touch-icon, so the page carries this one inline.
    static let remoteTouchIcon = remoteIconPNG(side: 180)

    /// The icon's body without the macOS margin, on black with no alpha channel, so the phone's own rounded mask
    /// has nothing transparent to fill.
    private static func remoteIconPNG(side: Int) -> Data {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // The macOS icon grid puts an 824 pt body in a 1024 pt canvas.
        let full = CGFloat(side) * 1024 / 824, inset = (full - CGFloat(side)) / 2
        NSApp.applicationIconImage?.draw(in: NSRect(x: -inset, y: -inset, width: full, height: full))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = cg.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}

/// A QR code for a link, drawn crisp at any size.
func qrImage(for text: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
}

/// Minutes and seconds, such as 6:11.
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}
