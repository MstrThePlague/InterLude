//  MDNS.swift
//  InterLudeCast
//
//  Finds Cast devices and Sonos speakers with multicast DNS, without Avahi or Bonjour: interlude-server runs in a
//  container, where the host's mDNS daemon isn't reachable. Answers come back by multicast, so a gateway's mDNS proxy
//  can relay them from another VLAN. Also finds the machine's own LAN address, for the stream URL speakers fetch.

import Foundation
import InterLudeCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A Chromecast or Cast group found on the network.
public struct CastSpeaker: Sendable, Hashable, Identifiable {
    /// The DNS-SD instance name, which stays the same across restarts.
    public var id: String
    /// The name set in the Google Home app.
    public var name: String
    /// The model, such as "Chromecast Audio" or "Google Cast Group".
    public var model: String
    public var host: String
    public var port: Int
    public var isGroup: Bool { model == "Google Cast Group" }
    public init(id: String, name: String, model: String, host: String, port: Int) {
        self.id = id; self.name = name; self.model = model; self.host = host; self.port = port
    }
}

/// Multicast DNS messages and the socket they travel on.
public enum MDNS {
    static let service = "_googlecast._tcp.local"
    static let sonosService = "_sonos._tcp.local"
    /// The mDNS port and IPv4 group.
    static let port: UInt16 = 5353
    static let group = "224.0.0.251"

    // MARK: Socket

    /// A UDP socket on port 5353 in the mDNS multicast group.
    ///
    /// It hears every answer and announcement on the network, not only replies to its own questions. Reads give up
    /// after a quarter of a second, so the caller can do other work between them.
    ///
    /// - Returns: The socket's descriptor, or nil if it couldn't be opened or bound.
    static func openSocket() -> Int32? {
        #if os(Linux)
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #else
        let datagram = SOCK_DGRAM
        #endif
        let socketFD = socket(AF_INET, datagram, Int32(IPPROTO_UDP))
        guard socketFD >= 0 else { return nil }
        var yes: Int32 = 1
        // Share the port with any other mDNS listener on the machine.
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(socketFD); return nil }
        var membership = ip_mreq()
        membership.imr_multiaddr.s_addr = inet_addr(group); membership.imr_interface.s_addr = INADDR_ANY
        setsockopt(socketFD, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return socketFD
    }

    /// Asks the network for every instance of `service`.
    static func ask(_ socketFD: Int32, _ service: String) {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET); destination.sin_port = port.bigEndian; destination.sin_addr.s_addr = inet_addr(group)
        _ = query(service).withUnsafeBytes { packet in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, packet.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// The records in the next packet, or none if nothing came within the read timeout.
    static func receive(_ socketFD: Int32) -> [Record] {
        var packet = [UInt8](repeating: 0, count: 9000)
        let length = recv(socketFD, &packet, packet.count, 0)
        return length > 0 ? parse(Array(packet[0..<length])) : []
    }

    // MARK: Messages

    /// The resource records InterLude reads.
    enum Record: Hashable {
        /// A service type pointing at an instance.
        case ptr(name: String, target: String)
        /// A PTR record with a time to live of zero: the instance is leaving the network.
        case goodbye(name: String, target: String)
        /// An instance's host and port.
        case srv(name: String, target: String, port: Int)
        /// An instance's key-value metadata.
        case txt(name: String, values: [String: String])
        /// A host's IPv4 address.
        case a(name: String, address: String)
    }

    /// A query packet asking for the PTR records of `name`.
    static func query(_ name: String) -> [UInt8] {
        var packet: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]       // ID 0, standard query, one question
        packet += encodeName(name)
        packet += [0, 12, 0, 1]                                         // type PTR, class IN
        return packet
    }

    /// A DNS name as length-prefixed labels.
    static func encodeName(_ name: String) -> [UInt8] {
        var encoded: [UInt8] = []
        for label in name.split(separator: ".") { let bytes = Array(label.utf8); encoded.append(UInt8(bytes.count)); encoded += bytes }
        return encoded + [0]
    }

    /// Reads a name, following compression pointers.
    ///
    /// - Parameters:
    ///   - message: The whole packet, which pointers refer into.
    ///   - offset: Where the name starts.
    /// - Returns: The name, and the offset just past it where it started, or nil if it runs off the packet or
    ///   follows more than 20 pointers.
    static func readName(_ message: [UInt8], _ offset: Int) -> (String, Int)? {
        var labels: [String] = [], position = offset, end: Int?, jumps = 0
        while position < message.count {
            let length = Int(message[position])
            if length == 0 { return (labels.joined(separator: "."), end ?? position + 1) }
            if length & 0xC0 == 0xC0 {
                guard position + 1 < message.count, jumps < 20 else { return nil }
                if end == nil { end = position + 2 }
                position = (length & 0x3F) << 8 | Int(message[position + 1]); jumps += 1; continue
            }
            guard position + 1 + length <= message.count else { return nil }
            labels.append(String(decoding: message[(position + 1)...(position + length)], as: UTF8.self))
            position += 1 + length
        }
        return nil
    }

