import Foundation

/// What the web app shows, sent as JSON to the page every second or two. The same page is the Mac's panel, its phone
/// remote and the server's app, so everything any of them shows is here.
public struct RemoteState: Codable, Sendable, Equatable {
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
    public struct SpeakerItem: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var detail: String?
        /// "mac", "speaker" or "group".
        public var kind: String
        public init(id: String, name: String, detail: String?, kind: String) { self.id = id; self.name = name; self.detail = detail; self.kind = kind }
    }
    public struct ProgrammeItem: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        /// The subtitle or length, or why it can't be played.
        public var detail: String
        /// Start time as the Mac writes it.
        public var time: String
        public var image: String?
        public var playable: Bool
        public var onNow: Bool
        /// The programme last picked; `playing` while it plays.
        public var chosen: Bool
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
        public var heard: Double
        public var analysed: Double
        public var news: [[Double]]
        /// "12:34 of 2 h 0 min"
        public var position: String
        /// "2 bulletins skipped · 6:11", or nil before any.
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
        /// When it started, as the Mac or server writes it.
        public var time: String
        /// "20 s", "4 min 20 s" or "muting now".
        public var length: String
        /// "done", "open" (still muting) or "notNews" (a false start, already put right).
        public var kind: String
        public init(id: String, time: String, length: String, kind: String) { self.id = id; self.time = time; self.length = length; self.kind = kind }
    }

    /// off, starting, live, earlier, muted or error, as the panel's status badge.
    public var state = "off"
    public var stationName = ""
    public var headline = ""
    public var subheadline = ""
    public var artwork: String?
    public var error: String?
    /// Playing or starting, so the main button stops.
    public var playing = false
    public var volume = 0.7
    public var muted = false
    public var muteElapsed: Double?
    public var muteStartsIn: Double?
    public var justSkipped: Double?
    /// Not news and News got through make sense: something is playing on a station whose news is muted.
    public var canCorrect = false
    public var note: String?
    public var footer: String?
    public var station = ""
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
    /// The station playing or starting, when it isn't `station`, the one being browsed. Set by a server.
    public var onAir: String?
    /// The web app's files as served now. A page loaded from older ones loads itself again.
    public var pageVersion: String?
    /// Set by a server, which the page then plays itself: the stream's address, and an ID that changes whenever a
    /// new session starts, so a browser playing along knows to load the stream again.
    public var stream: String?
    public var streamID: Int?
    /// What the Settings sheet shows.
    public var settings: SettingsItem?
    public var news: NewsItem?
    /// "Recent mutes" or "News in this programme", and the bulletins under it, newest first.
    public var recentTitle: String?
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

    public struct SettingsItem: Codable, Sendable, Equatable {
        /// The station the news options apply to.
        public var stationName: String
        public var delay: Double
        public var muteNews: Bool
        public var jingleOnly: Bool
        public var shadowMode: Bool
        /// Whether the news jingle is learned, as the Mac's Settings words it.
        public var jingle: String
        public var canForgetJingle: Bool
        /// Shown above the news options, such as when they don't take effect yet.
        public var newsNote: String?
        /// In kbps.
        public var bitrate: Int
        public var ambience: String
        /// Pairs of ID and name.
        public var ambienceChoices: [[String]]
        /// Where another device opens InterLude, for the QR code and the Reset link answer: the server's app path, such
        /// as `/app/<token>/`, or the Mac's phone remote address. Empty when there is none.
        public var link: String
        /// A QR code image for `link`, relative to the page, when the page shouldn't draw its own.
        public var qr: String?
        /// For music stations: the longest a mute may last, in minutes, and the bulletin minutes past the hour.
        public var maxMute: Double?
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
    case delay(Double), muteNews(Bool), jingleOnly(Bool), shadowMode(Bool), forgetJingle, bitrate(Int), ambience(String)
    /// Music stations: the longest mute in minutes, and the minutes past the hour bulletins start.
    case maxMute(Double), slots([Int])
    /// The Mac's own: accepted only from its panel.
    case startAtLogin(Bool), keepAwake(Bool), port(Int), remote(Bool)

    /// Whether only the Mac's own panel may change it.
    public var macOnly: Bool {
        switch self { case .startAtLogin, .keepAwake, .port, .remote: true; default: false }
    }

    public init?(key: String?, value: String?) {
        func flag() -> Bool? { switch value { case "1", "true": true; case "0", "false": false; default: nil } }
        switch key {
        case "delay":
            guard let d = value.flatMap(Double.init), d.isFinite, (30...600).contains(d) else { return nil }
            self = .delay((d / 5).rounded() * 5)
        case "muteNews": guard let f = flag() else { return nil }; self = .muteNews(f)
        case "jingleOnly": guard let f = flag() else { return nil }; self = .jingleOnly(f)
        case "shadowMode": guard let f = flag() else { return nil }; self = .shadowMode(f)
        case "forgetJingle": self = .forgetJingle
        case "bitrate":
            guard let b = value.flatMap(Int.init), b == 128 || b == 320 else { return nil }
            self = .bitrate(b * 1000)
        case "ambience":
            guard let a = value, Ambience.choices.contains(where: { $0.id == a }) else { return nil }
            self = .ambience(a)
        case "maxMute":
            guard let m = value.flatMap(Double.init), m.isFinite, (5...20).contains(m) else { return nil }
            self = .maxMute(m.rounded())
        case "slots":
            let mins = (value ?? "").split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }
            guard !mins.isEmpty, mins.count <= 12, mins.allSatisfy({ (0..<60).contains($0) }) else { return nil }
            self = .slots(Array(Set(mins)).sorted())
        case "startAtLogin": guard let f = flag() else { return nil }; self = .startAtLogin(f)
        case "keepAwake": guard let f = flag() else { return nil }; self = .keepAwake(f)
        case "remote": guard let f = flag() else { return nil }; self = .remote(f)
        case "port":
            guard let p = value.flatMap(Int.init), (1024...65535).contains(p) else { return nil }
            self = .port(p)
        default: return nil
        }
    }
}

