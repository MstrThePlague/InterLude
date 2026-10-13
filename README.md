# InterLude

A macOS menu bar app that plays BBC radio to Chromecast devices (or the Mac itself), about a minute behind live, and mutes each news bulletin.

**Unofficial.** InterLude has no affiliation with the BBC. It depends on undocumented stream addresses that can change without notice. It sends no telemetry; its only network traffic is to BBC hosts and to Cast devices on your network. Never commit BBC audio, logos or artwork.

## How it works

InterLude downloads the station's HLS segments, classifies the audio a short way ahead of the playhead, and serves its own HLS playlist from the Mac. Playback holds a fixed delay (60 seconds by default). When a bulletin starts, InterLude serves silent segments, with the timestamps of the segments they replace, until music returns. The silence lasts as long as the bulletin, so the delay never changes. In Settings you can choose ocean waves, a woodland stream or woodland birds instead of silence; the sound fades in as the mute starts and out as the station returns.

Detection combines Apple's built-in sound classifier (speech and music scores), a learned news ident per station, bulletin-time slots (default minutes 0 and 30), and a track-metadata poll for display. The rule is deterministic and every decision is written to `events.jsonl`.

Album artwork and track titles shown in the panel come from the BBC's metadata service and are fetched at runtime only; nothing is stored in this repository.

## Build and run

Needs macOS 15 or later, Apple silicon, and Xcode.

```
./scripts/build-app.sh      # builds build/InterLude.app, signed with your Apple Development identity if you have one
open build/InterLude.app
```

For a quick look at the panel states without playing anything, launch with `--demo=playing`, `--demo=muted`, `--demo=error` or `--demo=settings`.

Use `SANDBOX=0 ./scripts/build-app.sh` for a build without the App Sandbox. Builds go to `~/Library/Caches/InterLudeBuild`, because extended attributes in Documents or iCloud folders make `codesign` fail.

Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path ~/Library/Caches/InterLudeBuild`

## Data files

| File | Purpose |
|---|---|
| `~/Library/Application Support/InterLude/stations.json` | Station list and URL template. Edit pool IDs here when the BBC changes them. |
| `.../profiles/{serviceId}.json` | Per-station delay, thresholds, bulletin slots, learned idents. |
| `.../events.jsonl` | One JSON line per detected block and user correction. |

(Inside the App Sandbox these live under `~/Library/Containers/org.benbull.InterLude/Data/Library/Application Support/InterLude`.)

## Command-line tools

All tools are in `Tools/` and are run with `swift run --scratch-path ~/Library/Caches/InterLudeBuild <name>`.

| Tool | Use |
|---|---|
| `spike01-stream` | Phase 0.1: check playlists, rewind depth, timing. |
| `record <serviceId> <hoursAgo> <minutes> <dir>` | Save segments from the BBC's 6 hour window for testing. |
| `classify <dir> <csv>` | Per-window speech and music scores. |
| `rms-poll <serviceId> <minutes> <file>` | Poll track metadata every 30 s. |
| `evaluate <csv> [labels.json] [profile.json]` | Replay the detector; report recall, false starts, edge loss. |
| `serve <serviceId> [delay] [port]` | Headless session for testing with ffmpeg or curl. |
| `cast-spike list` / `play <device> <url>` | List Cast devices and groups; load a stream. |

## Sounds

The bulletin sounds in `Resources/Ambience` are trimmed from recordings by Joseph Sardin at [BigSoundBank](https://bigsoundbank.com), released into the public domain (CC0): sea waves #0698, forest and stream #2 #2714, forest #3 #2715.

## Licence

MIT. See `LICENSE`. Read the BBC's terms for its online services before any public release.