    /// The PTR, SRV, TXT and A records in a packet's answer, authority and additional sections. Anything malformed
    /// ends the reading, keeping what came before.
    static func parse(_ message: [UInt8]) -> [Record] {
        guard message.count >= 12 else { return [] }
        func u16(_ i: Int) -> Int { Int(message[i]) << 8 | Int(message[i + 1]) }
        let questions = u16(4), records = u16(6) + u16(8) + u16(10)
        var position = 12
        for _ in 0..<questions { guard let (_, next) = readName(message, position) else { return [] }; position = next + 4 }
        var found: [Record] = []
        for _ in 0..<records {
            guard let (name, next) = readName(message, position), next + 10 <= message.count else { break }
            let type = u16(next), length = u16(next + 8), data = next + 10
            guard data + length <= message.count else { break }
            switch type {
            case 12:
                let timeToLive = u16(next + 4) << 16 | u16(next + 6)
                if let (target, _) = readName(message, data) {
                    found.append(timeToLive == 0 ? .goodbye(name: name, target: target) : .ptr(name: name, target: target))
                }
            case 33:
                // Priority and weight come first; the port, then the target.
                if length >= 6, let (target, _) = readName(message, data + 6) { found.append(.srv(name: name, target: target, port: u16(data + 4))) }
            case 16:
                var values: [String: String] = [:], entry = data
                while entry < data + length {
                    let entryLength = Int(message[entry]); guard entry + 1 + entryLength <= data + length else { break }
                    let text = String(decoding: message[(entry + 1)..<(entry + 1 + entryLength)], as: UTF8.self)
                    if let equals = text.firstIndex(of: "=") { values[String(text[..<equals])] = String(text[text.index(after: equals)...]) }
                    entry += 1 + entryLength
                }
                found.append(.txt(name: name, values: values))
            case 1:
                if length == 4 { found.append(.a(name: name, address: "\(message[data]).\(message[data + 1]).\(message[data + 2]).\(message[data + 3])")) }
            default: break
            }
            position = data + length
        }
        return found
    }

    /// Each instance of `service` whose address came back.
    ///
    /// - Parameters:
    ///   - service: The service type, such as `_googlecast._tcp.local`.
    ///   - records: Records heard, newest first, so a later address wins.
    /// - Returns: For each instance: its name without the service, its address, its port and its TXT values.
    static func instances(of service: String, from records: [Record]) -> [(id: String, host: String, port: Int, txt: [String: String])] {
        var found: [String: (id: String, host: String, port: Int, txt: [String: String])] = [:]
        let lower = { (name: String) in name.lowercased() }
        for case .ptr(let name, let instance) in records where lower(name) == service {
            guard let (target, port) = records.lazy.compactMap({ record -> (String, Int)? in
                      if case .srv(let n, let t, let p) = record, lower(n) == lower(instance) { (t, p) } else { nil } }).first,
                  let address = records.lazy.compactMap({ record -> String? in
                      if case .a(let n, let a) = record, lower(n) == lower(target) { a } else { nil } }).first else { continue }
            let txt = records.lazy.compactMap { record -> [String: String]? in
                if case .txt(let n, let v) = record, lower(n) == lower(instance) { v } else { nil } }.first ?? [:]
            let id = String(instance.dropLast(service.count + 1))
            found[id] = (id, address, port, txt)
        }
        return Array(found.values)
    }

    /// The Cast devices among `records`, sorted by name.
    static func speakers(from records: [Record]) -> [CastSpeaker] {
        instances(of: service, from: records)
            .map { CastSpeaker(id: $0.id, name: $0.txt["fn"] ?? $0.id, model: $0.txt["md"] ?? "", host: $0.host, port: $0.port) }
            .sorted { $0.name < $1.name }
    }
}

