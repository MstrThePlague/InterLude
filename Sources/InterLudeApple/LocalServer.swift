//  LocalServer.swift
//  InterLudeApple
//
//  The Mac's web server, and finding the Mac's addresses on the LAN and on Tailscale for the links it hands out.

import Foundation
import Network
import InterLudeCore

/// A small HTTP server on NWListener.
///
/// It serves the playlist and segments to AVPlayer (on loopback) and to speakers (on the LAN), and the web app to the
/// panel and the phone remote. Every path starts with a random token, so other devices can't guess the URLs. POST
/// carries no body: commands put their arguments in the query.
public final class LocalServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "interlude.server")
    public let port: UInt16
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    /// - Parameters:
    ///   - port: The TCP port to listen on, on every interface.
    ///   - handler: Answers each request.
    public init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port; self.handler = handler
    }

    /// Starts listening. Throws if the port is in use.
    public func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port), port > 0 else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: .tcp, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() { listener?.cancel(); listener = nil }

    /// Answers one request per connection: the players ask for small files, so keep-alive isn't worth the complexity.
    /// Only the request line is read; headers are ignored.
    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [handler] data, _, _, err in
            guard let data, err == nil, let text = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let first = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            guard var req = HTTPRequest(requestLine: first) else {
                c.send(content: Data("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
                return
            }
            // Taken from the connection itself, so a request can't claim to be local.
            if case .hostPort(let host, _) = c.endpoint {
                let address = "\(host)"
                req.fromLoopback = address == "127.0.0.1" || address == "::1" || address.hasPrefix("::1%") || address == "::ffff:127.0.0.1"
            }
            let head = req.method == "HEAD"
            Task {
                let response = await handler(req)
                if let stream = response.stream { Self.send(stream, contentType: response.contentType, head: head, on: c); return }
                var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n"
                if response.noCache { header += "Cache-Control: no-cache\r\n" }
                header += "\r\n"
                var out = Data(header.utf8); if !head { out.append(response.body) }
                c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// Sends a body with no end, such as the AAC stream for a Sonos speaker, until either side stops.
    private static func send(_ stream: AsyncStream<Data>, contentType: String, head: Bool, on c: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        guard !head else { c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        Task {
            for await chunk in stream {
                // Wait for each chunk to go before sending the next, so a slow speaker isn't buried in data.
                let sent = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    c.send(content: chunk, completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
                }
                if !sent { break }
            }
            c.cancel()
        }
    }

    /// The Mac's LAN IPv4 address, on en0 if it has one, otherwise the first other Ethernet or Wi-Fi interface.
    /// Never loopback or link-local, which a speaker can't reach.
    public static func lanAddress() -> String? {
        var best: String?
        for (name, address) in ipv4Addresses() where name.hasPrefix("en") && !address.hasPrefix("169.254") {
            if name == "en0" { return address }
            best = best ?? address
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

    /// The DNS name for an IPv4 address, or nil if it has none.
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
        return r == 0 ? string(fromNullTerminated: host) : nil
    }

    /// The Mac App Store and standalone builds keep the CLI in the app; Homebrew puts it on the path.
    private static let tailscaleCLIs = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    /// `tailscale status --json` for this Mac alone, given up after 3 seconds.
    private static func tailscaleStatus() -> Data? {
        guard let path = tailscaleCLIs.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json", "--peers=false"]
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut { process.terminate(); return nil }
        return process.terminationStatus == 0 ? out.fileHandleForReading.readDataToEndOfFile() : nil
    }

    /// The text in a C buffer, up to its first null.
    private static func string(fromNullTerminated buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every up, non-loopback IPv4 address, with its interface name.
    private static func ipv4Addresses() -> [(name: String, addr: String)] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var found: [(name: String, addr: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0, (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            found.append((String(cString: interface.ifa_name), string(fromNullTerminated: host)))
        }
        return found
    }
}
