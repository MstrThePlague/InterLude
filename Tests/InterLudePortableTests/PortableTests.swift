import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import InterLudeCore
@testable import InterLudePortable
import InterLudeHTTP

/// A 440 Hz tone encoded as ADTS AAC by ffmpeg itself, split into frames as a segment carries them.
private func toneFrames(ffmpeg: URL, seconds: Double) throws -> [Data] {
    let p = Process()
    p.executableURL = ffmpeg
    p.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds),pan=stereo|c0=c0|c1=c0",
                   "-c:a", "aac", "-b:a", "128k", "-f", "adts", "pipe:1"]
    let out = Pipe(); p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var frames: [Data] = [], i = data.startIndex
    while i + 7 <= data.endIndex {
        let len = (Int(data[i + 3] & 0x03) << 11) | (Int(data[i + 4]) << 3) | (Int(data[i + 5]) >> 5)
        guard len >= 7, i + len <= data.endIndex else { break }
        frames.append(data[i..<i + len]); i += len
    }
    return frames
}

@Test(.enabled(if: FFmpegDecoder.find() != nil, "needs ffmpeg"))
func ffmpegDecodesADTS() throws {
    let ffmpeg = try #require(FFmpegDecoder.find())
    let frames = try toneFrames(ffmpeg: ffmpeg, seconds: 2)
    #expect(frames.count > 80)
    let pcm = try #require(try FFmpegDecoder(executable: ffmpeg).decode(adts: frames))
    #expect(pcm.sampleRate == 48000)
    #expect(pcm.channels.count == 2)
    #expect(abs(pcm.duration - 2) < 0.1)
    // ffmpeg's sine source has amplitude 1/8, so an RMS of 1/8/√2 away from the encoder's fade-in.
    let middle = pcm.channels[0][24_000..<72_000]
    let rms = (middle.reduce(0) { $0 + $1 * $1 } / Float(middle.count)).squareRoot()
    #expect(abs(rms - Float(0.125 / 2.0.squareRoot())) < 0.01)
}

@Test(.enabled(if: FFmpegDecoder.find() != nil, "needs ffmpeg"))
func ffmpegReportsBadInput() throws {
    let ffmpeg = try #require(FFmpegDecoder.find())
    #expect(throws: FFmpeg.Failure.self) { try FFmpegDecoder(executable: ffmpeg).decode(adts: [Data(repeating: 0x55, count: 400)]) }
    #expect(try FFmpegDecoder(executable: ffmpeg).decode(adts: []) == nil)
}

@Test func interleavedStereoSplits() {
    let samples: [Float] = [0.5, -0.5, 0.25, -0.25, 1]
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let pcm = PCMAudio(interleavedStereo: data, sampleRate: 48000)
    #expect(pcm.channels == [[0.5, 0.25], [-0.5, -0.25]])
}

@Test func serverAnswersGetAndHead() async throws {
    let port = Int.random(in: 20_000..<40_000)
    let running = AsyncStream<Void>.makeStream()
    let server = HTTPServer(host: "127.0.0.1", port: port) { req in
        if req.path == "/host" { return HTTPResponse(contentType: "text/plain", body: Data((req.headers["host"] ?? "none").utf8)) }
        guard req.path == "/stream/live.m3u8" else { return .notFound }
        return HTTPResponse(contentType: "application/vnd.apple.mpegurl", body: Data("#EXTM3U\n\(req.query["x"] ?? "")".utf8), noCache: true)
    }
    let task = Task { try await server.run { running.continuation.yield() } }
    defer { task.cancel() }
    for await _ in running.stream { break }

    let url = URL(string: "http://127.0.0.1:\(port)/stream/live.m3u8?x=7")!
    let (body, response) = try await URLSession.shared.data(from: url)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
    #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    #expect(String(decoding: body, as: UTF8.self) == "#EXTM3U\n7")

    var head = URLRequest(url: url); head.httpMethod = "HEAD"
    let (headBody, headResponse) = try await URLSession.shared.data(for: head)
    #expect((headResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(headBody.isEmpty)

    let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)

    // The Origin check compares against the host, which HTTP/1 sends as a header and NIO hands over as the authority.
    let (host, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/host")!)
    #expect(String(decoding: host, as: UTF8.self) == "127.0.0.1:\(port)")
}

@Test func serverStreamsEvents() async throws {
    let port = Int.random(in: 40_000..<60_000)
    let running = AsyncStream<Void>.makeStream()
    let server = HTTPServer(host: "127.0.0.1", port: port, events: { req in
        guard req.path == "/events" else { return nil }
        return AsyncStream { c in c.yield("data: 1\n\n"); c.yield("data: 2\n\n"); c.finish() }
    }) { _ in .notFound }
    let task = Task { try await server.run { running.continuation.yield() } }
    defer { task.cancel() }
    for await _ in running.stream { break }

    let (body, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/events")!)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
    #expect(String(decoding: body, as: UTF8.self) == "data: 1\n\ndata: 2\n\n")
}