public enum RemoteCommand: Equatable, Sendable {
    /// `play` starts if stopped and otherwise does nothing, for a browser about to play along.
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
        case .setting(let s): s.macOnly
        default: false
        }
    }
}

public enum RemoteRoute: Equatable, Sendable {
    /// `events` is the state as server-sent events, which only a server offers. `asset` is the page's style or script.
    /// `qr` is a QR code for the link to open InterLude on another device.
    case page, asset(String), manifest, icon, qr, state, events, command(RemoteCommand)
}

/// Addresses for the phone remote on the Mac, `/remote/<token>/`, the Mac's own panel, `/panel/<token>/`, and the web
/// app on a server, `/app/<token>/`, and what sits under them.
public enum RemoteRoutes {
    public static let prefix = "/remote/"
    public static let appPrefix = "/app/"
    public static let panelPrefix = "/panel/"

    public static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The page's path for a token, with the trailing slash its relative links need.
    public static func pagePath(token: String, prefix: String = prefix) -> String { "\(prefix)\(token)/" }

    /// What a request asks for, or nil if it isn't for the remote with this token. Commands must be POSTs, so a
    /// browser fetching links ahead of time can never press a button.
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
        let q = req.query
        switch rest.dropFirst(4) {
        case "toggle": return .command(.toggle)
        case "play": return .command(.play)
        case "station": return q["id"].map { .command(.station($0)) }
        case "speaker": return q["id"].map { .command(.speaker($0)) }
        case "volume":
            guard let v = q["v"].flatMap(Double.init), v.isFinite else { return nil }
            return .command(.volume(min(max(v, 0), 1)))
        case "notnews": return .command(.notNews)
        case "gotthrough": return .command(.newsGotThrough)
        case "mode":
            switch q["m"] { case "live": return .command(.earlier(false)); case "earlier": return .command(.earlier(true)); default: return nil }
        case "day":
            guard let d = q["d"].flatMap(Int.init), (0..<OnDemand.days).contains(d) else { return nil }
            return .command(.day(d))
        case "schedule": return .command(.reloadSchedule)
        case "programme":
            guard let id = q["id"], isProgrammeID(id) else { return nil }
            return .command(.programme(id))
        case "setting": return RemoteSetting(key: q["k"], value: q["v"]).map { .command(.setting($0)) }
        case "resetlink": return .command(.resetLink)
        case "favourite": return q["id"].map { .command(.favourite($0)) }
        case "wrong":
            guard let id = q["id"], UUID(uuidString: id) != nil else { return nil }
            return .command(.wrong(id))
        case "welcomed": return .command(.welcomed)
        case "diagnostics": return .command(.diagnostics)
        case "quit": return .command(.quit)
        default: return nil
        }
    }

    /// BBC programme IDs are short and alphanumeric, like `p0lxz91z`.
    static func isProgrammeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    public static func json(_ s: RemoteState) -> HTTPResponse {
        HTTPResponse(contentType: "application/json", body: (try? JSONEncoder().encode(s)) ?? Data("{}".utf8), noCache: true)
    }

    /// The page from `files`, with `touchIcon` (a PNG) inline as its Home Screen icon: iOS 27 shows a letter tile for
    /// a fetched one.
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

    private static func missing(_ name: String, _ files: WebFiles) -> HTTPResponse {
        HTTPResponse(status: 500, contentType: "text/plain",
                     body: Data("InterLude can't find its \(name) in \(files.folders.map(\.path).joined(separator: " or ")).\n".utf8), noCache: true)
    }

    public static let manifest = HTTPResponse(contentType: "application/manifest+json", body: Data("""
        {"name":"InterLude","short_name":"InterLude","start_url":"./","scope":"./","display":"standalone",
        "background_color":"#070a1e","theme_color":"#070a1e",
        "icons":[{"src":"icon.png","sizes":"512x512","type":"image/png"}]}
        """.utf8))
}

