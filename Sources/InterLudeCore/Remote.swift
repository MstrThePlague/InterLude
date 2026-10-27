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
    public static func page(token: String, touchIcon: Data = Data(), prefix: String = prefix) -> HTTPResponse {
        let icon = touchIcon.isEmpty ? "icon.png" : "data:image/png;base64,\(touchIcon.base64EncodedString())"
        let html = RemotePage.html.replacingOccurrences(of: "__BASE__", with: pagePath(token: token, prefix: prefix))
            .replacingOccurrences(of: "__TOUCH_ICON__", with: icon)
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(html.utf8), noCache: true)
    }

    public static let manifest = HTTPResponse(contentType: "application/manifest+json", body: Data("""
        {"name":"InterLude","short_name":"InterLude","start_url":"./","scope":"./","display":"standalone",
        "background_color":"#000000","theme_color":"#000000",
        "icons":[{"src":"icon.png","sizes":"512x512","type":"image/png"}]}
        """.utf8))
}

/// The remote's single page. Plain HTML, CSS and script with nothing loaded from elsewhere, apart from album art from
/// the BBC. Every value from the Mac is set as text, never as markup.
enum RemotePage {
    static let html = #"""
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
<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" sizes="180x180" href="__TOUCH_ICON__">
<link rel="icon" href="icon.png">
<title>InterLude</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #f2f2f7; --card: #ffffff; --text: #1c1c1e; --muted: #6e6e73; --line: rgba(60,60,67,.14);
  --accent: #007aff; --green: #248a3d; --orange: #c93400; --orange-bg: rgba(255,149,0,.16); --blue: #0064d1; --red: #d70015;
  --press: rgba(0,0,0,.06); --track: rgba(118,118,128,.12); --seg-on: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #000000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --line: rgba(84,84,88,.6);
    --accent: #0a84ff; --green: #30d158; --orange: #ff9f0a; --orange-bg: rgba(255,159,10,.18); --blue: #409cff; --red: #ff6961;
    --press: rgba(255,255,255,.08); --track: rgba(118,118,128,.24); --seg-on: #636366;
  }
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; background: var(--bg); color: var(--text); }
body {
  font: 17px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif;
  padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(24px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
  -webkit-user-select: none; user-select: none;
}
main { max-width: 480px; margin: 0 auto; display: flex; flex-direction: column; gap: 14px; }
button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; }
.card { background: var(--card); border-radius: 16px; }
.banner { padding: 12px 14px; border-radius: 12px; font-size: 15px; }
.banner.offline { background: var(--orange-bg); }
.banner.error { background: rgba(255,59,48,.14); color: var(--red); }
.banner b { display: block; color: var(--text); margin-bottom: 2px; }
[hidden] { display: none !important; }

.now { padding: 18px; display: flex; flex-direction: column; align-items: center; text-align: center; gap: 4px; }
.art { position: relative; width: min(64vw, 240px); aspect-ratio: 1; border-radius: 18px; overflow: hidden; margin-bottom: 12px;
  box-shadow: 0 8px 24px rgba(0,0,0,.18); display: grid; place-items: center; color: #fff; font-weight: 800;
  font-size: min(24vw, 90px); background: var(--accent); }
.art img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.art .shade { position: absolute; inset: 0; background: rgba(0,0,0,.55); display: grid; place-items: center; }
.art .shade svg { width: 30%; height: 30%; }
.meta { display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--muted); font-weight: 600; }
.pill { font-size: 11px; font-weight: 800; letter-spacing: .04em; padding: 2px 7px; border-radius: 99px; }
.pill.live { color: var(--green); background: color-mix(in srgb, var(--green) 16%, transparent); }
.pill.muted { color: var(--orange); background: var(--orange-bg); }
.pill.earlier { color: var(--blue); background: color-mix(in srgb, var(--blue) 16%, transparent); }
.pill.starting { color: var(--muted); background: var(--press); }
h1 { font-size: 22px; margin: 2px 0 0; line-height: 1.2; overflow-wrap: anywhere; }
.sub { color: var(--muted); font-size: 16px; overflow-wrap: anywhere; }

