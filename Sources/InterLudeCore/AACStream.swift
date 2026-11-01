import Foundation

/// Turns InterLude's own playlist into one continuous ADTS AAC stream, for speakers that can't play HLS (Sonos).
/// It behaves as a player would: it reads `live.m3u8` through `fetch`, starts the usual few segments behind the
/// newest listed, and sends each segment's audio frames as the segment is listed. Muted and skipped news is
/// already dealt with in the playlist, so the stream hears exactly what any other player does.
public enum AACStream {
    /// The path speakers ask for, beside `live.m3u8`.
    public static let path = "live.aac"

    /// A response that streams until the speaker hangs up or an earlier programme ends.
    public static func response(fetch: @escaping @Sendable (String) async -> HTTPResponse) -> HTTPResponse {
        HTTPResponse(contentType: "audio/aac", stream: frames(fetch: fetch))
    }

    /// `audio` takes a segment's ADTS frames out of it; tests replace it.
    static func frames(fetch: @escaping @Sendable (String) async -> HTTPResponse, poll: Duration = .seconds(1),
                       audio: @escaping @Sendable (Data) -> Data? = adts) -> AsyncStream<Data> {
        let (stream, cont) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(16))
        let task = Task {
            var next: Int?
            var failures = 0
            while !Task.isCancelled {
                let r = await fetch("live.m3u8")
                guard r.status == 200 else {
                    // The session may be starting again; give up only if it stays away.
                    failures += 1
                    if failures > 30 { break }
                    try? await Task.sleep(for: poll); continue
                }
                failures = 0
                let text = String(decoding: r.body, as: UTF8.self)
                let listed = HLS.parse(r.body).names.compactMap(index(of:))
                if next == nil, !listed.isEmpty { next = listed[max(0, listed.count - Playout.headStart)] }
                for i in listed where i >= (next ?? .max) {
                    let seg = await fetch("seg/\(i).ts")
                    next = i + 1
                    guard seg.status == 200, let frames = audio(seg.body) else { continue }
                    if case .terminated = cont.yield(frames) { return }
                }
                if text.contains("#EXT-X-ENDLIST") { break }
                try? await Task.sleep(for: poll)
            }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A segment's audio frames, back to back.
    static func adts(_ segment: Data) -> Data? {
        TS.parse(segment).map { $0.frames.reduce(into: Data()) { $0.append($1) } }
    }

    /// The segment number in a path such as `seg/42.ts`.
    static func index(of path: String) -> Int? {
        guard path.hasPrefix("seg/"), path.hasSuffix(".ts") else { return nil }
        return Int(path.dropFirst(4).dropLast(3))
    }
}
