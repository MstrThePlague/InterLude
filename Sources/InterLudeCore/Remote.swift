//  Remote.swift
//  InterLudeCore
//
//  The contract between InterLude and its web app. The same page is the Mac's menu bar panel, its phone remote and
//  the Linux server's app, so this file defines everything the page shows (`RemoteState`), everything it can ask
//  for (`RemoteCommand`, `RemoteSetting`), how its addresses are routed (`RemoteRoutes`), and the wording the Mac
//  and the server share, so both describe things the same way.

import Foundation

/// What the web app shows, sent as JSON to the page every second or two.
public struct RemoteState: Codable, Sendable, Equatable {
    /// A station in the station list.
    public struct StationItem: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var short: String?
        public var colour: String?
        public var group: String?
        public var favourite: Bool
        public init(id: String, name: String, short: String?, colour: String?, group: String?, favourite: Bool) {
            self.id = id; self.name = name; self.short = short; self.colour = colour; self.group = group; self.favourite = favourite
        }
    }

    /// A place to play: this Mac or browser, a speaker, or a group.
    public struct SpeakerItem: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var detail: String?
        /// "mac", "browser", "speaker" or "group", which picks the icon.
        public var kind: String
        public init(id: String, name: String, detail: String?, kind: String) { self.id = id; self.name = name; self.detail = detail; self.kind = kind }
    }

    /// A programme in the Earlier list.
    public struct ProgrammeItem: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        /// The subtitle or length, or why it can't be played.
        public var detail: String
        /// The start time, written in the Mac's or server's locale.
        public var time: String
        public var image: String?
        public var playable: Bool
        public var onNow: Bool
        /// The programme last picked.
        public var chosen: Bool
        /// The programme playing now.
        public var playing: Bool
        public init(id: String, title: String, detail: String, time: String, image: String?, playable: Bool, onNow: Bool, chosen: Bool, playing: Bool) {
            self.id = id; self.title = title; self.detail = detail; self.time = time; self.image = image
            self.playable = playable; self.onNow = onNow; self.chosen = chosen; self.playing = playing
        }
    }

    /// The Earlier list: one day of the station's schedule.
    public struct EarlierItem: Codable, Sendable, Equatable {
        /// 0 is today, up to `lastDay` days back.
        public var day = 0
        public var lastDay = OnDemand.days - 1
        public var dayTitle = "Today"
        public var loading = false
        public var problem: String?
        public var programmes: [ProgrammeItem] = []
        public init() {}
    }

    /// Progress through the earlier programme playing, as fractions of its length.
    public struct ReplayItem: Codable, Sendable, Equatable {
        /// How far the listener has heard.
        public var heard: Double
        /// How far the analysis has reached.
        public var analysed: Double
        /// Each bulletin found, as a start and end.
        public var news: [[Double]]
        /// Such as "12:34 of 2 h 0 min".
        public var position: String
        /// Such as "2 bulletins skipped · 6:11", or nil before any.
        public var skipped: String?
        public init(heard: Double, analysed: Double, news: [[Double]], position: String, skipped: String?) {
            self.heard = heard; self.analysed = analysed; self.news = news; self.position = position; self.skipped = skipped
        }
    }

    /// The news card: whether the station's bulletins are muted (skipped in Earlier), and a line saying how.
    public struct NewsItem: Codable, Sendable, Equatable {
        public var on: Bool
        /// "Mute news" or "Skip news".
        public var title: String
        public var detail: String
        /// False for speech stations, where talk is the programme.
        public var available: Bool
        public init(on: Bool, title: String, detail: String, available: Bool) {
            self.on = on; self.title = title; self.detail = detail; self.available = available
        }
    }

    /// A bulletin muted or skipped recently.
    public struct RecentItem: Codable, Sendable, Equatable {
        public var id: String
        /// When it started, written in the Mac's or server's locale.
        public var time: String
        /// Such as "20 s", "4 min 20 s" or "muting now".
        public var length: String
        /// "done", "open" (still muting) or "notNews" (a false start, already put right).
        public var kind: String
        public init(id: String, time: String, length: String, kind: String) { self.id = id; self.time = time; self.length = length; self.kind = kind }
    }

    /// "off", "starting", "live", "earlier", "muted" or "error", as the panel's status badge shows it.
    public var state = "off"
    public var stationName = ""
    public var headline = ""
    public var subheadline = ""
    public var artwork: String?
    public var error: String?
    /// Playing or starting, so the main button stops.
    public var playing = false
    /// From 0 to 1.
    public var volume = 0.7
    public var muted = false
    /// How long the current bulletin has been muted [s].
    public var muteElapsed: Double?
    /// How long until a bulletin already found is muted [s].
    public var muteStartsIn: Double?
    /// News just cut from an earlier programme [s], shown for a few seconds after.
    public var justSkipped: Double?
    /// Whether "Not news" and "News got through" make sense: something is playing on a station whose news is muted.
    public var canCorrect = false
    /// A short note, such as whether the news jingle is learned.
    public var note: String?
    public var footer: String?
    /// The station chosen.
    public var station = ""
    /// The speaker chosen.
    public var speaker = ""
    public var stations: [StationItem] = []
    public var speakers: [SpeakerItem] = []
    /// Shown under the speaker list: still searching, no speakers, or Local Network permission is off.
    public var speakerNote: String?
    /// "live" or "earlier", as the panel's Live / Earlier switch.
    public var mode = "live"
    /// Set in Earlier.
    public var earlier: EarlierItem?
    /// Set while an earlier programme plays.
    public var replay: ReplayItem?
    /// Live is showing while an earlier programme or another station plays, so the page offers to play the chosen
    /// station live instead.
    public var offerLive = false
    /// The station playing or starting, when it isn't `station`, the one being browsed.
    public var onAir: String?
    /// The web app's files as served now. A page loaded from older ones loads itself again.
    public var pageVersion: String?
    /// Set by a server, which the page then plays itself: the stream's address.
    public var stream: String?
    /// Changes whenever a new session starts, so a browser playing along knows to load the stream again.
    public var streamID: Int?
    /// What the Settings sheet shows.
    public var settings: SettingsItem?
    public var news: NewsItem?
    /// "Recent mutes" or "News in this programme": the heading over `recent`.
    public var recentTitle: String?
    /// Recent bulletins, newest first.
    public var recent: [RecentItem] = []
    /// Ways out of `error`: "retry" (start again), "here" (play on this Mac instead of a speaker).
    public var recover: [String] = []
    /// A first-run note, until it is dismissed.
    public var welcome = false
    public init() {}

    /// Settings only the Mac has, shown in its own panel and never on a phone.
    public struct MacSettings: Codable, Sendable, Equatable {
        public var startAtLogin: Bool
        public var keepAwake: Bool
        public var port: Int
        public var remote: Bool
        /// Why the phone remote has no link, or what the phone needs to reach it.
        public var remoteNote: String?
        public init(startAtLogin: Bool, keepAwake: Bool, port: Int, remote: Bool, remoteNote: String?) {
            self.startAtLogin = startAtLogin; self.keepAwake = keepAwake; self.port = port; self.remote = remote; self.remoteNote = remoteNote
        }
    }

    /// The Settings sheet.
    public struct SettingsItem: Codable, Sendable, Equatable {
        /// The station the news options apply to.
        public var stationName: String
        /// [s]
        public var delay: Double
        public var muteNews: Bool
        public var jingleOnly: Bool
        public var shadowMode: Bool
        /// Whether the news jingle is learned, in words.
        public var jingle: String
        public var canForgetJingle: Bool
        /// Shown above the news options, such as when they don't take effect yet.
        public var newsNote: String?
        /// [kbit/s]
        public var bitrate: Int
        public var ambience: String
        /// Pairs of ID and name.
        public var ambienceChoices: [[String]]
        /// Where another device opens InterLude, for the QR code and Reset link: the server's app path, such as
        /// `/app/<token>/`, or the Mac's phone remote address. Empty when there is none.
        public var link: String
        /// A QR code image for `link`, relative to the page, when the page shouldn't draw its own.
        public var qr: String?
        /// For music stations: the longest a mute may last [min].
        public var maxMute: Double?
        /// For music stations: the minutes past the hour bulletins start, such as "0, 30".
        public var slots: String?
        /// Set only in the Mac's own panel.
        public var mac: MacSettings?
        public init(stationName: String, delay: Double, muteNews: Bool, jingleOnly: Bool, shadowMode: Bool, jingle: String,
                    canForgetJingle: Bool, newsNote: String?, bitrate: Int, ambience: String, ambienceChoices: [[String]], link: String,
                    qr: String? = nil, maxMute: Double? = nil, slots: String? = nil, mac: MacSettings? = nil) {
            self.stationName = stationName; self.delay = delay; self.muteNews = muteNews; self.jingleOnly = jingleOnly
            self.shadowMode = shadowMode; self.jingle = jingle; self.canForgetJingle = canForgetJingle; self.newsNote = newsNote
            self.bitrate = bitrate; self.ambience = ambience; self.ambienceChoices = ambienceChoices; self.link = link
            self.qr = qr; self.maxMute = maxMute; self.slots = slots; self.mac = mac
        }
    }
}

