#!/usr/bin/env python3
"""Fits YAMNetCalibration: maps YAMNet's speech and music scores onto Apple's classifier's by matching quantiles.

    calibrate.py apple.csv yamnet-raw.csv

Both CSVs come from the classify tool over the same recording (CLASSIFIER=yamnet:<dir> YAMNET_RAW=1 for the second).
Windows are paired by segment and offset. Prints Swift for Sources/InterLudeML/YAMNet.swift and how well the mapped
scores agree with Apple's on the thresholds the detector uses."""
import csv, sys

def load(path):
    with open(path) as f:
        return {(r["index"], r["offset_in_segment"]): (float(r["speech"]), float(r["music"])) for r in csv.DictReader(f)}

apple, yam = load(sys.argv[1]), load(sys.argv[2])
keys = sorted(set(apple) & set(yam))
print(f"// {len(keys)} paired windows ({len(apple)} Apple, {len(yam)} YAMNet)", file=sys.stderr)

def quantile(xs, q):
    xs = sorted(xs); i = q * (len(xs) - 1); lo = int(i); hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)

def fit(col):
    a = [apple[k][col] for k in keys]; y = [yam[k][col] for k in keys]
    qs = [i / 40 for i in range(41)]
    knots = []
    for q in qs:
        x, v = quantile(y, q), quantile(a, q)
        if knots and x <= knots[-1][0] + 1e-6:      # keep x strictly increasing; y stays monotone by construction
            knots[-1] = (knots[-1][0], max(knots[-1][1], v)); continue
        knots.append((x, v))
    return knots

def apply(knots, x):
    if x <= knots[0][0]: return knots[0][1]
    if x >= knots[-1][0]: return knots[-1][1]
    for (x0, y0), (x1, y1) in zip(knots, knots[1:]):
        if x <= x1: return y0 + (y1 - y0) * (x - x0) / (x1 - x0)

maps = {}
for col, name in [(0, "speech"), (1, "music")]:
    maps[name] = fit(col)
    for t in ([0.5, 0.6] if name == "speech" else [0.5]):      # the detector's thresholds and the speech ceiling for music
        agree = sum((apple[k][col] >= t) == (apply(maps[name], yam[k][col]) >= t) for k in keys) / len(keys)
        print(f"// {name} >= {t}: mapped YAMNet agrees with Apple on {agree:.1%} of windows", file=sys.stderr)

print("public enum YAMNetCalibration {")
for name, knots in maps.items():
    body = ", ".join(f"({x:.4f}, {y:.4f})" for x, y in knots)
    print(f"    public static let {name} = ScoreMap([{body}])")
print("}")
