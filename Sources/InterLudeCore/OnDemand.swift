//  OnDemand.swift
//  InterLudeCore
//
//  Plays BBC Sounds on-demand episodes for programmes older than the live origin keeps (docs/on-demand.md). The
//  stream URLs are used as the BBC's media selector issues them.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An episode's HLS stream. Its segments are 6.4 s MPEG-TS, the same as the live stream.
public struct OnDemandStream: Sendable, Equatable {
    /// The directory the segments are in.
    public var base: URL
    /// The part of each segment's file name before its number.
    public var prefix: String
    /// The number of the programme's first segment.
    public var first: Int
    /// How many segments there are.
    public var count: Int
}

/// Finding and listing on-demand episodes.
public enum OnDemand {
    /// How far back episodes are kept [days].
    public static let days = 30
    /// Allowance for container overhead when matching a variant's bandwidth to the chosen bit rate [bit/s].
    static let bandwidthOverhead = 40_000

    /// Opens a programme version's HLS stream.
    ///
    /// The media selector lists several master playlists; each is tried in turn, and from the first that answers,
    /// the variant closest to `bitrate` is opened.
    ///
    /// - Parameters:
    ///   - versionId: The programme version, from the schedule.
    ///   - bitrate: The bit rate wanted [bit/s].
    public static func resolve(versionId: String, bitrate: Int) async throws -> OnDemandStream {
        guard let selector = URL(string: "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/\(versionId)/format/json")
        else { throw FetchError.badURL }
        let (answer, _) = try await get(selector)
        let masters = masterURLs(selectorJSON: answer)
        guard !masters.isEmpty else { throw FetchError.unhealthy("This programme isn't available to play on demand.") }
        var lastError: Error = FetchError.notHTTP
        for master in masters {
            do {
                let (masterPlaylist, _) = try await get(master)
                guard let variant = chooseVariant(master: masterPlaylist, base: master, bitrate: bitrate) else { continue }
                let (variantPlaylist, _) = try await get(variant)
                let playlist = HLS.parse(variantPlaylist)
                guard let name = playlist.names.first, let (prefix, first) = HLS.splitName(name) else { continue }
                var components = URLComponents(url: variant.deletingLastPathComponent(), resolvingAgainstBaseURL: false)
                components?.query = nil
                guard let base = components?.url else { continue }
                return OnDemandStream(base: base, prefix: prefix, first: first, count: playlist.names.count)
            } catch { lastError = error }
        }
        throw lastError
    }

    /// The HLS master playlists in a media selector answer, HTTPS before HTTP and Akamai before CloudFront.
    static func masterURLs(selectorJSON: Data) -> [URL] {
        guard let root = try? JSONSerialization.jsonObject(with: selectorJSON) as? [String: Any],
              let media = root["media"] as? [[String: Any]] else { return [] }
        var ranked: [(rank: Int, url: URL)] = []
        for item in media {
            for connection in item["connection"] as? [[String: Any]] ?? [] {
                guard connection["transferFormat"] as? String == "hls", let href = connection["href"] as? String,
                      let url = URL(string: href) else { continue }
                let httpsRank = connection["protocol"] as? String == "https" ? 0 : 2
                let akamaiRank = (connection["supplier"] as? String ?? "").contains("akamai") ? 0 : 1
                ranked.append((httpsRank + akamaiRank, url))
            }
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.url)
    }

    /// Chooses a variant from a master playlist.
    ///
    /// - Returns: The variant with the highest bandwidth not above `bitrate` (plus overhead), or the lowest if none
    ///   fits, resolved against `base`.
    static func chooseVariant(master: Data, base: URL, bitrate: Int) -> URL? {
        var variants: [(bandwidth: Int, uri: String)] = []
        var pending: Int?
        for line in String(decoding: master, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let bandwidth = line.split(separator: ",").first { $0.contains("BANDWIDTH=") }?
                    .split(separator: "=").last.flatMap { Int($0) }
                pending = bandwidth ?? 0
            } else if !line.hasPrefix("#"), let bandwidth = pending {
                variants.append((bandwidth, String(line))); pending = nil
            }
        }
        let fit = variants.filter { $0.bandwidth <= bitrate + bandwidthOverhead }.max { $0.bandwidth < $1.bandwidth }
            ?? variants.min { $0.bandwidth < $1.bandwidth }
        return fit.flatMap { URL(string: $0.uri, relativeTo: base)?.absoluteURL }
    }

    /// One day of the station's schedule, by UK date.
    ///
    /// - Parameters:
    ///   - serviceId: The station.
    ///   - daysAgo: 0 for today, up to `days` − 1.
    /// - Returns: The programmes that have started, newest first.
    public static func day(serviceId: String, daysAgo: Int, now: Date = Date()) async throws -> [Programme] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let dayFormat = DateFormatter(); dayFormat.calendar = calendar; dayFormat.timeZone = calendar.timeZone; dayFormat.dateFormat = "yyyy-MM-dd"
        guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now),
              let url = URL(string: "https://rms.api.bbc.co.uk/v2/experience/inline/schedules/\(serviceId)/\(dayFormat.string(from: date))")
        else { throw FetchError.badURL }
        let (answer, _) = try await get(url)
        // The day's schedule runs on into the next day's first programme; leave that to the next day.
        return Schedule.filter(Schedule.parse(answer).filter { calendar.isDate($0.start, inSameDayAs: date) }, now: now)
    }

    /// Whether `programme` can be played on demand: it has finished, has a version, and is within the archive.
    public static func isAvailable(_ programme: Programme, now: Date = Date()) -> Bool {
        programme.versionId != nil && programme.end <= now && programme.start > now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Fetches `url`, failing on anything but HTTP 200.
    private static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
        guard http.statusCode == 200 else { throw FetchError.status(http.statusCode) }
        return (data, http)
    }
}
