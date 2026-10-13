import Foundation

/// Per-station settings and learned data. Stored as JSON in Application Support so the user can edit it.
/// Jingle candidates are large (up to eight 70 s fingerprints), so they live in a binary file beside the JSON.
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
        if candidates.contains(where: { $0.first?.count != expected || $0.count < 1000 }) { candidates = []; candidateSources = [] }
        if idents.contains(where: { $0.features.first?.count != expected }) { idents = [] }
    }
    enum Keys: String, CodingKey {
        case delaySeconds, muteNews, favourite, shadowMode, detector, idents, candidates, candidateSources, startMinuteHistogram, bulletinSeconds
    }

    /// Everything except the candidates, which `save` writes separately.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(delaySeconds, forKey: .delaySeconds); try c.encode(muteNews, forKey: .muteNews)
        try c.encode(favourite, forKey: .favourite); try c.encode(shadowMode, forKey: .shadowMode)
        try c.encode(detector, forKey: .detector); try c.encode(idents, forKey: .idents)
        try c.encode(candidateSources, forKey: .candidateSources)
        try c.encode(startMinuteHistogram, forKey: .startMinuteHistogram); try c.encode(bulletinSeconds, forKey: .bulletinSeconds)
    }

    public static func url(_ serviceId: String) throws -> URL {
        let dir = try AppPaths.supportDirectory().appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(serviceId).json")
    }

    static func candidatesURL(_ serviceId: String) throws -> URL {
        try url(serviceId).deletingPathExtension().appendingPathExtension("candidates")
    }

    public static func load(_ station: Station) -> StationProfile {
        if let u = try? url(station.serviceId), let d = try? Data(contentsOf: u), var p = try? JSONDecoder().decode(StationProfile.self, from: d) {
            // Older profiles kept candidates in the JSON; newer ones keep them in the binary file.
            if p.candidates.isEmpty, let cu = try? candidatesURL(station.serviceId), let blob = try? Data(contentsOf: cu) {
                p.candidates = CandidateFile.decode(blob)
            }
            if p.candidateSources.count != p.candidates.count { p.candidateSources = Array(repeating: "", count: p.candidates.count) }
            return p
        }
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
        if let cu = try? StationProfile.candidatesURL(station.serviceId) { try? CandidateFile.encode(candidates).write(to: cu, options: .atomic) }
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

/// A learned news theme: four seconds of log-band features, and the score a match must reach.
public struct IdentReference: Codable, Sendable, Equatable {
    public var features: [[Float]]
    public var threshold: Float = IdentMatcher.defaultThreshold
}

/// The binary layout of a `.candidates` file: a count, then for each candidate its frame count, its band count and
/// the features as little-endian Float32. About 1.7 MB for eight candidates, against several MB of JSON.
enum CandidateFile {
    static func encode(_ candidates: [[[Float]]]) -> Data {
        var d = Data()
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt32(candidates.count))
        for c in candidates {
            put(UInt32(c.count)); put(UInt32(c.first?.count ?? 0))
            for frame in c { for v in frame { put(v.bitPattern) } }
        }
        return d
    }

    static func decode(_ d: Data) -> [[[Float]]] {
        var pos = 0
        func get() -> UInt32? {
            guard pos + 4 <= d.count else { return nil }
            let v = d[d.startIndex + pos..<d.startIndex + pos + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            pos += 4
            return UInt32(littleEndian: v)
        }
        guard let n = get() else { return [] }
        var out: [[[Float]]] = []
        for _ in 0..<n {
            guard let frames = get(), let bands = get() else { return [] }
            var c: [[Float]] = []
            for _ in 0..<frames {
                var f: [Float] = []
                for _ in 0..<bands { guard let v = get() else { return [] }; f.append(Float(bitPattern: v)) }
                c.append(f)
            }
            out.append(c)
        }
        return out
    }
}
