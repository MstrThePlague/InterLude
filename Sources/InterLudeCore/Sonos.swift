//  Sonos.swift
//  InterLudeCore
//
//  Sonos speakers are controlled with UPnP: SOAP requests to port 1400 on the speaker. They can't play HLS, so they
//  are given InterLude's AAC stream (`AACStream`) as an internet radio station. Speakers are found by their
//  `_sonos._tcp` Bonjour service, and any one of them describes the whole household: its rooms and how they are
//  grouped.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Sonos room, or rooms grouped in the Sonos app, which play as one. Sound is sent to the group's coordinator.
public struct SonosGroup: Sendable, Hashable, Identifiable {
    /// The coordinator's UUID, such as `RINCON_000000000000001400`.
    public var id: String
    /// The rooms in the group, the coordinator first.
    public var rooms: [String]
    /// The coordinator's address.
    public var host: String
    public var port: Int
    public init(id: String, rooms: [String], host: String, port: Int = Sonos.port) {
        self.id = id; self.rooms = rooms; self.host = host; self.port = port
    }
    public var isGroup: Bool { rooms.count > 1 }
    /// The name the Sonos app gives a group, such as "Kitchen + 2".
    public var name: String { rooms.count > 1 ? "\(rooms[0]) + \(rooms.count - 1)" : rooms.first ?? "Sonos" }
    /// "Sonos", with the rooms listed for a group.
    public var detail: String { rooms.count > 1 ? "Sonos: " + rooms.joined(separator: ", ") : "Sonos" }
}

/// Why a Sonos speaker couldn't play.
public enum SonosError: Error, LocalizedError {
    case unreachable(String), refused(String, Int?), cannotOpen(String)
    public var errorDescription: String? {
        switch self {
        case .unreachable(let name): "\(name) did not answer."
        case .refused(let name, let code): "\(name) refused the stream\(code.map { " (UPnP error \($0))" } ?? "")."
        case .cannotOpen(let name):
            "\(name) couldn't open the stream. It has to reach InterLude's port on this computer: check for a firewall here, or between networks."
        }
    }
}

/// Talking to Sonos speakers.
public enum Sonos {
    /// The Bonjour service Sonos speakers advertise.
    public static let service = "_sonos._tcp"
    /// The port a speaker answers UPnP on.
    public static let port = 1400

    /// The household's groups, asked of the first of `hosts` that answers.
    ///
    /// - Returns: The groups sorted by name, or none if no speaker answered.
    public static func groups(hosts: [String]) async -> [SonosGroup] {
        for host in hosts {
            if let body = try? await call(host: host, port: port, .topology, "GetZoneGroupState", [:]) { return parseTopology(body) }
        }
        return []
    }

    // MARK: SOAP

    /// The UPnP services InterLude uses.
    enum Service {
        case avTransport, groupRendering, topology
        var path: String {
            switch self {
            case .avTransport: "/MediaRenderer/AVTransport/Control"
            case .groupRendering: "/MediaRenderer/GroupRenderingControl/Control"
            case .topology: "/ZoneGroupTopology/Control"
            }
        }
        var urn: String {
            switch self {
            case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
            case .groupRendering: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
            case .topology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
            }
        }
    }

    static let session = URLSession(configuration: .ephemeral)

