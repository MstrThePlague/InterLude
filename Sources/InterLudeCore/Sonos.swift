import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Sonos speakers are controlled with UPnP: SOAP requests to port 1400 on the speaker. They can't play HLS, so they
// are given InterLude's AAC stream (`AACStream`) as an internet radio station. Speakers are found by their
// `_sonos._tcp` Bonjour service, and any one of them describes the whole household: its rooms and how they're grouped.

/// A Sonos room, or rooms grouped in the Sonos app, which play as one. Sound is sent to the group's coordinator.
public struct SonosGroup: Sendable, Hashable, Identifiable {
    /// The coordinator's UUID, such as RINCON_48A6B8E1F2C401400.
    public var id: String
    /// The rooms in the group, the coordinator first.
    public var rooms: [String]
    public var host: String
    public var port: Int
    public init(id: String, rooms: [String], host: String, port: Int = 1400) {
        self.id = id; self.rooms = rooms; self.host = host; self.port = port
    }
    public var isGroup: Bool { rooms.count > 1 }
    /// As the Sonos app names a group: "Kitchen + 2".
    public var name: String { rooms.count > 1 ? "\(rooms[0]) + \(rooms.count - 1)" : rooms.first ?? "Sonos" }
    public var detail: String { rooms.count > 1 ? "Sonos: " + rooms.joined(separator: ", ") : "Sonos" }
}

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

public enum Sonos {
    public static let service = "_sonos._tcp"

    /// The household's groups, asked of the first of `hosts` that answers. Empty if none does.
    public static func groups(hosts: [String]) async -> [SonosGroup] {
        for h in hosts {
            if let body = try? await call(host: h, port: 1400, .topology, "GetZoneGroupState", [:]) { return parseTopology(body) }
        }
        return []
    }

    // MARK: SOAP

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

    /// Sends one action and returns the response body. Arguments are written in the order given by their names.
    @discardableResult
    static func call(host: String, port: Int, _ service: Service, _ action: String, _ args: KeyValuePairs<String, String>,
                     timeout: Double = 6) async throws -> String {
        guard let url = URL(string: "http://\(host):\(port)\(service.path)") else { throw SonosError.unreachable(host) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(envelope(service, action, args).utf8)
        let (d, r) = try await session.data(for: req)
        let body = String(decoding: d, as: UTF8.self)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw SonosError.refused(host, errorCode(body)) }
        return body
    }

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

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The text of the first `<name>` element, unescaped.
    static func value(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"), let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return unescape(String(xml[open.upperBound..<close.lowerBound]))
    }

    static func errorCode(_ body: String) -> Int? { value("errorCode", in: body).flatMap { Int($0) } }

    /// The attributes of each `<name …>` tag in `xml`, in order, with their values unescaped.
    static func tags(_ name: String, in xml: Substring) -> [[String: String]] {
        var out: [[String: String]] = []
        var rest = xml[...]
        while let start = rest.range(of: "<\(name) "), let end = rest[start.upperBound...].firstIndex(of: ">") {
            var attrs: [String: String] = [:]
            var s = rest[start.upperBound..<end]
            while let eq = s.range(of: "=\""), let close = s[eq.upperBound...].firstIndex(of: "\"") {
                let key = s[..<eq.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                attrs[key] = unescape(String(s[eq.upperBound..<close]))
                s = s[s.index(after: close)...]
            }
            out.append(attrs)
            rest = rest[end...]
        }
        return out
    }

    /// Reads GetZoneGroupState's answer. Hidden members (the second of a stereo pair) and bridges are left out.
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
            groups.append(SonosGroup(id: coordinator, rooms: rooms.compactMap { $0["ZoneName"] }, host: host, port: location.port ?? 1400))
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Plays a stream on a Sonos room or group, through the same interface as a Cast device. Sonos keeps no connection
/// open, so it is asked every few seconds what it is playing, to notice another app taking over or the speaker
/// going away.
public final class SonosController: CastController, @unchecked Sendable {
    public let group: SonosGroup
    public let events: AsyncStream<CastEvent>
    private let eventCont: AsyncStream<CastEvent>.Continuation
    private let lock = NSLock()
    private var uri: String?
    private var watcher: Task<Void, Never>?

    public init(group: SonosGroup) {
        self.group = group
        (events, eventCont) = AsyncStream.makeStream()
    }

    @discardableResult
    private func call(_ service: Sonos.Service, _ action: String, _ args: KeyValuePairs<String, String>, timeout: Double = 6) async throws -> String {
        do { return try await Sonos.call(host: group.host, port: group.port, service, action, args, timeout: timeout) }
        catch SonosError.refused(_, let code) { throw SonosError.refused(group.name, code) }
        catch { throw SonosError.unreachable(group.name) }
    }

    public func connect() async throws {
        try await call(.avTransport, "GetTransportInfo", ["InstanceID": "0"])
    }

    public func load(url: URL, title: String) async throws {
        let u = Sonos.radioURI(url)
        do {
            try await call(.avTransport, "SetAVTransportURI", ["InstanceID": "0", "CurrentURI": u, "CurrentURIMetaData": Sonos.radioMetadata(title: title)])
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
            eventCont.yield(.loadFailed(error.localizedDescription))
            throw error
        }
        lock.withLock { uri = u }
        watch()
    }

    /// No spectrum is drawn for Sonos, so its position isn't asked for.
    public var playbackSeconds: Double? { nil }

    public func setVolume(_ level: Double) async {
        _ = try? await call(.groupRendering, "SetGroupVolume", ["InstanceID": "0", "DesiredVolume": String(Int((max(0, min(1, level)) * 100).rounded()))])
    }

    public func stop() async {
        let w = lock.withLock { () -> Task<Void, Never>? in defer { watcher = nil; uri = nil }; return watcher }
        w?.cancel()
        _ = try? await call(.avTransport, "Stop", ["InstanceID": "0"])
        eventCont.finish()
    }

    /// Every five seconds: still playing our stream? Three unanswered questions in a row mean the speaker has gone.
    private func watch() {
        let t = Task { [weak self] in
            var failures = 0, played = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, let mine = self.lock.withLock({ self.uri }) else { return }
                do {
                    let media = try await self.call(.avTransport, "GetMediaInfo", ["InstanceID": "0"])
                    let info = try await self.call(.avTransport, "GetTransportInfo", ["InstanceID": "0"])
                    failures = 0
                    guard !Task.isCancelled else { return }
                    if let now = Sonos.value("CurrentURI", in: media), now != mine { self.eventCont.yield(.takenOver); return }
                    switch Sonos.value("CurrentTransportState", in: info) {
                    case "PLAYING": played = true
                    case "STOPPED", "PAUSED_PLAYBACK" where played: self.eventCont.yield(.stoppedOnDevice); return
                    default: break
                    }
                } catch {
                    failures += 1
                    if failures >= 3 { self.eventCont.yield(.lost); return }
                }
            }
        }
        lock.withLock { watcher?.cancel(); watcher = t }
    }
}
