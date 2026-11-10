//  Coordinator.swift
//  InterLudeCore
//
//  What the Mac app's model and the server's controller both do, kept here so it is written once: the station
//  profiles, the per-station settings, the Earlier schedule, where to resume an earlier programme, and the wording of
//  the player. Each side keeps only what differs: where the sound goes, where its own settings live, and notifications.

import Foundation

/// The station profiles in use, read from disk and saved back.
///
/// The session saves what it learns straight to disk, so a change made in Settings starts from the file, never from
/// an older copy held here, which would write over what was learned meanwhile.
public struct ProfileBook: Sendable {
    private var profiles: [String: StationProfile] = [:]
    public init() {}

    /// The station's profile, or defaults if it hasn't been read.
    public func profile(_ id: String) -> StationProfile { profiles[id] ?? StationProfile() }

    /// Reads the profiles of stations not read yet.
    public mutating func load(_ stations: [Station]) {
        for station in stations where profiles[station.serviceId] == nil { profiles[station.serviceId] = StationProfile.load(station) }
    }

    /// Reads a station's profile again, after the session may have saved what it learned.
    public mutating func reload(_ station: Station) { profiles[station.serviceId] = StationProfile.load(station) }

    /// Changes a station's profile as it is on disk, and saves it.
    ///
    /// - Returns: The profile as saved, to pass to a session playing the station.
    @discardableResult
    public mutating func update(_ station: Station, _ change: (inout StationProfile) -> Void) -> StationProfile {
        var updated = StationProfile.load(station)
        change(&updated)
        profiles[station.serviceId] = updated
        updated.save(station)
        return updated
    }

    /// Favourites first, then the rest in the list's order.
    public func ordered(_ stations: [Station]) -> [Station] {
        stations.filter { profile($0.serviceId).favourite } + stations.filter { !profile($0.serviceId).favourite }
    }

    /// The station list as the web app shows it.
    public func items(_ stations: [Station]) -> [RemoteState.StationItem] {
        ordered(stations).map {
            .init(id: $0.serviceId, name: $0.name, short: $0.short, colour: $0.colour, group: $0.group, favourite: profile($0.serviceId).favourite)
        }
    }
}

extension RemoteSetting {
    /// The change this setting makes to the chosen station's profile, or nil for one that isn't per station.
    public var profileChange: ((inout StationProfile) -> Void)? {
        switch self {
        case .delay(let seconds): { $0.delaySeconds = seconds }
        case .muteNews(let on): { $0.muteNews = on }
        case .jingleOnly(let on): { $0.detector.identOnly = on }
        case .shadowMode(let on): { $0.shadowMode = on }
        case .forgetJingle: { $0.idents = []; $0.candidates = []; $0.candidateSources = [] }
        case .maxMute(let minutes): { $0.detector.maxMuteSeconds = minutes * 60 }
        case .slots(let minutes): { $0.detector.slotMinutes = minutes; $0.slotMinutesByHand = true }
        case .bitrate, .ambience, .startAtLogin, .keepAwake, .port, .remote: nil
        }
    }

    /// "Start muting" on a station still being learned: leaves shadow mode, and mutes on the jingle if one is known,
    /// otherwise on the speech rule, whose finds the listener has just seen.
    public static func startMuting(_ profile: inout StationProfile) {
        profile.shadowMode = false
        profile.detector.identOnly = !profile.idents.isEmpty
    }
}

/// One day of a station's schedule for the Earlier list, kept for five minutes per station and day.
public struct ScheduleBook: Sendable {
    public private(set) var programmes: [Programme] = []
    /// Days back from today.
    public var day = 0
    public private(set) var loading = false
    public private(set) var problem: String?
    private var loadedFor: (station: String, day: Int, at: Date)?
    public init() {}

    /// Whether the schedule for `station` needs reading, and if so marks it as being read.
    ///
    /// - Parameter force: Read it again even if it was read in the last five minutes.
    public mutating func begin(station: String, force: Bool = false) -> Bool {
        if !force, let cached = loadedFor, cached.station == station, cached.day == day, Date().timeIntervalSince(cached.at) < 300,
           !programmes.isEmpty { return false }
        loading = true; problem = nil
        return true
    }

