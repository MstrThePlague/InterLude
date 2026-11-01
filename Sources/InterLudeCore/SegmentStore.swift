//  SegmentStore.swift
//  InterLudeCore
//
//  Downloads the station's segments and keeps them on disk while they may still be analysed or played, and fetches
//  the live playlist. Downloads are limited and retried, so a brief hiccup at the BBC loses nothing.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why something couldn't be fetched.
public enum FetchError: Error {
    /// The server answered with this HTTP status.
    case status(Int)
    /// The answer wasn't HTTP.
    case notHTTP
    case badURL
    /// A problem worth showing to the listener as it stands.
    case unhealthy(String)
}

/// Downloads and caches a station's segments on disk.
public actor SegmentStore {
    public let directory: URL
    private let base: URL
    private let prefix: String
    /// Subtracted from an index to get the file's number, when the store's indices are on another clock.
    private let offset: Int
    private let maxInFlight: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Downloads under way, so two requests for one segment share one download.
    private var tasks: [Int: Task<Data, Error>] = [:]
    private let session: URLSession

    /// - Parameters:
    ///   - directory: Where segments are kept, as `<index>.ts`.
    ///   - base: The playlist's directory.
    ///   - prefix: The file name before the index, such as `bbc_6music-audio=320000-`.
    ///   - offset: Subtracted from an index to get the file's number.
    ///   - maxInFlight: The most downloads to run at once.
    public init(directory: URL, base: URL, prefix: String, offset: Int = 0, maxInFlight: Int = 4) {
        self.directory = directory; self.base = base; self.prefix = prefix; self.offset = offset; self.maxInFlight = maxInFlight
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ index: Int) -> URL { directory.appendingPathComponent("\(index).ts") }

    /// The segment if it is on disk.
    public func cached(_ index: Int) -> Data? { try? Data(contentsOf: path(index)) }
    /// Whether the segment is on disk.
    public func has(_ index: Int) -> Bool { FileManager.default.fileExists(atPath: path(index).path) }

    /// The segment, from disk or downloaded now.
    public func segment(_ index: Int) async throws -> Data {
        if let data = cached(index) { return data }
        if let running = tasks[index] { return try await running.value }
        let download = Task { try await self.download(index) }
        tasks[index] = download
        defer { tasks[index] = nil }
        return try await download.value
    }

    /// Waits for a download slot.
    private func acquire() async {
        if inFlight < maxInFlight { inFlight += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the next waiter, or frees it.
    private func release() {
        if waiters.isEmpty { inFlight -= 1 } else { waiters.removeFirst().resume() }
    }

    /// Downloads a segment to disk, with three attempts and a doubling pause, so a segment that is briefly
    /// unavailable is not lost.
    private func download(_ index: Int) async throws -> Data {
        await acquire(); defer { release() }
        guard let url = URL(string: base.absoluteString + prefix + "\(index - offset).ts") else { throw FetchError.badURL }
        var pause = 0.5                                     // [s]
        var lastError: Error = FetchError.notHTTP
        for _ in 0..<3 {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
                guard http.statusCode == 200 else { throw FetchError.status(http.statusCode) }
                try data.write(to: path(index), options: .atomic)
                return data
            } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(pause)); pause *= 2
            }
        }
        throw lastError
    }

    /// Removes cached segments outside `low...high`.
    public func evict(below low: Int, above high: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            if name.hasSuffix(".ts"), let index = Int(name.dropLast(3)), index < low || index > high {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Removes every cached segment.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// Fetches a station's live playlist.
public struct PlaylistClient: Sendable {
    public init() {}

    /// Fetches the playlist, trying HTTPS then HTTP, since hosts have differed in which they accept.
    ///
    /// - Returns: The playlist, and the directory its segments are in.
    /// - Throws: `FetchError.unhealthy` on HTTP 403 or 404, which almost always means the station's pool ID has
    ///   changed, so the message says so.
    public func fetch(catalogue: Catalogue, station: Station, bitrate: Int, norewind: Bool = true) async throws -> (ParsedPlaylist, base: URL) {
        var lastError: Error = FetchError.notHTTP
        for scheme in ["https", "http"] {
            guard let url = catalogue.playlistURL(station, bitrate: bitrate, norewind: norewind, scheme: scheme) else { continue }
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
                if http.statusCode == 403 || http.statusCode == 404 {
                    throw FetchError.unhealthy("\(station.name): HTTP \(http.statusCode). The pool ID (\(station.poolId)) has probably changed.")
                }
                guard http.statusCode == 200 else { throw FetchError.status(http.statusCode) }
                return (HLS.parse(data), url.deletingLastPathComponent())
            } catch {
                lastError = error
                if case FetchError.unhealthy = error { throw error }     // trying HTTP won't help
            }
        }
        throw lastError
    }
}
