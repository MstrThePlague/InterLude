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

/// A small GET-only HTTP server on NWListener. Paths are prefixed with a random token.
public final class LocalServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "interlude.server")
    public let port: UInt16
    private let handler: @Sendable (String) async -> HTTPResponse

    public init(port: UInt16, handler: @escaping @Sendable (String) async -> HTTPResponse) {
        self.port = port; self.handler = handler
    }

    public func start() throws {
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [handler] data, _, _, err in
            guard let data, err == nil, let text = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let first = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
                c.send(content: Data("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let head = parts[0] == "HEAD"
            let path = String(parts[1]).components(separatedBy: "?")[0]
            Task {
                let r = await handler(path)
                var h = "HTTP/1.1 \(r.status) \(r.status == 200 ? "OK" : "Error")\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n"
                if r.noCache { h += "Cache-Control: no-cache\r\n" }
                h += "\r\n"
                var out = Data(h.utf8); if !head { out.append(r.body) }
                c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// The Mac's LAN IPv4 address (en0, en1, ...), never loopback.
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
