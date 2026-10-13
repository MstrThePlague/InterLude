# InterLude

InterLude is a small macOS menu bar app that plays BBC radio about a minute behind live and quietly mutes the news bulletins. It plays on the Mac itself or on Chromecast speakers and groups.

I wanted 6 Music in the background all day without the hourly news, so it is tuned for music stations. Speech stations play normally.

> **Unofficial.** InterLude is not affiliated with the BBC. It relies on stream addresses the BBC does not document and can change at any time. It sends no telemetry: its only network traffic is to BBC servers and to speakers on your own network.

## What it does

- Plays any BBC station a fixed time behind live (60 seconds by default).
- Recognises each bulletin as it arrives and replaces it with silence, or with ocean waves, a woodland stream or birdsong if you prefer. When the bulletin ends, the station comes back.
- Plays on the Mac, on a Chromecast, or on a Cast group, and you can switch speaker while it plays.
- Learns a station's news theme from the last few hours of broadcast, the first time you play it (so far proven on 6 Music).
- Keeps a log of every decision, so a wrong mute can be explained and the rules improved.

## How it works

The BBC's live streams are HLS: a playlist of 6.4 second audio segments. InterLude downloads the segments itself, analyses them, and serves its own playlist from the Mac to the player. Because it runs about a minute behind live, it has heard each bulletin begin before you do.

A bulletin is found in a few ways, all running on the Mac:

1. **Speech near the hour or half hour.** Apple's built-in sound classifier scores speech and music every 1.5 seconds. Twenty seconds of sustained speech close to a bulletin slot starts a mute.
2. **The news theme.** InterLude learns the station's news jingle from recent bulletins and starts the mute when it hears it, so the presenter's handover still plays.
3. **The newsreader's words.** While a bulletin is muted, on-device speech recognition listens for the sign-off ("…your next update's at six thirty", "That's 6 Music News for tonight") and ends the mute there, so trails and the presenter's chat afterwards are not lost. This needs macOS 26 or later; otherwise the mute ends when music returns.

Muted segments are replaced one for one with segments carrying the same timestamps, so the player sees one continuous stream and the delay never drifts. If a mute is wrong, **Not news** brings the sound back within a few seconds, and **News got through** teaches it from a bulletin it missed.

The design, the measurements behind each rule and the mistakes along the way are written up in [docs/findings.md](docs/findings.md).

## Requirements

- macOS 15 or later on Apple silicon (macOS 26 or later for ending mutes at the newsreader's sign-off)
- Xcode, to build
- The BBC's UK stream addresses, which may not play outside the UK

## Build and run

```
./scripts/build-app.sh
open build/InterLude.app
```

The script builds `build/InterLude.app` and signs it with your Apple Development certificate if you have one (a free Apple ID is enough), or ad hoc otherwise. A stable signature stops macOS asking for local network permission after every rebuild. `SANDBOX=0 ./scripts/build-app.sh` builds without the App Sandbox.

Builds go to `~/Library/Caches/InterLudeBuild`, because `codesign` rejects files with the extended attributes that iCloud-synced folders such as Documents add.

To run the tests:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path ~/Library/Caches/InterLudeBuild
```

To see the panel's states without playing anything, launch with `--demo=playing`, `--demo=muted`, `--demo=upcoming`, `--demo=error` or `--demo=settings`.

## Where things are kept

| File | What it holds |
|---|---|
| `Application Support/InterLude/stations.json` | The station list and stream address template. Edit a station's pool ID here if the BBC changes it. |
| `Application Support/InterLude/profiles/` | Per-station settings, bulletin minutes and the learned news theme. |
| `Application Support/InterLude/events.jsonl` | One line per detected bulletin and per correction. Settings › Export diagnostics zips these up. |

Inside the App Sandbox, `Application Support` is the app's own container under `~/Library/Containers`.

## Project layout

| Folder | Contents |
|---|---|
| `Sources/InterLudeCore` | Everything that isn't user interface: stream handling, MPEG-TS, detection, playout, the local server and Cast. |
| `Sources/InterLudeApp` | The SwiftUI menu bar app. |
| `Tests` | Unit tests for the parts that can be tested without a network or speakers. |
| `Tools` | Command-line programs used to measure and tune detection (below). |
| `docs` | Findings from testing, and checklists for the tests that need ears or hardware. |

### Tools

Run with `swift run --scratch-path ~/Library/Caches/InterLudeBuild <name>`. Recordings are for personal testing and are kept out of git.

| Tool | Use |
|---|---|
| `record <serviceId> <hoursAgo> <minutes> <dir>` | Save segments from the BBC's six hour rewind window. |
| `classify <dir> <csv>` | Speech and music scores for a recording. |
| `evaluate <csv> [labels.json] [profile.json]` | Replay the speech rule over scores and report accuracy against labelled bulletins. |
| `ident-check` | Find and test a station's news theme in recordings. |
| `signoff-check` | Transcribe bulletins and report where the newsreader opens and signs off. |
| `voice-changes`, `presenter-check` | Experiments in telling voices apart (they didn't work; see the findings). |
| `serve <serviceId> [delay] [port]` | A session without the app, for testing with ffmpeg or curl. |
| `cast-spike list` / `play <device> <url>` | List Cast speakers and groups, or play a stream on one. |
| `rms-poll`, `spike01-stream` | Early experiments with the track metadata and stream format. |

## Sounds

The sounds offered in place of bulletins are trimmed from recordings by Joseph Sardin at [BigSoundBank](https://bigsoundbank.com), released into the public domain (CC0): sea waves #0698, forest and stream #2 #2714, and forest #3 #2715.

## Licence

MIT. See [LICENSE](LICENSE).

BBC audio, artwork and logos are the BBC's and are never stored in this repository. Album art and track names shown in the panel are fetched from the BBC while the app runs.
