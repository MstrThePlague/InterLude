import Foundation

// The web app is plain files read from disk as they are asked for, so its interface can change on a running server or
// Mac without a rebuild. Open pages notice a change through `version` in the state and load themselves again.

/// The modification dates and sizes of some files, which change when any of them is saved.
public struct FileStamp: Equatable, Sendable {
    let parts: [String]

    public static func of(_ urls: [URL]) -> FileStamp {
        FileStamp(parts: urls.map { u in
            guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return "\(u.path):-" }
            let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(u.path):\(date):\((a[.size] as? NSNumber)?.intValue ?? 0)"
        })
    }

    /// A short hex digest, the same on every run for the same files (FNV-1a).
    public var digest: String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in parts.joined(separator: "\n").utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}

/// The web app's files. Each comes from the first folder that has it, so an override folder ahead of the bundled one
/// can replace any of them, and removing an override brings the bundled file back.
public final class WebFiles: @unchecked Sendable {
    public static let names = ["index.html", "app.css", "app.js"]
    public let folders: [URL]
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, data: Data)] = [:]

    public init(folders: [URL]) { self.folders = folders }

    /// Where `name` is read from, or nil if no folder has it.
    public func url(_ name: String) -> URL? {
        guard Self.names.contains(name) else { return nil }
        return folders.lazy.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The file's contents, read again only when it has changed.
    public func data(_ name: String) -> Data? {
        guard let u = url(name) else { return nil }
        let stamp = FileStamp.of([u])
        lock.lock(); defer { lock.unlock() }
        if let c = cache[name], c.stamp == stamp { return c.data }
        guard let d = try? Data(contentsOf: u) else { return nil }
        cache[name] = (stamp, d)
        return d
    }

    /// Changes whenever any of the files, or the folder one comes from, changes.
    public var version: String {
        FileStamp.of(Self.names.compactMap(url)).digest
    }
}
