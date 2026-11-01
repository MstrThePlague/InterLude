//  Schedule.swift
//  InterLudeCore
//
//  The station's schedule, for playing an earlier programme from its start. The BBC's live origin keeps about
//  11 hours of segments (docs/archive/findings.md, "Playing earlier programmes"), so a programme that began within
//  that window plays from the live stream; older ones play on demand (OnDemand.swift).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One broadcast from the station's schedule.
public struct Programme: Sendable, Equatable, Identifiable, Hashable {
    /// The broadcast's ID, such as `p0lxz91z`.
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

    /// The first segment of the programme on the stream clock.
    public var firstSegment: Int { Int(floor(start.timeIntervalSince1970 / segmentDuration)) + 1 }
    /// The last segment of the programme on the stream clock.
    public var lastSegment: Int { Int(ceil(end.timeIntervalSince1970 / segmentDuration)) }

    /// Whether the programme can be played now, from the live origin or on demand.
    public var canPlay: Bool { Schedule.isPlayable(self) || OnDemand.isAvailable(self) }
}

/// Reading the BBC's schedules.
public enum Schedule {
    /// How long ago a programme may have started and still be played from the live origin [s]. The origin keeps
    /// about 11 hours; the margin covers the two minutes of context fetched before the start and differences between
    /// stations.
    public static let reach: TimeInterval = 10.5 * 3600

    /// Reads one day of a schedule from the BBC's RMS API (`/v2/experience/inline/schedules/{serviceId}/{yyyy-mm-dd}`).
    ///
    /// The broadcasts are nested at different depths depending on the answer's layout, so the whole document is
    /// searched for `broadcast_summary` objects.
    public static func parse(_ data: Data) -> [Programme] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dates = ISO8601DateFormatter()
        var found: [Programme] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if object["type"] as? String == "broadcast_summary", let id = object["id"] as? String,
                   let start = (object["start"] as? String).flatMap(dates.date), let end = (object["end"] as? String).flatMap(dates.date) {
                    let titles = object["titles"] as? [String: Any]
                    let subtitle = (titles?["secondary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let image = (object["image_url"] as? String).flatMap { URL(string: $0.replacingOccurrences(of: "{recipe}", with: "480x480")) }
                    let version = (object["playable_item"] as? [String: Any])?["id"] as? String
                    found.append(Programme(id: id, title: titles?["primary"] as? String ?? "Programme", subtitle: subtitle,
                                           start: start, end: end, imageURL: image, versionId: version))
                    return
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(root)
        return found
    }

    /// Programmes that started within `reach` and have started, newest first.
    ///
    /// Today's and yesterday's schedules (UTC) are both read, since the window crosses midnight for half the day.
    public static func playable(serviceId: String, now: Date = Date()) async throws -> [Programme] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayFormat = DateFormatter(); dayFormat.calendar = calendar; dayFormat.timeZone = calendar.timeZone; dayFormat.dateFormat = "yyyy-MM-dd"
        var all: [Programme] = []
        for day in [now.addingTimeInterval(-86_400), now] {
            guard let url = URL(string: "https://rms.api.bbc.co.uk/v2/experience/inline/schedules/\(serviceId)/\(dayFormat.string(from: day))") else { continue }
            var request = URLRequest(url: url); request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw FetchError.status(status) }
            all += parse(data)
        }
        return filter(all, now: now)
    }

    /// Drops programmes that haven't started and repeats of the same broadcast, and puts the newest first.
    public static func filter(_ all: [Programme], now: Date) -> [Programme] {
        var seen = Set<String>()
        return all.filter { $0.start <= now && seen.insert($0.id).inserted }.sorted { $0.start > $1.start }
    }

    /// Whether `programme` has started and started recently enough to play from the live origin.
    public static func isPlayable(_ programme: Programme, now: Date = Date()) -> Bool {
        programme.start <= now && programme.start > now.addingTimeInterval(-reach)
    }
}
