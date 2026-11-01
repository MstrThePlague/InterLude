//  Cast.swift
//  InterLudeApple
//
//  Chromecast on the Mac: finding Cast devices with Bonjour, and a minimal Cast v2 sender over Network.framework.
//  The wire format is shared with the Linux server's sender (InterLudeCast) through `CastWire`.

import Foundation
import Network
import InterLudeCore

// MARK: Discovery

/// A Chromecast or Cast group found with Bonjour.
public struct CastDevice: Identifiable, Sendable, Hashable {
    /// The Bonjour service name, which stays the same across restarts.
    public var id: String
    /// The name set in the Google Home app.
    public var name: String
    /// The model, such as "Chromecast Audio" or "Google Cast Group".
    public var model: String
    public var isGroup: Bool { model == "Google Cast Group" }
    public var endpoint: NWEndpoint
    public static func == (a: CastDevice, b: CastDevice) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Follows the Cast devices on the network.
public final class CastDiscovery: @unchecked Sendable {
    /// `kDNSServiceErr_PolicyDenied`: macOS has refused the app local network access.
    private static let policyDenied: Int32 = -65570

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "interlude.cast.discovery")
    /// The devices found, sorted by name, each time the list changes.
    public let updates: AsyncStream<[CastDevice]>
    private let updatesContinuation: AsyncStream<[CastDevice]>.Continuation
    /// Yields true when macOS has refused local network access.
    public let permission: AsyncStream<Bool>
    private let permissionContinuation: AsyncStream<Bool>.Continuation

    public init() {
        (updates, updatesContinuation) = AsyncStream.makeStream(of: [CastDevice].self, bufferingPolicy: .bufferingNewest(1))
        (permission, permissionContinuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [updatesContinuation] results, _ in
            var devices: [CastDevice] = []
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                // The TXT record carries the friendly name (fn) and the model (md).
                var friendlyName = name, model = ""
                if case .bonjour(let txt) = result.metadata {
                    friendlyName = txt["fn"] ?? name; model = txt["md"] ?? ""
                }
                devices.append(CastDevice(id: name, name: friendlyName, model: model, endpoint: result.endpoint))
            }
            updatesContinuation.yield(devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { [permissionContinuation] state in
            if case .waiting(let error) = state, case .dns(let code) = error, code == Self.policyDenied { permissionContinuation.yield(true) }
            if case .failed = state { permissionContinuation.yield(true) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() { browser?.cancel(); browser = nil }
}

/// A JSON message, passed between threads. Only ever read after it is made.
struct JSONBox: @unchecked Sendable { let value: [String: Any]; init(_ value: [String: Any]) { self.value = value } }

// MARK: Sender

/// A minimal Cast v2 sender: connection, heartbeat, launch of the Default Media Receiver, load, volume and stop.
///
/// Everything mutable is touched only on `queue`, apart from the reported position, which has its own lock.
public final class DirectCastController: CastController, @unchecked Sendable {
    private let device: CastDevice
    private let queue = DispatchQueue(label: "interlude.cast.conn")
    private var connection: NWConnection?
    /// Bytes read but not yet framed.
    private var buffer = [UInt8]()
    private var requestId = 0
    /// Answers awaited, by request ID.
    private var waiters: [Int: @Sendable (Result<JSONBox, Error>) -> Void] = [:]
    private var transportId: String?
    private var sessionId: String?
    private var heartbeat: DispatchSourceTimer?
    /// Whether the receiver has reported its status once, after which a status without our session means another
    /// app has taken over.
    private var launched = false
    private let positionLock = NSLock()
    /// The device's last reported position [s], whether it was playing, and when it said so.
    private var reported: (time: Double, playing: Bool, at: Date)?
    private var statusTimer: DispatchSourceTimer?
    private let eventContinuation: AsyncStream<CastEvent>.Continuation
    public let events: AsyncStream<CastEvent>

    private typealias Namespace = CastWire.Namespace

    public init(device: CastDevice) {
        self.device = device
        (events, eventContinuation) = AsyncStream.makeStream(of: CastEvent.self)
    }

    /// Opens a TLS connection and launches the Default Media Receiver.
    public func connect() async throws {
        let tls = NWProtocolTLS.Options()
        // Cast devices present self-signed certificates, so none can be verified.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let connection = NWConnection(to: device.endpoint, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()      // only touched on `queue`
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if !once.done { once.done = true; continuation.resume() }
                case .failed(let error):
                    if !once.done { once.done = true; continuation.resume(throwing: error) } else { self?.eventContinuation.yield(.lost) }
                case .cancelled: if !once.done { once.done = true; continuation.resume(throwing: CastError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        receiveLoop()
        send(Namespace.connection, to: CastWire.platformReceiver, ["type": "CONNECT"])
        startHeartbeat()
        let status = try await request(Namespace.receiver, to: CastWire.platformReceiver,
                                       ["type": "LAUNCH", "appId": CastWire.defaultReceiverAppId], timeout: 15)
        guard let app = CastWire.defaultReceiver(in: status) else { throw CastError.rejected("receiver did not start") }
        transportId = app.transportId; sessionId = app.sessionId
        send(Namespace.connection, to: app.transportId, ["type": "CONNECT"])
    }

    /// Loads the playlist, trying each HLS segment format in turn until the receiver accepts one.
    public func load(url: URL, title: String) async throws {
        guard let transport = transportId, let session = sessionId else { throw CastError.closed }
        var lastError: Error = CastError.timeout
        for format in CastWire.segmentFormats {
            do {
                let answer = try await request(Namespace.media, to: transport,
                                               ["type": "LOAD", "sessionId": session, "autoplay": true, "currentTime": 0,
                                                "media": CastWire.loadMedia(url: url, title: title, segmentFormat: format)], timeout: 20)
                if let type = answer["type"] as? String, type == "LOAD_FAILED" || type == "INVALID_REQUEST" { throw CastError.rejected(type) }
                startStatusPolling()
                return
            } catch { lastError = error }
        }
        eventContinuation.yield(.loadFailed(lastError.localizedDescription))
        throw lastError
    }

    /// The device's last reported position, carried forward by our own clock while it is playing [s].
    public var playbackSeconds: Double? {
        positionLock.lock(); defer { positionLock.unlock() }
        guard let reported else { return nil }
        return reported.playing ? reported.time + Date().timeIntervalSince(reported.at) : reported.time
    }

    /// Asks the receiver where it is once a second. The answers arrive as MEDIA_STATUS messages.
    private func startStatusPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let transport = self.transportId else { return }
            self.send(Namespace.media, to: transport, ["type": "GET_STATUS", "requestId": self.nextIdOnQueue()])
        }
        timer.resume(); statusTimer = timer
    }

    public func setVolume(_ level: Double) async {
        send(Namespace.receiver, to: CastWire.platformReceiver, ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))], "requestId": nextId()])
    }