.transport { display: flex; flex-direction: column; align-items: center; gap: 18px; padding: 6px 0 2px; }
.play { width: 84px; height: 84px; border-radius: 50%; background: var(--accent); color: #fff; display: grid; place-items: center;
  box-shadow: 0 6px 18px color-mix(in srgb, var(--accent) 40%, transparent); transition: transform .12s; }
.play:active { transform: scale(.94); }
.play svg { width: 34px; height: 34px; }
.play[aria-busy="true"] { opacity: .7; }
.volume { width: 100%; display: flex; align-items: center; gap: 12px; color: var(--muted); }
.volume svg { width: 22px; height: 22px; flex: none; }
input[type=range] { flex: 1; min-width: 0; height: 32px; accent-color: var(--accent); }

.rows { overflow: hidden; }
.row { width: 100%; display: flex; align-items: center; gap: 12px; padding: 12px 14px; min-height: 60px; text-align: left; }
.row + .row { border-top: 1px solid var(--line); }
.row:active { background: var(--press); }
.row .label { flex: 1; min-width: 0; }
.row .label small { display: block; color: var(--muted); font-size: 13px; }
.row .label span { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-weight: 600; }
.row .chev { width: 14px; height: 14px; color: var(--muted); flex: none; }
.badge { width: 36px; height: 36px; border-radius: 9px; flex: none; display: grid; place-items: center; color: #fff;
  font-weight: 800; font-size: 14px; background: var(--accent); }
.icon { width: 36px; height: 36px; flex: none; display: grid; place-items: center; color: var(--muted); }
.icon svg { width: 24px; height: 24px; }

