//  HLS.swift
//  InterLudeCore
//
//  Reads the BBC's HLS playlists and writes InterLude's own. The BBC numbers its segments so that a segment's index
//  is its end time divided by the segment duration, which lets every part of InterLude turn an index into a time
//  without asking the network.

import Foundation

/// Length of every BBC HLS segment [s]: 300 AAC frames of 1024 samples at 48 kHz.
public let segmentDuration = 6.4

/// Samples in one segment of 48 kHz audio, per channel.
public let samplesPerSegment = 307_200

/// The parts of a BBC playlist InterLude uses.
public struct ParsedPlaylist: Sendable {
    /// `EXT-X-MEDIA-SEQUENCE`: the index of the first segment listed.
    public var firstSequence = 0
    /// Segment file names in order, such as `bbc_6music-audio=320000-279967301.ts`.
    public var names: [String] = []
    /// `EXT-X-PROGRAM-DATE-TIME`, when present.
    public var programDate: Date?
    /// The index of the newest segment listed.
    public var lastSequence: Int { firstSequence + names.count - 1 }
}

/// Reading the BBC's playlists and writing InterLude's own.
public enum HLS {
    /// Extracts the media sequence, program date and segment names from a playlist.
    public static func parse(_ data: Data) -> ParsedPlaylist {
        var playlist = ParsedPlaylist()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { playlist.firstSequence = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let stamp = String(line.dropFirst(25))
                playlist.programDate = fractional.date(from: stamp) ?? whole.date(from: stamp)
            } else if !line.hasPrefix("#") { playlist.names.append(String(line)) }
        }
        return playlist
    }

    /// Splits a segment name into its prefix and index.
    ///
    /// For example, `bbc_6music-audio=320000-279967301.ts` gives `("bbc_6music-audio=320000-", 279967301)`.
    ///
    /// - Returns: Nil if the name doesn't end in `-<digits>.ts`.
    public static func splitName(_ name: String) -> (prefix: String, index: Int)? {
        guard name.hasSuffix(".ts"), let dash = name.lastIndex(of: "-") else { return nil }
        let digits = name[name.index(after: dash)...].dropLast(3)
        guard let index = Int(digits) else { return nil }
        return (String(name[...dash]), index)
    }

    /// The start of a segment on the stream's clock.
    ///
    /// A segment's index is its *end* time divided by 6.4 s, so one is subtracted. This was checked against
    /// `EXT-X-PROGRAM-DATE-TIME`; see docs/archive/findings.md.
    public static func startTime(ofIndex index: Int) -> Date {
        Date(timeIntervalSince1970: Double(index - 1) * segmentDuration)
    }

    /// Writes InterLude's own sliding-window playlist.
    ///
    /// No `EXT-X-DISCONTINUITY` is ever written: replacement segments carry the timestamps of the segments they
    /// stand in for, so the player sees one continuous stream.
    ///
    /// - Parameters:
    ///   - mediaSequence: The sequence number of the first segment listed.
    ///   - segments: The indices to list, oldest first.
    ///   - segmentPath: The URI to write for each index, relative to the playlist.
    public static func write(mediaSequence: Int, segments: [Int], segmentPath: (Int) -> String) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:7\n#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)\n"
        for index in segments { text += "#EXTINF:6.4,\n\(segmentPath(index))\n" }
        return text
    }
}
