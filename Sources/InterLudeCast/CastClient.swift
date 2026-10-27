import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import InterLudeCore

/// Plays a stream on a Cast device from Linux: the Cast v2 channel (TLS to the device, length-prefixed protobuf
/// messages carrying JSON) over SwiftNIO. It follows the Mac's DirectCastController message for message: connect,
/// launch the Default Media Receiver, load the HLS playlist, keep the channel alive and watch for losing it.
public final class CastClient: CastController, @unchecked Sendable {
    static let appId = "CC1AD845"           // Default Media Receiver
    enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    public let speaker: CastSpeaker
    public let events: AsyncStream<CastEvent>
    private let eventCont: AsyncStream<CastEvent>.Continuation
    private let lock = NSLock()
    private var channel: Channel?
    private var buffer: [UInt8] = []
    private var requestId = 0
    private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var transportId: String?
    private var sessionId: String?
    private var launched = false
    private var timers: [RepeatedTask] = []

    public init(speaker: CastSpeaker) {
        self.speaker = speaker
        (events, eventCont) = AsyncStream.makeStream()
    }

    public func connect() async throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none      // Cast devices present self-signed certificates
        let context = try NIOSSLContext(configuration: tls)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(8))
            .channelInitializer { [weak self] ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: nil))
                    try ch.pipeline.syncOperations.addHandler(Inbound { [weak self] bytes in self?.received(bytes) })
                }
            }
        let ch = try await bootstrap.connect(host: speaker.host, port: speaker.port).get()
        lock.withLock { channel = ch }
        send(NS.connection, to: "receiver-0", ["type": "CONNECT"])
        lock.withLock {
            timers.append(ch.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5)) { [weak self] _ in
                self?.send(NS.heartbeat, to: "receiver-0", ["type": "PING"])
            })
        }
        let status = try await request(NS.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.appId], timeout: 15)
        guard let s = status["status"] as? [String: Any], let apps = s["applications"] as? [[String: Any]],
              let app = apps.first(where: { $0["appId"] as? String == Self.appId }),
              let t = app["transportId"] as? String, let sid = app["sessionId"] as? String else { throw CastError.rejected("receiver did not start") }
        lock.withLock { transportId = t; sessionId = sid }
        send(NS.connection, to: t, ["type": "CONNECT"])
    }

    public func load(url: URL, title: String) async throws {
        guard let (t, sid) = lock.withLock({ transportId.flatMap { t in sessionId.map { (t, $0) } } }) else { throw CastError.closed }
        var lastError: Error = CastError.timeout
        for format in ["ts_aac", "ts", ""] {
            var media: [String: Any] = ["contentId": url.absoluteString, "contentType": "application/x-mpegURL", "streamType": "LIVE",
                                        "metadata": ["metadataType": 3, "title": title]]
            if !format.isEmpty { media["hlsSegmentFormat"] = format }
            do {
                let r = try await request(NS.media, to: t, ["type": "LOAD", "sessionId": sid, "media": media, "autoplay": true, "currentTime": 0], timeout: 20)
                if let type = r["type"] as? String, type == "LOAD_FAILED" || type == "INVALID_REQUEST" { throw CastError.rejected(type) }
                return
            } catch { lastError = error }
        }
        eventCont.yield(.loadFailed(lastError.localizedDescription))
        throw lastError
    }

    /// The server shows no spectrum for Cast output, so position reports aren't asked for.
    public var playbackSeconds: Double? { nil }

    public func setVolume(_ level: Double) async {
        send(NS.receiver, to: "receiver-0", ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))], "requestId": nextId()])
    }

    public func stop() async {
        if let sid = lock.withLock({ sessionId }) { send(NS.receiver, to: "receiver-0", ["type": "STOP", "sessionId": sid, "requestId": nextId()]) }
        try? await Task.sleep(for: .milliseconds(200))
        let (ch, ts, ws) = lock.withLock { () -> (Channel?, [RepeatedTask], [CheckedContinuation<[String: Any], Error>]) in
            defer { channel = nil; timers = []; waiters = [:] }
            return (channel, timers, Array(waiters.values))
        }
        ts.forEach { $0.cancel() }
        ws.forEach { $0.resume(throwing: CastError.closed) }
        try? await ch?.close()
        eventCont.finish()
    }

    // MARK: Plumbing

    private func nextId() -> Int { lock.withLock { requestId += 1; return requestId } }

    private func send(_ ns: String, to dest: String, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let json = String(data: d, encoding: .utf8),
              let ch = lock.withLock({ channel }) else { return }
        ch.writeAndFlush(ByteBuffer(bytes: CastWire.encode(source: "sender-0", destination: dest, namespace: ns, payload: json)), promise: nil)
    }

    private func request(_ ns: String, to dest: String, _ obj: [String: Any], timeout: Double) async throws -> [String: Any] {
        var obj = obj
        let id = nextId(); obj["requestId"] = id
        return try await withCheckedThrowingContinuation { k in
            lock.withLock { waiters[id] = k }
            send(ns, to: dest, obj)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.lock.withLock { self?.waiters.removeValue(forKey: id) }?.resume(throwing: CastError.timeout)
            }
        }
    }

    /// Bytes from the device, or nil when the channel closed.
    private func received(_ bytes: [UInt8]?) {
        guard let bytes else { eventCont.yield(.lost); return }
        var messages: [CastWire.Message] = []
        lock.withLock {
            buffer += bytes
            while buffer.count >= 4 {
                let len = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard buffer.count >= 4 + len else { break }
                if let m = CastWire.decode(Array(buffer[4..<(4 + len)])) { messages.append(m) }
                buffer.removeFirst(4 + len)
            }
        }
        for m in messages { handle(m) }
    }

    private func handle(_ m: CastWire.Message) {
        guard let d = m.payload.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let type = o["type"] as? String
        if m.namespace == NS.heartbeat, type == "PING" { send(NS.heartbeat, to: m.source, ["type": "PONG"]); return }
        if m.namespace == NS.connection, type == "CLOSE" { eventCont.yield(.lost); return }
        if m.namespace == NS.receiver, type == "RECEIVER_STATUS", let s = o["status"] as? [String: Any] {
            let (wasLaunched, sid) = lock.withLock { () -> (Bool, String?) in defer { launched = true }; return (launched, sessionId) }
            let apps = (s["applications"] as? [[String: Any]]) ?? []
            if wasLaunched, sid != nil, !apps.contains(where: { $0["appId"] as? String == Self.appId && $0["sessionId"] as? String == sid }) {
                eventCont.yield(.takenOver)
            }
        }
        if let id = (o["requestId"] as? NSNumber)?.intValue, id != 0, let w = lock.withLock({ waiters.removeValue(forKey: id) }) {
            w.resume(returning: o)
        }
    }

    private final class Inbound: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let onBytes: ([UInt8]?) -> Void
        init(_ onBytes: @escaping ([UInt8]?) -> Void) { self.onBytes = onBytes }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            onBytes(b.readBytes(length: b.readableBytes))
        }
        func channelInactive(context: ChannelHandlerContext) { onBytes(nil) }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
