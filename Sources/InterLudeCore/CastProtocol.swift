//  CastProtocol.swift
//  InterLudeCore
//
//  What a speaker controller needs that doesn't depend on a network library: the interface the app drives every
//  kind of speaker through, and the Google Cast v2 wire format. The Mac (Network.framework) and the Linux server
//  (SwiftNIO) each supply their own transport on top of this.

import Foundation

/// Something that happened on a speaker, reported by its controller.
public enum CastEvent: Sendable {
    /// The connection went and didn't come back.
    case lost
    /// Another app started playing on the speaker.
    case takenOver
    /// Someone stopped or paused playback on the speaker itself or in its own app, which Sonos allows.
    case stoppedOnDevice
    /// The volume was changed on the speaker or in its own app, from 0 to 1.
    case volume(Double)
    /// The speaker couldn't open the stream, with its reason.
    case loadFailed(String)
}

/// Everything the app needs from a speaker controller, so Cast and Sonos can be driven the same way.
public protocol CastController: AnyObject, Sendable {
    /// Opens the connection and readies the speaker to play.
    func connect() async throws
    /// Starts playing `url`, showing `title` in the speaker's own app.
    func load(url: URL, title: String) async throws
    /// Sets the speaker's volume, from 0 to 1.
    func setVolume(_ level: Double) async
    /// Stops playback and closes the connection. `events` finishes.
    func stop() async
    /// What happens on the speaker, until `stop`.
    var events: AsyncStream<CastEvent> { get }
    /// How far into the stream the speaker is playing now [s]. Nil until it has said, or if it never does.
    var playbackSeconds: Double? { get }
}

/// A Cast connection or request failed.
public enum CastError: Error, LocalizedError {
    case timeout, closed, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .timeout: "The Cast device did not answer."
        case .closed: "The Cast connection closed."
        case .rejected(let reason): "The Cast device refused the stream (\(reason))."
        }
    }
}

// MARK: Cast v2 protocol

/// Cast v2 constants and the framing of its messages: a 4-byte big-endian length, then a `CastMessage` protobuf whose
/// payload is a JSON string.
public enum CastWire {
    /// Google's Default Media Receiver, which plays an HLS URL without a custom receiver app.
    public static let defaultReceiverAppId = "CC1AD845"
    /// The platform receiver every connection first talks to.
    public static let platformReceiver = "receiver-0"
    /// This end of the connection.
    public static let sender = "sender-0"

    /// The message namespaces InterLude uses.
    public enum Namespace {
        public static let connection = "urn:x-cast:com.google.cast.tp.connection"
        public static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        public static let receiver = "urn:x-cast:com.google.cast.receiver"
        public static let media = "urn:x-cast:com.google.cast.media"
    }

    /// HLS segment formats to offer when loading, in order. Receivers differ in which they accept; an empty
    /// string means leaving the field out and letting the receiver guess.
    public static let segmentFormats = ["ts_aac", "ts", ""]

    /// A protobuf base-128 varint.
    public static func varint(_ value: UInt64) -> [UInt8] {
        var rest = value, out: [UInt8] = []
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 { byte |= 0x80 }               // more bytes follow
            out.append(byte)
        } while rest != 0
        return out
    }

    /// A length-delimited protobuf field (wire type 2) holding `text`.
    public static func string(_ field: Int, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    /// One framed message, ready to write to the connection.
    ///
    /// - Parameters:
    ///   - source: The sender's ID, normally `sender`.
    ///   - destination: The receiver's ID, `platformReceiver` or an app's transport ID.
    ///   - namespace: One of `Namespace`.
    ///   - payload: The JSON message.
    public static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var message: [UInt8] = varint(1 << 3) + varint(0)            // protocol_version = CASTV2_1_0
        message += string(2, source) + string(3, destination) + string(4, namespace)
        message += varint(5 << 3) + varint(0)                        // payload_type = STRING
        message += string(6, payload)
        let length = UInt32(message.count)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + message)
    }

    /// The fields of a `CastMessage` that InterLude reads.
    public struct Message { public var source = "", destination = "", namespace = "", payload = "" }

    /// Decodes a `CastMessage` without its length prefix.
    ///
    /// - Returns: Nil if the bytes are not a well-formed message. Fields InterLude doesn't use are skipped.
    public static func decode(_ bytes: [UInt8]) -> Message? {
        var message = Message(), position = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while position < bytes.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3), wireType = Int(key & 7)
            switch wireType {
            case 0: guard readVarint() != nil else { return nil }
            case 2:
                guard let length = readVarint(), position + Int(length) <= bytes.count else { return nil }
                let text = String(decoding: bytes[position..<(position + Int(length))], as: UTF8.self)
                position += Int(length)
                switch field {
                case 2: message.source = text
                case 3: message.destination = text
                case 4: message.namespace = text
                case 6: message.payload = text
                default: break
                }
            default: return nil
            }
        }
        return message
    }

    /// Takes every complete frame off the front of `buffer`.
    ///
    /// - Parameter buffer: Bytes read from the connection. Complete frames are removed; a partial frame stays for
    ///   the next read.
    /// - Returns: The decoded messages, in order. Frames that don't decode are dropped.
    public static func takeMessages(from buffer: inout [UInt8]) -> [Message] {
        var messages: [Message] = []
        while buffer.count >= 4 {
            let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + length else { break }
            if let message = decode(Array(buffer[4..<(4 + length)])) { messages.append(message) }
            buffer.removeFirst(4 + length)
        }
        return messages
    }

    /// The JSON body of a LOAD request for an HLS stream.
    ///
    /// - Parameters:
    ///   - url: The playlist.
    ///   - title: Shown in the speaker's own app.
    ///   - segmentFormat: One of `segmentFormats`.
    public static func loadMedia(url: URL, title: String, segmentFormat: String) -> [String: Any] {
        var media: [String: Any] = ["contentId": url.absoluteString, "contentType": "application/x-mpegURL", "streamType": "LIVE",
                                    "metadata": ["metadataType": 3, "title": title]]      // 3: a music track
        if !segmentFormat.isEmpty { media["hlsSegmentFormat"] = segmentFormat }
        return media
    }

    /// The transport and session IDs of the Default Media Receiver in a RECEIVER_STATUS answer, or nil if it isn't
    /// running.
    public static func defaultReceiver(in status: [String: Any]) -> (transportId: String, sessionId: String)? {
        guard let receiver = status["status"] as? [String: Any], let apps = receiver["applications"] as? [[String: Any]],
              let app = apps.first(where: { $0["appId"] as? String == defaultReceiverAppId }),
              let transport = app["transportId"] as? String, let session = app["sessionId"] as? String else { return nil }
        return (transport, session)
    }

    /// Whether a RECEIVER_STATUS answer still lists our session of the Default Media Receiver. When it doesn't,
    /// another app has taken the speaker over.
    public static func stillOurs(_ status: [String: Any], sessionId: String?) -> Bool {
        let apps = ((status["status"] as? [String: Any])?["applications"] as? [[String: Any]]) ?? []
        return apps.contains { $0["appId"] as? String == defaultReceiverAppId && $0["sessionId"] as? String == sessionId }
    }
}