    public func stop() async {
        if let session = sessionId {
            send(Namespace.receiver, to: CastWire.platformReceiver, ["type": "STOP", "sessionId": session, "requestId": nextId()])
        }
        try? await Task.sleep(for: .milliseconds(200))          // let the STOP go out before the connection closes
        heartbeat?.cancel(); heartbeat = nil
        statusTimer?.cancel(); statusTimer = nil
        connection?.cancel(); connection = nil
        eventContinuation.finish()
    }

    // MARK: Plumbing

    private func nextId() -> Int { queue.sync { requestId += 1; return requestId } }
    /// For callers already running on `queue`, where `sync` would deadlock.
    private func nextIdOnQueue() -> Int { requestId += 1; return requestId }

    private func send(_ namespace: String, to destination: String, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        sendRaw(namespace, to: destination, json)
    }

    private func sendRaw(_ namespace: String, to destination: String, _ json: String) {
        connection?.send(content: CastWire.encode(source: CastWire.sender, destination: destination, namespace: namespace, payload: json),
                         completion: .contentProcessed { _ in })
    }

    /// Sends a message with a fresh request ID and waits for the answer that carries it.
    ///
    /// - Parameter timeout: [s]
    private func request(_ namespace: String, to destination: String, _ message: [String: Any], timeout: Double) async throws -> [String: Any] {
        var message = message
        let id = nextId(); message["requestId"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else {
            throw CastError.rejected("bad request")
        }
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONBox, Error>) in
            queue.async {
                self.waiters[id] = { continuation.resume(with: $0) }
                self.sendRaw(namespace, to: destination, json)
                self.queue.asyncAfter(deadline: .now() + timeout) { self.waiters.removeValue(forKey: id)?(.failure(CastError.timeout)) }
            }
        }
        return box.value
    }

    /// Pings the device every 5 s, which it expects of a live sender.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.send(Namespace.heartbeat, to: CastWire.platformReceiver, ["type": "PING"]) }
        timer.resume(); heartbeat = timer
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data { self.buffer += data; self.handleMessages() }
            if error != nil || isDone { self.eventContinuation.yield(.lost); return }
            self.receiveLoop()
        }
    }

    /// Acts on every complete message received: answers pings, notices closing and takeovers, records the position,
    /// and hands answers to their waiters.
    private func handleMessages() {
        for message in CastWire.takeMessages(from: &buffer) {
            guard let data = message.payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if message.namespace == Namespace.heartbeat, type == "PING" { send(Namespace.heartbeat, to: message.source, ["type": "PONG"]); continue }
            if message.namespace == Namespace.connection, type == "CLOSE" { eventContinuation.yield(.lost); continue }
            if message.namespace == Namespace.receiver, type == "RECEIVER_STATUS" {
                if launched, !CastWire.stillOurs(object, sessionId: sessionId) { eventContinuation.yield(.takenOver) }
                launched = true
            }
            if message.namespace == Namespace.media, type == "MEDIA_STATUS", let status = (object["status"] as? [[String: Any]])?.first,
               let time = (status["currentTime"] as? NSNumber)?.doubleValue {
                let playing = status["playerState"] as? String == "PLAYING"
                positionLock.lock(); reported = (time, playing, Date()); positionLock.unlock()
            }
            if let id = (object["requestId"] as? NSNumber)?.intValue, id != 0, let waiter = waiters.removeValue(forKey: id) {
                waiter(.success(JSONBox(object)))
            }
        }
    }
}
