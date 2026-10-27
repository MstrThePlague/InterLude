import Foundation
import Hummingbird
import InterLudeCore

/// The portable counterpart of the Mac's LocalServer: Hummingbird on SwiftNIO, with the same handler shape, so the
/// session's routes and the remote's answer here exactly as they do on the Mac. Unlike LocalServer it keeps
/// connections alive, which suits a browser that fetches a playlist and a segment every few seconds.
public struct HTTPServer: Sendable {
    public let host: String
    public let port: Int
    private let handler: @Sendable (InterLudeCore.HTTPRequest) async -> InterLudeCore.HTTPResponse

    public init(host: String = "0.0.0.0", port: Int, handler: @escaping @Sendable (InterLudeCore.HTTPRequest) async -> InterLudeCore.HTTPResponse) {
        self.host = host; self.port = port; self.handler = handler
    }

    /// Serves until the task is cancelled or the process is told to stop.
    public func run(onRunning: @escaping @Sendable () async -> Void = {}) async throws {
        let app = Application(responder: Bridge(handler: handler),
                              configuration: .init(address: .hostname(host, port: port), serverName: "InterLude"),
                              onServerRunning: { _ in await onRunning() })
        try await app.runService()
    }

    private struct Bridge: HTTPResponder {
        typealias Context = BasicRequestContext
        let handler: @Sendable (InterLudeCore.HTTPRequest) async -> InterLudeCore.HTTPResponse

        func respond(to request: Request, context: Context) async throws -> Response {
            guard let req = InterLudeCore.HTTPRequest(requestLine: "\(request.method.rawValue) \(request.uri.description) HTTP/1.1") else {
                return Response(status: .methodNotAllowed)
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
