import Foundation

/// Per-station settings and learned data. Stored as JSON in Application Support so the user can edit it.
public struct StationProfile: Codable, Sendable, Equatable {
    public var delaySeconds = 60.0
    public var muteNews = true
    public var favourite = false
    /// Detect and log bulletins but never mute.
    public var shadowMode = false
    public var detector = DetectorConfig()
    public var idents: [IdentReference] = []
    public var candidates: [[[Float]]] = []
    /// The block each candidate came from, so "Wasn't news" can withdraw it.
    public var candidateSources: [String] = []
    public var startMinuteHistogram: [Int: Int] = [:]
    public var bulletinSeconds: [Double] = []
    public init() {}

    /// Tolerant decoding, so profiles written by older versions keep their settings.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ k: Keys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        get(.delaySeconds, &delaySeconds); get(.muteNews, &muteNews); get(.favourite, &favourite); get(.shadowMode, &shadowMode)
        get(.detector, &detector); get(.idents, &idents); get(.candidates, &candidates); get(.candidateSources, &candidateSources)
        get(.startMinuteHistogram, &startMinuteHistogram); get(.bulletinSeconds, &bulletinSeconds)
        // Candidates from before candidate windows changed are a different shape; drop them.
        let expected = IdentFeatures.bands
        if candidates.contains(where: { $0.first?.count != expected || $0.count < 400 }) { candidates = []; candidateSources = []; idents = [] }
        if candidateSources.count != candidates.count { candidateSources = Array(repeating: "", count: candidates.count) }
    }
    enum Keys: String, CodingKey {
        case delaySeconds, muteNews, favourite, shadowMode, detector, idents, candidates, candidateSources, startMinuteHistogram, bulletinSeconds
    }

    public static func url(_ serviceId: String) throws -> URL {
        let dir = try AppPaths.supportDirectory().appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(serviceId).json")
    }

    public static func load(_ station: Station) -> StationProfile {
        if let u = try? url(station.serviceId), let d = try? Data(contentsOf: u), let p = try? JSONDecoder().decode(StationProfile.self, from: d) { return p }
        var p = StationProfile()
        if station.kind == .speech { p.muteNews = false }
        if station.serviceId == "bbc_radio_two" {      // Radio 2's bulletins and speech content have not been measured
            p.shadowMode = true; p.detector.identOnly = true
        }
        return p
    }

    public func save(_ station: Station) {
        guard let u = try? StationProfile.url(station.serviceId) else { return }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: u, options: .atomic)
    }

    /// Learns the bulletin's start minute and length after a confirmed bulletin.
    public mutating func learn(start: Double, end: Double) {
        let minute = Int((start.truncatingRemainder(dividingBy: 3600)) / 60)
        startMinuteHistogram[minute, default: 0] += 1
        bulletinSeconds.append(end - start)
        if bulletinSeconds.count > 200 { bulletinSeconds.removeFirst() }
        if bulletinSeconds.count >= 5 {
            let s = bulletinSeconds.sorted()
            detector.minBulletinSeconds = max(30, s[s.count / 20] * 0.7)
            detector.maxBulletinSeconds = s[s.count - 1 - s.count / 20] * 1.3
        }
    }
}

/// A stored news ident: log-band features of the first seconds of a bulletin.
public struct IdentReference: Codable, Sendable, Equatable {
    public var features: [[Float]]
    public var threshold: Float = IdentMatcher.defaultThreshold
}
