import Foundation
import Network
import InterLudeCore

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
        var best: String?
        for (name, addr) in ipv4Addresses() where name.hasPrefix("en") && !addr.hasPrefix("169.254") {
            if name == "en0" { return addr }
            best = best ?? addr
        }
        return best
    }

    /// The Mac's Tailscale IPv4 address, so a phone on the tailnet can reach it away from home. Nil when Tailscale is not up.
    public static func tailscaleAddress() -> String? {
        ipv4Addresses().first { Tailnet.isTailscale($0.addr) }?.addr
    }

    /// The Mac's MagicDNS name, such as `mac.tailnet.ts.net`. Nil when Tailscale is not up or the name can't be found.
    /// It asks DNS for the name of the Tailscale address, then the Tailscale CLI, which also covers a Mac set not to
    /// use Tailscale's DNS. Both work in the App Sandbox. This can wait on DNS or the CLI, so call it off the main thread.
    public static func tailscaleName() -> String? {
        guard let ip = tailscaleAddress() else { return nil }
        return reverseLookup(ip).flatMap(Tailnet.magicDNSName) ?? tailscaleStatus().flatMap(Tailnet.magicDNSName(statusJSON:))
    }

    private static func reverseLookup(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return r == 0 ? String(cString: host) : nil
    }

    /// The Mac App Store and standalone builds keep the CLI in the app; Homebrew puts it on the path.
    private static let tailscaleCLIs = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    /// `tailscale status --json` for this Mac alone, given up after 3 seconds.
    private static func tailscaleStatus() -> Data? {
        guard let path = tailscaleCLIs.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["status", "--json", "--peers=false"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut { p.terminate(); return nil }
        return p.terminationStatus == 0 ? out.fileHandleForReading.readDataToEndOfFile() : nil
    }

    /// Every up, non-loopback IPv4 address, with its interface name.
    private static func ipv4Addresses() -> [(name: String, addr: String)] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var out: [(name: String, addr: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            out.append((String(cString: i.ifa_name), String(cString: host)))
        }
        return out
    }
}
