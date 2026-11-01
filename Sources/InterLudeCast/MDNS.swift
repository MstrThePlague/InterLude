import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A Chromecast or Cast group found on the network.
public struct CastSpeaker: Sendable, Hashable, Identifiable {
    /// The DNS-SD instance name, which stays the same across restarts.
    public var id: String
    public var name: String
    public var model: String
    public var host: String
    public var port: Int
    public var isGroup: Bool { model == "Google Cast Group" }
    public init(id: String, name: String, model: String, host: String, port: Int) {
        self.id = id; self.name = name; self.model = model; self.host = host; self.port = port
    }
}

/// Finds Cast devices and Sonos speakers with multicast DNS, without Avahi or Bonjour: interlude-server runs
/// in a container, where the host's mDNS daemon isn't reachable. Answers come back by multicast, so a gateway's mDNS
/// proxy can relay them from another VLAN.
public enum MDNS {
    static let service = "_googlecast._tcp.local"
    static let sonosService = "_sonos._tcp.local"

    /// Asks for Cast services and gathers the answers for `timeout` seconds.
    public static func browseCast(timeout: Double = 3) -> [CastSpeaker] {
        speakers(from: records(service, timeout: timeout))
    }

    /// Asks for `service` and gathers every record that comes back for `timeout` seconds.
    static func records(_ service: String, timeout: Double) -> [Record] {
        guard let fd = openSocket() else { return [] }
        defer { close(fd) }
        ask(fd, service)
        var records: [Record] = []
        let end = Date().addingTimeInterval(timeout)
        var askedAgain = false
        while Date() < end {
            if !askedAgain && Date() > end.addingTimeInterval(-timeout / 2) { ask(fd, service); askedAgain = true }   // once more, for lost packets
            records += receive(fd)
        }
        return records
    }

    // MARK: Socket

    /// A UDP socket on port 5353 in the mDNS multicast group, which hears every answer and announcement on the
    /// network, not only replies to its own questions. Reads give up after a quarter of a second.
    static func openSocket() -> Int32? {
        #if os(Linux)
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #else
        let datagram = SOCK_DGRAM
        #endif
        let fd = socket(AF_INET, datagram, Int32(IPPROTO_UDP))
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(5353).bigEndian; addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(fd); return nil }
        var group = ip_mreq()
        group.imr_multiaddr.s_addr = inet_addr("224.0.0.251"); group.imr_interface.s_addr = INADDR_ANY
        setsockopt(fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &group, socklen_t(MemoryLayout<ip_mreq>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func ask(_ fd: Int32, _ service: String) {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET); dest.sin_port = UInt16(5353).bigEndian; dest.sin_addr.s_addr = inet_addr("224.0.0.251")
        _ = query(service).withUnsafeBytes { q in
            withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, q.baseAddress, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }

    /// The records in the next packet, or none if nothing came within the read timeout.
    static func receive(_ fd: Int32) -> [Record] {
        var buf = [UInt8](repeating: 0, count: 9000)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? parse(Array(buf[0..<n])) : []
    }

    // MARK: Messages

    enum Record: Hashable {
        case ptr(name: String, target: String)
        /// A PTR record with a time to live of zero: the instance is leaving the network.
        case goodbye(name: String, target: String)
        case srv(name: String, target: String, port: Int)
        case txt(name: String, values: [String: String])
        case a(name: String, address: String)
    }

    static func query(_ name: String) -> [UInt8] {
        var q: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]        // id 0, standard query, one question
        q += encodeName(name)
        q += [0, 12, 0, 1]                                         // PTR, IN
        return q
    }

    static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") { let b = Array(label.utf8); out.append(UInt8(b.count)); out += b }
        return out + [0]
    }

