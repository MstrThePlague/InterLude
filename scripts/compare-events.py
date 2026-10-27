#!/usr/bin/env python3
"""Compares the bulletins two InterLude event logs found, such as the Mac app's and the server's over a shadow week.

    compare-events.py mac-events.jsonl server-events.jsonl [--station bbc_6music] [--tolerance 60]

Only the time both logs cover is compared. Blocks pair up when their starts are within the tolerance (seconds).
Prints each pair's start and end differences, then the blocks only one side found, then a summary."""
import argparse, json, datetime

ap = argparse.ArgumentParser()
ap.add_argument("a"); ap.add_argument("b")
ap.add_argument("--station", default="bbc_6music")
ap.add_argument("--tolerance", type=float, default=60)
args = ap.parse_args()

def load(path):
    blocks, logged = {}, []
    for line in open(path):
        try: e = json.loads(line)
        except ValueError: continue
        if "loggedAt" in e: logged.append(e["loggedAt"])
        b = e.get("block")
        if e.get("event") == "close" and isinstance(b, dict) and b.get("station") == args.station and b.get("end"):
            blocks[b["id"]] = b          # the last close wins, as a block can be reopened and closed again
    return [b for b in blocks.values() if not b.get("falseStart")], (min(logged), max(logged)) if logged else (0, 0)

a, ra = load(args.a); b, rb = load(args.b)
lo, hi = max(ra[0], rb[0]), min(ra[1], rb[1])
a = sorted((x for x in a if lo <= x["start"] <= hi), key=lambda x: x["start"])
b = sorted((x for x in b if lo <= x["start"] <= hi), key=lambda x: x["start"])
t = lambda s: datetime.datetime.fromtimestamp(s, datetime.timezone.utc).strftime("%a %d %b %H:%M:%S")
print(f"comparing {t(lo)} to {t(hi)} UTC: {len(a)} blocks in {args.a}, {len(b)} in {args.b}\n")

used, pairs = set(), []
for x in a:
    best = min((y for y in b if id(y) not in used), key=lambda y: abs(y["start"] - x["start"]), default=None)
    if best and abs(best["start"] - x["start"]) <= args.tolerance:
        used.add(id(best)); pairs.append((x, best))
only_a = [x for x in a if all(x is not p[0] for p in pairs)]
only_b = [y for y in b if id(y) not in used]

for x, y in pairs:
    print(f"both  {t(x['start'])}  start {y['start'] - x['start']:+6.1f} s  end {y['end'] - x['end']:+6.1f} s"
          f"{'  (doubtful in one)' if x.get('doubtful') != y.get('doubtful') else ''}")
for x in only_a: print(f"only in {args.a}: {t(x['start'])} ({x['end'] - x['start']:.0f} s) {x.get('evidence', '')}")
for y in only_b: print(f"only in {args.b}: {t(y['start'])} ({y['end'] - y['start']:.0f} s) {y.get('evidence', '')}")
if pairs:
    ds = sorted(abs(y["start"] - x["start"]) for x, y in pairs); de = sorted(abs(y["end"] - x["end"]) for x, y in pairs)
    print(f"\n{len(pairs)} matched, {len(only_a)} only in the first, {len(only_b)} only in the second; "
          f"median start difference {ds[len(ds) // 2]:.1f} s, median end difference {de[len(de) // 2]:.1f} s")
