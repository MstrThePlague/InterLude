import Foundation

/// AAC encoding with the platform's encoder: silent frames for muted segments, and the frames of a chosen sound.
public enum Silence {
    /// One silent AAC-LC frame (1024 samples, 48 kHz, stereo) in raw form, from the platform's encoder.
    public static func rawFrame() throws -> Data {
        guard let last = try encode([Float](repeating: 0, count: 12 * 1024 * 2)).frames.last else { throw SilenceError.encoder }
        return last
    }

    /// Encodes interleaved 48 kHz stereo samples as raw AAC-LC frames. `delay` is the encoder's lead-in in samples:
    /// output sample n carries input sample n - delay.
    public static func encode(_ pcm: [Float], bitrate: UInt32 = 320_000) throws -> (frames: [Data], delay: Int) {
        try Platform.current.encoder.encode(pcm, bitrate: bitrate)
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