extension RemoteState.NewsItem {
    /// The news card for a station, worded the same on the Mac and a server. `earlier` is whether bulletins are
    /// skipped rather than muted: an earlier programme playing, or Earlier showing with nothing playing.
    public static func describe(_ p: StationProfile, kind: StationKind?, earlier: Bool, ambience: String) -> Self {
        let speech = kind == .speech
        let title = earlier ? "Skip news" : "Mute news"
        let detail: String
        if speech { detail = "Off for speech stations, where talk is the programme." }
        else if p.shadowMode { detail = "Shadow mode: bulletins are noted but not muted." }
        else if !p.muteNews { detail = "Off. Bulletins will play." }
        else if earlier {
            detail = p.detector.identOnly && p.idents.isEmpty ? "Set to jingle only, but no jingle is learned yet, so nothing is skipped."
                                                              : "Cuts bulletins out, so the programme runs on without them."
        } else if p.detector.identOnly {
            detail = p.idents.isEmpty ? "Set to jingle only, but no jingle is learned yet, so nothing is muted. Change this in Settings."
                                      : "Mutes when the station's news jingle plays."
        } else if ambience == "silence" { detail = "Silences bulletins until the music returns." }
        else {
            let name = Ambience.choices.first { $0.id == ambience }?.name.lowercased() ?? "a soothing sound"
            detail = "Plays \(name) over bulletins until the music returns."
        }
        return .init(on: p.muteNews && !speech, title: title, detail: detail, available: !speech)
    }
}

extension RemoteState.RecentItem {
    /// The newest bulletins first, at most six, as the panel lists them.
    public static func list(_ blocks: [NewsBlock]) -> [Self] {
        blocks.prefix(6).map { b in
            let length: String
            if let e = b.end {
                let s = Int(e - b.start)
                length = s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
            } else { length = "muting now" }
            return .init(id: b.id.uuidString, time: Date(timeIntervalSince1970: b.start).formatted(date: .omitted, time: .shortened),
                         length: length, kind: b.falseStart ? "notNews" : (b.isOpen ? "open" : "done"))
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