    /// Reads a possibly compressed name at `offset`. Returns it and the offset just past it in the original position.
    static func readName(_ m: [UInt8], _ offset: Int) -> (String, Int)? {
        var labels: [String] = [], i = offset, end: Int?, jumps = 0
        while i < m.count {
            let len = Int(m[i])
            if len == 0 { return (labels.joined(separator: "."), end ?? i + 1) }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < m.count, jumps < 20 else { return nil }
                if end == nil { end = i + 2 }
                i = (len & 0x3F) << 8 | Int(m[i + 1]); jumps += 1; continue
            }
            guard i + 1 + len <= m.count else { return nil }
            labels.append(String(decoding: m[(i + 1)...(i + len)], as: UTF8.self))
            i += 1 + len
        }
        return nil
    }

    static func parse(_ m: [UInt8]) -> [Record] {
        guard m.count >= 12 else { return [] }
        func u16(_ i: Int) -> Int { Int(m[i]) << 8 | Int(m[i + 1]) }
        let qd = u16(4), counts = u16(6) + u16(8) + u16(10)
        var i = 12
        for _ in 0..<qd { guard let (_, next) = readName(m, i) else { return [] }; i = next + 4 }
        var out: [Record] = []
        for _ in 0..<counts {
            guard let (name, next) = readName(m, i), next + 10 <= m.count else { break }
            let type = u16(next), len = u16(next + 8), data = next + 10
            guard data + len <= m.count else { break }
            switch type {
            case 12:
                let ttl = u16(next + 4) << 16 | u16(next + 6)
                if let (t, _) = readName(m, data) { out.append(ttl == 0 ? .goodbye(name: name, target: t) : .ptr(name: name, target: t)) }
            case 33: if len >= 6, let (t, _) = readName(m, data + 6) { out.append(.srv(name: name, target: t, port: u16(data + 4))) }
            case 16:
                var values: [String: String] = [:], j = data
                while j < data + len {
                    let l = Int(m[j]); guard j + 1 + l <= data + len else { break }
                    let s = String(decoding: m[(j + 1)..<(j + 1 + l)], as: UTF8.self)
                    if let eq = s.firstIndex(of: "=") { values[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
                    j += 1 + l
                }
                out.append(.txt(name: name, values: values))
            case 1: if len == 4 { out.append(.a(name: name, address: "\(m[data]).\(m[data + 1]).\(m[data + 2]).\(m[data + 3])")) }
            default: break
            }
            i = data + len
        }
        return out
    }

    /// Each instance of `service` whose address came back, by its instance name (without the service).
    static func instances(of service: String, from records: [Record]) -> [(id: String, host: String, port: Int, txt: [String: String])] {
        var out: [String: (id: String, host: String, port: Int, txt: [String: String])] = [:]
        let lower = { (s: String) in s.lowercased() }
        for case .ptr(let name, let instance) in records where lower(name) == service {
            guard let (target, port) = records.lazy.compactMap({ r -> (String, Int)? in
                      if case .srv(let n, let t, let p) = r, lower(n) == lower(instance) { (t, p) } else { nil } }).first,
                  let address = records.lazy.compactMap({ r -> String? in
                      if case .a(let n, let a) = r, lower(n) == lower(target) { a } else { nil } }).first else { continue }
            let txt = records.lazy.compactMap { r -> [String: String]? in
                if case .txt(let n, let v) = r, lower(n) == lower(instance) { v } else { nil } }.first ?? [:]
            let id = String(instance.dropLast(service.count + 1))
            out[id] = (id, address, port, txt)
        }
        return Array(out.values)
    }

    static func speakers(from records: [Record]) -> [CastSpeaker] {
        instances(of: service, from: records)
            .map { CastSpeaker(id: $0.id, name: $0.txt["fn"] ?? $0.id, model: $0.txt["md"] ?? "", host: $0.host, port: $0.port) }
            .sorted { $0.name < $1.name }
    }
}

/// Watches the network for Cast devices and Sonos speakers as they come and go. It keeps one multicast DNS socket
/// open, so it hears a speaker announce itself when it joins and say goodbye when it leaves, and asks every
/// `askEvery` seconds, so one that vanishes without a goodbye (unplugged) drops out once it stops answering.
public final class MDNSWatcher: @unchecked Sendable {
    public struct Found: Equatable, Sendable {
        public var cast: [CastSpeaker] = []
        /// Sonos speakers' addresses. Any one of them describes the household's rooms and groups (`Sonos.groups`).
        public var sonos: [String] = []
    }

    /// The speakers found, each time that changes. The first comes a few seconds after `start`, once the opening
    /// questions have been answered, so the list doesn't fill one speaker at a time.
    public let updates: AsyncStream<Found>
    private let cont: AsyncStream<Found>.Continuation
    private let askEvery: TimeInterval
    private let lock = NSLock()
    private var running = false

    public init(askEvery: TimeInterval = 30) {
        self.askEvery = askEvery
        (updates, cont) = AsyncStream.makeStream(of: Found.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard lock.withLock({ defer { running = true }; return !running }) else { return }
        Thread.detachNewThread { [self] in run() }
    }

    public func stop() { lock.withLock { running = false } }

    private func run() {
        guard let fd = MDNS.openSocket() else { cont.yield(Found()); cont.finish(); return }
        defer { close(fd); cont.finish() }
        var cache = MDNSCache(lifetime: askEvery * 2.5)
        var last: Found?
        let started = Date()
        var nextAsk = started, asked = 0
        while lock.withLock({ running }) {
            let now = Date()
            if now >= nextAsk {
                MDNS.ask(fd, MDNS.service); MDNS.ask(fd, MDNS.sonosService)
                asked += 1
                nextAsk = now.addingTimeInterval(asked < 3 ? 1 : askEvery)      // three quick rounds at first, for lost packets
            }
            cache.add(MDNS.receive(fd), at: now)
            cache.expire(now)
            guard now.timeIntervalSince(started) >= 3 else { continue }
            let records = cache.records
            let found = Found(cast: MDNS.speakers(from: records),
                              sonos: Set(MDNS.instances(of: MDNS.sonosService, from: records).map(\.host)).sorted())
            if found != last { cont.yield(found); last = found }
        }
    }
}

/// Every mDNS record heard lately, with when it was last heard. A record not heard again within `lifetime` is
/// forgotten, and a goodbye forgets its instance at once.
struct MDNSCache {
    let lifetime: TimeInterval
    private var heard: [MDNS.Record: Date] = [:]

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    mutating func add(_ records: [MDNS.Record], at now: Date) {
        for r in records {
            if case .goodbye(_, let instance) = r { forget(instance) } else { heard[r] = now }
        }
    }

    mutating func expire(_ now: Date) { heard = heard.filter { now.timeIntervalSince($0.value) < lifetime } }

    /// Newest first, so a speaker's latest address wins over one it has since given up.
    var records: [MDNS.Record] { heard.sorted { $0.value > $1.value }.map(\.key) }

    private mutating func forget(_ instance: String) {
        let i = instance.lowercased()
        heard = heard.filter { r, _ in
            switch r {
            case .ptr(_, let t): t.lowercased() != i
            case .srv(let n, _, _), .txt(let n, _): n.lowercased() != i
            default: true
            }
        }
    }
}

/// The machine's address on the home network, for the stream URL a Cast device fetches. Skips loopback, Docker's
/// bridges and Tailscale, which a speaker can't reach.
public enum LocalAddress {
    public static func lan() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var found: [(name: String, address: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET), (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (i.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: i.ifa_name)
            guard !["docker", "br-", "veth", "tailscale", "virbr", "utun"].contains(where: name.hasPrefix) else { continue }
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { continue }
            let address = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !address.hasPrefix("169.254."), !isTailscale(address) else { continue }
            found.append((name, address))
        }
        return found.first(where: { $0.address.hasPrefix("10.") || $0.address.hasPrefix("192.168.") })?.address ?? found.first?.address
    }

    static func isTailscale(_ a: String) -> Bool {
        let p = a.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }
}
