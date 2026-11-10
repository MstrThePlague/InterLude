//  RemoteControl.swift
//  InterLude (the Mac app)
//
//  The Mac's side of the web app: what the panel and the phone remote show (`remoteState`) and what they can do
//  (`perform`), plus the remote's QR code and icons.

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

    /// Everything the web app shows.
    ///
    /// - Parameter panel: Whether the page is the Mac's own panel, which also gets the Mac's settings and the
    ///   first-run note.
    func remoteState(panel: Bool = false) -> RemoteState {
        var state = RemoteState()
        state.state = playState.rawValue
        state.stationName = statusCaption
        state.headline = headline
        state.subheadline = subheadline
        // In Earlier, Play replays the programme last picked, or plays live if none was.
        if mode == .earlier && !isPlaying && !isStarting, let programme = replaying, programme.canPlay {
            let offset = bookmarks.offset(for: programme)
            state.subheadline = Wording.playStarts(programme, at: offset)
            if offset > 0 { state.resumeAt = Wording.clock(offset) }
        }
        state.startProgress = isStarting ? startProgress : nil
        state.artwork = artworkURL?.absoluteString
        state.error = errorText
        state.playing = isPlaying || isStarting
        state.volume = volume
        state.muted = isPlaying && status.muted
        state.muteElapsed = status.muteElapsed
        state.muteStartsIn = status.muteStartsIn
        state.justSkipped = status.replay?.justSkipped
        state.canCorrect = isPlaying && onAirStation?.mutesNews == true
        state.note = learnedNote
        state.footer = isPlaying ? footerText : nil
        state.station = selectedStationID
        if let id = source?.station.serviceId, id != selectedStationID { state.onAir = id }
        state.offerLive = offersLive
        state.speaker = selectedOutputID
        state.stations = profiles.items(stations)
        let speakers = outputs.filter { $0.isSpeaker && !$0.isGroup }
        let groups = outputs.filter { $0.isSpeaker && $0.isGroup }
        state.speakers = ([Output.thisMac] + speakers + groups).map { output in
            let kind = output.isSpeaker ? (output.isGroup ? "group" : "speaker") : "mac"
            return .init(id: output.id, name: output.label, detail: output.detail, kind: kind)
        }
        switch discoveryState {
        case .searching: state.speakerNote = "Looking for speakers…"
        case .denied: state.speakerNote = "To find speakers, allow Local Network for InterLude on the Mac in System Settings › Privacy & Security."
        case .ready: if speakers.isEmpty && groups.isEmpty { state.speakerNote = "No Chromecast or Sonos speakers found." }
        }
        state.mode = mode.rawValue
        state.pageVersion = Self.webFiles.version
        if mode == .earlier {
            state.earlier = schedule.item(chosen: replaying, playing: isReplay ? source?.replay : nil)
        }
        if isReplay, let progress = status.replay { state.replay = .describe(progress) }
        state.news = .describe(profile(selectedStationID), kind: selectedStation?.kind, hasNews: selectedStation?.news != false, earlier: isReplay || (mode == .earlier && !isPlaying && !isStarting),
                               ambience: ambience)
        let onAirProfile = profile(onAirStation?.serviceId ?? selectedStationID)
        if isPlaying && !status.recentBlocks.isEmpty {
            state.recentTitle = RemoteState.RecentItem.title(replay: isReplay, shadow: onAirProfile.shadowMode)
            state.recent = RemoteState.RecentItem.list(status.recentBlocks)
        }
        if isPlaying && !isReplay { state.learning = .describe(station: onAirStation, profile: onAirProfile, blocks: status.recentBlocks) }
        if errorText != nil && !isPlaying && !isStarting {
            state.recover = (castFailed ? ["here"] : []) + (castFailed || stationFailed ? ["retry"] : [])
        }
        state.welcome = panel && showWelcome && !demoHidesWelcome
        state.settings = remoteSettings(panel: panel)
        return state
    }

    /// Settings for the chosen station. The phone remote gets the shared ones; the panel also gets the Mac's own and
    /// the phone remote's link, which a phone could otherwise reset from under itself.
    private func remoteSettings(panel: Bool) -> RemoteState.SettingsItem {
        let link = panel ? remoteURL?.absoluteString ?? "" : ""
        var item = RemoteState.SettingsItem.describe(station: selectedStation, id: selectedStationID, profile: profile(selectedStationID),
                                                     newsNote: nil, bitrate: bitrate, ambience: ambience, link: link,
                                                     qr: link.isEmpty ? nil : "qr.png")
        if panel {
            let note: String?
            if !remoteEnabled { note = nil }
            else if let error = remoteError { note = error }
            else if remoteURL == nil { note = "Connect this Mac to Wi-Fi or Ethernet to use the remote." }
            else if remoteOnTailscale { note = "The link uses Tailscale, so the phone needs Tailscale on. The Mac must be awake with InterLude open." }
            else { note = "The phone needs to be on the same Wi-Fi as this Mac, and the Mac awake with InterLude open." }
            item.mac = .init(startAtLogin: startAtLogin, keepAwake: keepAwake, port: port, remote: remoteEnabled, remoteNote: note)
        }
        return item
    }

    /// The phone remote's link as a QR code.
    func remoteQR() -> HTTPResponse {
        guard let url = remoteURL, let image = qrImage(for: url.absoluteString), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return .notFound }
        return HTTPResponse(contentType: "image/png", body: png, noCache: true)
    }

    /// Does what the page asked. A phone can't change the Mac's own settings, save diagnostics, quit, or reset its link.
    func perform(_ command: RemoteCommand, panel: Bool = false) {
        if !panel && (command.macOnly || command == .resetLink) { return }
        switch command {
        case .toggle:
            if isPlaying || isStarting { stop() }
            else if mode == .earlier, let programme = replaying, programme.canPlay { play(programme) }
            else { playLive(selectedStationID) }
        case .play: if !isPlaying && !isStarting { perform(.toggle) }
        case .station(let id):
            // In Earlier a station shows its schedule, as on the Mac; in Live it plays.
            if mode == .earlier { if stations.contains(where: { $0.serviceId == id }) { switchStation(to: id) } }
            else { playLive(id) }
        case .speaker(let id): if outputs.contains(where: { $0.id == id }) { switchOutput(to: id) }
        case .volume(let level): volume = level
        case .notNews: if isPlaying { notNews() }
        case .newsGotThrough: if isPlaying { newsGotThrough() }
        case .earlier(let on): mode = on ? .earlier : .live
        case .day(let day): if mode == .earlier { scheduleDay = day }
        case .reloadSchedule: if mode == .earlier { loadSchedule(force: true) }
        case .programme(let id): if mode == .earlier, let programme = programmes.first(where: { $0.id == id }) { play(programme) }
        case .seek(let fraction): if isReplay, let programme = source?.replay { play(from: ReplayBookmarks.offset(at: fraction, in: programme)) }
        case .startOver: if isReplay || (mode == .earlier && replaying != nil) { play(from: 0) }
        case .startMuting: if let station = onAirStation { updateProfile(station.serviceId, RemoteSetting.startMuting) }
        case .setting(let setting): apply(setting)
        case .resetLink: resetRemoteLink()
        case .favourite(let id): if stations.contains(where: { $0.serviceId == id }) { updateProfile(id) { $0.favourite.toggle() } }
        case .wrong(let id): if let block = UUID(uuidString: id) { markWrong(block) }
        case .welcomed: showWelcome = false
        case .diagnostics: exportDiagnostics()
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    /// Applies a change from the Settings sheet to the chosen station, restarting the session when it must.
    private func apply(_ setting: RemoteSetting) {
        let id = selectedStationID
        if let change = setting.profileChange {
            updateProfile(id, change)
            guard source?.station.serviceId == id else { return }
            if case .forgetJingle = setting { forgetJingleInSession() }
            if case .delay = setting, isPlaying, !isReplay { restart() }
            return
        }
        switch setting {
        case .bitrate(let newBitrate):
            guard newBitrate != bitrate else { return }
            bitrate = newBitrate
            if isPlaying { restart() }
        case .ambience(let sound): ambience = sound
        case .delay, .muteNews, .jingleOnly, .shadowMode, .forgetJingle, .maxMute, .slots: break    // per station, above
        case .startAtLogin(let on): setStartAtLogin(on)
        case .keepAwake(let on): keepAwake = on
        case .port(let newPort): port = newPort
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
        var error: NSError?
        // Reading for uploading hands back a zip of the folder.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zip in
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
        guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: colourSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // The macOS icon grid puts an 824 pt body in a 1024 pt canvas.
        let full = CGFloat(side) * 1024 / 824, inset = (full - CGFloat(side)) / 2
        NSApp.applicationIconImage?.draw(in: NSRect(x: -inset, y: -inset, width: full, height: full))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}

/// A QR code for a link, drawn crisp at any size.
func qrImage(for text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    // Scale each module to 10 pixels without smoothing, so it stays sharp.
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let image = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: out.extent.width, height: out.extent.height))
}
