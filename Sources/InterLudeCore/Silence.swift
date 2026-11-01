//  Silence.swift
//  InterLudeCore
//
//  AAC encoding through the platform's encoder: the silent frames that stand in for a muted bulletin, and the
//  frames of a chosen ambient sound. Also wraps raw AAC frames in the ADTS headers that MPEG-TS segments carry.

import Foundation

/// AAC encoding for replacement segments.
public enum Silence {
    /// Length of one ADTS header without a CRC [bytes].
    static let adtsHeaderLength = 7

    /// One silent AAC-LC frame (1024 samples at 48 kHz, stereo) in raw form, without an ADTS header.
    ///
    /// Twelve frames of silence are encoded and the last is kept, so the encoder's priming frames are past.
    public static func rawFrame() throws -> Data {
        let samples = [Float](repeating: 0, count: 12 * 1024 * 2)
        guard let last = try encode(samples).frames.last else { throw SilenceError.encoder }
        return last
    }

    /// Encodes audio with the installed platform's encoder.
    ///
    /// - Parameters:
    ///   - pcm: Interleaved 48 kHz stereo samples.
    ///   - bitrate: Target bit rate [bit/s].
    /// - Returns: Raw AAC-LC frames, and the encoder's lead-in [samples]: output sample n carries input
    ///   sample n − delay.
    public static func encode(_ pcm: [Float], bitrate: UInt32 = 320_000) throws -> (frames: [Data], delay: Int) {
        try Platform.current.encoder.encode(pcm, bitrate: bitrate)
    }

    /// Wraps a raw AAC frame in an ADTS header.
    ///
    /// - Parameters:
    ///   - raw: The frame's payload.
    ///   - like: An ADTS frame from the station whose profile, sample rate and channel layout are copied, so the
    ///     replacement matches the stream exactly. Without one, AAC-LC at 48 kHz stereo is assumed.
    /// - Returns: The header followed by the payload.
    public static func adts(raw: Data, like: Data?) -> Data {
        var header: [UInt8]
        if let like, like.count >= adtsHeaderLength { header = Array(like.prefix(adtsHeaderLength)) }
        else { header = [0xFF, 0xF1, 0x4C, 0x80, 0, 0x1F, 0xFC] }
        // The 13-bit frame length (header included) straddles bytes 3 to 5; the buffer fullness is set to 0x7FF
        // (variable bit rate), and the frame count to one.
        let length = raw.count + adtsHeaderLength
        header[3] = (header[3] & 0xFC) | UInt8((length >> 11) & 3)
        header[4] = UInt8((length >> 3) & 0xFF)
        header[5] = UInt8(((length & 7) << 5) | 0x1F)
        header[6] = 0xFC
        header[1] |= 0x01                                   // protection absent: no CRC follows
        return Data(header) + raw
    }
}

/// The platform's encoder produced no frames.
public enum SilenceError: Error { case encoder }
