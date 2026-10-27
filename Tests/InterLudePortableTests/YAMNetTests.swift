import Foundation
import Testing
import InterLudeCore
@testable import InterLudeML

@Test func scoreMapInterpolatesAndClamps() {
    let m = ScoreMap([(0.1, 0), (0.5, 0.8), (0.9, 1)])
    #expect(m.map(0) == 0)
    #expect(abs(m.map(0.3) - 0.4) < 1e-12)
    #expect(abs(m.map(0.7) - 0.9) < 1e-12)
    #expect(m.map(2) == 1)
    #expect(ScoreMap.identity.map(0.42) == 0.42)
}

@Test func framesAverageIntoAppleWindows() {
    // 0.48 s frames over 6.4 s: windows at 0 and 1.5 s and 3 s fit; one at 4.5 s would end past the audio.
    let frames = (0..<12).map { i in (speech: Double(i), music: 1.0) }
    let w = YAMNetClassifier.windows(frames, duration: 6.4)
    #expect(w.map(\.time) == [0, 1.5, 3])
    // The first window holds frames starting at 0 to 1.92 s (indices 0...4): mean 2.
    #expect(w[0].speech == 2)
    #expect(w.allSatisfy { $0.music == 1 })
}

@Test func resamplingKeepsSpeechBandAndDropsHighs() {
    func rms(_ x: [Float]) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
    func tone(_ hz: Double) -> [Float] { (0..<48000).map { Float(sin(2 * .pi * hz * Double($0) / 48000)) } }
    let low = Resample.to16k(tone(1000), from: 48000), high = Resample.to16k(tone(10_000), from: 48000)
    #expect(low.count == 16000)
    #expect(abs(rms(Array(low[200..<15800])) - Float(0.5.squareRoot())) < 0.01)
    #expect(rms(Array(high[200..<15800])) < 0.01)
}

/// Runs the real model when it is in Models/ (scripts/yamnet/convert.sh): a tone isn't speech.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "Models/yamnet.onnx"), "needs Models/yamnet.onnx"))
func yamnetRunsOnAudio() throws {
    let clf = try YAMNetClassifier(directory: URL(fileURLWithPath: "Models"), calibrated: false)
    let samples = (0..<(48000 * 7)).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / 48000)) }
    let scores = try clf.classify([PCMAudio(channels: [samples, samples], sampleRate: 48000)])
    #expect(scores.map(\.time) == [0, 1.5, 3])
    #expect(scores.allSatisfy { $0.speech < 0.2 })
}
