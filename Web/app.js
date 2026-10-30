// InterLude's web app: the Mac's phone remote and interlude-server's page. Served from disk (see WebFiles), so it
// can change without a rebuild; open pages load themselves again when it does.
// Plain script with nothing loaded from elsewhere, apart from album art from the BBC. Every value from the Mac or
// server is set as text, never as markup.
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

// The version of the files this page was loaded from. When the server's files change, load the new ones.
const PAGE_VERSION = document.querySelector('meta[name="interlude-version"]').content;
function render(s) {
  if (s.pageVersion && s.pageVersion !== PAGE_VERSION && !document.querySelector("dialog[open]")) { location.reload(); return; }
  state = s;
  $("error").hidden = !s.error;
  $("error").textContent = s.error || "";

  const station = s.stations.find(x => x.id === s.station);
  // The player shows the station on air, which can differ from the one chosen for browsing Earlier.
  const onAir = (s.onAir && s.stations.find(x => x.id === s.onAir)) || station;
  const art = $("art");
  art.style.background = gradient(onAir && onAir.colour);
  $("artText").textContent = onAir ? (onAir.short || onAir.name.slice(0, 1)) : "R";
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
  $("goLive").hidden = !s.offerLive;
  if (station) $("goLive").textContent = "Play " + station.name + " live instead";
  document.documentElement.dataset.mood = s.state === "muted" ? "muted" : s.state === "earlier" ? "earlier" : "live";
  document.documentElement.dataset.playing = s.playing ? "1" : "0";
  // The phone's "On air" hero: the station large, a line saying what it is doing, and what's playing beneath.
  document.documentElement.classList.toggle("idle", !s.playing && s.state !== "starting" && s.mode !== "earlier");
  const behind = s.footer ? " · " + s.footer.charAt(0).toLowerCase() + s.footer.slice(1) : "";
  $("eyebrow").textContent = s.muted ? "Bulletin muted" + (s.muteElapsed != null ? " · " + clock(s.muteElapsed) : "")
    : s.state === "starting" ? "Starting" : s.state === "earlier" ? "Earlier programme" : s.playing ? "On air" + behind : "Not playing";
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
  $("bigName").textContent = onAir ? onAir.name : "InterLude";
  const tint = colourOf(onAir && onAir.colour);
  if (tint) document.documentElement.style.setProperty("--station", tint); else document.documentElement.style.removeProperty("--station");
  $("stationLabel").textContent = $("quickStationLabel").textContent = station ? station.name : "Choose a station";
  const speaker = s.speakers.find(x => x.id === s.speaker) || s.speakers[0];
  $("speakerIcon").innerHTML = $("quickIcon").innerHTML = ICONS[speaker ? speaker.kind : "mac"];
  $("speakerLabel").textContent = $("quickSpeakerLabel").textContent = speaker ? speaker.name : "This Mac";
  $("speakerCaption").textContent = $("quickSpeakerCaption").textContent = on ? "Playing on" : "Play on";
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
  requestAnimationFrame(fitDock);
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
        // In Earlier a station shows its programmes; in Live it plays, taking over from an earlier programme.
        if (st.id !== state.station || state.offerLive || (!state.playing && state.mode !== "earlier")) await send("station", { id: st.id });
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
$("goLive").addEventListener("click", () => {
  if (!state) return;
  if (playsHere() && !here) playHere();
  send("station", { id: state.station });
});
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

// The dock is fixed to the bottom on phones; the page keeps its height free so nothing hides under it.
const dock = $("dock");
function fitDock() {
  const fixed = getComputedStyle(dock).position === "fixed";
  const h = fixed ? dock.getBoundingClientRect().height : 0;
  document.documentElement.style.setProperty("--dock-h", h + "px");
  document.body.style.paddingBottom = fixed ? (h + 16) + "px" : "";
}
if (window.ResizeObserver) new ResizeObserver(() => requestAnimationFrame(fitDock)).observe(dock);
window.addEventListener("resize", fitDock);
fitDock();

// A plain background, remembered on this device. The phone's Increase Contrast setting applies it too.
function setPlain(on) {
  document.documentElement.toggleAttribute("data-plain", on);
  $("plainBtn").textContent = on ? "Colourful background" : "Plain background";
  try { localStorage.setItem("plain", on ? "1" : "0"); } catch {}
}
try { setPlain(localStorage.getItem("plain") === "1"); } catch { setPlain(false); }
$("plainBtn").addEventListener("click", () => setPlain(!document.documentElement.hasAttribute("data-plain")));

refresh();
