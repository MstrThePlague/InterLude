import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The station's schedule, for playing an earlier programme from its start. The BBC's live origin keeps about
// 11 hours of segments (docs/findings.md, "Playing earlier programmes"), so only programmes that began within
// that window can be played.

/// One broadcast from the station's schedule.
public struct Programme: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var start: Date
    public var end: Date
    public var imageURL: URL?
    /// The version to ask the media selector for, to play the programme on demand.
    public var versionId: String?
    public init(id: String, title: String, subtitle: String?, start: Date, end: Date, imageURL: URL?, versionId: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.start = start; self.end = end; self.imageURL = imageURL
        self.versionId = versionId
    }

    /// First segment of the programme on the stream clock.
    public var firstSegment: Int { Int(floor(start.timeIntervalSince1970 / segmentDuration)) + 1 }
    public var lastSegment: Int { Int(ceil(end.timeIntervalSince1970 / segmentDuration)) }
}

public enum Schedule {
    /// How far back a programme may have started and still be played. The origin keeps about 11 hours; the margin
    /// covers the two minutes of context fetched before the start and differences between stations.
    public static let reach: TimeInterval = 10.5 * 3600

    /// Reads one day of an RMS schedule (`/v2/experience/inline/schedules/{serviceId}/{yyyy-mm-dd}`).
    public static func parse(_ data: Data) -> [Programme] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let f = ISO8601DateFormatter()
        var out: [Programme] = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] {
                if d["type"] as? String == "broadcast_summary", let id = d["id"] as? String,
                   let s = (d["start"] as? String).flatMap(f.date), let e = (d["end"] as? String).flatMap(f.date) {
                    let t = d["titles"] as? [String: Any]
                    let sub = (t?["secondary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let img = (d["image_url"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "{recipe}", with: "480x480")) }
                    let version = (d["playable_item"] as? [String: Any])?["id"] as? String
                    out.append(Programme(id: id, title: t?["primary"] as? String ?? "Programme", subtitle: sub, start: s, end: e, imageURL: img, versionId: version))
                    return
                }
                d.values.forEach(walk)
            } else if let a = o as? [Any] { a.forEach(walk) }
        }
        walk(root)
        return out
    }

    /// Programmes that began within reach and have started, newest first. Today's and yesterday's schedules (UTC)
    /// are both read, since the window crosses midnight for half the day.
    public static func playable(serviceId: String, now: Date = Date()) async throws -> [Programme] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        var all: [Programme] = []
        for day in [now.addingTimeInterval(-86_400), now] {
            guard let url = URL(string: "https://rms.api.bbc.co.uk/v2/experience/inline/schedules/\(serviceId)/\(f.string(from: day))") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 10
            let (d, r) = try await URLSession.shared.data(for: req)
            guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.status((r as? HTTPURLResponse)?.statusCode ?? 0) }
            all += parse(d)
        }
        return filter(all, now: now)
    }

    public static func filter(_ all: [Programme], now: Date) -> [Programme] {
        var seen = Set<String>()
        return all.filter { $0.start <= now && seen.insert($0.id).inserted }.sorted { $0.start > $1.start }
    }

    public static func isPlayable(_ p: Programme, now: Date = Date()) -> Bool {
        p.start <= now && p.start > now.addingTimeInterval(-reach)
    }
}