    /// Takes a schedule read, unless the station or day changed while it was read.
    public mutating func loaded(_ list: [Programme], station: String, day: Int, current: String) {
        guard station == current, day == self.day else { return }
        programmes = list; loadedFor = (station, day, Date()); loading = false
    }

    /// Notes that a schedule couldn't be read, unless the station or day changed meanwhile.
    public mutating func failed(_ message: String, station: String, day: Int, current: String) {
        guard station == current, day == self.day else { return }
        loading = false; problem = message
    }

    /// Forgets the programmes shown, for another station or day.
    public mutating func clear() { programmes = [] }

    /// Reads the schedule for `station` and `day`.
    public static func fetch(station: String, day: Int) async -> Result<[Programme], Error> {
        do { return .success(try await OnDemand.day(serviceId: station, daysAgo: day)) } catch { return .failure(error) }
    }

    /// The words shown when the schedule can't be read.
    public static func problem(_ error: Error) -> String { "Couldn't get the schedule: \(error.localizedDescription)" }

    /// The Earlier list for the web app.
    public func item(chosen: Programme?, playing: Programme?) -> RemoteState.EarlierItem {
        .describe(day: day, programmes: programmes, loading: loading, problem: problem, chosen: chosen, playing: playing)
    }
}

/// Where the listener stopped in each earlier programme, so Play carries on from there.
public struct ReplayBookmarks: Sendable {
    private var offsets: [String: Double] = [:]
    public init() {}

    /// Where to start `programme` [s from its start]: where it was left, or its start.
    public func offset(for programme: Programme) -> Double { offsets[programme.id] ?? 0 }

    /// Notes where the listener has got to, a few seconds back so the moment isn't lost. A programme heard to its end,
    /// or barely started, is forgotten.
    public mutating func remember(_ replay: ReplayStatus) {
        let programme = replay.programme
        let heard = replay.heard.timeIntervalSince(programme.start), length = programme.end.timeIntervalSince(programme.start)
        if heard < 30 || heard > length - 60 { offsets[programme.id] = nil } else { offsets[programme.id] = heard - 5 }
        if offsets.count > 50, let oldest = offsets.keys.first { offsets[oldest] = nil }
    }

    public mutating func forget(_ programme: Programme) { offsets[programme.id] = nil }

    /// The offset a tap on the progress bar asks for [s], kept clear of the very end.
    public static func offset(at fraction: Double, in programme: Programme) -> Double {
        let length = programme.end.timeIntervalSince(programme.start)
        return max(0, min(length - 60, fraction * length))
    }
}

extension Wording {
    /// The large line on the player.
    ///
    /// - Parameters:
    ///   - chosen: The station chosen, shown when nothing plays.
    ///   - onAir: The station playing or starting.
    ///   - starting: The programme starting, if an earlier one is.
    public static func headline(chosen: Station?, onAir: Station?, starting: Programme?, isStarting: Bool, isPlaying: Bool,
                                status: SessionStatus) -> String {
        if isStarting, let programme = starting { return programme.title }
        guard isPlaying else { return chosen?.name ?? "InterLude" }
        if status.muted { return "News muted" }
        return status.nowPlaying?.title ?? status.nowPlaying?.artist ?? onAir?.name ?? "Playing"
    }

    /// The line under the headline.
    ///
    /// - Parameters:
    ///   - starting: The programme starting, if an earlier one is.
    ///   - offset: How far into it the start is [s].
    ///   - earlier: Whether the Earlier list is showing.
    ///   - output: Where the sound goes, such as "Kitchen", or nil where that isn't said.
    ///   - onAir: The station playing.
    public static func subheadline(starting: Programme?, offset: Double = 0, isStarting: Bool, isPlaying: Bool, earlier: Bool,
                                   status: SessionStatus, output: String?, onAir: Station?) -> String {
        if isStarting, let programme = starting {
            return offset > 0 ? "Starting \(clock(offset)) in…" : "Starting from \(programme.start.formatted(date: .omitted, time: .shortened))…"
        }
        if isStarting { return "Starting about a minute behind live…" }
        guard isPlaying else {
            if earlier { return "Pick a programme to play from its start" }
            return output.map { "Ready to play on \($0)" } ?? "Ready to play"
        }
        if status.muted { return "Sound returns when the music does" }
        if let track = status.nowPlaying, track.title != nil { return track.artist }
        return output.map { "On \($0)" } ?? onAir?.name ?? ""
    }

