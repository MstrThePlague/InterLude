import Foundation
import Network

// MARK: Public interface

public struct CastDevice: Identifiable, Sendable, Hashable {
    public var id: String          // Bonjour service name
    public var name: String
    public var model: String
    public var isGroup: Bool { model == "Google Cast Group" }
    public var endpoint: NWEndpoint
    public static func == (a: CastDevice, b: CastDevice) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public enum CastEvent: Sendable { case lost, takenOver, loadFailed(String) }

/// Everything the app needs from a Cast implementation, so the library can be swapped.
public protocol CastController: AnyObject, Sendable {
    func connect() async throws
    func load(url: URL, title: String) async throws
    func setVolume(_ level: Double) async
    func stop() async
    var events: AsyncStream<CastEvent> { get }
}

public enum CastError: Error, LocalizedError {
    case timeout, closed, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .timeout: "The Cast device did not answer."
        case .closed: "The Cast connection closed."
        case .rejected(let r): "The Cast device refused the stream (\(r))."
        }
    }
}

// MARK: Discovery

public final class CastDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "interlude.cast.discovery")
    public let updates: AsyncStream<[CastDevice]>
    private let cont: AsyncStream<[CastDevice]>.Continuation

    /// Yields true when macOS has refused local network access.
    public let permission: AsyncStream<Bool>
    private let permCont: AsyncStream<Bool>.Continuation

    public init() {
        (updates, cont) = AsyncStream.makeStream(of: [CastDevice].self, bufferingPolicy: .bufferingNewest(1))
        (permission, permCont) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [cont] results, _ in
            var out: [CastDevice] = []
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                var fn = name, md = ""
                if case .bonjour(let txt) = r.metadata {
                    fn = txt["fn"] ?? name; md = txt["md"] ?? ""
                }
                out.append(CastDevice(id: name, name: fn, model: md, endpoint: r.endpoint))
            }
            cont.yield(out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        b.stateUpdateHandler = { [permCont] st in
            if case .waiting(let e) = st, case .dns(let code) = e, code == -65570 { permCont.yield(true) }     // kDNSServiceErr_PolicyDenied
            if case .failed = st { permCont.yield(true) }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() { browser?.cancel(); browser = nil }
}

// MARK: Protobuf (CastMessage) and framing

enum CastWire {
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    static func string(_ field: Int, _ s: String) -> [UInt8] {
        let b = Array(s.utf8); return varint(UInt64(field << 3 | 2)) + varint(UInt64(b.count)) + b
    }

    static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var m: [UInt8] = varint(1 << 3) + varint(0)                 // protocol_version = CASTV2_1_0
        m += string(2, source) + string(3, destination) + string(4, namespace)
        m += varint(5 << 3) + varint(0)                              // payload_type = STRING
        m += string(6, payload)
        let len = UInt32(m.count)
        return Data([UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)] + m)
    }

    struct Message { var source = "", destination = "", namespace = "", payload = "" }

    static func decode(_ b: [UInt8]) -> Message? {
        var m = Message(), i = 0
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count { let c = b[i]; i += 1; r |= UInt64(c & 0x7F) << shift; if c & 0x80 == 0 { return r }; shift += 7 }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3), wt = Int(key & 7)
            switch wt {
            case 0: guard readVarint() != nil else { return nil }
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return nil }
                let s = String(decoding: b[i..<(i + Int(len))], as: UTF8.self); i += Int(len)
                switch field { case 2: m.source = s; case 3: m.destination = s; case 4: m.namespace = s; case 6: m.payload = s; default: break }
            default: return nil
            }
        }
        return m
    }
}

struct JSONBox: @unchecked Sendable { let v: [String: Any]; init(_ v: [String: Any]) { self.v = v } }

// MARK: Direct implementation

/// A minimal Cast v2 sender: connection, heartbeat, launch of the Default Media Receiver, load, volume and stop.
public final class DirectCastController: CastController, @unchecked Sendable {
    private let device: CastDevice
    private let queue = DispatchQueue(label: "interlude.cast.conn")
    private var conn: NWConnection?
    private var buffer = [UInt8]()
    private var requestId = 0
    private var waiters: [Int: @Sendable (Result<JSONBox, Error>) -> Void] = [:]
    private var transportId: String?
    private var sessionId: String?
    private var heartbeat: DispatchSourceTimer?
    private var launched = false
    private let eventCont: AsyncStream<CastEvent>.Continuation
    public let events: AsyncStream<CastEvent>

    static let appId = "CC1AD845"
    enum NS { static let connection = "urn:x-cast:com.google.cast.tp.connection", heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat",
              receiver = "urn:x-cast:com.google.cast.receiver", media = "urn:x-cast:com.google.cast.media" }

    public init(device: CastDevice) {
        self.device = device
        (events, eventCont) = AsyncStream.makeStream(of: CastEvent.self)
    }

