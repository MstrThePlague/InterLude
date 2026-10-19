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
    public init() {}
}

public enum RemoteCommand: Equatable, Sendable {
    case toggle, station(String), speaker(String), volume(Double), notNews, newsGotThrough
}

public enum RemoteRoute: Equatable, Sendable {
    case page, manifest, icon, state, command(RemoteCommand)
}

/// Addresses on the local server for the phone remote: `/remote/<token>/` and what sits under it.
public enum RemoteRoutes {
    public static let prefix = "/remote/"

    public static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The page's path for a token, with the trailing slash its relative links need.
    public static func pagePath(token: String) -> String { "\(prefix)\(token)/" }

    /// What a request asks for, or nil if it isn't for the remote with this token. Commands must be POSTs, so a
    /// browser fetching links ahead of time can never press a button.
    public static func route(_ req: HTTPRequest, token: String) -> RemoteRoute? {
        let base = prefix + token
        guard !token.isEmpty, req.path == base || req.path.hasPrefix(base + "/") else { return nil }
        let rest = String(req.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let post = req.method == "POST"
        switch rest {
        case "", "index.html": return post ? nil : .page
        case "manifest.webmanifest": return post ? nil : .manifest
        case "icon.png": return post ? nil : .icon
        case "api/state": return .state
        default: break
        }
        guard post, rest.hasPrefix("api/") else { return nil }
        let q = req.query
        switch rest.dropFirst(4) {
        case "toggle": return .command(.toggle)
        case "station": return q["id"].map { .command(.station($0)) }
        case "speaker": return q["id"].map { .command(.speaker($0)) }
        case "volume":
            guard let v = q["v"].flatMap(Double.init), v.isFinite else { return nil }
            return .command(.volume(min(max(v, 0), 1)))
        case "notnews": return .command(.notNews)
        case "gotthrough": return .command(.newsGotThrough)
        default: return nil
        }
    }

    public static func json(_ s: RemoteState) -> HTTPResponse {
        HTTPResponse(contentType: "application/json", body: (try? JSONEncoder().encode(s)) ?? Data("{}".utf8), noCache: true)
    }

    public static func page(token: String) -> HTTPResponse {
        let html = RemotePage.html.replacingOccurrences(of: "__BASE__", with: pagePath(token: token))
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
<link rel="apple-touch-icon" href="icon.png">
<link rel="icon" href="icon.png">
<title>InterLude</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #f2f2f7; --card: #ffffff; --text: #1c1c1e; --muted: #6e6e73; --line: rgba(60,60,67,.14);
  --accent: #007aff; --green: #248a3d; --orange: #c93400; --orange-bg: rgba(255,149,0,.16); --blue: #0064d1; --red: #d70015;
  --press: rgba(0,0,0,.06);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #000000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --line: rgba(84,84,88,.6);
    --accent: #0a84ff; --green: #30d158; --orange: #ff9f0a; --orange-bg: rgba(255,159,10,.18); --blue: #409cff; --red: #ff6961;
    --press: rgba(255,255,255,.08);
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
.toast { position: fixed; left: 50%; bottom: max(24px, env(safe-area-inset-bottom)); transform: translateX(-50%); background: rgba(40,40,40,.94);
  color: #fff; padding: 10px 16px; border-radius: 12px; font-size: 15px; max-width: calc(100% - 32px); text-align: center; z-index: 10;
  transition: opacity .25s; }
</style>
</head>
<body>
<main>
  <div class="banner offline" id="offline" hidden role="status"><b>Can't reach InterLude</b>Check that the Mac is awake, InterLude is open, and this phone is on the same Wi-Fi.</div>
  <div class="banner offline" id="gone" hidden role="status"><b>This link has stopped working</b>The remote was turned off or its link was reset. Open InterLude's Settings on the Mac and scan the code again.</div>
  <div class="banner error" id="error" hidden role="alert"></div>

  <section class="card now" aria-live="polite">
    <div class="art" id="art"><span id="artText">R</span><img id="artImg" alt="" hidden><div class="shade" id="artShade" hidden><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 9v6h4l5 5V4L7 9H3zm13.6 3 2.7-2.7-1.4-1.4-2.7 2.7-2.7-2.7-1.4 1.4 2.7 2.7-2.7 2.7 1.4 1.4 2.7-2.7 2.7 2.7 1.4-1.4z"/></svg></div></div>
    <div class="meta"><span class="pill" id="pill" hidden></span><span id="stationName"></span></div>
    <h1 id="headline">InterLude</h1>
    <div class="sub" id="subheadline">Connecting to your Mac…</div>
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
<div class="toast" id="toast" hidden role="status"></div>

<script>
"use strict";
const $ = id => document.getElementById(id);
const ICONS = {
  mac: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5V16H4V5.5zM6 6v8h12V6H6zM1 17h22v1a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2v-1z"/></svg>',
  speaker: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm5 2.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM12 10a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9zm0 2.2a2.3 2.3 0 1 1 0 4.6 2.3 2.3 0 0 1 0-4.6z"/></svg>',
  group: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 4h7a1.5 1.5 0 0 1 1.5 1.5v13A1.5 1.5 0 0 1 10 20H3a1.5 1.5 0 0 1-1.5-1.5v-13A1.5 1.5 0 0 1 3 4zm3.5 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM14 4h7a1.5 1.5 0 0 1 1.5 1.5v13A1.5 1.5 0 0 1 21 20h-7a1.5 1.5 0 0 1-1.5-1.5v-13A1.5 1.5 0 0 1 14 4zm3.5 6a3 3 0 1 0 0 6 3 3 0 0 0 0-6z"/></svg>'
};
const CHECK = '<svg class="check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" aria-hidden="true"><path d="m5 12 5 5 9-10"/></svg>';
const PILLS = { live: "LIVE", muted: "MUTED", earlier: "EARLIER", starting: "STARTING" };

let state = null, timer = null, failures = 0, volumeHeldUntil = 0, volumeTimer = null, toastTimer = null;

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
  try { render(await request("state")); failures = 0; connected(true); }
  catch (e) { failures++; if (e.gone) connected(false, true); else if (failures >= 2) connected(false); }
  if (!document.hidden) timer = setTimeout(refresh, failures ? 3000 : 1500);
}
async function send(command, params) {
  const q = params ? "?" + new URLSearchParams(params) : "";
  try { render(await request(command + q, true)); failures = 0; connected(true); return true; }
  catch (e) { connected(false, !!e.gone); return false; }
}
document.addEventListener("visibilitychange", () => { if (document.hidden) clearTimeout(timer); else refresh(); });
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

  const play = $("play");
  play.setAttribute("aria-label", s.playing ? "Stop" : "Play");
  play.setAttribute("aria-busy", s.state === "starting" ? "true" : "false");
  // SVG elements have no hidden property, so set the attribute.
  $("iconPlay").toggleAttribute("hidden", s.playing);
  $("iconStop").toggleAttribute("hidden", !s.playing);

  if (Date.now() > volumeHeldUntil) $("volume").value = Math.round(s.volume * 100);

  paintBadge($("stationBadge"), station);
  $("stationLabel").textContent = station ? station.name : "Choose a station";
  const speaker = s.speakers.find(x => x.id === s.speaker) || s.speakers[0];
  $("speakerIcon").innerHTML = ICONS[speaker ? speaker.kind : "mac"];
  $("speakerLabel").textContent = speaker ? speaker.name : "This Mac";
  $("speakerCaption").textContent = s.playing ? "Playing on" : "Play on";

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

  if ($("speakerSheet").open) renderSpeakers();
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
        if (st.id !== state.station || !state.playing) await send("station", { id: st.id });
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
  $("play").setAttribute("aria-busy", "true");
  await send("toggle");
});
$("volume").addEventListener("input", e => {
  volumeHeldUntil = Date.now() + 2000;
  clearTimeout(volumeTimer);
  volumeTimer = setTimeout(() => send("volume", { v: (e.target.value / 100).toFixed(2) }), 150);
});
$("stationRow").addEventListener("click", () => { if (!state) return; renderStations(); $("stationSheet").showModal(); });
$("speakerRow").addEventListener("click", () => { if (!state) return; renderSpeakers(); $("speakerSheet").showModal(); });
for (const d of document.querySelectorAll("dialog")) {
  d.addEventListener("click", e => { if (e.target === d || e.target.hasAttribute("data-close")) d.close(); });
}
$("notNews").addEventListener("click", async () => {
  if (await send("notnews")) toast("Sound comes back in a few seconds.");
});
$("gotThrough").addEventListener("click", async () => {
  if (await send("gotthrough")) toast("Thanks. InterLude will learn from that bulletin.");
});

refresh();
</script>
</body>
</html>
"""#
}
