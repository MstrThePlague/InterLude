//  Profile.swift
//  InterLudeCore
//
//  Per-station settings and what InterLude has learned about each station: its bulletin times and lengths, and its
//  news theme. Stored as JSON in Application Support so the user can read and edit it; the jingle candidates are
//  large, so they live in a binary file beside the JSON.

import Foundation

/// A station's settings and learned data.
public struct StationProfile: Codable, Sendable, Equatable {
    /// How far behind live to play [s].
    public var delaySeconds = 60.0
    public var muteNews = true
    public var favourite = false
    /// Detect and log bulletins, but never mute them.
    public var shadowMode = false
    public var detector = DetectorConfig()
    /// The learned news theme, if any.
    public var idents: [IdentReference] = []
    /// Fingerprints of the audio around recent bulletin starts, from which the theme is learned: up to eight 70 s
    /// windows of `IdentFeatures` frames.
    public var candidates: [[[Float]]] = []
    /// The bulletin each candidate came from, so "Wasn't news" can withdraw it.
    public var candidateSources: [String] = []
    /// How many confirmed bulletins started in each minute of the hour.
    public var startMinuteHistogram: [Int: Int] = [:]
    /// The lengths of recent confirmed bulletins [s].
    public var bulletinSeconds: [Double] = []

    /// Candidates kept at once.
    static let maxCandidates = 8
    /// Bulletin lengths kept at once.
    static let maxBulletinLengths = 200

    public init() {}

    /// Decodes tolerantly, so profiles written by older versions keep their settings.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ key: Keys, _ value: inout T) { if let found = try? container.decodeIfPresent(T.self, forKey: key) { value = found } }
        get(.delaySeconds, &delaySeconds); get(.muteNews, &muteNews); get(.favourite, &favourite); get(.shadowMode, &shadowMode)
        get(.detector, &detector); get(.idents, &idents); get(.candidates, &candidates); get(.candidateSources, &candidateSources)
        get(.startMinuteHistogram, &startMinuteHistogram); get(.bulletinSeconds, &bulletinSeconds)
        // Candidates and themes from before the fingerprint changed shape can't be compared with new ones; drop them.
        let expected = IdentFeatures.bands
        if candidates.contains(where: { $0.first?.count != expected || $0.count < 1000 }) { candidates = []; candidateSources = [] }
        if idents.contains(where: { $0.features.first?.count != expected }) { idents = [] }
    }

    enum Keys: String, CodingKey {
        case delaySeconds, muteNews, favourite, shadowMode, detector, idents, candidates, candidateSources, startMinuteHistogram, bulletinSeconds
    }

    /// Encodes everything except the candidates, which `save` writes to their own file.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(delaySeconds, forKey: .delaySeconds); try container.encode(muteNews, forKey: .muteNews)
        try container.encode(favourite, forKey: .favourite); try container.encode(shadowMode, forKey: .shadowMode)
        try container.encode(detector, forKey: .detector); try container.encode(idents, forKey: .idents)
        try container.encode(candidateSources, forKey: .candidateSources)
        try container.encode(startMinuteHistogram, forKey: .startMinuteHistogram); try container.encode(bulletinSeconds, forKey: .bulletinSeconds)
    }

    /// The profile's JSON file, `profiles/<serviceId>.json` in the support directory.
    public static func url(_ serviceId: String) throws -> URL {
        let directory = try AppPaths.supportDirectory().appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(serviceId).json")
    }

    /// The candidates' binary file beside the JSON.
    static func candidatesURL(_ serviceId: String) throws -> URL {
        try url(serviceId).deletingPathExtension().appendingPathExtension("candidates")
    }

    /// The station's saved profile, or a new one with defaults suited to the station.
    public static func load(_ station: Station) -> StationProfile {
        if let url = try? url(station.serviceId), let data = try? Data(contentsOf: url),
           var profile = try? JSONDecoder().decode(StationProfile.self, from: data) {
            // Older profiles kept candidates in the JSON; newer ones keep them in the binary file.
            if profile.candidates.isEmpty, let binary = try? candidatesURL(station.serviceId), let blob = try? Data(contentsOf: binary) {
                profile.candidates = CandidateFile.decode(blob)
            }
            if profile.candidateSources.count != profile.candidates.count {
                profile.candidateSources = Array(repeating: "", count: profile.candidates.count)
            }
            return profile
        }
        var profile = StationProfile()
        if station.kind == .speech { profile.muteNews = false }
        if station.serviceId == "bbc_radio_two" {
            // Radio 2's bulletins and speech content have not been measured, so only its jingle mutes, and only
            // once it has been checked in shadow mode.
            profile.shadowMode = true; profile.detector.identOnly = true
        }
        return profile
    }

    /// Writes the profile and its candidates. Failures are ignored: a profile not saved is learned again.
    public func save(_ station: Station) {
        guard let url = try? StationProfile.url(station.serviceId) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
        if let binary = try? StationProfile.candidatesURL(station.serviceId) {
            try? CandidateFile.encode(candidates).write(to: binary, options: .atomic)
        }
    }

    /// Learns a confirmed bulletin's start minute and length, and once five are known, tightens the range of lengths
    /// the detector treats as normal to the middle 90 %, with a margin.
    ///
    /// - Parameters:
    ///   - start: The bulletin's start, on the stream clock [s since 1970].
    ///   - end: Its end, on the same clock.
    public mutating func learn(start: Double, end: Double) {
        let minute = Int((start.truncatingRemainder(dividingBy: 3600)) / 60)
        startMinuteHistogram[minute, default: 0] += 1
        bulletinSeconds.append(end - start)
        if bulletinSeconds.count > Self.maxBulletinLengths { bulletinSeconds.removeFirst() }
        if bulletinSeconds.count >= 5 {
            let sorted = bulletinSeconds.sorted()
            detector.minBulletinSeconds = max(30, sorted[sorted.count / 20] * 0.7)
            detector.maxBulletinSeconds = sorted[sorted.count - 1 - sorted.count / 20] * 1.3
        }
    }
}

/// A learned news theme: four seconds of `IdentFeatures` frames, and the score a match must reach.
public struct IdentReference: Codable, Sendable, Equatable {
    public var features: [[Float]]
    public var threshold: Float = IdentMatcher.defaultThreshold
}

/// The binary layout of a `.candidates` file.
///
/// A count, then for each candidate its frame count, its band count and its features, all little-endian 32-bit
/// values (the features as Float32). About 1.7 MB for eight candidates, against several MB of JSON.
enum CandidateFile {
    static func encode(_ candidates: [[[Float]]]) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(UInt32(candidates.count))
        for candidate in candidates {
            put(UInt32(candidate.count)); put(UInt32(candidate.first?.count ?? 0))
            for frame in candidate { for value in frame { put(value.bitPattern) } }
        }
        return data
    }

    /// Reads a `.candidates` file. A truncated or malformed file gives no candidates at all.
    static func decode(_ data: Data) -> [[[Float]]] {
        var position = 0
        func get() -> UInt32? {
            guard position + 4 <= data.count else { return nil }
            let start = data.startIndex + position
            let raw = data[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            position += 4
            return UInt32(littleEndian: raw)
        }
        guard let count = get() else { return [] }
        var candidates: [[[Float]]] = []
        for _ in 0..<count {
            guard let frames = get(), let bands = get() else { return [] }
            var candidate: [[Float]] = []
            for _ in 0..<frames {
                var frame: [Float] = []
                for _ in 0..<bands { guard let bits = get() else { return [] }; frame.append(Float(bitPattern: bits)) }
                candidate.append(frame)
            }
            candidates.append(candidate)
        }
        return candidates
    }
}
