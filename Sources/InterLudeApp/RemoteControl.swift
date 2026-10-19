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
        // The remote's Play button plays live, so an unstarted Earlier pick is not offered there.
        s.subheadline = mode == .earlier && !isPlaying && !isStarting ? "Ready to play on \(selectedOutput.label)" : subheadline
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
        return s
    }

    func perform(_ c: RemoteCommand) {
        switch c {
        case .toggle: if isPlaying || isStarting { stop() } else { playLive(selectedStationID) }
        case .station(let id): playLive(id)
        case .speaker(let id): if outputs.contains(where: { $0.id == id }) { switchOutput(to: id) }
        case .volume(let v): volume = v
        case .notNews: if isPlaying { notNews() }
        case .newsGotThrough: if isPlaying { newsGotThrough() }
        }
    }

    /// The app icon as a 512 px PNG for the phone's home screen: the icon's body without the macOS margin, on black
    /// so the phone's own rounded mask has nothing transparent to fill.
    static let remoteIcon: Data = {
        let side = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        // The macOS icon grid puts an 824 pt body in a 1024 pt canvas.
        let full = CGFloat(side) * 1024 / 824, inset = (full - CGFloat(side)) / 2
        NSApp.applicationIconImage?.draw(in: NSRect(x: -inset, y: -inset, width: full, height: full))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }()
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
