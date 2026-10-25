import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import InterLudeCore

/// What the phone remote sees and does. The page is served by the local server; see `RemotePage`.
extension AppModel {
    func remoteState() -> RemoteState {
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
        s.canCorrect = isPlaying && selectedStation?.kind != .speech
        s.note = learnedNote
        s.footer = isPlaying ? footerText : nil
        s.station = selectedStationID
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
        if mode == .earlier { s.earlier = remoteEarlier() }
        if isReplay, let r = status.replay { s.replay = remoteReplay(r) }
        return s
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
        let now = Date()
        e.programmes = programmes.map { p in
            let playable = Self.canPlay(p), onNow = p.end > now, chosen = replaying?.id == p.id
            let length = Self.duration(p.end.timeIntervalSince(p.start))
            return .init(id: p.id, title: p.title, detail: playable ? (p.subtitle ?? length) : (onNow ? "On now" : "Not available"),
                         time: p.start.formatted(date: .omitted, time: .shortened), image: p.imageURL?.absoluteString,
                         playable: playable, onNow: onNow, chosen: chosen, playing: chosen && isReplay)
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

    func perform(_ c: RemoteCommand) {
        switch c {
        case .toggle:
            if isPlaying || isStarting { stop() }
            else if mode == .earlier, let p = replaying, Self.canPlay(p) { play(p) }
            else { playLive(selectedStationID) }
        case .station(let id):
            // In Earlier a station shows its schedule, as on the Mac; in Live it plays.
            if mode == .earlier { if id != selectedStationID, stations.contains(where: { $0.serviceId == id }) { switchStation(to: id) } }
            else { playLive(id) }
        case .speaker(let id): if outputs.contains(where: { $0.id == id }) { switchOutput(to: id) }
        case .volume(let v): volume = v
        case .notNews: if isPlaying { notNews() }
        case .newsGotThrough: if isPlaying { newsGotThrough() }
        case .earlier(let on): mode = on ? .earlier : .live
        case .day(let d): if mode == .earlier { scheduleDay = d }
        case .reloadSchedule: if mode == .earlier { loadSchedule(force: true) }
        case .programme(let id): if mode == .earlier, let p = programmes.first(where: { $0.id == id }) { play(p) }
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
