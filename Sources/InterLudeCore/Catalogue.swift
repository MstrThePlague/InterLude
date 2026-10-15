import Foundation

// The station list lives in a JSON file the user can edit, because the BBC changes stream addresses
// (the pool IDs in particular) without notice. Nothing about a station is hard-coded in Swift.

public enum StationKind: String, Codable, Sendable { case music, speech }

/// One BBC station as described in `stations.json`.
public struct Station: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var serviceId: String
    public var poolId: String
    public var kind: StationKind
    /// Optional presentation: a one or two character badge and a colour as hex, for the panel.
    public var short: String?
    public var colour: String?
    /// Optional heading the station appears under in the station menu, such as "National" or "Local".
    public var group: String?
    public var id: String { serviceId }
    public init(name: String, serviceId: String, poolId: String, kind: StationKind) {
        self.name = name; self.serviceId = serviceId; self.poolId = poolId; self.kind = kind
    }
}

/// The station list plus the URL template its playlists are built from.
public struct Catalogue: Codable, Sendable {
    public var urlTemplate: String
    public var stations: [Station]

    public static func load(from url: URL) throws -> Catalogue {
        try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: url))
    }

    public func station(_ serviceId: String) -> Station? { stations.first { $0.serviceId == serviceId } }

    /// Live playlist URL. `norewind` keeps only the live edge; otherwise the 6 hour window is listed.
    public func playlistURL(_ s: Station, bitrate: Int = 320_000, norewind: Bool = true, scheme: String = "https") -> URL? {
        var t = urlTemplate
            .replacingOccurrences(of: "{poolId}", with: s.poolId)
            .replacingOccurrences(of: "{serviceId}", with: s.serviceId)
            .replacingOccurrences(of: "{bitrate}", with: String(bitrate))
        if !norewind { t = t.replacingOccurrences(of: ".norewind", with: "") }
        if t.hasPrefix("https:") && scheme != "https" { t = scheme + t.dropFirst(5) }
        return URL(string: t)
    }

    /// Copies the bundled catalogue to Application Support on first run and returns the editable file.
    public static func editableURL(bundled: URL) throws -> URL {
        let dir = try AppPaths.supportDirectory()
        let dest = dir.appendingPathComponent("stations.json")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: bundled, to: dest)
        }
        return dest
    }
}

/// Where InterLude keeps its files. Inside the App Sandbox these resolve to the app's container.
public enum AppPaths {
    public static func supportDirectory() throws -> URL {
        let u = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("InterLude", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public static func cacheDirectory() throws -> URL {
        let u = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("InterLude/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
