import Testing
import Foundation
@testable import InterLudeCore

@Suite struct SpectrumTests {
    private func tone(_ hz: Double, seconds: Double = 1, amplitude: Float = 0.5) -> PCMAudio {
        let n = Int(48000 * seconds)
        let ch = (0..<n).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / 48000)) }
        return PCMAudio(channels: [ch, ch], sampleRate: 48000)
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