.news { overflow: hidden; }
.alert { display: flex; align-items: center; gap: 12px; padding: 12px 14px; background: var(--orange-bg); }
.alert .label { flex: 1; }
.alert .label small { display: block; color: var(--muted); font-size: 14px; font-variant-numeric: tabular-nums; }
.alert b { font-weight: 700; }
.btn { background: var(--orange); color: #fff; font-weight: 700; padding: 10px 16px; border-radius: 99px; font-size: 16px; flex: none; }
.btn:active { opacity: .8; }
.secondary { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 4px 14px; min-height: 52px; }
.link { color: var(--accent); font-weight: 600; padding: 10px 0; }
.secondary small { color: var(--muted); font-size: 13px; text-align: right; }
footer { text-align: center; color: var(--muted); font-size: 13px; }

dialog { border: 0; padding: 0; margin: auto auto 0; width: 100%; max-width: 520px; max-height: 82vh; background: var(--bg); color: var(--text);
  border-radius: 18px 18px 0 0; display: flex; flex-direction: column; }
dialog:not([open]) { display: none; }
dialog::backdrop { background: rgba(0,0,0,.4); }
.sheet-head { display: flex; align-items: center; justify-content: space-between; padding: 16px 16px 8px; }
.sheet-head h2 { margin: 0; font-size: 20px; }
.sheet-body { overflow-y: auto; padding: 0 16px max(20px, env(safe-area-inset-bottom)); -webkit-overflow-scrolling: touch; }
.group-title { color: var(--muted); font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .03em; margin: 16px 4px 6px; }
.check { width: 20px; height: 20px; color: var(--accent); flex: none; }
.hint { color: var(--muted); font-size: 14px; margin: 12px 4px; }
.progress { width: 100%; margin-top: 12px; }
.bar { position: relative; height: 6px; border-radius: 99px; overflow: hidden; background: var(--track); }
.bar i { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 99px; }
.bar .analysed { background: var(--press); }
.bar .heard { background: var(--accent); min-width: 6px; }
.bar .cut { position: absolute; top: 0; bottom: 0; min-width: 2px; background: var(--orange); }
.progress-text { display: flex; justify-content: space-between; gap: 12px; margin-top: 6px; color: var(--muted); font-size: 13px;
  font-variant-numeric: tabular-nums; }

.seg { display: grid; grid-template-columns: 1fr 1fr; gap: 2px; padding: 2px; border-radius: 10px; background: var(--track); }
.seg button { padding: 7px 0; border-radius: 8px; font-size: 15px; font-weight: 600; color: var(--text); }
.seg button[aria-pressed="true"] { background: var(--seg-on); box-shadow: 0 1px 4px rgba(0,0,0,.14); }

.earlier { overflow: hidden; }
.days { display: flex; align-items: center; justify-content: space-between; padding: 4px; border-bottom: 1px solid var(--line); }
.days b { font-size: 16px; }
.step { width: 48px; height: 44px; display: grid; place-items: center; color: var(--accent); border-radius: 10px; }
.step:active { background: var(--press); }
.step:disabled { color: var(--muted); opacity: .4; }
.step svg { width: 18px; height: 18px; }
.prog { width: 100%; display: flex; align-items: center; gap: 12px; padding: 10px 14px; text-align: left; }
.prog + .prog { border-top: 1px solid var(--line); }
.prog:active:not(:disabled) { background: var(--press); }
.prog:disabled { cursor: default; }
.prog:disabled .thumb, .prog:disabled .label { opacity: .45; }
.thumb { position: relative; width: 52px; height: 52px; border-radius: 9px; overflow: hidden; flex: none; display: grid; place-items: center;
  color: #fff; font-weight: 800; font-size: 15px; background: var(--accent); }
.thumb img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; opacity: 0; transition: opacity .25s; }
.thumb img.ready { opacity: 1; }
.prog .label { flex: 1; min-width: 0; }
.prog .when { display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 13px; font-weight: 600; font-variant-numeric: tabular-nums; }
.prog .title { display: block; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.prog .detail { display: block; color: var(--muted); font-size: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.prog .end { width: 22px; height: 22px; flex: none; color: var(--muted); }
.prog .end.on { color: var(--accent); }
.pill.now { color: var(--green); background: color-mix(in srgb, var(--green) 16%, transparent); font-size: 10px; padding: 1px 6px; }
.empty { padding: 14px; color: var(--muted); font-size: 15px; }
.empty .link { display: block; padding: 8px 0 0; }

.col { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
@media (min-width: 900px) {
  main { max-width: 980px; display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 14px 28px; align-items: start; }
  main > .banner, main > footer { grid-column: 1 / -1; }
  main > .col:first-of-type { position: sticky; top: 16px; }      /* the player stays in view beside a long list */
  dialog { margin: auto; border-radius: 18px; max-height: 80vh; }
}
.set { display: flex; align-items: center; gap: 12px; padding: 12px 14px; min-height: 52px; }
.set + .set { border-top: 1px solid var(--line); }
.set .label { flex: 1; min-width: 0; }
.set .label small { display: block; color: var(--muted); font-size: 13px; }
.set.column { flex-direction: column; align-items: stretch; }
.set output { color: var(--muted); font-variant-numeric: tabular-nums; }
.set .seg { min-width: 180px; }
input.toggle { appearance: none; -webkit-appearance: none; width: 51px; height: 31px; margin: 0; border-radius: 99px; background: var(--track);
  position: relative; flex: none; cursor: pointer; transition: background .2s; }
input.toggle::after { content: ""; position: absolute; top: 2px; left: 2px; width: 27px; height: 27px; border-radius: 50%; background: #fff;
  box-shadow: 0 2px 4px rgba(0,0,0,.2); transition: transform .2s; }
input.toggle:checked { background: var(--green); }
input.toggle:checked::after { transform: translateX(20px); }
select { font: inherit; color: inherit; background: var(--track); border: 0; border-radius: 8px; padding: 6px 10px; }
.qr { background: #fff; border-radius: 12px; padding: 10px; width: 180px; align-self: center; }
.qr svg { display: block; width: 100%; height: auto; }
.linkbox { font: 14px ui-monospace, Menlo, monospace; width: 100%; color: var(--muted); background: var(--track); border: 0; border-radius: 8px;
  padding: 8px 10px; -webkit-user-select: text; user-select: text; }
.actions { display: flex; gap: 24px; justify-content: center; }
.link.danger { color: var(--red); }
.toast { position: fixed; left: 50%; bottom: max(24px, env(safe-area-inset-bottom)); transform: translateX(-50%); background: rgba(40,40,40,.94);
  color: #fff; padding: 10px 16px; border-radius: 12px; font-size: 15px; max-width: calc(100% - 32px); text-align: center; z-index: 10;
  transition: opacity .25s; }
</style>
</head>
<body>
<main>
  <div class="banner offline" id="offline" hidden role="status"><b>Can't reach InterLude</b><span id="offlineText">Check that the Mac is awake, InterLude is open, and this phone is on the same Wi-Fi.</span></div>
  <div class="banner offline" id="gone" hidden role="status"><b>This link has stopped working</b><span id="goneText">The remote was turned off or its link was reset. Open InterLude's Settings on the Mac and scan the code again.</span></div>
  <div class="banner error" id="error" hidden role="alert"></div>

  <div class="col">
  <section class="card now" aria-live="polite">
    <div class="art" id="art"><span id="artText">R</span><img id="artImg" alt="" hidden><div class="shade" id="artShade" hidden><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 9v6h4l5 5V4L7 9H3zm13.6 3 2.7-2.7-1.4-1.4-2.7 2.7-2.7-2.7-1.4 1.4 2.7 2.7-2.7 2.7 1.4 1.4 2.7-2.7 2.7 2.7 1.4-1.4z"/></svg></div></div>
    <div class="meta"><span class="pill" id="pill" hidden></span><span id="stationName"></span></div>
    <h1 id="headline">InterLude</h1>
    <div class="sub" id="subheadline">Connecting…</div>
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
    <label class="volume">
      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M5 9v6h4l5 5V4L9 9H5z"/></svg>
      <input type="range" id="volume" min="0" max="100" step="1" value="70" aria-label="Volume">
      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.47 4.47 0 0 0 16.5 12zM14 3.23v2.06a7 7 0 0 1 0 13.42v2.06A9 9 0 0 0 14 3.23z"/></svg>
    </label>
  </section>

  <div class="seg" role="group" aria-label="Listen">
    <button id="modeLive" aria-pressed="true">Live</button>
    <button id="modeEarlier" aria-pressed="false">Earlier</button>
  </div>
  </div>

  <div class="col">
  <section class="card rows">
    <button class="row" id="stationRow">
      <div class="badge" id="stationBadge">R</div>
      <div class="label"><small>Station</small><span id="stationLabel">…</span></div>
      <svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>
    </button>
    <button class="row" id="speakerRow">
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

function toast(text) {
  const t = $("toast");
  t.textContent = text; t.hidden = false; t.style.opacity = 1;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.style.opacity = 0; setTimeout(() => { t.hidden = true; }, 300); }, 2600);
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
  $("stationName").textContent = s.stationName;
  $("headline").textContent = s.headline;
  $("subheadline").textContent = s.subheadline;
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

  paintBadge($("stationBadge"), station);
  $("stationLabel").textContent = station ? station.name : "Choose a station";
  const speaker = s.speakers.find(x => x.id === s.speaker) || s.speakers[0];
  $("speakerIcon").innerHTML = ICONS[speaker ? speaker.kind : "mac"];
  $("speakerLabel").textContent = speaker ? speaker.name : "This Mac";
  $("speakerCaption").textContent = on ? "Playing on" : "Play on";
  $("settingsRow").hidden = !s.settings;
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
$("stationRow").addEventListener("click", () => { if (!state) return; renderStations(); $("stationSheet").showModal(); });
$("speakerRow").addEventListener("click", () => { if (!state) return; renderSpeakers(); $("speakerSheet").showModal(); });
$("settingsRow").addEventListener("click", () => { if (!state || !state.settings) return; renderSettings(); $("settingsSheet").showModal(); });
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
    hls.on(Hls.Events.ERROR, (_, d) => { if (d.fatal && here) { toast("Playback stopped (" + d.details + ")"); stopHere(); render(state); } });
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
  range.setAttribute("aria-label", "Delay behind live");
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
  reset.addEventListener("click", async () => {
    if (!confirm("Make a new link? Pages and Home Screen icons with the old link stop working.")) return;
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
  sc.onerror = () => { el.hidden = true; };
  document.head.append(sc);
}

refresh();
</script>
</body>
</html>
"""#
}
