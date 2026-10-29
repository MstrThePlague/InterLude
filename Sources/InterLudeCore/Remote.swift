import Foundation

/// What the phone remote shows, sent as JSON to the page every second or two.
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
    /// Set by a server, which the page then plays itself: the stream's address, and an ID that changes whenever a
    /// new session starts, so a browser playing along knows to load the stream again.
    public var stream: String?
    public var streamID: Int?
    /// Set by a server: what its Settings sheet shows.
    public var settings: SettingsItem?
    public init() {}

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
        /// The app's path, such as `/app/<token>/`, for the QR code and the Reset link answer.
        public var link: String
        public init(stationName: String, delay: Double, muteNews: Bool, jingleOnly: Bool, shadowMode: Bool, jingle: String,
                    canForgetJingle: Bool, newsNote: String?, bitrate: Int, ambience: String, ambienceChoices: [[String]], link: String) {
            self.stationName = stationName; self.delay = delay; self.muteNews = muteNews; self.jingleOnly = jingleOnly
            self.shadowMode = shadowMode; self.jingle = jingle; self.canForgetJingle = canForgetJingle; self.newsNote = newsNote
            self.bitrate = bitrate; self.ambience = ambience; self.ambienceChoices = ambienceChoices; self.link = link
        }
    }
}

/// A change made in a server's Settings sheet, checked against the same ranges as the Mac's Settings.
public enum RemoteSetting: Equatable, Sendable {
    case delay(Double), muteNews(Bool), jingleOnly(Bool), shadowMode(Bool), forgetJingle, bitrate(Int), ambience(String)

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
    /// A server's Settings, and a new link that stops the old one working.
    case setting(RemoteSetting), resetLink
}

public enum RemoteRoute: Equatable, Sendable {
    /// `events` is the state as server-sent events, which only a server offers.
    case page, manifest, icon, state, events, command(RemoteCommand)
}

/// Addresses for the phone remote on the Mac, `/remote/<token>/`, and for the web app on a server, `/app/<token>/`,
/// and what sits under them.
public enum RemoteRoutes {
    public static let prefix = "/remote/"
    public static let appPrefix = "/app/"

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
        case "manifest.webmanifest": return post ? nil : .manifest
        case "icon.png": return post ? nil : .icon
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

    /// The page, with `touchIcon` (a PNG) inline as its Home Screen icon: iOS 27 shows a letter tile for a fetched one.
    /// `html` is the built-in page unless the server has a newer copy (see interlude-server).
    public static func page(token: String, touchIcon: Data = Data(), prefix: String = prefix, html: String = RemotePage.html) -> HTTPResponse {
        let icon = touchIcon.isEmpty ? "icon.png" : "data:image/png;base64,\(touchIcon.base64EncodedString())"
        let html = html.replacingOccurrences(of: "__BASE__", with: pagePath(token: token, prefix: prefix))
            .replacingOccurrences(of: "__TOUCH_ICON__", with: icon)
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(html.utf8), noCache: true)
    }

    public static let manifest = HTTPResponse(contentType: "application/manifest+json", body: Data("""
        {"name":"InterLude","short_name":"InterLude","start_url":"./","scope":"./","display":"standalone",
        "background_color":"#070a1e","theme_color":"#070a1e",
        "icons":[{"src":"icon.png","sizes":"512x512","type":"image/png"}]}
        """.utf8))
}