    public func connect() async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)   // devices use self-signed certificates
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(to: device.endpoint, using: params)
        conn = c
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()      // only touched on `queue`
            c.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: if !once.done { once.done = true; k.resume() }
                case .failed(let e): if !once.done { once.done = true; k.resume(throwing: e) } else { self?.eventCont.yield(.lost) }
                case .cancelled: if !once.done { once.done = true; k.resume(throwing: CastError.closed) }
                default: break
                }
            }
            c.start(queue: queue)
        }
        receiveLoop()
        send(NS.connection, to: "receiver-0", ["type": "CONNECT"])
        startHeartbeat()
        // Launch the Default Media Receiver and wait for its transport.
        let status = try await request(NS.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.appId], timeout: 15)
        try adopt(status: status)
    }

    private func adopt(status: [String: Any]) throws {
        guard let s = status["status"] as? [String: Any], let apps = s["applications"] as? [[String: Any]],
              let app = apps.first(where: { $0["appId"] as? String == Self.appId }),
              let t = app["transportId"] as? String, let sid = app["sessionId"] as? String else { throw CastError.rejected("receiver did not start") }
        transportId = t; sessionId = sid
        send(NS.connection, to: t, ["type": "CONNECT"])
    }

    public func load(url: URL, title: String) async throws {
        guard let t = transportId, let sid = sessionId else { throw CastError.closed }
        var lastError: Error = CastError.timeout
        for fmt in ["ts_aac", "ts", ""] {
            var media: [String: Any] = ["contentId": url.absoluteString, "contentType": "application/x-mpegURL", "streamType": "LIVE",
                                        "metadata": ["metadataType": 3, "title": title]]
            if !fmt.isEmpty { media["hlsSegmentFormat"] = fmt }
            do {
                let r = try await request(NS.media, to: t, ["type": "LOAD", "sessionId": sid, "media": media, "autoplay": true, "currentTime": 0], timeout: 20)
                if let type = r["type"] as? String, type == "LOAD_FAILED" || type == "INVALID_REQUEST" { throw CastError.rejected(type) }
                return
            } catch { lastError = error }
        }
        eventCont.yield(.loadFailed(lastError.localizedDescription))
        throw lastError
    }

    public func setVolume(_ level: Double) async {
        send(NS.receiver, to: "receiver-0", ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))], "requestId": nextId()])
    }

    public func stop() async {
        if let sid = sessionId { send(NS.receiver, to: "receiver-0", ["type": "STOP", "sessionId": sid, "requestId": nextId()]) }
        try? await Task.sleep(for: .milliseconds(200))
        heartbeat?.cancel(); heartbeat = nil
        conn?.cancel(); conn = nil
        eventCont.finish()
    }

    // MARK: Plumbing

    private func nextId() -> Int { queue.sync { requestId += 1; return requestId } }

    private func send(_ ns: String, to dest: String, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        sendRaw(ns, to: dest, s)
    }

    private func sendRaw(_ ns: String, to dest: String, _ json: String) {
        conn?.send(content: CastWire.encode(source: "sender-0", destination: dest, namespace: ns, payload: json), completion: .contentProcessed { _ in })
    }

    private func request(_ ns: String, to dest: String, _ obj: [String: Any], timeout: Double) async throws -> [String: Any] {
        var obj = obj
        let id = nextId(); obj["requestId"] = id
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let json = String(data: d, encoding: .utf8) else { throw CastError.rejected("bad request") }
        let box = try await withCheckedThrowingContinuation { (k: CheckedContinuation<JSONBox, Error>) in
            queue.async {
                self.waiters[id] = { r in k.resume(with: r) }
                self.sendRaw(ns, to: dest, json)
                self.queue.asyncAfter(deadline: .now() + timeout) { self.waiters.removeValue(forKey: id)?(.failure(CastError.timeout)) }
            }
        }
        return box.v
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.send(NS.heartbeat, to: "receiver-0", ["type": "PING"]) }
        t.resume(); heartbeat = t
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
            guard let self else { return }
            if let data { self.buffer += data; self.drain() }
            if err != nil || isDone { self.eventCont.yield(.lost); return }
            self.receiveLoop()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + len else { return }
            let frame = Array(buffer[4..<(4 + len)]); buffer.removeFirst(4 + len)
            guard let m = CastWire.decode(frame), let d = m.payload.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = o["type"] as? String
            if m.namespace == NS.heartbeat, type == "PING" { send(NS.heartbeat, to: m.source, ["type": "PONG"]); continue }
            if m.namespace == NS.connection, type == "CLOSE" { eventCont.yield(.lost); continue }
            if m.namespace == NS.receiver, type == "RECEIVER_STATUS", launched,
               let s = o["status"] as? [String: Any] {
                let apps = (s["applications"] as? [[String: Any]]) ?? []
                if !apps.contains(where: { $0["appId"] as? String == Self.appId && $0["sessionId"] as? String == sessionId }) { eventCont.yield(.takenOver) }
            }
            if m.namespace == NS.receiver, type == "RECEIVER_STATUS" { launched = true }
            if let id = o["requestId"] as? Int, id != 0, let w = waiters.removeValue(forKey: id) { w(.success(JSONBox(o))) }
        }
    }
}