    /// Sends one SOAP action.
    ///
    /// - Parameters:
    ///   - host: The speaker's address.
    ///   - port: Its UPnP port.
    ///   - service: The service the action belongs to.
    ///   - action: The action's name, such as `Play`.
    ///   - args: The action's arguments, written in the order given.
    ///   - timeout: [s]
    /// - Returns: The response body.
    /// - Throws: `SonosError.refused` with the UPnP error code when the speaker answers with an error.
    @discardableResult
    static func call(host: String, port: Int, _ service: Service, _ action: String, _ args: KeyValuePairs<String, String>,
                     timeout: Double = 6) async throws -> String {
        guard let url = URL(string: "http://\(host):\(port)\(service.path)") else { throw SonosError.unreachable(host) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope(service, action, args).utf8)
        let (data, response) = try await session.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SonosError.refused(host, errorCode(body)) }
        return body
    }

    /// The SOAP envelope for an action.
    static func envelope(_ service: Service, _ action: String, _ args: KeyValuePairs<String, String>) -> String {
        let inner = args.map { "<\($0.key)>\(escape($0.value))</\($0.key)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(inner)</u:\(action)></s:Body></s:Envelope>"
    }

    /// The address a speaker plays an internet radio stream from: the stream's own, with Sonos's scheme for radio.
    static func radioURI(_ url: URL) -> String {
        "x-rincon-mp3radio://" + url.absoluteString.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
    }

    /// The DIDL-Lite description that makes the Sonos app show `title` as a radio station.
    static func radioMetadata(title: String) -> String {
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" "
            + "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
            + "<item id=\"R:0/0/0\" parentID=\"R:0/0\" restricted=\"true\"><dc:title>\(escape(title))</dc:title>"
            + "<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>"
            + "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON65031_</desc></item></DIDL-Lite>"
    }

    // MARK: XML

    /// Escapes text for an XML element or attribute.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Undoes `escape`, and `&apos;`. Ampersands go last, so `&amp;lt;` becomes `&lt;` rather than `<`.
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The text of the first `<name>` element in `xml`, unescaped.
    static func value(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return unescape(String(xml[open.upperBound..<close.lowerBound]))
    }

    /// The UPnP error code in a SOAP fault, if any.
    static func errorCode(_ body: String) -> Int? { value("errorCode", in: body).flatMap { Int($0) } }

    /// The attributes of each `<name …>` tag in `xml`, in order, with their values unescaped.
    static func tags(_ name: String, in xml: Substring) -> [[String: String]] {
        var found: [[String: String]] = []
        var rest = xml[...]
        while let start = rest.range(of: "<\(name) "), let end = rest[start.upperBound...].firstIndex(of: ">") {
            var attributes: [String: String] = [:]
            var remaining = rest[start.upperBound..<end]
            while let equals = remaining.range(of: "=\""), let close = remaining[equals.upperBound...].firstIndex(of: "\"") {
                let key = remaining[..<equals.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                attributes[key] = unescape(String(remaining[equals.upperBound..<close]))
                remaining = remaining[remaining.index(after: close)...]
            }
            found.append(attributes)
            rest = rest[end...]
        }
        return found
    }

    /// Reads the answer to GetZoneGroupState.
    ///
    /// Hidden members (the second speaker of a stereo pair) and bridges are left out.
    ///
    /// - Returns: The groups, sorted by name.
    static func parseTopology(_ soap: String) -> [SonosGroup] {
        guard let state = value("ZoneGroupState", in: soap) else { return [] }
        var groups: [SonosGroup] = []
        var rest = state[...]
        while let start = rest.range(of: "<ZoneGroup ") {
            let end = rest.range(of: "</ZoneGroup>", range: start.upperBound..<rest.endIndex)?.upperBound ?? rest.endIndex
            let block = rest[start.lowerBound..<end]
            rest = rest[end...]
            guard let coordinator = tags("ZoneGroup", in: block).first?["Coordinator"] else { continue }
            let members = tags("ZoneGroupMember", in: block).filter { $0["Invisible"] != "1" && $0["IsZoneBridge"] != "1" }
            guard let lead = members.first(where: { $0["UUID"] == coordinator }),
                  let location = lead["Location"].flatMap(URLComponents.init(string:)), let host = location.host else { continue }
            let rooms = [lead] + members.filter { $0["UUID"] != coordinator }
            groups.append(SonosGroup(id: coordinator, rooms: rooms.compactMap { $0["ZoneName"] }, host: host, port: location.port ?? port))
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Plays a stream on a Sonos room or group, through the same interface as a Cast device.
///
/// Sonos keeps no connection open, so the speaker is asked every second what it is doing. That also follows its own
/// buttons and the Sonos app: a change of volume is reported, and so is being paused or stopped, another app taking
/// over, or the speaker going away.
public final class SonosController: CastController, @unchecked Sendable {
    /// Unanswered polls in a row after which the speaker is taken to have gone.
    static let failureLimit = 10
    /// Polls between checks that the speaker is still playing our stream.
    static let mediaCheckEvery = 5

    public let group: SonosGroup
    public let events: AsyncStream<CastEvent>
    private let eventContinuation: AsyncStream<CastEvent>.Continuation
    private let lock = NSLock()
    /// The radio URI playing, while it is ours.
    private var uri: String?
    private var watcher: Task<Void, Never>?
    /// The group volume (0 to 100) last set or reported, so only changes made elsewhere are reported.
    private var volume: Int?
    /// Until when readings are ignored after setting the volume, as one taken just before may still arrive.
    private var volumeHeld = Date.distantPast

    public init(group: SonosGroup) {
        self.group = group
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    /// Sends an action to the group's coordinator, naming the group rather than its address in any error.
    @discardableResult
    private func call(_ service: Sonos.Service, _ action: String, _ args: KeyValuePairs<String, String>, timeout: Double = 6) async throws -> String {
        do { return try await Sonos.call(host: group.host, port: group.port, service, action, args, timeout: timeout) }
        catch SonosError.refused(_, let code) { throw SonosError.refused(group.name, code) }
        catch { throw SonosError.unreachable(group.name) }
    }

    /// Checks that the speaker answers. Sonos needs no other set-up.
    public func connect() async throws {
        try await call(.avTransport, "GetTransportInfo", ["InstanceID": "0"])
    }

    public func load(url: URL, title: String) async throws {
        let radio = Sonos.radioURI(url)
        do {
            try await call(.avTransport, "SetAVTransportURI", ["InstanceID": "0", "CurrentURI": radio, "CurrentURIMetaData": Sonos.radioMetadata(title: title)])
            // Play answers once the speaker has tried the stream, which takes a few seconds, and answers the same
            // whether or not it could open it. Only its state says which.
            try await call(.avTransport, "Play", ["InstanceID": "0", "Speed": "1"], timeout: 20)
            var state: String?
            for _ in 0..<10 {
                state = Sonos.value("CurrentTransportState", in: try await call(.avTransport, "GetTransportInfo", ["InstanceID": "0"]))
                if state == "PLAYING" || state == "STOPPED" { break }
                try await Task.sleep(for: .seconds(1))
            }
            if state == "STOPPED" { throw SonosError.cannotOpen(group.name) }
        } catch {
            eventContinuation.yield(.loadFailed(error.localizedDescription))
            throw error
        }
        lock.withLock { uri = radio }
        watch()
    }

    /// Takes over a speaker already playing `url`, as when its own Play button asked for the stream.
    ///
    /// Nothing is loaded again, only followed, and the speaker's own volume is kept and reported.
    ///
    /// - Returns: False if the speaker is doing anything else.
    public func adopt(url: URL) async -> Bool {
        let radio = Sonos.radioURI(url)
        guard let media = try? await call(.avTransport, "GetMediaInfo", ["InstanceID": "0"]), Sonos.value("CurrentURI", in: media) == radio,
              let info = try? await call(.avTransport, "GetTransportInfo", ["InstanceID": "0"]),
              ["PLAYING", "TRANSITIONING"].contains(Sonos.value("CurrentTransportState", in: info)) else { return false }
        lock.withLock { uri = radio; volume = nil }
        watch()
        return true
    }

    /// No spectrum is drawn for Sonos, so its position isn't asked for.
    public var playbackSeconds: Double? { nil }

    public func setVolume(_ level: Double) async {
        let percent = Int((max(0, min(1, level)) * 100).rounded())
        lock.withLock { volume = percent; volumeHeld = Date().addingTimeInterval(2) }
        _ = try? await call(.groupRendering, "SetGroupVolume", ["InstanceID": "0", "DesiredVolume": String(percent)])
    }

    public func stop() async {
        let running = lock.withLock { () -> Task<Void, Never>? in defer { watcher = nil; uri = nil }; return watcher }
        running?.cancel()
        _ = try? await call(.avTransport, "Stop", ["InstanceID": "0"])
        eventContinuation.finish()
    }

    /// Polls the speaker every second for whether it is playing and its volume, and every `mediaCheckEvery` seconds
    /// for whether it is still playing our stream. `failureLimit` unanswered polls in a row mean it has gone.
    private func watch() {
        let task = Task { [weak self] in
            var failures = 0, played = false, polls = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let ours = self.lock.withLock({ self.uri }) else { return }
                do {
                    let info = try await self.call(.avTransport, "GetTransportInfo", ["InstanceID": "0"])
                    let level = try await self.call(.groupRendering, "GetGroupVolume", ["InstanceID": "0"])
                    let media = polls % Self.mediaCheckEvery == 0 ? try await self.call(.avTransport, "GetMediaInfo", ["InstanceID": "0"]) : nil
                    failures = 0; polls += 1
                    guard !Task.isCancelled else { return }
                    if let now = media.flatMap({ Sonos.value("CurrentURI", in: $0) }), now != ours {
                        self.eventContinuation.yield(.takenOver); return
                    }
                    switch Sonos.value("CurrentTransportState", in: info) {
                    case "PLAYING": played = true
                    case "STOPPED", "PAUSED_PLAYBACK" where played: self.eventContinuation.yield(.stoppedOnDevice); return
                    default: break
                    }
                    if let percent = Sonos.value("CurrentVolume", in: level).flatMap({ Int($0) }), self.volumeChanged(to: percent) {
                        self.eventContinuation.yield(.volume(Double(percent) / 100))
                    }
                } catch {
                    failures += 1
                    if failures >= Self.failureLimit { self.eventContinuation.yield(.lost); return }
                }
            }
        }
        lock.withLock { watcher?.cancel(); watcher = task }
    }

    /// Whether a volume reading is news: different from the last, and not one that may predate a volume just set.
    private func volumeChanged(to percent: Int) -> Bool {
        lock.withLock {
            guard Date() >= volumeHeld, percent != volume else { return false }
            volume = percent; return true
        }
    }
}