/// A change made in the Settings sheet, checked against the ranges the controls allow.
public enum RemoteSetting: Equatable, Sendable {
    /// The delay [s], the news switches, forgetting the jingle, the bit rate [bit/s] and the sound during bulletins.
    case delay(Double), muteNews(Bool), jingleOnly(Bool), shadowMode(Bool), forgetJingle, bitrate(Int), ambience(String)
    /// For music stations: the longest mute [min], and the minutes past the hour bulletins start.
    case maxMute(Double), slots([Int])
    /// The Mac's own: accepted only from its panel.
    case startAtLogin(Bool), keepAwake(Bool), port(Int), remote(Bool)

    /// Whether only the Mac's own panel may change it.
    public var macOnly: Bool {
        switch self { case .startAtLogin, .keepAwake, .port, .remote: true; default: false }
    }

    /// Reads a setting from the page's `k` and `v` query parameters.
    ///
    /// - Returns: Nil for an unknown key or a value out of range. Values are rounded to what the controls offer.
    public init?(key: String?, value: String?) {
        func flag() -> Bool? { switch value { case "1", "true": true; case "0", "false": false; default: nil } }
        switch key {
        case "delay":
            guard let seconds = value.flatMap(Double.init), seconds.isFinite, (30...600).contains(seconds) else { return nil }
            self = .delay((seconds / 5).rounded() * 5)
        case "muteNews": guard let on = flag() else { return nil }; self = .muteNews(on)
        case "jingleOnly": guard let on = flag() else { return nil }; self = .jingleOnly(on)
        case "shadowMode": guard let on = flag() else { return nil }; self = .shadowMode(on)
        case "forgetJingle": self = .forgetJingle
        case "bitrate":
            guard let kbps = value.flatMap(Int.init), kbps == 128 || kbps == 320 else { return nil }
            self = .bitrate(kbps * 1000)
        case "ambience":
            guard let id = value, Ambience.choices.contains(where: { $0.id == id }) else { return nil }
            self = .ambience(id)
        case "maxMute":
            guard let minutes = value.flatMap(Double.init), minutes.isFinite, (5...20).contains(minutes) else { return nil }
            self = .maxMute(minutes.rounded())
        case "slots":
            let minutes = (value ?? "").split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }
            guard !minutes.isEmpty, minutes.count <= 12, minutes.allSatisfy({ (0..<60).contains($0) }) else { return nil }
            self = .slots(Array(Set(minutes)).sorted())
        case "startAtLogin": guard let on = flag() else { return nil }; self = .startAtLogin(on)
        case "keepAwake": guard let on = flag() else { return nil }; self = .keepAwake(on)
        case "remote": guard let on = flag() else { return nil }; self = .remote(on)
        case "port":
            guard let port = value.flatMap(Int.init), (1024...65535).contains(port) else { return nil }
            self = .port(port)
        default: return nil
        }
    }
}