    /// What Play does in Earlier with a programme picked and nothing playing.
    public static func playStarts(_ programme: Programme, at offset: Double) -> String {
        offset > 0 ? "Play resumes \(programme.title) at \(clock(offset))"
                   : "Play starts \(programme.title) from \(programme.start.formatted(date: .omitted, time: .shortened))"
    }
}

extension RemoteState.SettingsItem {
    /// The Settings sheet's shared rows for the chosen station.
    ///
    /// - Parameters:
    ///   - station: The station chosen.
    ///   - id: Its ID, named if the station isn't in the list.
    ///   - profile: Its profile.
    ///   - newsNote: Shown above the news options.
    ///   - bitrate: [bit/s]
    ///   - ambience: The sound during bulletins.
    ///   - link: Where another device opens InterLude.
    ///   - qr: A QR code image for `link`, if the page shouldn't draw its own.
    public static func describe(station: Station?, id: String, profile: StationProfile, newsNote: String?, bitrate: Int,
                                ambience: String, link: String, qr: String? = nil) -> Self {
        let music = station?.mutesNews == true
        return .init(stationName: station?.name ?? id, delay: max(SessionSettings.shortestDelay, profile.delaySeconds), muteNews: profile.muteNews,
                     jingleOnly: profile.detector.identOnly, shadowMode: profile.shadowMode, jingle: profile.jingleStatus,
                     canForgetJingle: !profile.idents.isEmpty || !profile.candidates.isEmpty, newsNote: newsNote,
                     bitrate: bitrate / 1000, ambience: ambience, ambienceChoices: Ambience.choices.map { [$0.id, $0.name] },
                     link: link, qr: qr, maxMute: music ? profile.detector.maxMuteSeconds / 60 : nil,
                     slots: music ? profile.detector.slotMinutes.map(String.init).joined(separator: ", ") : nil)
    }
}

extension RemoteState.LearningItem {
    /// The note on the player for a station whose news detection hasn't been checked, while it only notes bulletins.
    ///
    /// - Parameters:
    ///   - station: The station playing live.
    ///   - profile: Its profile.
    ///   - blocks: The bulletins the session has listed, newest first.
    /// - Returns: Nil unless the station is untested, still in shadow mode, and set to mute news.
    public static func describe(station: Station?, profile: StationProfile, blocks: [NewsBlock]) -> Self? {
        guard let station, station.untested == true, station.mutesNews, profile.shadowMode, profile.muteNews else { return nil }
        let found = blocks.filter { !$0.falseStart && !$0.isOpen }
        let times = found.map { Date(timeIntervalSince1970: $0.start).formatted(date: .omitted, time: .shortened) }
        if found.count < Self.enough {
            return .init(title: "Still learning \(station.name)",
                         detail: "News plays for now. InterLude notes each bulletin it finds, and offers to start muting once it has found a few.",
                         found: times, canStartMuting: false)
        }
        return .init(title: "Found \(found.count) bulletins on \(station.name)",
                     detail: "If these times look right, InterLude can start muting bulletins on this station.",
                     found: times, canStartMuting: true)
    }

    /// Bulletins found before "Start muting" is offered.
    static let enough = 2
}

extension RemoteState.RecentItem {
    /// The heading over the recent bulletins.
    ///
    /// - Parameters:
    ///   - replay: Whether an earlier programme plays.
    ///   - shadow: Whether bulletins are only noted, not muted.
    public static func title(replay: Bool, shadow: Bool) -> String {
        replay ? "News in this programme" : (shadow ? "Bulletins found" : "Recent mutes")
    }
}
