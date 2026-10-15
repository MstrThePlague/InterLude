import Testing
import AVFoundation
@testable import InterLudeCore

@Suite struct SpectrumTests {
    private func tone(_ hz: Double, seconds: Double = 1, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let n = AVAudioFrameCount(48000 * seconds)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        for c in 0..<2 { for i in 0..<Int(n) { b.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / 48000)) } }
        return b
    }

    @Test func frameRateAndWidth() {
        let f = Spectrum.frames(tone(440))
        #expect(abs(f.count - 30) <= 1)
        #expect(f.allSatisfy { $0.count == Spectrum.bands })
    }

    @Test func toneLightsTheRightBand() {
        let low = Spectrum.frames(tone(120))[10], high = Spectrum.frames(tone(6000))[10]
        #expect(low.firstIndex(of: low.max()!)! < high.firstIndex(of: high.max()!)!)
        #expect(low.max()! > 0.5)
    }

    @Test func silenceIsFlat() {
        let f = Spectrum.frames(tone(440, amplitude: 0))
        #expect(f.allSatisfy { $0.max()! == 0 })
    }

    @Test func tapeLooksUpByPlayerTime() {
        let tape = SpectrumTape()
        #expect(tape.claim(100))
        #expect(!tape.claim(100))
        tape.record(100, [[0.1], [0.2], [0.3]])
        tape.record(101, [[0.9]])
        #expect(tape.bands(at: 1.0 / 30)?.first == 0.2)
        #expect(tape.bands(at: segmentDuration + 0.1)?.first == 0.9)
        #expect(tape.bands(at: 2 * segmentDuration + 0.1) == nil)
    }
}
