//  Catalogue.swift
//  InterLudeCore
//
//  The station list lives in a JSON file the user can edit, because the BBC changes stream addresses (the pool IDs
//  in particular) without notice. Nothing about a station is hard-coded in Swift. This file also decides where
//  InterLude keeps its files.

import Foundation

/// Whether a station is mostly music, where bulletins are muted, or speech, where talk is the programme.
public enum StationKind: String, Codable, Sendable { case music, speech }

/// A bulletin longer than the usual few minutes, at the same UK time every day, such as Newsbeat's 15 minutes at
/// 12:45 on Radio 1.
public struct LongBulletin: Codable, Sendable, Hashable {
    /// When it starts, UK time, as "HH:MM".
    public var at: String
    public var minutes: Double
    public init(at: String, minutes: Double) { self.at = at; self.minutes = minutes }
    /// Minutes after midnight, UK time, or nil if `at` is unreadable.
    public var minuteOfDay: Int? {
        let parts = at.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }
}

/// One BBC station as described in `stations.json`.
public struct Station: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// The BBC's service ID, such as `bbc_6music`.
    public var serviceId: String
    /// The Akamai pool the station's stream is served from, which the BBC changes from time to time.
    public var poolId: String
    public var kind: StationKind
    /// A one- or two-character badge for the panel, such as "6".
    public var short: String?
    /// The badge's colour as hexadecimal, such as `#1A9E5F`.
    public var colour: String?
    /// The heading the station appears under in the station list, such as "National" or "Local".
    public var group: String?
    /// What the station's newsreaders call its news, lower case, such as "newsbeat" or "6 music news". Heard at the
    /// start or end of a bulletin, it marks the opening or sign-off; "BBC News" and "next update" work on any station.
    public var newsNames: [String]?
    /// Wording that opens this station's bulletins, lower case, on top of the English that opens any BBC bulletin
    /// ("bbc news at"). For a station whose news is in another language, such as Welsh on Radio Cymru 2.
    public var openings: [String]?
    /// Wording that closes this station's bulletins, lower case, on top of the English ones such as "next update".
    public var signOffs: [String]?
    /// False for a stream that carries no news bulletins, such as Radio 1 Dance, so nothing is ever muted there.
    public var news: Bool?
    /// True where the speech rule hasn't been checked, such as Radio 2, whose presenters talk at length near the
    /// hour: a new profile starts in shadow mode and mutes only on the station's jingle.
    public var untested: Bool?
    /// Bulletins at fixed times that run longer than the longest mute, which may run their length.
    public var longBulletins: [LongBulletin]?
    public var id: String { serviceId }
    /// Whether InterLude looks for bulletins to mute: music stations that carry news.
    public var mutesNews: Bool { kind == .music && news != false }
    public init(name: String, serviceId: String, poolId: String, kind: StationKind) {
        self.name = name; self.serviceId = serviceId; self.poolId = poolId; self.kind = kind
    }
}

/// The station list, plus the URL template its playlists are built from.
public struct Catalogue: Codable, Sendable {
    /// A playlist URL with `{poolId}`, `{serviceId}` and `{bitrate}` placeholders.
    public var urlTemplate: String
    public var stations: [Station]

    /// Reads a station list from a JSON file.
    public static func load(from url: URL) throws -> Catalogue {
        try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: url))
    }

    /// The station with `serviceId`, if the list has it.
    public func station(_ serviceId: String) -> Station? { stations.first { $0.serviceId == serviceId } }

    /// The station's live playlist URL.
    ///
    /// - Parameters:
    ///   - station: The station.
    ///   - bitrate: 128 000 or 320 000 [bit/s].
    ///   - norewind: True lists only the live edge; false lists the six-hour rewind window.
    ///   - scheme: `https`, or `http` for hosts that refuse HTTPS.
    public func playlistURL(_ station: Station, bitrate: Int = 320_000, norewind: Bool = true, scheme: String = "https") -> URL? {
        var address = urlTemplate
            .replacingOccurrences(of: "{poolId}", with: station.poolId)
            .replacingOccurrences(of: "{serviceId}", with: station.serviceId)
            .replacingOccurrences(of: "{bitrate}", with: String(bitrate))
        if !norewind { address = address.replacingOccurrences(of: ".norewind", with: "") }
        if address.hasPrefix("https:") && scheme != "https" { address = scheme + address.dropFirst(5) }
        return URL(string: address)
    }

    /// The user's editable list, brought up to date with the bundled one.
    ///
    /// Stations added to the bundled list since the copy was made are appended, and presentation fields that older copies
    /// lack are filled in, and news names added since are appended. The user's own edits, such as a changed pool ID, win.
    ///
    /// - Parameters:
    ///   - bundled: The list that ships with the app or server.
    ///   - editable: A list kept elsewhere, such as a server's config folder, to use in place of the copy in
    ///     Application Support.
    public static func loadEditable(bundled: URL, editable: URL? = nil) throws -> Catalogue {
        var catalogue = try load(from: editable ?? editableURL(bundled: bundled))
        guard let shipped = try? load(from: bundled) else { return catalogue }
        for i in catalogue.stations.indices {
            guard let match = shipped.station(catalogue.stations[i].serviceId) else { continue }
            if catalogue.stations[i].short == nil { catalogue.stations[i].short = match.short }
            if catalogue.stations[i].colour == nil { catalogue.stations[i].colour = match.colour }
            if catalogue.stations[i].group == nil { catalogue.stations[i].group = match.group }
            // News names are added to rather than kept as they are, so spellings found later reach saved lists.
            if let shippedNames = match.newsNames {
                let mine = catalogue.stations[i].newsNames ?? []
                catalogue.stations[i].newsNames = mine + shippedNames.filter { !mine.contains($0) }
            }
            if catalogue.stations[i].news == nil { catalogue.stations[i].news = match.news }
            if catalogue.stations[i].openings == nil { catalogue.stations[i].openings = match.openings }
            if catalogue.stations[i].signOffs == nil { catalogue.stations[i].signOffs = match.signOffs }
            if catalogue.stations[i].untested == nil { catalogue.stations[i].untested = match.untested }
            if catalogue.stations[i].longBulletins == nil { catalogue.stations[i].longBulletins = match.longBulletins }
        }
        let known = Set(catalogue.stations.map(\.serviceId))
        catalogue.stations += shipped.stations.filter { !known.contains($0.serviceId) }
        return catalogue
    }

    /// The editable station list in Application Support, copied from the bundled one on first run.
    public static func editableURL(bundled: URL) throws -> URL {
        let destination = try AppPaths.supportDirectory().appendingPathComponent("stations.json")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: bundled, to: destination)
        }
        return destination
    }
}

/// Where InterLude keeps its files.
///
/// On the Mac these are the user's Library folders, which inside the App Sandbox resolve to the app's container. A
/// server sets `root` once at launch, and then everything lives under that one directory.
public enum AppPaths {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rootOverride: URL?

    /// The data directory chosen at launch, such as `/var/lib/interlude`. Nil means the user's Library folders.
    public static var root: URL? {
        get { lock.lock(); defer { lock.unlock() }; return rootOverride }
        set { lock.lock(); defer { lock.unlock() }; rootOverride = newValue }
    }

    /// Settings, profiles, the station list and the event log. Created if missing.
    public static func supportDirectory() throws -> URL {
        let directory = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("InterLude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Downloaded segments, which can be thrown away at any time. Created if missing.
    public static func cacheDirectory() throws -> URL {
        let directory = try root?.appendingPathComponent("cache", isDirectory: true)
            ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("InterLude/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
