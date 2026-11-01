//  WebFiles.swift
//  InterLudeCore
//
//  The web app is plain files read from disk as they are asked for, so its interface can change on a running server
//  or Mac without a rebuild. Open pages notice a change through `version` in the state and load themselves again.

import Foundation

/// The modification dates and sizes of a set of files, which changes when any of them is saved.
public struct FileStamp: Equatable, Sendable {
    let parts: [String]

    /// Stamps `urls` as they are now. A missing file is recorded as missing, so its appearance counts as a change.
    public static func of(_ urls: [URL]) -> FileStamp {
        FileStamp(parts: urls.map { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "\(url.path):-" }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return "\(url.path):\(modified):\(size)"
        })
    }

    /// A short hexadecimal digest, the same on every run for the same files (64-bit FNV-1a).
    public var digest: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325                      // FNV offset basis
        for byte in parts.joined(separator: "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }   // FNV prime
        return String(hash, radix: 16)
    }
}

/// The web app's files.
///
/// Each file comes from the first folder that has it, so an override folder ahead of the bundled one can replace
/// any of them, and removing an override brings the bundled file back.
public final class WebFiles: @unchecked Sendable {
    /// The only names served. Anything else is refused, so a request can never reach another file.
    public static let names = ["index.html", "app.css", "app.js"]
    /// The folders searched, in order of preference.
    public let folders: [URL]
    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, data: Data)] = [:]

    public init(folders: [URL]) { self.folders = folders }

    /// Where `name` is read from, or nil if it isn't one of `names` or no folder has it.
    public func url(_ name: String) -> URL? {
        guard Self.names.contains(name) else { return nil }
        return folders.lazy.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The file's contents, read from disk again only when it has changed.
    public func data(_ name: String) -> Data? {
        guard let url = url(name) else { return nil }
        let stamp = FileStamp.of([url])
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name], cached.stamp == stamp { return cached.data }
        guard let data = try? Data(contentsOf: url) else { return nil }
        cache[name] = (stamp, data)
        return data
    }

    /// A digest that changes whenever any of the files changes, or moves to another folder.
    public var version: String {
        FileStamp.of(Self.names.compactMap(url)).digest
    }
}
