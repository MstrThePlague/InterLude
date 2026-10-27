import Foundation

// What a Cast sender needs that doesn't depend on the network library: the controller interface and the wire format.

public enum CastEvent: Sendable { case lost, takenOver, loadFailed(String) }

/// Everything the app needs from a Cast implementation, so the library can be swapped.
public protocol CastController: AnyObject, Sendable {
    func connect() async throws
    func load(url: URL, title: String) async throws
    func setVolume(_ level: Double) async
    func stop() async
    var events: AsyncStream<CastEvent> { get }
    /// Seconds into the stream the device is playing now, when it has said. Nil until its first status.
    var playbackSeconds: Double? { get }
}

public enum CastError: Error, LocalizedError {
    case timeout, closed, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .timeout: "The Cast device did not answer."
        case .closed: "The Cast connection closed."
        case .rejected(let r): "The Cast device refused the stream (\(r))."
        }
    }
}

// MARK: Protobuf (CastMessage) and framing

public enum CastWire {
    public static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    public static func string(_ field: Int, _ s: String) -> [UInt8] {
        let b = Array(s.utf8); return varint(UInt64(field << 3 | 2)) + varint(UInt64(b.count)) + b
    }

    public static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var m: [UInt8] = varint(1 << 3) + varint(0)                 // protocol_version = CASTV2_1_0
        m += string(2, source) + string(3, destination) + string(4, namespace)
        m += varint(5 << 3) + varint(0)                              // payload_type = STRING
        m += string(6, payload)
        let len = UInt32(m.count)
        return Data([UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)] + m)
    }

    public struct Message { public var source = "", destination = "", namespace = "", payload = "" }

    public static func decode(_ b: [UInt8]) -> Message? {
        var m = Message(), i = 0
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count { let c = b[i]; i += 1; r |= UInt64(c & 0x7F) << shift; if c & 0x80 == 0 { return r }; shift += 7 }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3), wt = Int(key & 7)
            switch wt {
            case 0: guard readVarint() != nil else { return nil }
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return nil }
                let s = String(decoding: b[i..<(i + Int(len))], as: UTF8.self); i += Int(len)
                switch field { case 2: m.source = s; case 3: m.destination = s; case 4: m.namespace = s; case 6: m.payload = s; default: break }
            default: return nil
            }
        }
        return m
    }
}
