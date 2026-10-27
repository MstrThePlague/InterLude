import Testing
import Foundation
import AVFoundation
@testable import InterLudeCore
@testable import InterLudeApple

// Tests that need Apple's codecs: the AAC encoder for silence and ambience, and AVFoundation to read the result back.
// Each installs the Apple platform first; every test installs the same one, so the order doesn't matter.

func syntheticPrototype() -> TSSegmentInfo {
    // PAT/PMT shaped like the BBC's: audio on PID 34, PMT on PID 32.
    func pkt(_ pid: Int, _ payload: [UInt8]) -> Data {
        var d = Data([0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10, 0x00]) + Data(payload)
        d.append(Data(repeating: 0xFF, count: 188 - d.count)); return d
    }
    let pat = pkt(0, [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0, 0x20, 0, 0, 0, 0])
    let pmt = pkt(32, [0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0, 0x22, 0xF0, 0x00, 0x0F, 0xE0, 0x22, 0xF0, 0x00, 0, 0, 0, 0])
    return TSSegmentInfo(audioPID: 34, frames: [], firstPTS: nil, patPacket: pat, pmtPacket: pmt)
}

@Test func silentSegmentRoundTrips() throws {
    Platform.install(.apple)
    let raw = try Silence.rawFrame()
    let frame = Silence.adts(raw: raw, like: nil)
    let seg = TS.build(frames: Array(repeating: frame, count: 300), startPTS: 2_323_604_384, prototype: syntheticPrototype(), patCC: 4, pmtCC: 4)
    #expect(seg.count % 188 == 0)
    let info = try #require(TS.parse(seg))
    #expect(info.audioPID == 34)
    #expect(info.frames.count == 300)
    #expect(info.firstPTS == 2_323_604_384)
    try seg.write(to: URL(fileURLWithPath: "/tmp/silent_test.ts"))
}

@Test func ambienceFadesAndJoins() throws {
    Platform.install(.apple)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let amb = try Ambience(url: root.appendingPathComponent("Resources/Ambience/ocean.m4a"))
    // A three-segment mute: fade in, steady, fade out.
    let i = 270_000_000
    var adts = Data()
    for (k, fi, fo) in [(i, true, false), (i + 1, false, false), (i + 2, false, true)] {
        let frames = try amb.frames(forSegment: k, fadeIn: fi, fadeOut: fo)
        #expect(frames.count == 300)
        for f in frames { adts.append(Silence.adts(raw: f, like: nil)) }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ambience_test.aac")
    try adts.write(to: url)
    let file = try AVAudioFile(forReading: url)
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buf)
    let x = buf.floatChannelData![0], n = Int(buf.frameLength)
    func rms(_ from: Double, _ to: Double) -> Float {
        let a = Int(from * 48000), b = min(n, Int(to * 48000))
        var s: Float = 0; for j in a..<b { s += x[j] * x[j] }; return (s / Float(b - a)).squareRoot()
    }
    let steady = rms(7, 12)
    #expect(steady > 0.01)
    #expect(rms(0, 0.3) < steady * 0.1)                  // starts from silence
    #expect(rms(18.9, 19.2) < steady * 0.1)              // ends in silence
    // Separately encoded segments line up: each one matches the source loop at the same lag.
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
    #expect(snr(7, 12, lag: lag) > 15)
    #expect(snr(3.5, 6.3, lag: lag) > 15)                // first segment, after its fade-in
    #expect(snr(12.9, 15, lag: lag) > 15)                // third segment, before its fade-out
}

@Test func silentSegmentsJoinRealOnesWithoutTimestampBreaks() throws {
    Platform.install(.apple)
    let dir = "/Users/ben/Documents/GitHub/InterLude/recordings/6music-a"
    guard let idx = try? String(contentsOfFile: dir + "/index.txt", encoding: .utf8) else { return }
    let first = Int(idx.split(separator: " ")[0])! + 200
    var out = Data()
    var proto: TSSegmentInfo?
    var frame: Data?
    for i in first..<(first + 12) {
        let d = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(i).ts"))
        let info = try #require(TS.parse(d))
        if proto == nil { proto = info; frame = Silence.adts(raw: try Silence.rawFrame(), like: info.frames[0]) }
        if (first + 4..<first + 8).contains(i) {
            let cc = (info.patPacket![3] & 0xF, info.pmtPacket![3] & 0xF)
            out.append(TS.build(frames: Array(repeating: frame!, count: 300), startPTS: info.firstPTS!, prototype: proto!, patCC: cc.0, pmtCC: cc.1))
        } else { out.append(d) }
    }
    try out.write(to: URL(fileURLWithPath: "/tmp/mix.ts"))
}


/// The portable kernels give what vDSP gives, so a jingle learned on one platform matches on another.
@Test func portableDSPMatchesAccelerate() {
    let portable = PortableDSP(), accel = AccelerateDSP()
    for n in [8, 4096] {
        let w = portable.hannWindow(count: n), v = accel.hannWindow(count: n)
        #expect(zip(w, v).allSatisfy { abs($0 - $1) < 1e-5 })
        let frame = (0..<n).map { Float(sin(Double($0) * 0.37) + 0.3 * cos(Double($0) * 1.9)) }
        for drop in [false, true] {
            let p = portable.powerSpectrum(frame, dropNyquist: drop), a = accel.powerSpectrum(frame, dropNyquist: drop)
            let peak = a.max() ?? 1
            #expect(p.count == a.count)
            #expect(zip(p, a).allSatisfy { abs($0 - $1) <= peak * 1e-4 })
        }
    }
    let a: [Float] = (0..<(7 * 5)).map { Float($0 % 11) - 4 }, b: [Float] = (0..<(3 * 5)).map { Float($0 % 7) * 0.5 }
    #expect(portable.rowDots(a, b, width: 5) == accel.rowDots(a, b, width: 5))
}

/// The same audio gives the same jingle features through either set of kernels.
@Test func identFeaturesAgreeAcrossKernels() {
    let samples = (0..<(48000 * 2)).map { Float(sin(Double($0) * (0.01 + 0.000001 * Double($0)))) }
    Platform.install(.apple)
    let viaAccelerate = IdentFeatures.extract(samples)
    var portable = Platform.apple; portable.dsp = PortableDSP()
    Platform.install(portable)
    let viaPortable = IdentFeatures.extract(samples)
    Platform.install(.apple)
    #expect(viaAccelerate.count == viaPortable.count)
    #expect(zip(viaAccelerate, viaPortable).allSatisfy { zip($0, $1).allSatisfy { abs($0 - $1) < 1e-3 } })
}