/// Something the page asked InterLude to do.
public enum RemoteCommand: Equatable, Sendable {
    /// Play or stop; play only (does nothing if already playing, for a browser about to play along); choose a station
    /// or speaker; set the volume (0 to 1); and correct the detector.
    case toggle, play, station(String), speaker(String), volume(Double), notNews, newsGotThrough
    /// Earlier programmes: switch between Live and Earlier, step through the days, read the schedule again, and
    /// play a programme from its start.
    case earlier(Bool), day(Int), reloadSchedule, programme(String)
    /// Settings, and a new link that stops the old one working.
    case setting(RemoteSetting), resetLink
    /// Add or remove a favourite station; mark a recent mute as wrong, by its ID; dismiss the first-run note.
    case favourite(String), wrong(String), welcomed
    /// The Mac's own, accepted only from its panel: save a diagnostics zip, and quit.
    case diagnostics, quit

    /// Whether only the Mac's own panel may send it.
    public var macOnly: Bool {
        switch self {
        case .diagnostics, .quit: true
        case .setting(let setting): setting.macOnly
        default: false
        }
    }
}

/// What a request under the page's address asks for.
public enum RemoteRoute: Equatable, Sendable {
    /// The page, its style sheet or script (`asset`), its web manifest, its icon, a QR code for its link, its state
    /// as JSON, its state as server-sent events (which only a server offers), or a command.
    case page, asset(String), manifest, icon, qr, state, events, command(RemoteCommand)
}

