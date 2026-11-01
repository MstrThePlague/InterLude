//  main.swift
//  ident-check
//
//  Finds and tests a station's news theme in recordings, offline, as the app learns it on the fly.
//
//  Usage: ident-check <recordingDir>[:<bulletinStart>,<bulletinStart>...] ...
//
//  Each argument names a folder made by `record`, with the Unix times at which bulletins start (from the event log).
//  By default the audio from 20 s before to 10 s after each start is cut out, the clips are checked for a shared
//  jingle (`IdentMatcher.promote`), and every recording is then scanned with what was learned, so false matches away
//  from bulletins show up.
//
//  Environment:
//    PLATFORM=portable            decode with ffmpeg and use the portable maths, as interlude-server does on Linux
//    BANDS, LOG2N, HOP            fingerprint settings to try in place of IdentFeatures' own
//    BOOT=1 [TEST=name,...]       learn as the app does on first play: from a window after every :00 and :30 slot,
//                                 bulletin or not; recordings named in TEST are held out and scanned end to end
//    REF=<name>:<start>:<seconds> take that stretch of a recording as the jingle and look for it everywhere
//    EXPLORE=1 [WIN=<seconds>]    for each pair of bulletins, find the best-matching stretch of WIN seconds (default 6)

import Foundation
import InterLudeCore
import InterLudeApple
import InterLudePortable

let environment = ProcessInfo.processInfo.environment
if environment["PLATFORM"] == "portable", let ffmpeg = FFmpegDecoder.find() {
    Platform.install(.portable(ffmpeg: ffmpeg))
} else {
    Platform.install(.apple)
}

let bands = Int(environment["BANDS"] ?? "") ?? IdentFeatures.bands
let log2n = Int(environment["LOG2N"] ?? "") ?? 12
let hop = Int(environment["HOP"] ?? "") ?? IdentFeatures.hop
let fftLength = 1 << log2n
/// Fingerprint frames per second.
let framesPerSecond = 48000.0 / Double(hop)
let iso = ISO8601DateFormatter()

/// A recording's fingerprint, with when it starts and the bulletin starts given for it.
struct Recording {
    var name: String
    /// [s since 1970]
    var start: Double
    var frames: [[Float]]
    var bulletinStarts: [Double]
}

