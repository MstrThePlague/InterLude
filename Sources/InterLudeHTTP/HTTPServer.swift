import Foundation
import Hummingbird
import InterLudeCore

/// The portable counterpart of the Mac's LocalServer: Hummingbird on SwiftNIO, with the same handler shape, so the
/// session's routes and the remote's answer here exactly as they do on the Mac. Unlike LocalServer it keeps
/// connections alive, which suits a browser that fetches a playlist and a segment every few seconds.
public struct HTTPServer: Sendable {
    public typealias Handler = @Sendable (InterLudeCore.HTTPRequest) async -> InterLudeCore.HTTPResponse
    /// Answers with a stream of server-sent events, or nil to leave the request to the handler.
    public typealias EventsHandler = @Sendable (InterLudeCore.HTTPRequest) async -> AsyncStream<String>?

    public let host: String
    public let port: Int
    private let handler: Handler
    private let events: EventsHandler

    public init(host: String = "0.0.0.0", port: Int, events: @escaping EventsHandler = { _ in nil }, handler: @escaping Handler) {
        self.host = host; self.port = port; self.events = events; self.handler = handler
    }

    /// Serves until the task is cancelled or the process is told to stop.
    public func run(onRunning: @escaping @Sendable () async -> Void = {}) async throws {
        let app = Application(responder: Bridge(handler: handler, events: events),
                              configuration: .init(address: .hostname(host, port: port), serverName: "InterLude"),
                              onServerRunning: { _ in await onRunning() })
        try await app.runService()
    }

    private struct Bridge: HTTPResponder {
        typealias Context = BasicRequestContext
        let handler: Handler
        let events: EventsHandler

        func respond(to request: Request, context: Context) async throws -> Response {
            guard var req = InterLudeCore.HTTPRequest(requestLine: "\(request.method.rawValue) \(request.uri.description) HTTP/1.1") else {
                return Response(status: .methodNotAllowed)
            }
            for field in request.headers { req.headers[field.name.canonicalName] = field.value }
            // HTTP/1's Host header arrives as the authority, as in HTTP/2.
            if let authority = request.head.authority { req.headers["host"] = authority }
            if let stream = await events(req) {
                let headers: HTTPFields = [.contentType: "text/event-stream", .cacheControl: "no-cache"]
                return Response(status: .ok, headers: headers,
                                body: ResponseBody(asyncSequence: stream.map { ByteBuffer(string: $0) }))
            }
            let r = await handler(req)
            var headers: HTTPFields = [.contentType: r.contentType, .accessControlAllowOrigin: "*"]
            if r.noCache { headers[.cacheControl] = "no-cache" }
            headers[.contentLength] = String(r.body.count)
            let body = req.method == "HEAD" ? ResponseBody() : ResponseBody(byteBuffer: ByteBuffer(bytes: r.body))
            return Response(status: .init(code: r.status), headers: headers, body: body)
        }
    }
}
