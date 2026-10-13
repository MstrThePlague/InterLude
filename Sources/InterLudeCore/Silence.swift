import Foundation
import AudioToolbox

/// AAC encoding with the system encoder: silent frames for muted segments, and the frames of a chosen sound.
public enum Silence {
    /// One silent AAC-LC frame (1024 samples, 48 kHz, stereo) in raw form, from the system encoder.
    public static func rawFrame() throws -> Data {
        guard let last = try encode([Float](repeating: 0, count: 12 * 1024 * 2)).frames.last else { throw SilenceError.encoder }
        return last
    }

    /// Encodes interleaved 48 kHz stereo samples as raw AAC-LC frames. `delay` is the encoder's lead-in in samples:
    /// output sample n carries input sample n - delay.
    public static func encode(_ pcm: [Float], bitrate: UInt32 = 320_000) throws -> (frames: [Data], delay: Int) {
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

    /// Wraps a raw AAC frame in an ADTS header, copying profile, rate and channels from `like` when given.
    public static func adts(raw: Data, like: Data?) -> Data {
        var h = [UInt8](repeating: 0, count: 7)
        if let like, like.count >= 7 { h = Array(like.prefix(7)) }
        else { h = [0xFF, 0xF1, 0x4C, 0x80, 0, 0x1F, 0xFC] }
        let len = raw.count + 7
        h[3] = (h[3] & 0xFC) | UInt8((len >> 11) & 3)
        h[4] = UInt8((len >> 3) & 0xFF)
        h[5] = UInt8(((len & 7) << 5) | 0x1F)
        h[6] = 0xFC
        h[1] |= 0x01                         // no CRC
        return Data(h) + raw
    }
}

public enum SilenceError: Error { case encoder }
