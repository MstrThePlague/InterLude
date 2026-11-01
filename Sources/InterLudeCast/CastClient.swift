//  CastClient.swift
//  InterLudeCast
//
//  Plays a stream on a Cast device from Linux: the Cast v2 channel (TLS to the device, length-prefixed protobuf
//  messages carrying JSON) over SwiftNIO. It follows the Mac's DirectCastController message for message, sharing its
//  wire format through `CastWire`: connect, launch the Default Media Receiver, load the HLS playlist, keep the channel
//  alive and watch for losing it.

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import InterLudeCore

/// A Cast v2 sender over SwiftNIO. Mutable state is guarded by `lock`.
public final class CastClient: CastController, @unchecked Sendable {
    public let speaker: CastSpeaker
    public let events: AsyncStream<CastEvent>
    private let eventContinuation: AsyncStream<CastEvent>.Continuation
    private let lock = NSLock()
    private var channel: Channel?
    /// Bytes read but not yet framed.
    private var buffer: [UInt8] = []
    private var requestId = 0
    /// Answers awaited, by request ID.
    private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var transportId: String?
    private var sessionId: String?
    /// Whether the receiver has reported its status once, after which a status without our session means another
    /// app has taken over.
    private var launched = false
    /// The heartbeat.
    private var timers: [RepeatedTask] = []

    private typealias Namespace = CastWire.Namespace

    public init(speaker: CastSpeaker) {
        self.speaker = speaker
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    /// Opens a TLS connection, starts the heartbeat and launches the Default Media Receiver.
    public func connect() async throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none      // Cast devices present self-signed certificates
        let context = try NIOSSLContext(configuration: tls)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(8))
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: nil))
                    try channel.pipeline.syncOperations.addHandler(Inbound { [weak self] bytes in self?.received(bytes) })
                }
            }
        let channel = try await bootstrap.connect(host: speaker.host, port: speaker.port).get()
        lock.withLock { self.channel = channel }
        send(Namespace.connection, to: CastWire.platformReceiver, ["type": "CONNECT"])
        lock.withLock {
            timers.append(channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5)) { [weak self] _ in
                self?.send(Namespace.heartbeat, to: CastWire.platformReceiver, ["type": "PING"])
            })
        }
        let status = try await request(Namespace.receiver, to: CastWire.platformReceiver,
                                       ["type": "LAUNCH", "appId": CastWire.defaultReceiverAppId], timeout: 15)
        guard let app = CastWire.defaultReceiver(in: status) else { throw CastError.rejected("receiver did not start") }
        lock.withLock { transportId = app.transportId; sessionId = app.sessionId }
        send(Namespace.connection, to: app.transportId, ["type": "CONNECT"])
    }

    /// Loads the playlist, trying each HLS segment format in turn until the receiver accepts one.
    public func load(url: URL, title: String) async throws {
        guard let (transport, session) = lock.withLock({ transportId.flatMap { t in sessionId.map { (t, $0) } } }) else { throw CastError.closed }
        var lastError: Error = CastError.timeout
        for format in CastWire.segmentFormats {
            do {
                let answer = try await request(Namespace.media, to: transport,
                                               ["type": "LOAD", "sessionId": session, "autoplay": true, "currentTime": 0,
                                                "media": CastWire.loadMedia(url: url, title: title, segmentFormat: format)], timeout: 20)
                if let type = answer["type"] as? String, type == "LOAD_FAILED" || type == "INVALID_REQUEST" { throw CastError.rejected(type) }
                return
            } catch { lastError = error }
        }
        eventContinuation.yield(.loadFailed(lastError.localizedDescription))
        throw lastError
    }

    /// The server shows no spectrum for Cast output, so position reports aren't asked for.
    public var playbackSeconds: Double? { nil }

    public func setVolume(_ level: Double) async {
        send(Namespace.receiver, to: CastWire.platformReceiver, ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, level))], "requestId": nextId()])
    }

    public func stop() async {
        if let session = lock.withLock({ sessionId }) {
            send(Namespace.receiver, to: CastWire.platformReceiver, ["type": "STOP", "sessionId": session, "requestId": nextId()])
        }
        try? await Task.sleep(for: .milliseconds(200))          // let the STOP go out before the channel closes
        let (channel, timers, waiters) = lock.withLock { () -> (Channel?, [RepeatedTask], [CheckedContinuation<[String: Any], Error>]) in
            defer { self.channel = nil; self.timers = []; self.waiters = [:] }
            return (self.channel, self.timers, Array(self.waiters.values))
        }
        timers.forEach { $0.cancel() }
        waiters.forEach { $0.resume(throwing: CastError.closed) }
        try? await channel?.close()
        eventContinuation.finish()
    }

    // MARK: Plumbing

    private func nextId() -> Int { lock.withLock { requestId += 1; return requestId } }

    private func send(_ namespace: String, to destination: String, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8),
              let channel = lock.withLock({ channel }) else { return }
        let frame = CastWire.encode(source: CastWire.sender, destination: destination, namespace: namespace, payload: json)
        channel.writeAndFlush(ByteBuffer(bytes: frame), promise: nil)
    }

    /// Sends a message with a fresh request ID and waits for the answer that carries it.
    ///
    /// - Parameter timeout: [s]
    private func request(_ namespace: String, to destination: String, _ message: [String: Any], timeout: Double) async throws -> [String: Any] {
        var message = message
        let id = nextId(); message["requestId"] = id
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters[id] = continuation }
            send(namespace, to: destination, message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.lock.withLock { self?.waiters.removeValue(forKey: id) }?.resume(throwing: CastError.timeout)
            }
        }
    }

    /// Bytes from the device, or nil when the channel closed.
    private func received(_ bytes: [UInt8]?) {
        guard let bytes else { eventContinuation.yield(.lost); return }
        let messages = lock.withLock { () -> [CastWire.Message] in
            buffer += bytes
            return CastWire.takeMessages(from: &buffer)
        }
        for message in messages { handle(message) }
    }

    /// Answers pings, notices closing and takeovers, and hands answers to their waiters.
    private func handle(_ message: CastWire.Message) {
        guard let data = message.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = object["type"] as? String
        if message.namespace == Namespace.heartbeat, type == "PING" { send(Namespace.heartbeat, to: message.source, ["type": "PONG"]); return }
        if message.namespace == Namespace.connection, type == "CLOSE" { eventContinuation.yield(.lost); return }
        if message.namespace == Namespace.receiver, type == "RECEIVER_STATUS" {
            let (wasLaunched, session) = lock.withLock { () -> (Bool, String?) in defer { launched = true }; return (launched, sessionId) }
            if wasLaunched, session != nil, !CastWire.stillOurs(object, sessionId: session) { eventContinuation.yield(.takenOver) }
        }
        if let id = (object["requestId"] as? NSNumber)?.intValue, id != 0, let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) {
            waiter.resume(returning: object)
        }
    }

    /// Hands the channel's bytes to the client, and nil when the channel closes.
    private final class Inbound: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let onBytes: ([UInt8]?) -> Void
        init(_ onBytes: @escaping ([UInt8]?) -> Void) { self.onBytes = onBytes }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            onBytes(bytes.readBytes(length: bytes.readableBytes))
        }
        func channelInactive(context: ChannelHandlerContext) { onBytes(nil) }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