/// The remote's single page. Plain HTML, CSS and script with nothing loaded from elsewhere, apart from album art from
/// the BBC. Every value from the Mac is set as text, never as markup.
public enum RemotePage {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<base href="__BASE__">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="InterLude">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#f2f2f7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#070a1e" media="(prefers-color-scheme: dark)">
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" sizes="180x180" href="__TOUCH_ICON__">
<link rel="icon" href="icon.png">
<title>InterLude</title>
<style>
@property --c1 { syntax: "<color>"; inherits: true; initial-value: #0080ff; }
@property --c2 { syntax: "<color>"; inherits: true; initial-value: #8b00ff; }
@property --c3 { syntax: "<color>"; inherits: true; initial-value: #20b2aa; }
:root {
  color-scheme: light dark;
  --bg: #f2f2f7; --card: rgba(255,255,255,.74); --glass-line: rgba(255,255,255,.7); --aurora-op: .3;
  --text: #1c1c1e; --muted: #55555a; --line: rgba(60,60,67,.14);
  --track-hi: rgba(60,60,67,.3); --card-solid: #ffffff; --chip: rgba(0,0,0,.06); --play-bg: #1c1c1e; --play-fg: #ffffff;
  --accent: #0068d6; --green: #0b7a73; --orange: #b0005a; --orange-bg: rgba(255,20,147,.14); --blue: #6a00c0; --red: #d70015;
  --warn-bg: rgba(255,149,0,.16); --pink: #ff1493;
  transition: --c1 1.4s, --c2 1.4s, --c3 1.4s;
  --press: rgba(0,0,0,.06); --track: rgba(118,118,128,.12); --seg-on: #ffffff; --on-orange: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #070a1e; --card: rgba(11,15,42,.6); --glass-line: rgba(255,255,255,.14); --aurora-op: 1;
    --text: #f2f2f7; --muted: #c6c9df; --line: rgba(255,255,255,.14);
    --track-hi: rgba(255,255,255,.3); --card-solid: #0f1330; --chip: rgba(255,255,255,.1); --play-bg: #ffffff; --play-fg: #0b0d1f;
    --accent: #3d9bff; --green: #5fe3d8; --orange: #ff7cc0; --orange-bg: rgba(255,20,147,.22); --blue: #b98cff; --red: #ff6961;
    --warn-bg: rgba(255,159,10,.18);
    --press: rgba(255,255,255,.08); --track: rgba(118,118,128,.24); --seg-on: rgba(255,255,255,.3); --on-orange: #2a0016;
  }
}
:root[data-mood="live"]    { --c1: var(--station, #0080ff); --c2: #8b00ff; --c3: #20b2aa; }
:root[data-mood="muted"]   { --c1: #ff1493; --c2: #8b00ff; --c3: #0080ff; }
:root[data-mood="earlier"] { --c1: #8b00ff; --c2: #0080ff; --c3: #20b2aa; }
/* The Aurora background: three colour fields drifting on 9 to 12 second loops. Text sits on the glass cards, not on it. */
.aurora { position: fixed; inset: 0; z-index: -1; overflow: hidden; pointer-events: none; opacity: var(--aurora-op); transition: opacity .6s; }
.aurora i { position: absolute; width: 90vmax; height: 70vmax; border-radius: 50%; filter: blur(40px); animation: drift 11s ease-in-out infinite alternate; will-change: transform; }
.aurora i:nth-child(1) { left: -30vmax; top: -25vmax; background: radial-gradient(circle, var(--c1), transparent 68%); }
.aurora i:nth-child(2) { right: -35vmax; top: 15vh; background: radial-gradient(circle, var(--c2), transparent 68%); animation-duration: 9s; animation-delay: -3s; }
.aurora i:nth-child(3) { left: -10vmax; bottom: -35vmax; background: radial-gradient(circle, var(--c3), transparent 68%); animation-duration: 12s; animation-delay: -6s; }
@keyframes drift { from { transform: translate(0, 0) scale(1); } to { transform: translate(8vmax, 6vmax) scale(1.15); } }
:root[data-playing="0"] .aurora i { animation-play-state: paused; }
:root[data-playing="0"] .aurora { opacity: calc(var(--aurora-op) * .6); }
@media (prefers-reduced-motion: reduce) { .aurora i { animation: none; } :root { transition: none; } }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html { background: var(--bg); font-size: 106.25%; }
@supports (font: -apple-system-body) { html { font: -apple-system-body; } }
html, body { margin: 0; color: var(--text); }
body {
  font: 1rem/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif;
  padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(24px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
  -webkit-user-select: none; user-select: none;
}
main { max-width: 480px; margin: 0 auto; display: flex; flex-direction: column; gap: 14px; }
button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; }
.card { background: var(--card); border-radius: 16px; border: 1px solid var(--glass-line);
  -webkit-backdrop-filter: blur(22px) saturate(150%); backdrop-filter: blur(22px) saturate(150%); }
.banner { padding: 12px 14px; border-radius: 12px; font-size: 0.882rem; }
.banner.offline { background: var(--warn-bg); }
.banner.error { background: rgba(255,59,48,.14); color: var(--red); }
.banner b { display: block; color: var(--text); margin-bottom: 2px; }
[hidden] { display: none !important; }

.now { padding: 18px; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 4px; }
.art { --art: min(64vw, 240px, 32vh); position: relative; width: var(--art); aspect-ratio: 1; border-radius: 18px; overflow: hidden; margin-bottom: 12px;
  box-shadow: 0 0 0 1px rgba(255,255,255,.2), 0 12px 40px -10px var(--c1); display: grid; place-items: center; color: #fff; font-weight: 800;
  font-size: calc(var(--art) * .3); background: var(--accent); }
.art::before { content: ""; position: absolute; inset: 0; pointer-events: none;
  background: radial-gradient(circle at 28% 22%, rgba(255,255,255,.22), transparent 55%),
    repeating-radial-gradient(circle at 50% 130%, rgba(255,255,255,.07) 0 2px, transparent 2px 26px); }
.art img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.art .shade { position: absolute; inset: 0; background: rgba(0,0,0,.55); display: grid; place-items: center; }
.art .shade svg { width: 30%; height: 30%; }
.meta { display: flex; align-items: center; gap: 8px; font-size: .76rem; color: var(--muted); font-weight: 700; letter-spacing: .06em; text-transform: uppercase; }
.pill { font-size: .76rem; font-weight: 800; letter-spacing: .04em; padding: 2px 7px; border-radius: 99px; }
.pill.live { color: var(--green); background: color-mix(in srgb, var(--green) 16%, transparent); }
.pill.muted { color: var(--orange); background: var(--orange-bg); }
.pill.earlier { color: var(--blue); background: color-mix(in srgb, var(--blue) 16%, transparent); }
.pill.starting { color: var(--muted); background: var(--press); }
h1 { font-size: 1.294rem; margin: 2px 0 0; line-height: 1.2; overflow-wrap: anywhere; }
.sub { color: var(--muted); font-size: 0.941rem; overflow-wrap: anywhere; }

.transport { display: flex; flex-direction: column; align-items: center; gap: 10px; }
.play { width: 4.5rem; height: 4.5rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: var(--play-bg); color: var(--play-fg);
  box-shadow: 0 10px 34px -8px color-mix(in srgb, var(--c1) 70%, transparent); transition: transform .12s; }
.play:active { transform: scale(.94); }
.play svg { width: 38%; height: 38%; }
#iconPlay { transform: translateX(6%); }
.play[aria-busy="true"] { opacity: .7; }
.volume { width: 100%; display: flex; align-items: center; gap: 2px; }
.vbtn { width: 2.75rem; height: 2.75rem; flex: none; display: grid; place-items: center; border-radius: 50%; color: var(--muted); }
.vbtn:active { background: var(--press); }
.vbtn svg { width: 1.3rem; height: 1.3rem; }
input[type=range] { --fill: 50%; flex: 1; min-width: 0; height: 2.75rem; margin: 0; background: transparent; -webkit-appearance: none; appearance: none; }
input[type=range]::-webkit-slider-runnable-track { height: 6px; border-radius: 99px; background: linear-gradient(90deg, var(--text) var(--fill), var(--track-hi) var(--fill)); }
input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; width: 24px; height: 24px; margin-top: -9px; border-radius: 50%; background: #fff;
  border: 1px solid rgba(0,0,0,.15); box-shadow: 0 2px 8px rgba(0,0,0,.35); }
input[type=range]::-moz-range-track { height: 6px; border-radius: 99px; background: var(--track-hi); }
input[type=range]::-moz-range-progress { height: 6px; border-radius: 99px; background: var(--text); }
input[type=range]::-moz-range-thumb { width: 24px; height: 24px; border-radius: 50%; background: #fff; border: 1px solid rgba(0,0,0,.15); box-shadow: 0 2px 8px rgba(0,0,0,.35); }
.topbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.topbar .seg { flex: 1; }
.iconbtn { width: 2.75rem; height: 2.75rem; flex: none; display: grid; place-items: center; border-radius: 50%; background: var(--chip); color: var(--text); }
.iconbtn svg { width: 1.3rem; height: 1.3rem; }

.rows { overflow: hidden; }
.row { width: 100%; display: flex; align-items: center; gap: 12px; padding: 12px 14px; min-height: 3.75rem; text-align: left; }
.row + .row { border-top: 1px solid var(--line); }
.row:active { background: var(--press); }
.row .label { flex: 1; min-width: 0; }
.row .label small { display: block; color: var(--muted); font-size: 0.765rem; }
.row .label span { display: block; overflow-wrap: anywhere; font-weight: 600; }
.row .chev { width: 14px; height: 14px; color: var(--muted); flex: none; }
.badge { width: 2.25rem; height: 2.25rem; border-radius: 9px; flex: none; display: grid; place-items: center; color: #fff;
  font-weight: 800; font-size: 0.824rem; background: var(--accent); }
.icon { width: 2.25rem; height: 2.25rem; flex: none; display: grid; place-items: center; color: var(--muted); }
.icon svg { width: 24px; height: 24px; }

.news { overflow: hidden; }
.alert { display: flex; align-items: center; gap: 12px; padding: 12px 14px; background: var(--orange-bg); }
.alert .label { flex: 1; }
.alert .label small { display: block; color: var(--muted); font-size: 0.824rem; font-variant-numeric: tabular-nums; }
.alert b { font-weight: 700; }
.btn { background: var(--orange); color: var(--on-orange); font-weight: 700; padding: .65rem 1.1rem; min-height: 2.75rem; border-radius: 99px; font-size: 0.941rem; flex: none; }
.btn:active { opacity: .8; }
.secondary { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 4px 14px; min-height: 3.25rem; }
.link { color: var(--accent); font-weight: 600; padding: 10px 0; min-height: 2.75rem; }
.secondary small { color: var(--muted); font-size: 0.765rem; text-align: right; }
.plainrow { text-align: center; }
footer { text-align: center; color: var(--muted); font-size: 0.765rem; }

dialog { border: 0; padding: 0; margin: auto auto 0; width: 100%; max-width: 520px; max-height: 82vh; background: var(--bg); color: var(--text);
  border-radius: 18px 18px 0 0; display: flex; flex-direction: column; }
dialog:not([open]) { display: none; }
dialog::backdrop { background: rgba(0,0,0,.4); }
.sheet-head { display: flex; align-items: center; justify-content: space-between; padding: 16px 16px 8px; }
.sheet-head h2 { margin: 0; font-size: 1.176rem; }
.sheet-body { overflow-y: auto; padding: 0 16px max(20px, env(safe-area-inset-bottom)); -webkit-overflow-scrolling: touch; }
.group-title { color: var(--muted); font-size: 0.765rem; font-weight: 600; text-transform: uppercase; letter-spacing: .03em; margin: 16px 4px 6px; }
.check { width: 20px; height: 20px; color: var(--accent); flex: none; }
.hint { color: var(--muted); font-size: 0.824rem; margin: 12px 4px; }
.progress { width: 100%; margin-top: 12px; }
.bar { position: relative; height: 6px; border-radius: 99px; overflow: hidden; background: var(--track); }
.bar i { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 99px; }
.bar .analysed { background: var(--press); }
.bar .heard { background: linear-gradient(90deg, #0080ff, #8b00ff); min-width: 6px; }
.bar .cut { position: absolute; top: 0; bottom: 0; min-width: 2px; background: var(--pink); }
.progress-text { display: flex; justify-content: space-between; gap: 12px; margin-top: 6px; color: var(--muted); font-size: 0.765rem;
  font-variant-numeric: tabular-nums; }

.seg { display: grid; grid-template-columns: 1fr 1fr; gap: 2px; padding: 3px; border-radius: 999px; background: var(--chip); }
.seg button { min-height: 2.75rem; padding: 0 .9rem; border-radius: 999px; font-size: 0.882rem; font-weight: 600; color: var(--text); }
.seg button[aria-pressed="true"] { background: var(--seg-on); font-weight: 800; box-shadow: 0 1px 4px rgba(0,0,0,.14), inset 0 0 0 1px var(--glass-line); }

.earlier { overflow: hidden; }
.days { display: flex; align-items: center; justify-content: space-between; padding: 4px; border-bottom: 1px solid var(--line); }
.days b { font-size: 0.941rem; }
.step { width: 3.5rem; height: 3.5rem; display: grid; place-items: center; color: var(--accent); border-radius: 10px; }
.step:active { background: var(--press); }
.step:disabled { color: var(--muted); opacity: .4; }
.step svg { width: 18px; height: 18px; }
.prog { width: 100%; display: flex; align-items: center; gap: 12px; padding: 10px 14px; text-align: left; }
.prog + .prog { border-top: 1px solid var(--line); }
.prog:active:not(:disabled) { background: var(--press); }
.prog:disabled { cursor: default; }
.prog:disabled .thumb, .prog:disabled .label { opacity: .45; }
.thumb { position: relative; width: 3.25rem; height: 3.25rem; border-radius: 9px; overflow: hidden; flex: none; display: grid; place-items: center;
  color: #fff; font-weight: 800; font-size: 0.882rem; background: var(--accent); }
.thumb img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; opacity: 0; transition: opacity .25s; }
.thumb img.ready { opacity: 1; }
.prog .label { flex: 1; min-width: 0; }
.prog .when { display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 0.765rem; font-weight: 600; font-variant-numeric: tabular-nums; }
.prog .title { display: block; font-weight: 600; overflow-wrap: anywhere; }
.prog .detail { display: block; color: var(--muted); font-size: 0.824rem; overflow-wrap: anywhere; }
.prog .end { width: 22px; height: 22px; flex: none; color: var(--muted); }
.prog .end.on { color: var(--accent); }
.pill.now { color: var(--green); background: color-mix(in srgb, var(--green) 16%, transparent); font-size: .7rem; padding: 1px 6px; }
.empty { padding: 14px; color: var(--muted); font-size: 0.882rem; }
.empty .link { display: block; padding: 8px 0 0; }

.col { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.quick { display: none; }
.artwrap { display: contents; }
@media (min-width: 900px) { .phoneonly { display: none !important; } }
/* Phones: one player screen, like a music app. Live and Earlier at the top with Settings beside them, the artwork in whatever
   height is left, the title below it, play and volume low where a thumb rests, and station and speaker at the foot.
   Everything else is a scroll away. */
@media (max-width: 899px) {
  .col.player { display: flex; flex-direction: column; gap: 16px; min-height: 100vh;
    min-height: calc(100svh - max(16px, env(safe-area-inset-top)) - max(24px, env(safe-area-inset-bottom))); }
  .topbar .seg { flex: 0 1 14rem; }
  .now.card { flex: 1 1 auto; min-height: 0; background: none; border: 0; -webkit-backdrop-filter: none; backdrop-filter: none; padding: 0;
    align-items: stretch; text-align: left; gap: 4px; }
  .artwrap { display: grid; place-items: center; flex: 1 1 7rem; min-height: 6rem; container-type: size; }
  .art { --art: min(100cqw, 100cqh, 24rem); width: var(--art); margin: 0; border-radius: 16px; }
  .meta { justify-content: flex-start; margin-top: 14px; }
  h1 { font-size: 1.65rem; }
  .sub { font-size: 1.05rem; }
  .quick { display: flex; flex-wrap: wrap; gap: 10px; }
  .chip { flex: 1 1 9rem; min-width: 0; display: flex; align-items: center; gap: 10px; min-height: 3rem; padding: .35rem 1rem .35rem .4rem;
    border-radius: 999px; background: var(--chip); font-weight: 600; text-align: left; }
  .chip:active { background: var(--press); }
  .chip .badge { width: 2.25rem; height: 2.25rem; border-radius: 50%; font-size: .8rem; }
  .chip .icon { width: 2.25rem; height: 2.25rem; color: var(--text); }
  .chip .icon svg { width: 1.3rem; height: 1.3rem; }
  .chip .name { min-width: 0; line-height: 1.2; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
  .deskonly, .rows { display: none; }
}
@media (max-width: 899px) and (prefers-color-scheme: dark) {
  .aurora::after { content: ""; position: absolute; inset: 0; background: linear-gradient(rgba(5,7,20,.4), rgba(5,7,20,.62)); }
}
/* A plain background for anyone who finds the gradient hard to read: chosen at the foot of the page, or by the phone's own settings. */
:root[data-plain] .aurora { display: none; }
:root[data-plain] .card, :root[data-plain] .vbtn { background: var(--card-solid); -webkit-backdrop-filter: none; backdrop-filter: none; }
@media (prefers-contrast: more), (prefers-reduced-transparency: reduce) {
  .aurora { display: none; }
  .card, .vbtn { background: var(--card-solid); -webkit-backdrop-filter: none; backdrop-filter: none; }
}
@media (min-width: 900px) {
  main { max-width: 980px; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 14px 28px; align-items: start; }
  main > .banner, main > footer, main > .plainrow { grid-column: 1 / -1; }
  main > .col.player { position: sticky; top: 16px; }      /* the player stays in view beside a long list */
  dialog { margin: auto; border-radius: 18px; max-height: 80vh; }
}
.set { display: flex; align-items: center; gap: 12px; padding: 12px 14px; min-height: 52px; }
.set + .set { border-top: 1px solid var(--line); }
.set .label { flex: 1; min-width: 0; }
.set .label small { display: block; color: var(--muted); font-size: 0.765rem; }
.set.column { flex-direction: column; align-items: stretch; }
.set output { color: var(--muted); font-variant-numeric: tabular-nums; }
.set .seg { min-width: 180px; }
input.toggle { appearance: none; -webkit-appearance: none; width: 51px; height: 31px; margin: 0; border-radius: 99px; background: var(--track);
  position: relative; flex: none; cursor: pointer; transition: background .2s; }
input.toggle::after { content: ""; position: absolute; top: 2px; left: 2px; width: 27px; height: 27px; border-radius: 50%; background: #fff;
  box-shadow: 0 2px 4px rgba(0,0,0,.2); transition: transform .2s; }
input.toggle:checked { background: linear-gradient(90deg, #20b2aa, #0080ff); }
input.toggle:checked::after { transform: translateX(20px); }
select { font: inherit; color: inherit; background: var(--track); border: 0; border-radius: 8px; padding: 6px 10px; }
.qr { background: #fff; border-radius: 12px; padding: 10px; width: 180px; align-self: center; }
.qr svg { display: block; width: 100%; height: auto; }
.linkbox { font: .82rem ui-monospace, Menlo, monospace; width: 100%; color: var(--muted); background: var(--track); border: 0; border-radius: 8px;
  padding: 8px 10px; -webkit-user-select: text; user-select: text; }
.actions { display: flex; gap: 24px; justify-content: center; }
.link.danger { color: var(--red); }
.toast { position: fixed; left: 50%; top: max(16px, env(safe-area-inset-top)); transform: translateX(-50%); background: rgba(40,40,40,.94);
  color: #fff; padding: 10px 16px; border-radius: 12px; font-size: 0.882rem; max-width: calc(100% - 32px); text-align: center; z-index: 10;
  transition: opacity .25s; }
</style>
</head>
<body>
<div class="aurora" aria-hidden="true"><i></i><i></i><i></i></div>
<main>
  <div class="banner offline" id="offline" hidden role="status"><b>Can't reach InterLude</b><span id="offlineText">Check that the Mac is awake, InterLude is open, and this phone is on the same Wi-Fi.</span></div>
  <div class="banner offline" id="gone" hidden role="status"><b>This link has stopped working</b><span id="goneText">The remote was turned off or its link was reset. Open InterLude's Settings on the Mac and scan the code again.</span></div>
  <div class="banner error" id="error" hidden role="alert"></div>

  <div class="col player">
  <div class="topbar">
    <div class="seg" role="group" aria-label="Listen">
      <button id="modeLive" aria-pressed="true">Live</button>
      <button id="modeEarlier" aria-pressed="false">Earlier</button>
    </div>
    <button class="iconbtn phoneonly" id="gearBtn" aria-label="Settings" hidden><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M19.4 13a7.5 7.5 0 0 0 0-2l2.1-1.6-2-3.5-2.5 1a7.6 7.6 0 0 0-1.7-1L15 3h-4l-.4 2.7a7.6 7.6 0 0 0-1.7 1l-2.5-1-2 3.5L6.6 11a7.5 7.5 0 0 0 0 2l-2.1 1.6 2 3.5 2.5-1a7.6 7.6 0 0 0 1.7 1L11 21h4l.4-2.7a7.6 7.6 0 0 0 1.7-1l2.5 1 2-3.5L19.4 13zM13 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7z" transform="translate(-1 0)"/></svg></button>
  </div>

  <section class="card now" aria-live="polite">
    <div class="artwrap"><div class="art" id="art"><span id="artText">R</span><img id="artImg" alt="" hidden><div class="shade" id="artShade" hidden><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 9v6h4l5 5V4L7 9H3zm13.6 3 2.7-2.7-1.4-1.4-2.7 2.7-2.7-2.7-1.4 1.4 2.7 2.7-2.7 2.7 1.4 1.4 2.7-2.7 2.7 2.7 1.4-1.4z"/></svg></div></div></div>
    <div class="meta"><span class="pill" id="pill" hidden></span><span id="stationName"></span></div>
    <h1 id="headline">InterLude</h1>
    <div class="sub" id="subheadline">Connecting…</div>
    <div class="hint" id="startNote" hidden>Starting. The first start takes about 20 seconds while InterLude builds its delay.</div>
    <div class="progress" id="progress" hidden aria-label="Position in programme">
      <div class="bar" id="bar"><i class="analysed" id="analysed"></i><i class="heard" id="heard"></i></div>
      <div class="progress-text"><span id="position"></span><span id="skipped"></span></div>
    </div>
  </section>

  <section class="transport">
    <button class="play" id="play" aria-label="Play">
      <svg id="iconPlay" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>
      <svg id="iconStop" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" hidden><rect x="6" y="6" width="12" height="12" rx="2"/></svg>
    </button>
    <div class="volume">
      <button class="vbtn" id="volDown" aria-label="Quieter"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M5 9v6h4l5 5V4L9 9H5z"/></svg></button>
      <input type="range" id="volume" min="0" max="100" step="1" value="70" aria-label="Volume">
      <button class="vbtn" id="volUp" aria-label="Louder"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.47 4.47 0 0 0 16.5 12zM14 3.23v2.06a7 7 0 0 1 0 13.42v2.06A9 9 0 0 0 14 3.23z"/></svg></button>
    </div>
  </section>

  <div class="quick">
    <button class="chip" id="quickStation"><div class="badge" id="quickBadge">R</div><span class="name" id="quickStationLabel">…</span></button>
    <button class="chip" id="quickSpeaker"><span class="icon" id="quickIcon"></span><span class="name" id="quickSpeakerLabel">…</span></button>
  </div>
  </div>

  <div class="col">
  <section class="card rows">
    <button class="row deskonly" id="stationRow">
      <div class="badge" id="stationBadge">R</div>
      <div class="label"><small>Station</small><span id="stationLabel">…</span></div>
      <svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>
    </button>
    <button class="row deskonly" id="speakerRow">
      <div class="icon" id="speakerIcon"></div>
      <div class="label"><small id="speakerCaption">Play on</small><span id="speakerLabel">…</span></div>
      <svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>
    </button>
    <button class="row" id="settingsRow" hidden>
      <div class="icon"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M19.4 13a7.5 7.5 0 0 0 0-2l2.1-1.6-2-3.5-2.5 1a7.6 7.6 0 0 0-1.7-1L15 3h-4l-.4 2.7a7.6 7.6 0 0 0-1.7 1l-2.5-1-2 3.5L6.6 11a7.5 7.5 0 0 0 0 2l-2.1 1.6 2 3.5 2.5-1a7.6 7.6 0 0 0 1.7 1L11 21h4l.4-2.7a7.6 7.6 0 0 0 1.7-1l2.5 1 2-3.5L19.4 13zM13 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7z" transform="translate(-1 0)"/></svg></div>
      <div class="label"><span>Settings</span></div>
      <svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>
    </button>
  </section>

  <section class="card news" id="news" hidden>
    <div class="alert" id="alert" hidden>
      <div class="label"><b id="alertTitle"></b><small id="alertDetail"></small></div>
      <button class="btn" id="notNews" hidden>Not news</button>
    </div>
    <div class="secondary">
      <button class="link" id="gotThrough">News got through</button>
      <small id="note"></small>
    </div>
  </section>

  <section class="card earlier" id="earlier" hidden>
    <div class="days">
      <button class="step" id="dayBack" aria-label="Earlier day"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m15 5-7 7 7 7"/></svg></button>
      <b id="dayTitle" aria-live="polite">Today</b>
      <button class="step" id="dayNext" aria-label="Later day"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg></button>
    </div>
    <div id="programmes"></div>
  </section>
  </div>

  <footer id="footer"></footer>
  <div class="plainrow"><button class="link" id="plainBtn">Plain background</button></div>
</main>

<dialog id="stationSheet" aria-labelledby="stationSheetTitle">
  <div class="sheet-head"><h2 id="stationSheetTitle">Station</h2><button class="link" data-close>Done</button></div>
  <div class="sheet-body" id="stationList"></div>
</dialog>
<dialog id="speakerSheet" aria-labelledby="speakerSheetTitle">
  <div class="sheet-head"><h2 id="speakerSheetTitle">Play on</h2><button class="link" data-close>Done</button></div>
  <div class="sheet-body" id="speakerList"></div>
</dialog>
<dialog id="settingsSheet" aria-labelledby="settingsSheetTitle">
  <div class="sheet-head"><h2 id="settingsSheetTitle">Settings</h2><button class="link" data-close>Done</button></div>
  <div class="sheet-body" id="settingsList"></div>
</dialog>
<audio id="player" preload="none"></audio>
<div class="toast" id="toast" hidden role="status"></div>

<script>
"use strict";
const $ = id => document.getElementById(id);
const ICONS = {
  mac: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5V16H4V5.5zM6 6v8h12V6H6zM1 17h22v1a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2v-1z"/></svg>',
  speaker: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm5 2.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM12 10a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9zm0 2.2a2.3 2.3 0 1 1 0 4.6 2.3 2.3 0 0 1 0-4.6z"/></svg>',
  group: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 4h7a1.5 1.5 0 0 1 1.5 1.5v13A1.5 1.5 0 0 1 10 20H3a1.5 1.5 0 0 1-1.5-1.5v-13A1.5 1.5 0 0 1 3 4zm3.5 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM14 4h7a1.5 1.5 0 0 1 1.5 1.5v13A1.5 1.5 0 0 1 21 20h-7a1.5 1.5 0 0 1-1.5-1.5v-13A1.5 1.5 0 0 1 14 4zm3.5 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6z"/></svg>',
  browser: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M4 3h16a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zm0 5v11h16V8H4zm1.5-3.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2zm3 0a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/></svg>'
};
// On a server the page is the whole app, at /app/<token>/; on the Mac it is the phone remote.
const ON_SERVER = location.pathname.startsWith("/app/");
if (ON_SERVER) {
  $("offlineText").textContent = "Check that the server is running and this device is on your network or tailnet.";
  $("goneText").textContent = "The link was reset. Open the new one from Settings on a device that has it, or from the server's log.";
}
const CHECK = '<svg class="check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m5 12 5 5 9-10"/></svg>';
const PROG_ICONS = {
  play: '<svg class="end" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
  chosen: '<svg class="end on" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m5 12 5 5 9-10"/></svg>',
  playing: '<svg class="end on" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.47 4.47 0 0 0 16.5 12zM14 3.23v2.06a7 7 0 0 1 0 13.42v2.06A9 9 0 0 0 14 3.23z"/></svg>'
};
const PILLS = { live: "LIVE", muted: "MUTED", earlier: "EARLIER", starting: "STARTING" };

let state = null, shownEarlier = "", shownSettings = "", dayWanted = null, timer = null, failures = 0, volumeHeldUntil = 0, volumeTimer = null, toastTimer = null;

function clock(seconds) {
  const s = Math.max(0, Math.round(seconds));
  return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
}
function colourOf(c) { return /^#?[0-9a-f]{6}$/i.test(c || "") ? (c[0] === "#" ? c : "#" + c) : null; }
function gradient(colour) {
  const c = colourOf(colour);
  return c ? `linear-gradient(135deg, ${c}, color-mix(in srgb, ${c} 65%, black))` : "";
}
function paintBadge(el, station) {
  el.style.background = gradient(station && station.colour);
  el.textContent = station ? (station.short || station.name.slice(0, 1)) : "R";
}

async function request(path, post) {
  const r = await fetch("api/" + path, { method: post ? "POST" : "GET", cache: "no-store" });
  if (r.status === 404) { const e = new Error("gone"); e.gone = true; throw e; }
  if (!r.ok) throw new Error(String(r.status));
  return r.json();
}
function connected(ok, gone) {
  $("gone").hidden = !gone;
  $("offline").hidden = ok || gone;
}
async function refresh() {
  clearTimeout(timer);
  try {
    render(await request("state")); failures = 0; connected(true);
    // A server sends changes as they happen; the Mac is polled.
    if (state.stream && window.EventSource) { listen(); return; }
  }
  catch (e) { failures++; if (e.gone) connected(false, true); else if (failures >= 2) connected(false); }
  if (!document.hidden || here) timer = setTimeout(refresh, failures ? 3000 : 1500);
}
let source = null;
function listen() {
  if (source) return;
  source = new EventSource("api/events");
  source.onmessage = e => { failures = 0; connected(true); render(JSON.parse(e.data)); };
  // Polling notices a reset link or a server that has gone, then listens again.
  source.onerror = () => { source.close(); source = null; clearTimeout(timer); timer = setTimeout(refresh, 2000); };
}
function quiet() { if (source) { source.close(); source = null; } clearTimeout(timer); }
async function send(command, params) {
  const q = params ? "?" + new URLSearchParams(params) : "";
  try { render(await request(command + q, true)); failures = 0; connected(true); return true; }
  catch (e) { connected(false, !!e.gone); return false; }
}
// Keeps listening in the background while this browser plays, so the lock screen shows the song.
document.addEventListener("visibilitychange", () => { if (document.hidden) { if (!here) quiet(); } else refresh(); });
window.addEventListener("pageshow", refresh);

function toast(text, ms = 2600) {
  const t = $("toast");
  t.textContent = text; t.hidden = false; t.style.opacity = 1;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.style.opacity = 0; setTimeout(() => { t.hidden = true; }, 300); }, ms);
}

function render(s) {
  state = s;
  $("error").hidden = !s.error;
  $("error").textContent = s.error || "";

  const station = s.stations.find(x => x.id === s.station);
  const art = $("art");
  art.style.background = gradient(station && station.colour);
  $("artText").textContent = station ? (station.short || station.name.slice(0, 1)) : "R";
  const img = $("artImg");
  const src = s.artwork && s.artwork.startsWith("https://") ? s.artwork : null;
  if (src) { if (img.getAttribute("src") !== src) { img.hidden = true; img.onload = () => { img.hidden = false; }; img.src = src; } }
  else { img.hidden = true; img.removeAttribute("src"); }
  $("artShade").hidden = !s.muted;

  const pill = $("pill");
  pill.hidden = !PILLS[s.state];
  pill.className = "pill " + s.state;
  pill.textContent = PILLS[s.state] || "";
  // A line that repeats the one above is left out, so a station name isn't shown three times.
  $("headline").textContent = s.headline;
  $("stationName").textContent = s.stationName && s.stationName !== s.headline ? s.stationName : "";
  const showSub = !!s.subheadline && s.subheadline !== s.headline && s.subheadline !== s.stationName && !(!s.playing && s.subheadline === "Ready to play");
  $("subheadline").textContent = showSub ? s.subheadline : "";
  $("subheadline").hidden = !showSub;
  $("startNote").hidden = !(s.stream && s.state === "starting");
  document.documentElement.dataset.mood = s.state === "muted" ? "muted" : s.state === "earlier" ? "earlier" : "live";
  document.documentElement.dataset.playing = s.playing ? "1" : "0";
  document.title = s.playing ? s.headline + " · InterLude" : "InterLude";

  if (s.stream) followStream(s);
  // With a server playing in this browser, the button plays and stops this browser, and the server stops by itself
  // when nobody listens. With a speaker chosen, it starts and stops the server, as the Mac's remote does.
  const local = !!s.stream && s.speaker === "browser";
  const on = local ? here : s.playing;
  const play = $("play");
  play.setAttribute("aria-label", on ? "Stop" : "Play");
  play.setAttribute("aria-busy", s.state === "starting" && (!local || here) ? "true" : "false");
  // SVG elements have no hidden property, so set the attribute.
  $("iconPlay").toggleAttribute("hidden", on);
  $("iconStop").toggleAttribute("hidden", !on);

  if (local) $("volume").value = Math.round(player.volume * 100);
  else if (Date.now() > volumeHeldUntil) $("volume").value = Math.round(s.volume * 100);
  fillRange($("volume"));

  paintBadge($("stationBadge"), station); paintBadge($("quickBadge"), station);
  const tint = colourOf(station && station.colour);
  if (tint) document.documentElement.style.setProperty("--station", tint); else document.documentElement.style.removeProperty("--station");
  $("stationLabel").textContent = $("quickStationLabel").textContent = station ? station.name : "Choose a station";
  const speaker = s.speakers.find(x => x.id === s.speaker) || s.speakers[0];
  $("speakerIcon").innerHTML = $("quickIcon").innerHTML = ICONS[speaker ? speaker.kind : "mac"];
  $("speakerLabel").textContent = $("quickSpeakerLabel").textContent = speaker ? speaker.name : "This Mac";
  $("speakerCaption").textContent = on ? "Playing on" : "Play on";
  $("quickStation").setAttribute("aria-label", "Station: " + $("stationLabel").textContent);
  $("quickSpeaker").setAttribute("aria-label", (on ? "Playing on " : "Play on ") + $("speakerLabel").textContent);
  $("settingsRow").hidden = $("gearBtn").hidden = !s.settings;
  if (s.settings && $("settingsSheet").open) {
    const key = JSON.stringify(s.settings);
    // Not while the delay slider is held, which a rebuild would drop.
    if (key !== shownSettings && document.activeElement?.type !== "range") renderSettings();
  }
  updateMediaSession();

  $("news").hidden = !s.canCorrect;
  const alert = $("alert");
  if (s.justSkipped != null) {
    alert.hidden = false; $("notNews").hidden = true;
    $("alertTitle").textContent = "Skipped " + clock(s.justSkipped) + " of news"; $("alertDetail").textContent = "";
  } else if (s.muted) {
    alert.hidden = false; $("notNews").hidden = false;
    $("alertTitle").textContent = "Bulletin muted";
    $("alertDetail").textContent = s.muteElapsed != null ? clock(s.muteElapsed) + " so far" : "Sound returns when the music does";
  } else if (s.muteStartsIn != null) {
    alert.hidden = false; $("notNews").hidden = true;
    $("alertTitle").textContent = "Bulletin coming up";
    $("alertDetail").textContent = (s.state === "earlier" ? "Skipping" : "Muting") + " in " + clock(s.muteStartsIn);
  } else alert.hidden = true;
  $("note").textContent = s.note || "";
  $("footer").textContent = s.footer || "";

  const earlier = s.mode === "earlier";
  $("modeLive").setAttribute("aria-pressed", earlier ? "false" : "true");
  $("modeEarlier").setAttribute("aria-pressed", earlier ? "true" : "false");
  renderReplay(s.replay);
  $("earlier").hidden = !s.earlier;
  if (s.earlier) renderEarlier(s.earlier, station);

  if ($("speakerSheet").open) renderSpeakers();
}

function renderReplay(r) {
  $("progress").hidden = !r;
  if (!r) return;
  $("heard").style.width = (r.heard * 100) + "%";
  $("analysed").style.width = (r.analysed * 100) + "%";
  const bar = $("bar");
  for (const c of bar.querySelectorAll(".cut")) c.remove();
  for (const [a, b] of r.news) {
    const cut = document.createElement("span"); cut.className = "cut";
    cut.style.left = (a * 100) + "%"; cut.style.width = ((b - a) * 100) + "%";
    bar.append(cut);
  }
  $("position").textContent = r.position;
  $("skipped").textContent = r.skipped || "";
}

// The list is rebuilt only when it changes, so it doesn't flicker or lose a tap while the state refreshes.
function renderEarlier(e, station) {
  $("dayTitle").textContent = e.dayTitle;
  $("dayBack").disabled = e.day >= e.lastDay;
  $("dayNext").disabled = e.day <= 0;
  const key = JSON.stringify([e, station && station.id]);
  if (key === shownEarlier) return;
  shownEarlier = key;
  const list = $("programmes");
  list.replaceChildren();
  if (e.loading || e.problem || !e.programmes.length) {
    const p = document.createElement("div"); p.className = "empty";
    p.textContent = e.loading ? "Getting the schedule…" : (e.problem || "No programmes found");
    if (e.problem) {
      const again = document.createElement("button"); again.className = "link"; again.textContent = "Try again";
      again.addEventListener("click", () => send("schedule"));
      p.append(again);
    }
    list.append(p);
    return;
  }
  for (const pr of e.programmes) {
    const b = document.createElement("button");
    b.className = "prog";
    b.disabled = !pr.playable;
    b.setAttribute("aria-label", pr.title + ", " + pr.time + (pr.playable ? "" : ", not available") + (pr.playing ? ", playing" : ""));
    const thumb = document.createElement("div"); thumb.className = "thumb"; paintBadge(thumb, station);
    const src = pr.image && pr.image.startsWith("https://") ? pr.image : null;
    if (src) {
      // Faded in rather than hidden: a lazy image that is hidden never loads.
      const img = document.createElement("img"); img.alt = ""; img.loading = "lazy";
      img.onload = () => { img.classList.add("ready"); };
      img.src = src; thumb.append(img);
    }
    const l = document.createElement("div"); l.className = "label";
    const when = document.createElement("span"); when.className = "when"; when.textContent = pr.time;
    if (pr.onNow) { const n = document.createElement("span"); n.className = "pill now"; n.textContent = "ON NOW"; when.append(n); }
    const t = document.createElement("span"); t.className = "title"; t.textContent = pr.title;
    const d = document.createElement("span"); d.className = "detail"; d.textContent = pr.playing ? "Playing now" : pr.detail;
    l.append(when, t, d);
    b.append(thumb, l);
    if (pr.playable) b.insertAdjacentHTML("beforeend", PROG_ICONS[pr.playing ? "playing" : pr.chosen ? "chosen" : "play"]);
    b.addEventListener("click", async () => {
      window.scrollTo({ top: 0, behavior: "smooth" });
      if (playsHere() && !here) playHere();
      await send("programme", { id: pr.id });
    });
    list.append(b);
  }
}

function option(label, detail, selected, lead, onPick) {
  const b = document.createElement("button");
  b.className = "row card";
  b.style.marginBottom = "8px";
  b.setAttribute("aria-pressed", selected ? "true" : "false");
  b.append(lead);
  const l = document.createElement("div"); l.className = "label";
  const name = document.createElement("span"); name.textContent = label; l.append(name);
  if (detail) { const d = document.createElement("small"); d.textContent = detail; l.append(d); }
  b.append(l);
  if (selected) b.insertAdjacentHTML("beforeend", CHECK);
  b.addEventListener("click", onPick);
  return b;
}
function title(text) { const h = document.createElement("div"); h.className = "group-title"; h.textContent = text; return h; }

function renderStations() {
  const list = $("stationList");
  list.replaceChildren();
  const groups = [];
  const fav = state.stations.filter(x => x.favourite);
  if (fav.length) groups.push(["Favourites", fav]);
  for (const st of state.stations.filter(x => !x.favourite)) {
    const name = st.group || "Stations";
    let g = groups.find(x => x[0] === name && x[1] !== fav);
    if (!g) { g = [name, []]; groups.push(g); }
    g[1].push(st);
  }
  for (const [name, items] of groups) {
    list.append(title(name));
    for (const st of items) {
      const badge = document.createElement("div"); badge.className = "badge"; paintBadge(badge, st);
      list.append(option(st.name, null, st.id === state.station, badge, async () => {
        $("stationSheet").close();
        if (playsHere() && state.mode !== "earlier" && !here) playHere();
        // In Earlier a station shows its programmes; in Live it plays.
        if (st.id !== state.station || (!state.playing && state.mode !== "earlier")) await send("station", { id: st.id });
      }));
    }
  }
}
function renderSpeakers() {
  const list = $("speakerList");
  list.replaceChildren();
  for (const sp of state.speakers) {
    const icon = document.createElement("div"); icon.className = "icon"; icon.innerHTML = ICONS[sp.kind] || ICONS.speaker;
    list.append(option(sp.name, sp.detail, sp.id === state.speaker, icon, async () => {
      $("speakerSheet").close();
      if (sp.id !== state.speaker) await send("speaker", { id: sp.id });
    }));
  }
  if (state.speakerNote) { const p = document.createElement("p"); p.className = "hint"; p.textContent = state.speakerNote; list.append(p); }
}

$("play").addEventListener("click", async () => {
  if (playsHere()) {
    if (here) { stopHere(); render(state); return; }
    playHere(); render(state);
    await send("play");
    return;
  }
  $("play").setAttribute("aria-busy", "true");
  await send("toggle");
});
// Space plays and stops, as on the Mac, unless it would press a focused control or a sheet is open.
document.addEventListener("keydown", e => {
  if (e.code !== "Space" || e.repeat || e.metaKey || e.ctrlKey || e.altKey) return;
  if (document.querySelector("dialog[open]") || e.target.closest("button, input, select, textarea, a, summary")) return;
  e.preventDefault(); $("play").click();
});
// The filled part of a slider's track follows its value.
function fillRange(el) { el.style.setProperty("--fill", ((el.value - el.min) / (el.max - el.min) * 100) + "%"); }
document.addEventListener("input", e => { if (e.target.type === "range") fillRange(e.target); });
// Large buttons beside the slider, for anyone who finds dragging hard.
for (const [id, step] of [["volDown", -5], ["volUp", 5]]) {
  $(id).addEventListener("click", () => {
    const v = $("volume");
    v.value = Math.min(100, Math.max(0, Number(v.value) + step));
    v.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
$("volume").addEventListener("input", e => {
  if (playsHere()) {
    player.volume = e.target.value / 100;
    try { localStorage.setItem("volume", String(player.volume)); } catch {}
    return;
  }
  volumeHeldUntil = Date.now() + 2000;
  clearTimeout(volumeTimer);
  volumeTimer = setTimeout(() => send("volume", { v: (e.target.value / 100).toFixed(2) }), 150);
});
for (const id of ["stationRow", "quickStation"]) $(id).addEventListener("click", () => { if (!state) return; renderStations(); $("stationSheet").showModal(); });
for (const id of ["speakerRow", "quickSpeaker"]) $(id).addEventListener("click", () => { if (!state) return; renderSpeakers(); $("speakerSheet").showModal(); });
for (const id of ["settingsRow", "gearBtn"]) $(id).addEventListener("click", () => { if (!state || !state.settings) return; renderSettings(); $("settingsSheet").showModal(); });
for (const d of document.querySelectorAll("dialog")) {
  d.addEventListener("click", e => { if (e.target === d || e.target.hasAttribute("data-close")) d.close(); });
}
$("modeLive").addEventListener("click", () => { if (state && state.mode !== "live") send("mode", { m: "live" }); });
$("modeEarlier").addEventListener("click", () => { if (state && state.mode !== "earlier") send("mode", { m: "earlier" }); });
// Counts from the day last asked for, so quick taps each move a day before the Mac has answered.
async function stepDay(by) {
  if (!state || !state.earlier) return;
  const d = Math.min(Math.max((dayWanted ?? state.earlier.day) + by, 0), state.earlier.lastDay);
  dayWanted = d;
  await send("day", { d });
  if (dayWanted === d) dayWanted = null;
}
$("dayBack").addEventListener("click", () => stepDay(1));
$("dayNext").addEventListener("click", () => stepDay(-1));
$("notNews").addEventListener("click", async () => {
  if (await send("notnews")) toast("Sound comes back in a few seconds.");
});
$("gotThrough").addEventListener("click", async () => {
  if (await send("gotthrough")) toast("Thanks. InterLude will learn from that bulletin.");
});

// Playing in this browser, when a server offers its stream. Safari plays HLS itself; other browsers use hls.js,
// served by the server and loaded only when needed.
const player = $("player");
let hls = null, here = false, hereStream = null, hereSince = 0, hlsLoading = null, mediaKey = "", switchingUntil = 0;
try { const v = parseFloat(localStorage.getItem("volume")); if (v >= 0 && v <= 1) player.volume = v; } catch {}
// Whether this browser is where the sound plays: a server's stream with no speaker chosen.
function playsHere() { return !!(state && state.stream && state.speaker === "browser"); }
function nativeHLS() { return player.canPlayType("application/vnd.apple.mpegurl") !== ""; }
function loadHls() {
  if (window.Hls || nativeHLS()) return;
  if (!hlsLoading) {
    hlsLoading = true;
    const sc = document.createElement("script"); sc.src = "/static/hls.min.js"; document.head.append(sc);
  }
}
function attach() {
  switchingUntil = Date.now() + 2000;     // swapping streams pauses the element; that isn't the listener stopping
  if (hls) { hls.destroy(); hls = null; }
  if (nativeHLS()) player.src = state.stream;
  else if (window.Hls && Hls.isSupported()) {
    // The first request starts the session, which takes 20 s or so to fill its delay.
    hls = new Hls({ manifestLoadingTimeOut: 60000, manifestLoadingMaxRetry: 4, levelLoadingTimeOut: 60000 });
    hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal && here) { toast("Playback stopped. Check your connection, then press play to try again.", 8000); stopHere(); render(state); } });
    hls.loadSource(state.stream); hls.attachMedia(player);
  } else { toast("This browser can't play the stream."); return false; }
  hereStream = state.streamID;
  return true;
}
// Called straight from a tap, so the browser lets the sound start.
function playHere() {
  here = true; hereSince = Date.now();
  if (!attach()) { here = false; return; }
  player.play().catch(e => { if (here && e.name !== "AbortError") toast(e.message); });
}
function stopHere() {
  here = false; hereStream = null;
  player.pause();
  if (hls) { hls.destroy(); hls = null; }
  player.removeAttribute("src"); player.load();
}
// Keeps this browser on the server's current session: a new session (another station or programme) means loading
// the stream again, and a session that has stopped means stopping here too.
function followStream(s) {
  loadHls();
  if (!here) return;
  if (s.speaker !== "browser") { stopHere(); return; }     // a speaker took over
  if (!s.playing && Date.now() - hereSince > 4000) { stopHere(); return; }
  if (s.streamID == null) return;
  if (hereStream == null) { hereStream = s.streamID; return; }
  if (s.streamID !== hereStream) { attach(); player.play().catch(() => {}); }
}
// Paused from outside the page, such as by the system or a headphone button: stop here.
player.addEventListener("pause", () => { if (here && Date.now() > switchingUntil) { stopHere(); if (state) render(state); } });

// The lock screen and headphone controls.
function updateMediaSession() {
  if (!("mediaSession" in navigator) || !state || !state.stream) return;
  // The lock screen follows this browser's own playing; a speaker has its own controls.
  const ms = navigator.mediaSession;
  if (!here) { ms.playbackState = "none"; return; }
  const art = state.artwork && state.artwork.startsWith("https://") ? state.artwork : new URL("icon.png", document.baseURI).href;
  const key = [state.headline, state.subheadline, state.stationName, art].join("|");
  if (key !== mediaKey && window.MediaMetadata) {
    mediaKey = key;
    ms.metadata = new MediaMetadata({ title: state.headline, artist: state.subheadline || state.stationName, album: "InterLude",
                                      artwork: [{ src: art, sizes: "512x512" }] });
  }
  ms.playbackState = "playing";
}
if ("mediaSession" in navigator) {
  const set = (a, f) => { try { navigator.mediaSession.setActionHandler(a, f); } catch {} };
  set("play", () => { if (!here && state && state.stream) { playHere(); send("play"); } });
  set("pause", () => { stopHere(); if (state) render(state); });
  set("stop", () => { stopHere(); if (state) render(state); });
}

// A server's Settings.
function settingRow(label, detail, control) {
  const r = document.createElement("div"); r.className = "set";
  const l = document.createElement("div"); l.className = "label";
  const n = document.createElement("span"); n.textContent = label; l.append(n);
  if (detail) { const d = document.createElement("small"); d.textContent = detail; l.append(d); }
  r.append(l);
  if (control) r.append(control);
  return r;
}
function toggle(checked, key) {
  const t = document.createElement("input"); t.type = "checkbox"; t.className = "toggle"; t.checked = checked;
  t.setAttribute("role", "switch");
  t.addEventListener("change", () => change(key, t.checked ? "1" : "0"));
  return t;
}
// Sends a setting; if it doesn't take, shows the server's settings again rather than what was tapped.
async function change(k, v) {
  if (!await send("setting", v == null ? { k } : { k, v }) && state.settings) renderSettings();
}
function card(...rows) { const c = document.createElement("div"); c.className = "card"; c.append(...rows); return c; }
function hint(text) { const p = document.createElement("p"); p.className = "hint"; p.textContent = text; return p; }
function appLink() { return new URL(state.settings.link, location.origin).href; }

function renderSettings() {
  const st = state.settings, list = $("settingsList");
  shownSettings = JSON.stringify(st);
  list.replaceChildren();

  list.append(title("Playback"));
  const delay = document.createElement("div"); delay.className = "set column";
  const head = settingRow("Delay behind live", null, document.createElement("output"));
  head.style.padding = "0"; head.style.minHeight = "0";
  const out = head.querySelector("output"); out.textContent = st.delay + " s";
  const range = document.createElement("input"); range.type = "range"; range.min = 30; range.max = 600; range.step = 5; range.value = st.delay;
  range.setAttribute("aria-label", "Delay behind live"); fillRange(range);
  range.addEventListener("input", () => { out.textContent = range.value + " s"; });
  range.addEventListener("change", () => change("delay", range.value));
  delay.append(head, range);
  const rate = document.createElement("div"); rate.className = "seg";
  for (const kbps of [128, 320]) {
    const b = document.createElement("button"); b.textContent = kbps + " kbps"; b.setAttribute("aria-pressed", st.bitrate === kbps ? "true" : "false");
    b.addEventListener("click", () => { if (st.bitrate !== kbps) change("bitrate", String(kbps)); });
    rate.append(b);
  }
  list.append(card(delay, settingRow("Bitrate", null, rate)));
  list.append(hint("A longer delay gives InterLude more time to recognise a bulletin before you hear it. Changing the delay or bitrate starts the stream again."));

  list.append(title("News detection for " + st.stationName));
  if (st.newsNote) list.append(hint(st.newsNote));
  const jingle = settingRow("News jingle", st.jingle, null);
  if (st.canForgetJingle) {
    const f = document.createElement("button"); f.className = "link"; f.textContent = "Forget";
    f.addEventListener("click", () => change("forgetJingle"));
    jingle.append(f);
  }
  list.append(card(
    settingRow("Mute news bulletins", null, toggle(st.muteNews, "muteNews")),
    settingRow("Mute only when the news jingle plays", null, toggle(st.jingleOnly, "jingleOnly")),
    settingRow("Shadow mode", "Note bulletins, never mute", toggle(st.shadowMode, "shadowMode")),
    jingle));

  list.append(title("Sound"));
  const pick = document.createElement("select"); pick.setAttribute("aria-label", "During bulletins");
  for (const [id, name] of st.ambienceChoices) {
    const o = document.createElement("option"); o.value = id; o.textContent = name; o.selected = id === st.ambience; pick.append(o);
  }
  pick.addEventListener("change", () => change("ambience", pick.value));
  list.append(card(settingRow("During bulletins", null, pick)));

  list.append(title("Open on another device"));
  const share = document.createElement("div"); share.className = "set column";
  const qr = document.createElement("div"); qr.className = "qr"; qr.setAttribute("aria-hidden", "true");
  const box = document.createElement("input"); box.className = "linkbox"; box.readOnly = true; box.value = appLink();
  box.setAttribute("aria-label", "Link to InterLude");
  const actions = document.createElement("div"); actions.className = "actions";
  const copy = document.createElement("button"); copy.className = "link"; copy.textContent = "Copy link";
  copy.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(box.value); }
    catch { box.select(); document.execCommand("copy"); }
    toast("Link copied.");
  });
  const reset = document.createElement("button"); reset.className = "link danger"; reset.textContent = "Reset link";
  // Asks again in the page rather than in the browser's dialog: the first press arms the button for a few seconds.
  let armed = null;
  reset.addEventListener("click", async () => {
    if (!armed) {
      reset.textContent = "Confirm reset";
      toast("Pages and Home Screen icons with the old link will stop working. Press again to confirm.", 5000);
      armed = setTimeout(() => { armed = null; reset.textContent = "Reset link"; }, 5000);
      return;
    }
    clearTimeout(armed); armed = null;
    if (await send("resetlink")) location.replace(state.settings.link);
  });
  actions.append(copy, reset);
  share.append(qr, box, actions);
  list.append(card(share));
  list.append(hint("Scan the code with a phone's camera to open InterLude there; on iPhone, Share › Add to Home Screen keeps it as an app. Anyone on your network or tailnet with the link can control InterLude."));
  drawQR(qr, box.value);
}
function drawQR(el, text) {
  const draw = () => { const q = qrcode(0, "M"); q.addData(text); q.make(); el.innerHTML = q.createSvgTag({ cellSize: 4, margin: 2, scalable: true }); };
  if (window.qrcode) return draw();
  const sc = document.createElement("script"); sc.src = "/static/qrcode.js"; sc.onload = draw;
  sc.onerror = () => { el.removeAttribute("aria-hidden"); el.style.cssText = "background:none;color:var(--muted);font-size:14px;width:auto;text-align:center"; el.textContent = "The QR code didn't load. Use the link below instead."; };
  document.head.append(sc);
}

// A plain background, remembered on this device. The phone's Increase Contrast setting applies it too.
function setPlain(on) {
  document.documentElement.toggleAttribute("data-plain", on);
  $("plainBtn").textContent = on ? "Colourful background" : "Plain background";
  try { localStorage.setItem("plain", on ? "1" : "0"); } catch {}
}
try { setPlain(localStorage.getItem("plain") === "1"); } catch { setPlain(false); }
$("plainBtn").addEventListener("click", () => setPlain(!document.documentElement.hasAttribute("data-plain")));

refresh();
</script>
</body>
</html>
"""#
}
