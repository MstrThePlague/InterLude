# Findings

Measured on 12 October 2026 on the owner's Mac. Evidence comes from the tools in `Tools/`. Items marked **Owner** need a person.

## Phase 0

### 0.1 Stream: done, passes

| Check | Result |
|---|---|
| HTTPS and HTTP | Both return 200 for the 6 Music 320 kbps playlist. HTTPS first, HTTP as fallback, as specified. |
| Playlist | HLS v3, `#EXTINF:6.4`, names like `bbc_6music-audio=320000-{index}.ts`, relative URLs. Live window (`.norewind`) is 5 segments. |
| Rewind | Removing `.norewind` lists 3375 segments, exactly 6.00 hours. Segments 11 hours old still return 200 with distinct audio. |
| Index to time | `PROGRAM-DATE-TIME` of the first segment is 6.4 s before `index × 6.4`. So `index × 6.4` is a segment's **end** time. The app uses `(index − 1) × 6.4` as the start. |
| Stream clock vs system clock | The newest segment in the live window ends about 29 s after the Mac's clock reads (checked against the `Date` and `X-USP-Last-Modified` headers). Segment timestamps are the BBC's stream clock, not UTC. Bulletin slot windows use the stream clock; the ±4 minute window absorbs the offset. |
| Container and codec | MPEG-TS, AAC-LC, 48 kHz, **stereo**, 321 kbps, constant size 268,088 bytes. Audio PID 34, PMT PID 32. Each segment has PAT, PMT, then about 1424 audio packets. |
| Frames | 300 ADTS frames per segment, 1920 PTS ticks (90 kHz) each. ADTS frames straddle PES boundaries: only the first PES in a segment starts on a frame boundary. |
| Audio CC | The audio continuity counter starts at 0 in every segment. PAT and PMT counters vary (4, 12, …). |
| Join test | 93 segments (about 10 minutes) fetched with 4 in flight, none missing. ffprobe reads the joined file as 595 s of AAC-LC. |

### 0.2 Classify: done, with caveats

- A 2-hour recording (04:54:56 to 06:55:02 UTC, 1125 segments) was decoded and classified into 4752 windows. Output: `recordings/6music-a.csv` (not committed).
- Apple's classifier uses 3 s windows with a 1.5 s hop. The stream analyzer (`SNAudioStreamAnalyzer`) silently dropped most buffers when fed faster than real time, so InterLude classifies short clips through a file instead (`ClipClassifier`).
- **Music-bed problem confirmed.** Within speech runs the mean music score is 0.45, and in some runs 0.7. A speech threshold of 0.6 still separates these runs, but "music" cannot be read as "not speech". The end-of-bulletin rule therefore requires music ≥ 0.5 **and** speech < 0.5 for 5 s.
- Speech runs of at least 20 s in that recording, with start time and length: 05:30:46 (230 s), 06:00:33 (96 s), 06:30:26 (260 s) fall on the half hour and hour and look like bulletins. Others (05:09:14 for 474 s, 06:12:34 for 161 s) are away from the slots and are ignored by the slot rule. **Owner:** these have not been checked by ear, so none of the figures above is an accuracy result. See checklist D.
- The detector run on that recording produces 7 blocks: three plausible bulletins and four short blocks (22 to 88 s) flagged doubtful.

### 0.3 Metadata: schema written, lag not yet measured

Endpoint `https://rms.api.bbc.co.uk/v2/services/{serviceId}/segments/latest?limit=N` works (HTTP 200).

```
{ "$schema", "total": 8, "limit": 10, "offset": 0,
  "data": [ { "type": "segment_item", "id": "p0pg7lw3", "urn": "...",
              "segment_type": "music",
              "titles": { "primary": artist, "secondary": title, "tertiary": null, "entity_title": ... },
              "offset": { "start": 7242, "end": 7421, "label": "Now Playing", "now_playing": true },
              "image_url": ".../{recipe}/...jpg", "uris": [] } ] }
```