/// Watches the network for Cast devices and Sonos speakers as they come and go.
///
/// It keeps one multicast DNS socket open, so it hears a speaker announce itself when it joins and say goodbye when
/// it leaves, and asks every `askEvery` seconds, so one that vanishes without a goodbye (unplugged) drops out once it
/// stops answering.
public final class MDNSWatcher: @unchecked Sendable {
    /// What was found.
    public struct Found: Equatable, Sendable {
        public var cast: [CastSpeaker] = []
        /// Sonos speakers' addresses. Any one of them describes the household's rooms and groups (`Sonos.groups`).
        public var sonos: [String] = []
    }

    /// The speakers found, each time that changes. The first comes a few seconds after `start`, once the opening
    /// questions have been answered, so the list doesn't fill one speaker at a time.
    public let updates: AsyncStream<Found>
    private let continuation: AsyncStream<Found>.Continuation
    /// [s]
    private let askEvery: TimeInterval
    private let lock = NSLock()
    private var running = false

    /// - Parameter askEvery: How often to ask again [s].
    public init(askEvery: TimeInterval = 30) {
        self.askEvery = askEvery
        (updates, continuation) = AsyncStream.makeStream(of: Found.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts watching on a thread of its own. Calling it again does nothing.
    public func start() {
        guard lock.withLock({ defer { running = true }; return !running }) else { return }
        Thread.detachNewThread { [self] in run() }
    }

    /// Stops watching within a quarter of a second, and finishes `updates`.
    public func stop() { lock.withLock { running = false } }

    private func run() {
        guard let socketFD = MDNS.openSocket() else { continuation.yield(Found()); continuation.finish(); return }
        defer { close(socketFD); continuation.finish() }
        var cache = MDNSCache(lifetime: askEvery * 2.5)
        var last: Found?
        let started = Date()
        var nextAsk = started, asked = 0
        while lock.withLock({ running }) {
            let now = Date()
            if now >= nextAsk {
                MDNS.ask(socketFD, MDNS.service); MDNS.ask(socketFD, MDNS.sonosService)
                asked += 1
                nextAsk = now.addingTimeInterval(asked < 3 ? 1 : askEvery)      // three quick rounds at first, for lost packets
            }
            cache.add(MDNS.receive(socketFD), at: now)
            cache.expire(now)
            guard now.timeIntervalSince(started) >= 3 else { continue }
            let records = cache.records
            let found = Found(cast: MDNS.speakers(from: records),
                              sonos: Set(MDNS.instances(of: MDNS.sonosService, from: records).map(\.host)).sorted())
            if found != last { continuation.yield(found); last = found }
        }
    }
}

/// Every mDNS record heard lately, with when it was last heard.
///
/// A record not heard again within `lifetime` is forgotten, and a goodbye forgets its instance at once.
struct MDNSCache {
    /// [s]
    let lifetime: TimeInterval
    private var heard: [MDNS.Record: Date] = [:]

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    mutating func add(_ records: [MDNS.Record], at now: Date) {
        for record in records {
            if case .goodbye(_, let instance) = record { forget(instance) } else { heard[record] = now }
        }
    }

    mutating func expire(_ now: Date) { heard = heard.filter { now.timeIntervalSince($0.value) < lifetime } }

    /// Newest first, so a speaker's latest address wins over one it has since given up.
    var records: [MDNS.Record] { heard.sorted { $0.value > $1.value }.map(\.key) }

    private mutating func forget(_ instance: String) {
        let name = instance.lowercased()
        heard = heard.filter { record, _ in
            switch record {
            case .ptr(_, let target): target.lowercased() != name
            case .srv(let n, _, _), .txt(let n, _): n.lowercased() != name
            default: true
            }
        }
    }
}

/// The machine's address on the home network.
public enum LocalAddress {
    /// Interface name prefixes a speaker can't reach: Docker's bridges, virtual machines and VPN tunnels.
    static let unreachable = ["docker", "br-", "veth", "tailscale", "virbr", "utun"]

    /// The machine's LAN IPv4 address, for the stream URL a Cast or Sonos speaker fetches.
    ///
    /// Skips loopback, link-local addresses, Docker's bridges and Tailscale, and prefers a private 10.x or 192.168.x
    /// address when there are several.
    public static func lan() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var found: [(name: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let socketAddress = interface.ifa_addr, socketAddress.pointee.sa_family == sa_family_t(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard !unreachable.contains(where: name.hasPrefix) else { continue }
            var inAddress = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inAddress, &text, socklen_t(text.count)) != nil else { continue }
            let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !address.hasPrefix("169.254."), !Tailnet.isTailscale(address) else { continue }
            found.append((name, address))
        }
        return found.first(where: { $0.address.hasPrefix("10.") || $0.address.hasPrefix("192.168.") })?.address ?? found.first?.address
    }
}
