//  main.swift
//  signoff-check
//
//  Transcribes muted bulletins and reports where the newsreader opens and signs off, to check the phrase lists in
//  NewsTranscript.swift against real broadcasts.
//
//  Usage: signoff-check <recordingDir>:<blockStart>,<blockEnd> ...
//
//  Each argument names a folder made by `record` and a block's start and end as Unix times (from the event log).
//  The audio from 20 s before the block to 10 s after it is transcribed. When the opening or sign-off isn't found,
//  the phrases near the block's start and end are printed, to see what was said instead.
//
//  Environment:
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

    for argument in CommandLine.arguments.dropFirst() {
        let parts = argument.split(separator: ":")
        let times = parts[1].split(separator: ",").compactMap { Double($0) }
        let directory = URL(fileURLWithPath: String(parts[0]))
        let blockStart = times[0], blockEnd = times[1]
        let from = blockStart - 20, to = blockEnd + 10
        var mono: [Float] = []
        let firstSegment = Int(floor(from / segmentDuration)) + 1, lastSegment = Int(floor(to / segmentDuration)) + 1
        for segment in firstSegment...lastSegment {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("\(segment).ts")), let info = TS.parse(data),
               let audio = try Decode.pcm(frames: info.frames) { mono += audio.mono }
        }
        let clipStart = HLS.startTime(ofIndex: firstSegment).timeIntervalSince1970
        let began = Date()
        let phrases = try await transcriber.transcribe(samples: mono, sampleRate: 48000)
        let opening = NewsPhrases.opening(in: phrases).map { clipStart + $0 }
        let signOff = NewsPhrases.signOff(in: phrases, after: (blockStart - clipStart) + 45).map { clipStart + $0 }
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