/// The web app's addresses, and the responses common to every server.
///
/// The page lives at `/remote/<token>/` for the Mac's phone remote, `/panel/<token>/` for the Mac's own panel, and
/// `/app/<token>/` on a server. The token is a long random code, so other devices on the network can't guess it.
public enum RemoteRoutes {
    public static let prefix = "/remote/"
    public static let appPrefix = "/app/"
    public static let panelPrefix = "/panel/"

    /// A new random token: 32 hexadecimal characters (122 random bits).
    public static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The page's path for a token, with the trailing slash its relative links need.
    public static func pagePath(token: String, prefix: String = prefix) -> String { "\(prefix)\(token)/" }

    /// What a request asks for.
    ///
    /// Commands must be POSTs, so a browser fetching links ahead of time can never press a button.
    ///
    /// - Returns: Nil if the request isn't for the page with this token, or isn't a valid request.
    public static func route(_ req: HTTPRequest, token: String, prefix: String = prefix) -> RemoteRoute? {
        let base = prefix + token
        guard !token.isEmpty, req.path == base || req.path.hasPrefix(base + "/") else { return nil }
        let rest = String(req.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let post = req.method == "POST"
        switch rest {
        case "", "index.html": return post ? nil : .page
        case "app.css", "app.js": return post ? nil : .asset(rest)
        case "manifest.webmanifest": return post ? nil : .manifest
        case "icon.png": return post ? nil : .icon
        case "qr.png": return post ? nil : .qr
        case "api/state": return .state
        case "api/events": return post ? nil : .events
        default: break
        }
        guard post, rest.hasPrefix("api/") else { return nil }
        let query = req.query
        switch rest.dropFirst(4) {
        case "toggle": return .command(.toggle)
        case "play": return .command(.play)
        case "station": return query["id"].map { .command(.station($0)) }
        case "speaker": return query["id"].map { .command(.speaker($0)) }
        case "volume":
            guard let level = query["v"].flatMap(Double.init), level.isFinite else { return nil }
            return .command(.volume(min(max(level, 0), 1)))
        case "notnews": return .command(.notNews)
        case "gotthrough": return .command(.newsGotThrough)
        case "mode":
            switch query["m"] { case "live": return .command(.earlier(false)); case "earlier": return .command(.earlier(true)); default: return nil }
        case "day":
            guard let day = query["d"].flatMap(Int.init), (0..<OnDemand.days).contains(day) else { return nil }
            return .command(.day(day))
        case "schedule": return .command(.reloadSchedule)
        case "programme":
            guard let id = query["id"], isProgrammeID(id) else { return nil }
            return .command(.programme(id))
        case "setting": return RemoteSetting(key: query["k"], value: query["v"]).map { .command(.setting($0)) }
        case "resetlink": return .command(.resetLink)
        case "favourite": return query["id"].map { .command(.favourite($0)) }
        case "wrong":
            guard let id = query["id"], UUID(uuidString: id) != nil else { return nil }
            return .command(.wrong(id))
        case "welcomed": return .command(.welcomed)
        case "diagnostics": return .command(.diagnostics)
        case "quit": return .command(.quit)
        default: return nil
        }
    }

    /// Whether `id` looks like a BBC programme ID: short and alphanumeric, like `p0lxz91z`.
    static func isProgrammeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    /// The state as a JSON response.
    public static func json(_ state: RemoteState) -> HTTPResponse {
        HTTPResponse(contentType: "application/json", body: (try? JSONEncoder().encode(state)) ?? Data("{}".utf8), noCache: true)
    }

    /// The page, with its placeholders filled in.
    ///
    /// - Parameters:
    ///   - token: The token in the page's address, for its base URL.
    ///   - touchIcon: A PNG to carry inline as the Home Screen icon, since iOS 27 shows a letter tile for a fetched
    ///     one. Empty to link to `icon.png` instead.
    ///   - prefix: The page's address prefix.
    ///   - files: Where the page is read from.
    public static func page(token: String, touchIcon: Data = Data(), prefix: String = prefix, files: WebFiles) -> HTTPResponse {
        guard let data = files.data("index.html") else { return missing("index.html", files) }
        let icon = touchIcon.isEmpty ? "icon.png" : "data:image/png;base64,\(touchIcon.base64EncodedString())"
        let html = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "__BASE__", with: pagePath(token: token, prefix: prefix))
            .replacingOccurrences(of: "__TOUCH_ICON__", with: icon)
            .replacingOccurrences(of: "__VERSION__", with: files.version)
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(html.utf8), noCache: true)
    }

    /// The page's style sheet or script. Never cached, so a reload always gets the current one.
    public static func asset(_ name: String, files: WebFiles) -> HTTPResponse {
        guard let data = files.data(name) else { return missing(name, files) }
        let type = name.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8"
        return HTTPResponse(contentType: type, body: data, noCache: true)
    }

    /// An error saying where the missing file was looked for.
    private static func missing(_ name: String, _ files: WebFiles) -> HTTPResponse {
        HTTPResponse(status: 500, contentType: "text/plain",
                     body: Data("InterLude can't find its \(name) in \(files.folders.map(\.path).joined(separator: " or ")).\n".utf8), noCache: true)
    }

    /// The web manifest, which lets a phone keep the page on its Home Screen as an app.
    public static let manifest = HTTPResponse(contentType: "application/manifest+json", body: Data("""
        {"name":"InterLude","short_name":"InterLude","start_url":"./","scope":"./","display":"standalone",
        "background_color":"#070a1e","theme_color":"#070a1e",
        "icons":[{"src":"icon.png","sizes":"512x512","type":"image/png"}]}
        """.utf8))
}

