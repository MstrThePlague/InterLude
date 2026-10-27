import Foundation
import Accelerate
import AudioToolbox
import AVFoundation
import SoundAnalysis
import InterLudeCore

extension Platform {
    /// AVFoundation, the system AAC encoder, Apple's sound classifier and speech model, and vDSP.
    public static let apple = Platform(decoder: AppleAudioDecoder(), encoder: AppleAACEncoder(),
                                       makeClassifier: { AppleSoundClassifier() }, makeTranscriber: { NewsTranscriber() },
                                       dsp: AccelerateDSP())
}

extension PCMAudio {
    init(_ buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength), channels = Int(buf.format.channelCount)
        let data = buf.floatChannelData
        self.init(channels: (0..<channels).map { c in data.map { Array(UnsafeBufferPointer(start: $0[c], count: n)) } ?? [] },
                  sampleRate: buf.format.sampleRate)
    }

    /// A deinterleaved float buffer with the same samples.
    func buffer() -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(max(channels.count, 1))),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)),
              let data = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frameCount)
        for (c, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { src in if let base = src.baseAddress { data[c].update(from: base, count: samples.count) } }
        }
        return buf
    }
}

/// Decodes ADTS AAC frames to PCM by round-tripping through a temporary file. AVAudioFile reads ADTS directly,
/// which is simpler and more robust than driving an AudioConverter by hand for decoding.
public struct AppleAudioDecoder: AudioDecoding {
    public init() {}

    public func decode(adts frames: [Data]) throws -> PCMAudio? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("il-\(UUID().uuidString).aac")
        var d = Data(); for f in frames { d.append(f) }
        try d.write(to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forReading: tmp)
        guard file.length > 0 else { return nil }
        return try read(file)
    }

    public func read(contentsOf url: URL) throws -> PCMAudio { try read(AVAudioFile(forReading: url)) }

    private func read(_ file: AVAudioFile) throws -> PCMAudio {
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PlatformError.unavailable("A buffer for \(file.length) samples")
        }
        try file.read(into: buf)
        return PCMAudio(buf)
    }
}

/// AAC-LC encoding with the system encoder.
public struct AppleAACEncoder: AACEncoding {
    public init() {}

    public func encode(_ pcm: [Float], bitrate: UInt32) throws -> (frames: [Data], delay: Int) {
        var inDesc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var outDesc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inDesc, &outDesc, &conv) == noErr, let conv else { throw SilenceError.encoder }
        defer { AudioConverterDispose(conv) }
        var rate = bitrate
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, 4, &rate)
        var prime = AudioConverterPrimeInfo(leadingFrames: 2112, trailingFrames: 0)
        var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        AudioConverterGetProperty(conv, kAudioConverterPrimeInfo, &primeSize, &prime)

        final class Feed {
            let samples: UnsafeMutableBufferPointer<Float>
            var pos = 0                                       // in sample frames
            init(_ pcm: [Float]) { samples = .allocate(capacity: max(pcm.count, 2)); _ = samples.initialize(from: pcm) }
            deinit { samples.deallocate() }
            var frameCount: Int { samples.count / 2 }
        }
        let feed = Feed(pcm)
        var frames: [Data] = []
        var out = [UInt8](repeating: 0, count: 8192)
        while true {
            var packets: UInt32 = 1
            var pd = AudioStreamPacketDescription()
            let status: OSStatus = out.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return withExtendedLifetime(feed) {
                    AudioConverterFillComplexBuffer(conv, { _, ioPackets, ioData, _, userData in
                        guard let userData else { return -1 }
                        let f = Unmanaged<Feed>.fromOpaque(userData).takeUnretainedValue()
                        guard let base = f.samples.baseAddress else { return -1 }
                        let n = min(Int(ioPackets.pointee), f.frameCount - f.pos)
                        ioPackets.pointee = UInt32(max(n, 0))
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = 2
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(max(n, 0) * 8)
                        ioData.pointee.mBuffers.mData = n > 0 ? UnsafeMutableRawPointer(base + f.pos * 2) : nil
                        f.pos += max(n, 0)
                        return noErr                          // zero packets marks the end, so the encoder flushes
                    }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &abl, &pd)
                }
            }
            guard status == noErr, packets > 0 else { break }
            if pd.mDataByteSize > 0 { frames.append(Data(out[Int(pd.mStartOffset)..<Int(pd.mStartOffset) + Int(pd.mDataByteSize)])) }
        }
        guard !frames.isEmpty else { throw SilenceError.encoder }
        return (frames, Int(prime.leadingFrames))
    }
}

/// Runs Apple's built-in sound classifier over a short clip. Windows are 3 s with a 1.5 s hop.
/// (The stream analyzer silently drops buffers when fed faster than real time, so clips go through a file.)
public final class AppleSoundClassifier: NSObject, SoundClassifying, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SoundScore] = []

    public override init() { super.init() }

    public func classify(_ clips: [PCMAudio]) throws -> [SoundScore] {
        let buffers = clips.compactMap { $0.buffer() }
        guard let first = buffers.first else { return [] }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("il-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: first.format.sampleRate,
                                           AVNumberOfChannelsKey: first.format.channelCount, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
            let out = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: first.format.commonFormat, interleaved: false)
            for b in buffers { try out.write(from: b) }
        }
        lock.lock(); results = []; lock.unlock()
        let analyzer = try SNAudioFileAnalyzer(url: tmp)
        try analyzer.add(try SNClassifySoundRequest(classifierIdentifier: .version1), withObserver: self)
        analyzer.analyze()
        lock.lock(); defer { lock.unlock() }
        return results
    }

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let speech = r.classification(forIdentifier: "speech")?.confidence ?? 0
        let music = r.classification(forIdentifier: "music")?.confidence ?? 0
        lock.lock()
        results.append(SoundScore(time: r.timeRange.start.seconds, duration: r.timeRange.duration.seconds, speech: speech, music: music))
        lock.unlock()
    }
}

/// vDSP versions of the DSP kernels. FFT setups are made once per length and shared, which vDSP allows.
public final class AccelerateDSP: DSPKernels, @unchecked Sendable {
    private let lock = NSLock()
    private var setups: [Int: FFTSetup] = [:]

    public init() {}
    deinit { for s in setups.values { vDSP_destroy_fftsetup(s) } }

    private func setup(log2n: Int) -> FFTSetup? {
        lock.lock(); defer { lock.unlock() }
        if let s = setups[log2n] { return s }
        let s = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))
        setups[log2n] = s
        return s
    }

    public func hannWindow(count n: Int) -> [Float] {
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        return w
    }

    public func powerSpectrum(_ frame: [Float], dropNyquist: Bool) -> [Float] {
        let n = frame.count, half = n / 2, log2n = n.trailingZeroBitCount
        guard n >= 2, n & (n - 1) == 0, let setup = setup(log2n: log2n) else { return [] }
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { im in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
            frame.withUnsafeBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
            }
            vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            if dropNyquist { split.imagp[0] = 0 }               // the Nyquist term is packed here
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
        } }
        return power
    }

    public func rowDots(_ a: [Float], _ b: [Float], width d: Int) -> [Float] {
        guard d > 0 else { return [] }
        let m = a.count / d, n = b.count / d
        var bt = [Float](repeating: 0, count: b.count)
        vDSP_mtrans(b, 1, &bt, 1, vDSP_Length(d), vDSP_Length(n))
        var out = [Float](repeating: 0, count: m * n)
        vDSP_mmul(a, 1, bt, 1, &out, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(d))
        return out
    }
}
