# Checklists for tests that need a person

Record your answers in `docs/findings.md` under "Owner results".

## A. Local playback (Phase 1)
1. Run `./scripts/build-app.sh`, then `open build/InterLude.app`. A radio icon appears in the menu bar.
2. Click it, choose Radio 6 Music and "This Mac", press Play. Sound should start within about 10 seconds.
3. The status line should say "About 60 seconds behind live." Compare with BBC Sounds or a radio: the app should be about a minute later.
4. Leave it for 2 hours. Note any stall or drop-out.
5. Switch station in the picker. Playback should restart on the new station.

## B. Muting a bulletin on the Mac (Phase 3)
Do this at a time when a 6 Music bulletin is due (usually on the hour or half past).
1. Play 6 Music with "Mute news" on.
2. About a minute after the bulletin starts on the radio, the sound should go silent, and the menu bar icon should show a crossed speaker.
3. When music returns it should come back with no click or gap beyond the bulletin itself.
4. Note: did any news words leak? How many seconds? Did the sound return too late (music missing at the start)?
5. If a presenter link was muted wrongly, press "Not news" while muted. Sound should return within about 7 seconds.
6. After a bulletin that played, press "News got through". Do this for three bulletins on one station and InterLude learns the station's ident.

## C. Cast (Phase 0.4 and Phase 4)
Use one Chromecast Audio first, then a Cast group. Say the device name when you ask me to run it.
1. I start playback to the device. You should hear the station within about 15 seconds.
2. During a bulletin, listen for: a clean silence, then a clean return. Any click, stutter or gap longer than 2 seconds?
3. Change the volume slider: the device volume should follow.
4. Start something else on the device from your phone. InterLude should stop and say another app took over.
5. Switch the Mac's Wi-Fi off and on. Playback should recover or give a clear error.

## D. Labelling bulletins (for accuracy measurement)
1. Listen to a recording or live stream and note the start and end time of each bulletin.
2. Write them in `recordings/labels.json` as `[{"start":"2026-10-12T05:30:46Z","end":"2026-10-12T05:34:36Z"}]` (UTC).
3. Run `evaluate recordings/6music-a.csv recordings/labels.json`.
