import Foundation
import AudioToolbox

public enum Silence {
    /// One silent AAC-LC frame (1024 samples, 48 kHz, stereo) in raw form, from the system encoder.
    public static func rawFrame() throws -> Data {
        var inDesc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var outDesc = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inDesc, &outDesc, &conv) == noErr, let conv else { throw SilenceError.encoder }
        defer { AudioConverterDispose(conv) }
        var bitrate: UInt32 = 320_000
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, 4, &bitrate)

        final class Feed { let zeros = [Float](repeating: 0, count: 2048 * 2) }
        let feed = Feed()
        var last = Data()
        for _ in 0..<12 {
            var packets: UInt32 = 1
            var out = [UInt8](repeating: 0, count: 4096)
            var pd = AudioStreamPacketDescription()
            let status: OSStatus = out.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: raw.baseAddress))
                return withExtendedLifetime(feed) {
                    AudioConverterFillComplexBuffer(conv, { _, ioPackets, ioData, _, userData in
                        let f = Unmanaged<Feed>.fromOpaque(userData!).takeUnretainedValue()
                        ioPackets.pointee = 1024
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = 2
                        ioData.pointee.mBuffers.mDataByteSize = 1024 * 8
                        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: f.zeros.withUnsafeBufferPointer { $0.baseAddress })
                        return noErr
                    }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &abl, &pd)
                }
            }
            if status == noErr, packets > 0, pd.mDataByteSize > 0 {
                last = Data(out[Int(pd.mStartOffset)..<Int(pd.mStartOffset) + Int(pd.mDataByteSize)])
            }
        }
        guard !last.isEmpty else { throw SilenceError.encoder }
        return last
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
