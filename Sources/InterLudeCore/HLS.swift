import Foundation

/// Every BBC HLS segment is 6.4 seconds long (300 AAC frames of 1024 samples at 48 kHz).
public let segmentDuration = 6.4

/// The parts of a BBC playlist InterLude uses.
public struct ParsedPlaylist: Sendable {
    public var firstSequence = 0
    public var names: [String] = []
    public var programDate: Date?
    public var lastSequence: Int { firstSequence + names.count - 1 }
}

/// Reading the BBC's playlists and writing InterLude's own.
public enum HLS {
    public static func parse(_ data: Data) -> ParsedPlaylist {
        var p = ParsedPlaylist()
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { p.firstSequence = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let s = String(line.dropFirst(25)); p.programDate = f.date(from: s) ?? g.date(from: s)
            } else if !line.hasPrefix("#") { p.names.append(String(line)) }
        }
        return p
    }

    /// Splits "bbc_6music-audio=320000-279967301.ts" into ("bbc_6music-audio=320000-", 279967301).
    public static func splitName(_ name: String) -> (prefix: String, index: Int)? {
        guard name.hasSuffix(".ts"), let dash = name.lastIndex(of: "-") else { return nil }
        let digits = name[name.index(after: dash)...].dropLast(3)
        guard let i = Int(digits) else { return nil }
        return (String(name[...dash]), i)
    }

    /// Start of a segment on the stream's clock. A segment's index is its *end* time divided by 6.4, which is
    /// why one is subtracted (checked against `EXT-X-PROGRAM-DATE-TIME`; see docs/findings.md).
    public static func startTime(ofIndex i: Int) -> Date {
        Date(timeIntervalSince1970: Double(i - 1) * segmentDuration)
    }

    /// The app's own sliding-window playlist. No `EXT-X-DISCONTINUITY` is ever written: replacement segments carry
    /// the timestamps of the ones they stand in for, so the player sees one continuous stream.
    public static func write(mediaSequence: Int, segments: [Int], segmentPath: (Int) -> String) -> String {
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:7\n#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)\n"
        for i in segments { s += "#EXTINF:6.4,\n\(segmentPath(i))\n" }
        return s
    }
}