/// Fingerprints a whole recording, a segment at a time, keeping the unfinished tail of the audio for the next.
/// A missing segment counts as silence, so the timing of the rest holds.
func fingerprint(_ directory: URL) throws -> (start: Double, frames: [[Float]]) {
    let index = try String(contentsOf: directory.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
    let first = Int(index[0])!, last = Int(index[1])!
    var frames: [[Float]] = []
    var pending: [Float] = []
    for segment in first...last {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(segment).ts")), let info = TS.parse(data),
              let audio = try? Decode.pcm(frames: info.frames) else {
            pending += [Float](repeating: 0, count: samplesPerSegment); continue
        }
        pending += audio.mono
        // Take whole hops, and keep the rest for the next segment.
        let usable = (pending.count - fftLength) / hop * hop
        if usable > 0 {
            frames += IdentFeatures.extract(Array(pending[0..<(usable + fftLength - hop)]), bands: bands, log2n: log2n, hop: hop)
            pending.removeFirst(usable)
        }
    }
    return (HLS.startTime(ofIndex: first).timeIntervalSince1970, frames)
}

/// Slides `reference` along a recording.
///
/// - Parameters:
///   - step: Frames between the windows searched.
///   - threshold: The score that counts as a match.
/// - Returns: The matches, merged so one within 10 s of another keeps the higher score, and every window's best score.
func scan(_ reference: [[Float]], in recording: Recording, step: Int, threshold: Float) -> (matches: [(time: Double, score: Float)], scores: [Float]) {
    var hits: [(time: Double, score: Float)] = [], scores: [Float] = []
    var offset = 0
    while offset + reference.count <= recording.frames.count {
        let window = Array(recording.frames[offset..<min(recording.frames.count, offset + reference.count + step)])
        if let match = IdentMatcher.bestMatch(reference: reference, in: window) {
            scores.append(match.score)
            if match.score >= threshold { hits.append((recording.start + Double(offset + match.offset) / framesPerSecond, match.score)) }
        }
        offset += step
    }
    var merged: [(time: Double, score: Float)] = []
    for hit in hits {
        if let previous = merged.last, hit.time - previous.time < 10 { if hit.score > previous.score { merged[merged.count - 1] = hit } }
        else { merged.append(hit) }
    }
    return (merged, scores.sorted())
}

/// The score at quantile `q` of sorted scores, or 0 if there are none.
func quantile(_ sorted: [Float], _ q: Double) -> Float { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }

/// The frames of `recording` from `from` to `to`, in seconds from its start.
func cut(_ recording: Recording, from: Double, to: Double) -> [[Float]] {
    let low = max(0, Int(from * framesPerSecond)), high = min(recording.frames.count, Int(to * framesPerSecond))
    return low < high ? Array(recording.frames[low..<high]) : []
}

var recordings: [Recording] = []
for argument in CommandLine.arguments.dropFirst() {
    let parts = argument.split(separator: ":")
    let directory = URL(fileURLWithPath: String(parts[0]))
    let starts = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
    let (start, frames) = try fingerprint(directory)
    recordings.append(Recording(name: directory.lastPathComponent, start: start, frames: frames, bulletinStarts: starts))
    print("\(directory.lastPathComponent): \(frames.count) frames, \(starts.count) bulletins")
}

if environment["BOOT"] != nil {
    // Learn as on first play: a 150 s window after every :00 and :30 slot, bulletin or not.
    let heldOut = Set((environment["TEST"] ?? "").split(separator: ",").map(String.init))
    var windows: [[[Float]]] = [], labels: [String] = []
    for recording in recordings where !heldOut.contains(recording.name) {
        var slot = (recording.start / 1800).rounded(.up) * 1800
        while slot + 150 <= recording.start + Double(recording.frames.count) / framesPerSecond {
            windows.append(cut(recording, from: slot - recording.start, to: slot + 150 - recording.start))
            labels.append(iso.string(from: Date(timeIntervalSince1970: slot)))
            slot += 1800
        }
    }
    print("\(windows.count) slot windows: \(labels.joined(separator: ", "))")
    let began = Date()
    guard let reference = IdentMatcher.promote(candidates: windows) else { print("no jingle found"); exit(0) }
    print(String(format: "learned a %d-frame reference in %.1f s", reference.features.count, Date().timeIntervalSince(began)))
    for (label, window) in zip(labels, windows) {
        let match = IdentMatcher.bestMatch(reference: reference.features, in: window)
        let score = match?.score ?? 0
        print("  \(label)  best \(String(format: "%.2f", score)) at +\(String(format: "%.0f", Double(match?.offset ?? 0) / framesPerSecond)) s"
              + (score >= reference.threshold ? "  MATCH" : ""))
    }
    for recording in recordings where heldOut.contains(recording.name) {
        let (matches, scores) = scan(reference.features, in: recording, step: 40, threshold: reference.threshold)
        print("held out \(recording.name): \(matches.count) matches; highest score elsewhere \(String(format: "%.2f", scores.last ?? 0)), "
              + "99.9th \(String(format: "%.2f", quantile(scores, 0.999)))")
        for match in matches { print("  \(iso.string(from: Date(timeIntervalSince1970: match.time)))  \(String(format: "%.2f", match.score))") }
    }
    exit(0)
}

if let spec = environment["REF"] {
    let parts = spec.split(separator: ":")
    guard parts.count == 3, let start = Double(parts[1]), let length = Double(parts[2]),
          let source = recordings.first(where: { $0.name == String(parts[0]) }) else { print("bad REF"); exit(2) }
    let reference = cut(source, from: start - source.start, to: start + length - source.start)
    for recording in recordings {
        let (matches, scores) = scan(reference, in: recording, step: 40, threshold: 0.75)
        print("\n\(recording.name): \(matches.count) matches >= 0.75 (median elsewhere \(String(format: "%.2f", quantile(scores, 0.5))), "
              + "99.9th \(String(format: "%.2f", quantile(scores, 0.999))))")
        for match in matches {
            let nearest = recording.bulletinStarts.map { match.time - $0 }.min(by: { abs($0) < abs($1) })
            print("  \(iso.string(from: Date(timeIntervalSince1970: match.time)))  \(String(format: "%.2f", match.score))"
                  + (nearest.map { String(format: "  (%+.0f s from detected start)", $0) } ?? ""))
        }
    }
    exit(0)
}

if environment["EXPLORE"] != nil {
    // For each pair of bulletins: the best-matching stretch of A within 40 s around B's start.
    var clips: [(label: String, frames: [[Float]])] = []
    for recording in recordings {
        for start in recording.bulletinStarts {
            clips.append((iso.string(from: Date(timeIntervalSince1970: start)),
                          cut(recording, from: start - 25 - recording.start, to: start + 15 - recording.start)))
        }
    }
    let width = Int((Double(environment["WIN"] ?? "6") ?? 6) * framesPerSecond)
    for i in clips.indices {
        for j in clips.indices where j > i {
            var best: (score: Float, inA: Int, inB: Int) = (-1, 0, 0)
            var offset = 0
            while offset + width <= clips[i].frames.count {
                if let match = IdentMatcher.bestMatch(reference: Array(clips[i].frames[offset..<(offset + width)]), in: clips[j].frames),
                   match.score > best.score { best = (match.score, offset, match.offset) }
                offset += max(1, Int(framesPerSecond / 4))
            }
            print(String(format: "%@ vs %@: best %.2f at %+.1f s and %+.1f s from the starts", clips[i].label, clips[j].label, best.score,
                         Double(best.inA) / framesPerSecond - 25, Double(best.inB) / framesPerSecond - 25))
        }
    }
    exit(0)
}

// Candidates: 20 s before to 10 s after each start.
var candidates: [[[Float]]] = []
for recording in recordings {
    for start in recording.bulletinStarts {
        // Only clips that lie wholly inside the recording.
        let low = Int((start - 20 - recording.start) * framesPerSecond), high = Int((start + 10 - recording.start) * framesPerSecond)
        if low >= 0 && high <= recording.frames.count { candidates.append(Array(recording.frames[low..<high])) }
    }
}
print("\n\(candidates.count) candidates")
guard let reference = IdentMatcher.promote(candidates: candidates) else { print("\nno reference: candidates do not agree"); exit(0) }
print("\nreference: \(reference.features.count) frames from agreeing candidates")

// Scan every recording in steps of about 2 s.
for recording in recordings {
    let (matches, scores) = scan(reference.features, in: recording, step: 47, threshold: reference.threshold)
    print("\n\(recording.name): matches >= \(reference.threshold):")
    for match in matches { print("  \(iso.string(from: Date(timeIntervalSince1970: match.time)))  \(String(format: "%.2f", match.score))") }
    if !scores.isEmpty { print(String(format: "  scores elsewhere: median %.2f, 99th percentile %.2f", quantile(scores, 0.5), quantile(scores, 0.99))) }
}
