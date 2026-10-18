import Foundation

// Plays BBC Sounds on-demand episodes for programmes older than the live origin keeps (docs/on-demand.md).
// The stream URLs are used as the media selector issues them.

/// An episode's HLS stream: where its segments are and how many there are. Segments are 6.4 s MPEG-TS, the same as
/// the live stream, numbered from `first` at the start of the programme.
public struct OnDemandStream: Sendable, Equatable {
    public var base: URL
    public var prefix: String
    public var first: Int
    public var count: Int
}

public enum OnDemand {
    /// How far back episodes are kept.
    public static let days = 30

    /// Asks the media selector for the version's streams and opens the HLS variant closest to `bitrate`.
    public static func resolve(versionId: String, bitrate: Int) async throws -> OnDemandStream {
        guard let sel = URL(string: "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/\(versionId)/format/json")
        else { throw FetchError.badURL }
        let (d, _) = try await get(sel)
        let masters = masterURLs(selectorJSON: d)
        guard !masters.isEmpty else { throw FetchError.unhealthy("This programme isn't available to play on demand.") }
        var lastError: Error = FetchError.notHTTP
        for master in masters {
            do {
                let (m, _) = try await get(master)
                guard let variant = chooseVariant(master: m, base: master, bitrate: bitrate) else { continue }
                let (v, _) = try await get(variant)
                let pl = HLS.parse(v)
                guard let name = pl.names.first, let (prefix, first) = HLS.splitName(name) else { continue }
                var c = URLComponents(url: variant.deletingLastPathComponent(), resolvingAgainstBaseURL: false)
                c?.query = nil
                guard let base = c?.url else { continue }
                return OnDemandStream(base: base, prefix: prefix, first: first, count: pl.names.count)
            } catch { lastError = error }
        }
        throw lastError
    }

    /// HLS master playlists from a media selector answer, HTTPS first, Akamai before CloudFront.
    static func masterURLs(selectorJSON d: Data) -> [URL] {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let media = o["media"] as? [[String: Any]] else { return [] }
        var out: [(rank: Int, url: URL)] = []
        for m in media {
            for c in m["connection"] as? [[String: Any]] ?? [] {
                guard c["transferFormat"] as? String == "hls", let h = c["href"] as? String, let u = URL(string: h) else { continue }
                let https = c["protocol"] as? String == "https" ? 0 : 2
                let akamai = (c["supplier"] as? String ?? "").contains("akamai") ? 0 : 1
                out.append((https + akamai, u))
            }
        }
        return out.sorted { $0.rank < $1.rank }.map(\.url)
    }

    /// The variant with the highest bandwidth not above `bitrate` (plus overhead), or the lowest if none qualify.
    static func chooseVariant(master: Data, base: URL, bitrate: Int) -> URL? {
        var variants: [(bw: Int, uri: String)] = []
        var pending: Int?
        for line in String(decoding: master, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let bw = line.split(separator: ",").first { $0.contains("BANDWIDTH=") }?.split(separator: "=").last.flatMap { Int($0) }
                pending = bw ?? 0
            } else if !line.hasPrefix("#"), let bw = pending {
                variants.append((bw, String(line))); pending = nil
            }
        }
        let fit = variants.filter { $0.bw <= bitrate + 40_000 }.max { $0.bw < $1.bw } ?? variants.min { $0.bw < $1.bw }
        return fit.flatMap { URL(string: $0.uri, relativeTo: base)?.absoluteURL }
    }

    /// One day of the station's schedule, by UK date, `daysAgo` days before today. Programmes that have not started
    /// are left out; the newest comes first.
    public static func day(serviceId: String, daysAgo: Int, now: Date = Date()) async throws -> [Programme] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        guard let date = cal.date(byAdding: .day, value: -daysAgo, to: now),
              let url = URL(string: "https://rms.api.bbc.co.uk/v2/experience/inline/schedules/\(serviceId)/\(f.string(from: date))")
        else { throw FetchError.badURL }
        let (d, _) = try await get(url)
        // The day's schedule runs on into the next day's first programme; leave that to the next day.
        return Schedule.filter(Schedule.parse(d).filter { cal.isDate($0.start, inSameDayAs: date) }, now: now)
    }

    /// Whether `p` can be played on demand: it has finished, has a version, and is within the archive.
    public static func isAvailable(_ p: Programme, now: Date = Date()) -> Bool {
        p.versionId != nil && p.end <= now && p.start > now.addingTimeInterval(-Double(days) * 86_400)
    }

    private static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url); req.timeoutInterval = 15
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let h = r as? HTTPURLResponse else { throw FetchError.notHTTP }
        guard h.statusCode == 200 else { throw FetchError.status(h.statusCode) }
        return (d, h)
    }
}
