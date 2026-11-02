//  main.swift
//  signoff-check
//
//  Transcribes muted bulletins and reports where the newsreader opens and signs off, to check the phrase lists in
//  NewsTranscript.swift against real broadcasts.
//
//  Usage: signoff-check <recordingDir>:<blockStart>,<blockEnd> ...
//         signoff-check <recordingDir>:slots ...
//
//  Each argument names a folder made by `record` and a block's start and end as Unix times (from the event log).
//  The audio from 20 s before the block to 10 s after it is transcribed. When the opening or sign-off isn't found,
//  the phrases near the block's start and end are printed, to see what was said instead.
//
//  With `slots`, there is no event log to go by: the audio from a minute before to five minutes after every quarter
//  hour in the recording is transcribed, and the opening, handover and sign-off found there are reported with the
//  whole transcript, for finding a new station's bulletins and wording by reading.
//
//  Environment:
//    STATION=<serviceId>         use that station's news names from Data/stations.json
//    WHISPER=<ggml model file>   transcribe with whisper.cpp, as interlude-server does, instead of Apple's speech model
//    TAIL=<seconds>              how far before the block's end to print phrases when nothing is found (default 40)

import Foundation
import InterLudeCore
import InterLudeApple
import InterLudeML

Platform.install(.apple)

func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    let transcriber: any NewsTranscribing = environment["WHISPER"].map { WhisperTranscriber(model: URL(fileURLWithPath: $0)) }
        ?? NewsTranscriber()
    guard await transcriber.prepare(install: true) else { print("speech model unavailable"); return }
    let tail = Double(environment["TAIL"] ?? "") ?? 40
    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"; clock.timeZone = TimeZone(identifier: "UTC")
    func time(_ seconds: Double) -> String { clock.string(from: Date(timeIntervalSince1970: seconds)) }
    let names = try environment["STATION"].flatMap { try Catalogue.load(from: URL(fileURLWithPath: "Data/stations.json")).station($0)?.newsNames } ?? []

    /// The recording's audio from `from` to `to`, as mono, and the time it starts.
    func audio(_ directory: URL, from: Double, to: Double) throws -> (mono: [Float], start: Double) {
        var mono: [Float] = []
        let firstSegment = Int(floor(from / segmentDuration)) + 1, lastSegment = Int(floor(to / segmentDuration)) + 1
        for segment in firstSegment...lastSegment {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("\(segment).ts")), let info = TS.parse(data),
               let audio = try Decode.pcm(frames: info.frames) { mono += audio.mono }
        }
        return (mono, HLS.startTime(ofIndex: firstSegment).timeIntervalSince1970)
    }

    for argument in CommandLine.arguments.dropFirst() {
        let parts = argument.split(separator: ":")
        let directory = URL(fileURLWithPath: String(parts[0]))
        if parts[1] == "slots" {
            let index = try String(contentsOf: directory.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: " ")
            guard let first = Int(index[0]), let last = Int(index[1]) else { continue }
            let start = HLS.startTime(ofIndex: first).timeIntervalSince1970, end = HLS.startTime(ofIndex: last + 1).timeIntervalSince1970
            var slot = ((start + 60) / 900).rounded(.up) * 900
            while slot + 300 <= end {
                let (mono, clipStart) = try audio(directory, from: slot - 60, to: slot + 300)
                let phrases = try await transcriber.transcribe(samples: mono, sampleRate: 48000)
                let opening = NewsPhrases.opening(in: phrases, names: names), handover = NewsPhrases.handover(in: phrases, names: names)
                let signOff = (opening ?? handover).flatMap { NewsPhrases.signOff(in: phrases, after: $0 + 45, names: names) }
                func at(_ offset: Double?) -> String { offset.map { String(format: "%+.0f s", clipStart + $0 - slot) } ?? "-" }
                print("\nslot \(time(slot)): opening \(at(opening)), handover \(at(handover)), sign-off \(at(signOff))")
                for phrase in phrases { print(String(format: "    %+6.1f  ", clipStart + phrase.start - slot) + phrase.text) }
                slot += 900
            }
            continue
        }
        let times = parts[1].split(separator: ",").compactMap { Double($0) }
        let blockStart = times[0], blockEnd = times[1]
        let from = blockStart - 20, to = blockEnd + 10
        let (mono, clipStart) = try audio(directory, from: from, to: to)
        let began = Date()
        let phrases = try await transcriber.transcribe(samples: mono, sampleRate: 48000)
        let opening = NewsPhrases.opening(in: phrases, names: names).map { clipStart + $0 }
        let signOff = NewsPhrases.signOff(in: phrases, after: (blockStart - clipStart) + 45, names: names).map { clipStart + $0 }
        print("\nblock \(time(blockStart))-\(time(blockEnd)) (\(Int(blockEnd - blockStart)) s), "
              + "transcribed \(Int(to - from)) s in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        print("  opening:  " + (opening.map { "\(time($0))  (\(String(format: "%+.0f", $0 - blockStart)) s from block start)" } ?? "not found"))
        print("  sign-off: " + (signOff.map { "\(time($0))  (\(String(format: "%+.0f", $0 - blockEnd)) s from block end)" } ?? "not found"))
        if signOff == nil || opening == nil {
            for phrase in phrases where clipStart + phrase.start > blockEnd - tail || clipStart + phrase.start < blockStart + 30 {
                print(String(format: "    %+6.1f  ", clipStart + phrase.start - blockStart) + phrase.text)
            }
        }
    }
}
try await run()