- `offset.start` and `offset.end` are **seconds since the programme began**, not Unix times. The programme start is not in the response, so the offset clock has to be aligned to the audio.
- `total` is only the last 8 or so tracks (about 30 minutes). History must be stored as it arrives.
- Only `segment_type: music` entries were seen so far. Presenter links are absent, as the spec expected.
- `rms-poll` has been running since 08:03 UTC and polls every 30 s; raw output is `recordings/rms-a.jsonl`. When it finishes (about 10:08 UTC), record the matching audio and run `scripts/rms-lag.py`:
  ```
  record bbc_6music 2.3 125 recordings/6music-c ; classify recordings/6music-c recordings/6music-c.csv
  python3 scripts/rms-lag.py recordings/6music-c.csv recordings/rms-a.jsonl
  ```
  A first run on 30 minutes of data was inconclusive (4 tracks). The detector does not use the metadata yet, only the "now playing" display, which is shifted by the delay.

### 0.4 Cast: discovery works, nothing loaded yet

- Bonjour discovery from a command-line tool found 6 services: **All speakers** (Google Cast Group) and five Chromecast Audio devices (JT Office, Kitchen B&W Speaker, Kraftwerk speaker, Master Bedroom, Vintage Hi-Fi). Names and models come from the `fn` and `md` TXT keys as specified.
- The direct Cast v2 sender (`DirectCastController`: TLS, protobuf framing, heartbeat, launch of app `CC1AD845`, LOAD with `hlsSegmentFormat` tried as `ts_aac`, `ts`, then omitted) is written and its message framing is unit-tested, but **has not been run against a device**. No playback was started on your speakers without your say-so.
- **Owner result (12 October 2026):** playback to a single Chromecast Audio (the one in the office) works through the app. Not yet recorded: which `hlsSegmentFormat` was accepted (the app tries `ts_aac`, `ts`, then none, and does not log which), how a muted bulletin sounds on the device, and the group test.
- Silent-segment template: built at run time from the system AAC encoder, wrapped in an ADTS header copied from a real frame. The 300-frame silent segment decodes to −91 dB, with no timestamp break. Verified with ffprobe and ffmpeg.

## Phase 1: local player

- Passes in the headless test and in the signed, sandboxed app: the playlist slides by exactly one per 6.4 s, `EXT-X-MEDIA-SEQUENCE` rises by 1, a 50 s ffmpeg capture of the served stream has continuous timestamps, and AVPlayer fetches each new segment as soon as it is listed.
- Real delay was 64 s for a 60 s setting. The status line shows the measured value, rounded to 5 s.
- The App Sandbox works with the free-account signing: the listener (`NWListener`), Bonjour browsing, SoundAnalysis and temporary files all work with the network client and server entitlements. No need to turn the sandbox off.
- **Owner:** the 2-hour stall test (checklist A).

## Phase 3: muting (mechanics verified)

- A mixed file of 12 real segments with 4 replaced by silent ones has 3600 audio packets, no timestamp breaks, −19.8 dB, then −91.0 dB over the replaced span, then −17.7 dB.
- **Live end-to-end test.** At 08:30 UTC the session opened a block (speech for 22 s near the half-hour slot) and closed it 251 s later when music returned. The served stream captured with ffmpeg was silent for 256.0 s (40 whole segments), with normal audio on both sides. The log line is in `recordings/serve-events.jsonl`.
- Leaked news audio and lost music at the edges are still to be measured against labels (checklist D).

## Spec amendments made

1. Wall-clock mapping of a segment uses `(index − 1) × 6.4` (the index is the end time). The stream clock runs about 29 s ahead of the system clock.
2. Audio is stereo AAC-LC. Silent segments are stereo.
3. The classifier runs on clips through a file, because the stream analyzer drops buffers. Windows are 3 s with a 1.5 s hop, so the "5 seconds of sustained music" rule means at least four overlapping windows.
4. The end-of-bulletin rule needs speech < 0.5 as well as music ≥ 0.5, because of the music bed.
5. Phase 1 uses a Swift package plus a bundling script (`scripts/build-app.sh`) rather than an Xcode project. The result is the same signed, sandboxed `.app`.
6. Playlist start: the player starts about 3 segments behind the newest listed segment, so the app lists 6 segments at start with the newest 3 segments ahead of the delay.
7. After the Mac sleeps, the playout clock restarts the session rather than racing to catch up.

## Not done yet (needs time or a person)

- Phase 2 acceptance (5 weekdays of 6 Music logs against labels) and the Radio 2 3-day shadow run. The app logs every candidate block to `events.jsonl`; shadow mode and ident-only detection are built, and Radio 2 defaults to both.
- Cast tests on a Chromecast Audio and on a group (checklist C).
- The BBC's terms for its online services have not been read. Record what they say here before any public release.
