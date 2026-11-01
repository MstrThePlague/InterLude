//  AACStream.swift
//  InterLudeCore
//
//  Sonos speakers can't play HLS, so they are given one continuous ADTS AAC stream made from InterLude's own
//  playlist. The stream reads `live.m3u8` exactly as a player would, so the delay and the muted or skipped news are
//  the same on a Sonos speaker as everywhere else.

import Foundation

/// Turns InterLude's own playlist into one continuous ADTS AAC stream.
///
/// It behaves as a player does: it reads `live.m3u8` through `fetch`, starts the usual few segments behind the
/// newest listed, and sends each segment's audio frames as the segment is listed.
public enum AACStream {
    /// The path speakers ask for, beside `live.m3u8`.
    public static let path = "live.aac"

    /// What `fetch` answers once the session the stream began with has gone, which ends the stream at once.
    public static let ended = HTTPResponse(status: 410, contentType: "text/plain", body: Data("The session ended.\n".utf8))

    /// Consecutive failed playlist reads after which the stream gives up: about 30 s at the default polling rate.
    static let failureLimit = 30

    /// A response that streams until the speaker hangs up or an earlier programme ends.
    ///
    /// - Parameter fetch: Answers a path relative to the session, such as `live.m3u8` or `seg/42.ts`.
    public static func response(fetch: @escaping @Sendable (String) async -> HTTPResponse) -> HTTPResponse {
        HTTPResponse(contentType: "audio/aac", stream: frames(fetch: fetch))
    }

    /// The stream's body.
    ///
    /// - Parameters:
    ///   - fetch: Answers a path relative to the session.
    ///   - poll: How long to wait between reads of the playlist.
    ///   - audio: Takes a segment's ADTS frames out of it. Tests replace it.
    static func frames(fetch: @escaping @Sendable (String) async -> HTTPResponse, poll: Duration = .seconds(1),
                       audio: @escaping @Sendable (Data) -> Data? = adts) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(16))
        let task = Task {
            var next: Int?
            var failures = 0
            while !Task.isCancelled {
                let playlist = await fetch("live.m3u8")
                if playlist.status == ended.status { break }
                guard playlist.status == 200 else {
                    // The session may be starting again; give up only if it stays away.
                    failures += 1
                    if failures > failureLimit { break }
                    try? await Task.sleep(for: poll); continue
                }
                failures = 0
                let text = String(decoding: playlist.body, as: UTF8.self)
                let listed = HLS.parse(playlist.body).names.compactMap(index(of:))
                // Start where a new player would: `headStart` segments behind the newest listed.
                if next == nil, !listed.isEmpty { next = listed[max(0, listed.count - Playout.headStart)] }
                for index in listed where index >= (next ?? .max) {
                    let segment = await fetch("seg/\(index).ts")
                    next = index + 1
                    guard segment.status == 200, let frames = audio(segment.body) else { continue }
                    if case .terminated = continuation.yield(frames) { return }
                }
                if text.contains("#EXT-X-ENDLIST") { break }
                try? await Task.sleep(for: poll)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A segment's ADTS frames, back to back, or nil if it isn't a readable MPEG-TS segment.
    static func adts(_ segment: Data) -> Data? {
        TS.parse(segment).map { $0.frames.reduce(into: Data()) { $0.append($1) } }
    }

    /// The session a speaker's stream belongs to: the first one it reads from.
    ///
    /// Once that session stops, the stream is told `ended`, so it can't carry on into another session and start
    /// the speaker playing again. Only touched by the one actor that answers the stream.
    public final class Binding: @unchecked Sendable {
        public var session: PlayerSession?
        public init() {}
    }

    /// The segment number in a path such as `seg/42.ts`, or nil for any other path.
    static func index(of path: String) -> Int? {
        guard path.hasPrefix("seg/"), path.hasSuffix(".ts") else { return nil }
        return Int(path.dropFirst(4).dropLast(3))
    }
}
