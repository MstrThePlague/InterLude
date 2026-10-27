import Foundation
import Testing
@testable import InterLudeCore
@testable import InterLudePortable

// The silence and ambience paths with ffmpeg's codecs, as interlude-server runs them. Each test sets the platform for
// itself only, since the Apple tests may run alongside in the same process.

private let ffmpeg = FFmpegDecoder.find()
private func portable() -> Platform { .portable(ffmpeg: ffmpeg!) }

@Test(.enabled(if: ffmpeg != nil, "needs ffmpeg"))
func encoderDelayIsWhatItSays() throws {
    try Platform.$scoped.withValue(portable()) {
        var pcm = [Float](repeating: 0, count: 48000 * 2)
        pcm[2 * 10_000] = 0.9; pcm[2 * 10_000 + 1] = 0.9
        let (frames, delay) = try Silence.encode(pcm)
        let back = try #require(try Platform.current.decoder.decode(adts: frames.map { Silence.adts(raw: $0, like: nil) }))
        let peak = back.channels[0].indices.max { abs(back.channels[0][$0]) < abs(back.channels[0][$1]) }!
        #expect(abs(peak - 10_000 - delay) <= 2)
    }
}

@Test(.enabled(if: ffmpeg != nil, "needs ffmpeg"))
func silentFrameDecodesToSilence() throws {
    try Platform.$scoped.withValue(portable()) {
        let frame = Silence.adts(raw: try Silence.rawFrame(), like: nil)
        let back = try #require(try Platform.current.decoder.decode(adts: Array(repeating: frame, count: 50)))
        #expect(back.frameCount == 50 * 1024)
        #expect(back.channels.allSatisfy { $0.allSatisfy { abs($0) < 1e-4 } })
    }
}

@Test(.enabled(if: ffmpeg != nil, "needs ffmpeg"))
func ambienceSegmentsJoinWithFfmpeg() throws {
    try Platform.$scoped.withValue(portable()) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let amb = try Ambience(url: root.appendingPathComponent("Resources/Ambience/ocean.m4a"))
        let i = 270_000_000
        var adts: [Data] = []
        for (k, fi, fo) in [(i, true, false), (i + 1, false, false), (i + 2, false, true)] {
            let frames = try amb.frames(forSegment: k, fadeIn: fi, fadeOut: fo)
            #expect(frames.count == 300)
            adts += frames.map { Silence.adts(raw: $0, like: nil) }
        }
        let back = try #require(try Platform.current.decoder.decode(adts: adts))
        let x = back.channels[0]
        func rms(_ from: Double, _ to: Double) -> Float {
            let a = Int(from * 48000), b = min(x.count, Int(to * 48000))
            return (x[a..<b].reduce(0) { $0 + $1 * $1 } / Float(b - a)).squareRoot()
        }
        let steady = rms(7, 12)
        #expect(steady > 0.01)
        #expect(rms(0, 0.3) < steady * 0.1)
        #expect(rms(18.9, 19.2) < steady * 0.1)
        // Separately encoded segments line up with the loop at one lag, as with Apple's encoder.
        let loopFrames = amb.loop.count / 2
        func snr(_ from: Double, _ to: Double, lag: Int) -> Double {
            var sig = 0.0, err = 0.0
            for j in Int(from * 48000)..<Int(to * 48000) {
                let ref = Double(amb.loop[2 * ((i * 300 * 1024 + j - lag) % loopFrames)])
                sig += ref * ref; err += (Double(x[j]) - ref) * (Double(x[j]) - ref)
            }
            return 10 * log10(sig / err)
        }
        let lag = (-3000...3000).max { snr(8, 8.1, lag: $0) < snr(8, 8.1, lag: $1) }!
        #expect(abs(lag) <= 2)
        #expect(snr(7, 12, lag: lag) > 15)
        #expect(snr(3.5, 6.3, lag: lag) > 15)
        #expect(snr(12.9, 15, lag: lag) > 15)
    }
}
