import Foundation
import Network

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var noCache = false
    public init(status: Int = 200, contentType: String, body: Data, noCache: Bool = false) {
        self.status = status; self.contentType = contentType; self.body = body; self.noCache = noCache
    }
    public static let notFound = HTTPResponse(status: 404, contentType: "text/plain", body: Data("not found".utf8))
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public init(method: String = "GET", path: String, query: [String: String] = [:]) {
        self.method = method; self.path = path; self.query = query
    }
    /// Parses the request line, such as `POST /a/b?x=1 HTTP/1.1`. Only GET, HEAD and POST are accepted.
    public init?(requestLine: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, ["GET", "HEAD", "POST"].contains(parts[0]),
              let c = URLComponents(string: String(parts[1])) else { return nil }
        method = String(parts[0]); path = c.path
        query = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
    }
}

/// A small HTTP server on NWListener. It serves the playlist and segments to AVPlayer (on loopback) and to Chromecasts
/// (on the LAN), and the phone remote. Every path starts with a random token, so other devices cannot guess the URLs.
/// POST carries no body: the phone remote's commands put their arguments in the query.
public final class LocalServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "interlude.server")
    public let port: UInt16
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    public init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port; self.handler = handler
    }

    public func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port), port > 0 else { throw NWError.posix(.EINVAL) }
        let l = try NWListener(using: .tcp, on: p)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    /// One request per connection: the players ask for small files, so keep-alive is not worth the complexity.
    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [handler] data, _, _, err in
            guard let data, err == nil, let text = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let first = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            guard let req = HTTPRequest(requestLine: first) else {
                c.send(content: Data("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let head = req.method == "HEAD"
            Task {
                let r = await handler(req)
                var h = "HTTP/1.1 \(r.status) \(r.status == 200 ? "OK" : "Error")\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n"
                if r.noCache { h += "Cache-Control: no-cache\r\n" }
                h += "\r\n"
                var out = Data(h.utf8); if !head { out.append(r.body) }
                c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// The Mac's LAN IPv4 address (en0, en1, ...), never loopback. A Chromecast cannot reach `localhost`.
    public static func lanAddress() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let addr = String(cString: host)
            if addr.hasPrefix("169.254") { continue }
            if name == "en0" { return addr }
            best = best ?? addr
        }
        return best
    }
}
