# Earlier programmes on demand

How InterLude plays programmes older than the live origin keeps, from BBC Sounds' on-demand episodes. For personal listening.

## Sounds on-demand probe (18 October 2026)

Radcliffe and Maconie, 17 October 07:00 to 09:00 UTC (version `m0032tkh`, the schedule's `playable_item.id`):

- The media selector (`https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/{pid}/format/json`) returns DASH and HLS at 128 and 320 kbps, on Akamai and CloudFront. The HLS master URL carries a signed `__gda__` token; use the URLs as issued. Every response starts with a disclaimer that the data is part of the BBC iPlayer content protection system. Episodes from 19 and 26 September also returned media.
- The HLS is MPEG-TS, AAC-LC 48 kHz stereo, 6.4 s segments (1124 segments, 7,190 s), numbered from 1 at the programme start. `TS.parse` and `Decode.pcm` read them unchanged.
- **The news is not edited out.** The length is the full two hours. `signoff-check` on the segments from 30:00 found the newsreader's opening at +1 s ("This is BBC Radio 6 Music… BBC News at 8.30") and the sign-off at 32:54, a three-minute bulletin. The 09:00 BST slot (offset 60:00) was music and chat, with no bulletin.

So on-demand needs skipping as much as live does. Slot times are the schedule's start plus the offset.

## How it plays (18 October 2026)

- The Earlier list steps back day by day through the last 30 days (UK dates). A programme that began within the last 10.5 hours plays from the live origin, as on `main`; anything older that has finished and has a `playable_item` plays on demand.
- `OnDemand.resolve` asks the media selector for the version, opens the HLS master it gives (HTTPS, Akamai first) and the variant nearest the chosen bitrate, and reads the segments as that playlist lists them.
- The episode's segments are put on the broadcast clock: segment 1 becomes the programme's first live index (`SegmentStore` `offset`). The detector's slot times, the replay playout, skipping, the log and Cast then work exactly as for the live origin. There is no audio before the start, so analysis starts at the first segment, and the playlist gets `#EXT-X-ENDLIST` once the last segment is listed. The app stops when the player reaches the end.
- The news theme is not learned from the live rewind for on-demand programmes (the live origin is not opened); learning from closed bulletins still works.

Test (`serve`, `REPLAY=2026-10-17T07:00:00Z VERSION=m0032tkh OFFSET=1680`): the presenter talked straight into the 07:30 bulletin, so speech alone never opened a block (the run began before the slot). The slot check on `main` (transcribing a minute before to two after each slot) heard the newsreader at 07:29:47 and the sign-off at 07:32:50; 30 segments were cut, and the rebuilt segments decode with continuous timestamps. Three closed bulletins then promoted 6 Music's news jingle.
