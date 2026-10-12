import Foundation

public enum FetchError: Error { case status(Int), notHTTP, unhealthy(String) }

/// Downloads and caches station segments on disk. At most `maxInFlight` downloads run at once.
public actor SegmentStore {
    public let directory: URL
    private let base: URL
    private let prefix: String
    private let maxInFlight: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var tasks: [Int: Task<Data, Error>] = [:]
    private let session: URLSession
    private(set) var failed: Set<Int> = []

    /// `base` is the playlist's directory; `prefix` the file name before the index, e.g. "bbc_6music-audio=320000-".
    public init(directory: URL, base: URL, prefix: String, maxInFlight: Int = 4) {
        self.directory = directory; self.base = base; self.prefix = prefix; self.maxInFlight = maxInFlight
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 15
        session = URLSession(configuration: c)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ i: Int) -> URL { directory.appendingPathComponent("\(i).ts") }

    public func cached(_ i: Int) -> Data? { try? Data(contentsOf: path(i)) }
    public func has(_ i: Int) -> Bool { FileManager.default.fileExists(atPath: path(i).path) }

    public func segment(_ i: Int) async throws -> Data {
        if let d = cached(i) { return d }
        if let t = tasks[i] { return try await t.value }
        let t = Task { try await self.download(i) }
        tasks[i] = t
        defer { tasks[i] = nil }
        return try await t.value
    }

    private func acquire() async {
        if inFlight < maxInFlight { inFlight += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { inFlight -= 1 } else { waiters.removeFirst().resume() }
    }

    private func download(_ i: Int) async throws -> Data {
        await acquire(); defer { release() }
        let url = URL(string: base.absoluteString + prefix + "\(i).ts")!
        var delay = 0.5
        var lastError: Error = FetchError.notHTTP
        for attempt in 0..<3 {
            do {
                let (d, r) = try await session.data(from: url)
                guard let h = r as? HTTPURLResponse else { throw FetchError.notHTTP }
                guard h.statusCode == 200 else { throw FetchError.status(h.statusCode) }
                try d.write(to: path(i), options: .atomic)
                failed.remove(i)
                return d
            } catch {
                lastError = error
                if case FetchError.status(let s) = error, s == 403 || s == 404, attempt == 0, i > 0 { /* may be too new */ }
                try? await Task.sleep(for: .seconds(delay)); delay *= 2
            }
        }
        failed.insert(i)
        throw lastError
    }

    /// Removes cached segments outside [low, high].
    public func evict(below low: Int, above high: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for n in names {
            if n.hasSuffix(".ts"), let i = Int(n.dropLast(3)), i < low || i > high {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(n))
            }
        }
    }

    public func clear() { try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
}

/// Fetches the live playlist, trying HTTPS then HTTP.
public struct PlaylistClient: Sendable {
    public init() {}
    public func fetch(catalogue: Catalogue, station: Station, bitrate: Int, norewind: Bool = true) async throws -> (ParsedPlaylist, base: URL) {
        var lastError: Error = FetchError.notHTTP
        for scheme in ["https", "http"] {
            guard let url = catalogue.playlistURL(station, bitrate: bitrate, norewind: norewind, scheme: scheme) else { continue }
            do {
                var req = URLRequest(url: url); req.timeoutInterval = 10
                let (d, r) = try await URLSession.shared.data(for: req)
                guard let h = r as? HTTPURLResponse else { throw FetchError.notHTTP }
                if h.statusCode == 403 || h.statusCode == 404 {
                    throw FetchError.unhealthy("\(station.name): HTTP \(h.statusCode). The pool ID (\(station.poolId)) has probably changed.")
                }
                guard h.statusCode == 200 else { throw FetchError.status(h.statusCode) }
                return (HLS.parse(d), url.deletingLastPathComponent())
            } catch { lastError = error; if case FetchError.unhealthy = error { throw error } }
        }
        throw lastError
    }
}
