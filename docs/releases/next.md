# Next release (not yet released)

What's on `main` since 0.5.0. When it is released, this becomes that version's notes.

## What's new

- **Sonos speakers.** InterLude plays on Sonos rooms and groups as well as Chromecasts, from the Mac app, the phone remote and the server. Groups appear as the Sonos app names them ("Kitchen + 2") and follow regrouping there.
  - Sonos can't play HLS, so InterLude gives it one continuous AAC stream made from the same playlist, with the same delay and the same news muted or skipped. It plays as an internet radio station.
  - The speaker's own controls work alongside InterLude: its volume moves InterLude's slider, Pause or Stop there stops InterLude, and Play there starts it again.
  - If the speaker can't open the stream, InterLude says so and points at a firewall, rather than waiting in silence.
- **Speakers as they come and go.** Speakers you add or remove appear in and leave the speaker list as it happens. The server now listens to multicast DNS all the time instead of looking every two minutes: a speaker shows up when it announces itself, goes when it says goodbye, and drops out about a minute after it stops answering if it was simply unplugged.

## Changes for people who build or run it

- The server takes `--sonos-host` (or `INTERLUDE_SONOS_HOSTS`, listed in `compose.yaml`) for a Sonos speaker whose multicast DNS doesn't reach it, such as one on another VLAN. One speaker is enough: it describes the whole household. On the Mac, the `sonosHosts` default does the same.
- Sonos speakers fetch `live.aac` from the server or the Mac on the same port as Chromecasts (8642 by default), and the server controls them on their TCP port 1400.
- The Mac app asks for Local Network access to find `_sonos._tcp` as well as Cast devices.
- `serve` also answers `/test/live.aac`, the stream as a Sonos speaker plays it.
- Live tests: `INTERLUDE_LIVE_SONOS=<speaker address> INTERLUDE_LIVE_SONOS_URL=<stream URL>` plays on a real Sonos speaker for 20 seconds, and `INTERLUDE_LIVE_CAST=1` now also runs the continuous discovery.