// MARK: Wording shared by the Mac and the server

/// Times and lengths written the same way on the Mac and the server.
public enum Wording {
    /// A length in whole minutes, such as "45 min" or "2 h 0 min".
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// A position, such as "6:11", or "1:02:03" past an hour.
    public static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
                             : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "Today", "Yesterday", or the weekday and date further back, such as "Monday 26 Oct".
    public static func dayTitle(daysAgo: Int, now: Date = Date()) -> String {
        switch daysAgo {
        case 0: "Today"
        case 1: "Yesterday"
        default: (Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now)
            .formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
    }

    /// The footer while something plays: how far behind live, and for an earlier programme when it started.
    public static func footer(delaySeconds: Double, replay: ReplayStatus?) -> String {
        if let replay {
            return "Started at \(replay.programme.start.formatted(date: .omitted, time: .shortened)) · \(duration(delaySeconds)) behind live"
        }
        return "About \(Int((delaySeconds / 5).rounded()) * 5) seconds behind live"
    }
}

extension RemoteState.EarlierItem {
    /// The Earlier list for one day of a station's schedule.
    ///
    /// - Parameters:
    ///   - day: Days back from today.
    ///   - programmes: The day's schedule, newest first.
    ///   - loading: Whether the schedule is being read.
    ///   - problem: Why it couldn't be read, if it couldn't.
    ///   - chosen: The programme last picked.
    ///   - playing: The programme playing now.
    public static func describe(day: Int, programmes: [Programme], loading: Bool, problem: String?,
                                chosen: Programme?, playing: Programme?, now: Date = Date()) -> Self {
        var item = Self()
        item.day = day
        item.dayTitle = Wording.dayTitle(daysAgo: day, now: now)
        item.loading = loading && programmes.isEmpty
        if programmes.isEmpty { item.problem = problem }
        item.programmes = programmes.map { programme in
            let playable = programme.canPlay, onNow = programme.end > now
            let length = Wording.duration(programme.end.timeIntervalSince(programme.start))
            return .init(id: programme.id, title: programme.title,
                         detail: playable ? (programme.subtitle ?? length) : (onNow ? "On now" : "Not available"),
                         time: programme.start.formatted(date: .omitted, time: .shortened), image: programme.imageURL?.absoluteString,
                         playable: playable, onNow: onNow, chosen: chosen?.id == programme.id, playing: playing?.id == programme.id)
        }
        return item
    }
}

extension RemoteState.ReplayItem {
    /// The progress bar for an earlier programme.
    public static func describe(_ status: ReplayStatus) -> Self {
        let programme = status.programme
        let total = max(1, programme.end.timeIntervalSince(programme.start))
        func fraction(_ date: Date) -> Double { min(1, max(0, date.timeIntervalSince(programme.start) / total)) }
        let skipped = status.skipCount > 0
            ? "\(status.skipCount) bulletin\(status.skipCount == 1 ? "" : "s") skipped · \(Wording.clock(status.skippedSeconds))" : nil
        return .init(heard: fraction(status.heard), analysed: fraction(status.analysedThrough),
                     news: status.news.map { [fraction($0.lowerBound), fraction($0.upperBound)] },
                     position: "\(Wording.clock(status.heard.timeIntervalSince(programme.start))) of \(Wording.duration(total))",
                     skipped: skipped)
    }
}

extension RemoteState.NewsItem {
    /// The news card for a station.
    ///
    /// - Parameters:
    ///   - profile: The station's settings.
    ///   - kind: Music or speech.
    ///   - hasNews: False for a stream with no bulletins, from `Station.news`.
    ///   - earlier: Whether bulletins are skipped rather than muted: an earlier programme playing, or Earlier showing
    ///     with nothing playing.
    ///   - ambience: The ID of the sound played during bulletins.
    public static func describe(_ profile: StationProfile, kind: StationKind?, hasNews: Bool = true, earlier: Bool, ambience: String) -> Self {
        let speech = kind == .speech || !hasNews
        let title = earlier ? "Skip news" : "Mute news"
        let detail: String
        if !hasNews { detail = "Off: this stream has no news bulletins." }
        else if speech { detail = "Off for speech stations, where talk is the programme." }
        else if profile.shadowMode { detail = "Shadow mode: bulletins are noted but not muted." }
        else if !profile.muteNews { detail = "Off. Bulletins will play." }
        else if earlier {
            detail = profile.detector.identOnly && profile.idents.isEmpty
                ? "Set to jingle only, but no jingle is learned yet, so nothing is skipped."
                : "Cuts bulletins out, so the programme runs on without them."
        } else if profile.detector.identOnly {
            detail = profile.idents.isEmpty
                ? "Set to jingle only, but no jingle is learned yet, so nothing is muted. Change this in Settings."
                : "Mutes when the station's news jingle plays."
        } else if ambience == "silence" { detail = "Silences bulletins until the music returns." }
        else {
            let name = Ambience.choices.first { $0.id == ambience }?.name.lowercased() ?? "a soothing sound"
            detail = "Plays \(name) over bulletins until the music returns."
        }
        return .init(on: profile.muteNews && !speech, title: title, detail: detail, available: !speech)
    }
}

extension RemoteState.RecentItem {
    /// The recent bulletins as the panel lists them.
    ///
    /// - Parameter blocks: The bulletins, newest first. At most six are listed.
    public static func list(_ blocks: [NewsBlock]) -> [Self] {
        blocks.prefix(6).map { block in
            let length: String
            if let end = block.end {
                let seconds = Int(end - block.start)
                length = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
            } else { length = "muting now" }
            return .init(id: block.id.uuidString, time: Date(timeIntervalSince1970: block.start).formatted(date: .omitted, time: .shortened),
                         length: length, kind: block.falseStart ? "notNews" : (block.isOpen ? "open" : "done"))
        }
    }
}

extension StationProfile {
    /// Whether the station's news jingle is learned, as Settings words it.
    public var jingleStatus: String {
        if !idents.isEmpty { return "Learned" }
        switch candidates.count {
        case 0: return "Not learned yet"
        case 1, 2: return "Learning: \(candidates.count) bulletin\(candidates.count == 1 ? "" : "s") heard"
        default: return "No shared jingle yet (\(candidates.count) bulletins)"
        }
    }
}
