//  TS.swift
//  InterLudeCore
//
//  Minimal MPEG-TS handling: enough to read the BBC's audio-only segments and to build replacement segments that a
//  player can't tell from the real ones. The BBC's segments carry one AAC stream, with a PAT and PMT at the start.

import Foundation

/// What InterLude needs from one segment.
public struct TSSegmentInfo: Sendable {
    /// The packet ID of the audio stream.
    public var audioPID: Int
    /// The segment's ADTS frames, in order.
    public var frames: [Data]
    /// The presentation timestamp of the first frame, on the 90 kHz clock.
    public var firstPTS: Int64?
    /// The segment's PAT packet, reused when building replacements.
    public var patPacket: Data?
    /// The segment's PMT packet, reused when building replacements.
    public var pmtPacket: Data?
}

/// Reading and writing MPEG-TS segments.
public enum TS {
    /// Size of a transport stream packet [bytes].
    static let packetSize = 188
    /// The byte every packet starts with.
    static let syncByte: UInt8 = 0x47
    /// Ticks of the 90 kHz clock in one AAC frame of 1024 samples at 48 kHz.
    static let ticksPerFrame: Int64 = 1920
    /// PTS values wrap at 33 bits.
    static let ptsMask: Int64 = 0x1_FFFF_FFFF

    /// Reads one segment.
    ///
    /// The audio stream is found through the PAT and PMT, its PES payloads are joined, and the result is split into
    /// ADTS frames. The BBC's frames straddle PES boundaries, so frames are only split after joining.
    ///
    /// - Returns: Nil if the data isn't MPEG-TS or has no AAC stream.
    public static func parse(_ data: Data) -> TSSegmentInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= packetSize, bytes[0] == syncByte else { return nil }
        var pmtPID = -1, audioPID = -1
        var pat: Data?, pmt: Data?
        var pes = [UInt8](), pesStarted = false
        var frames: [Data] = [], firstPTS: Int64?
        var elementary = [UInt8]()

        // Moves the payload of the PES packet gathered so far onto the elementary stream, noting the first PTS.
        func flush() {
            guard pesStarted, pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { pes = []; return }
            let headerLength = 9 + Int(pes[8])
            if firstPTS == nil, pes[7] & 0x80 != 0, pes.count >= 14 {
                firstPTS = (Int64(pes[9] >> 1) & 7) << 30 | Int64(pes[10]) << 22 | Int64(pes[11] >> 1) << 15
                    | Int64(pes[12]) << 7 | Int64(pes[13] >> 1)
            }
            if pes.count > headerLength { elementary.append(contentsOf: pes[headerLength...]) }
            pes = []
        }

        var packet = 0
        while packet + packetSize <= bytes.count {
            defer { packet += packetSize }
            guard bytes[packet] == syncByte else { continue }
            let payloadStart = bytes[packet + 1] & 0x40 != 0
            let pid = Int(bytes[packet + 1] & 0x1F) << 8 | Int(bytes[packet + 2])
            let adaptationControl = (bytes[packet + 3] >> 4) & 3
            var payload = packet + 4
            if adaptationControl & 2 != 0 { payload += 1 + Int(bytes[packet + 4]) }       // skip the adaptation field
            let end = packet + packetSize
            if adaptationControl & 1 == 0 || payload >= end { continue }                  // no payload
            if pid == 0 {
                // The PAT names the PMT's packet ID.
                if pat == nil { pat = Data(bytes[packet..<end]) }
                if payloadStart, pmtPID < 0 {
                    let section = payload + 1 + Int(bytes[payload])                        // skip the pointer field
                    if section + 12 <= end { pmtPID = Int(bytes[section + 10] & 0x1F) << 8 | Int(bytes[section + 11]) }
                }
            } else if pid == pmtPID {
                // The PMT lists the streams; the first AAC one (stream type 0x0F, ADTS, or 0x11, LATM) is the audio.
                if pmt == nil { pmt = Data(bytes[packet..<end]) }
                if payloadStart, audioPID < 0 {
                    let section = payload + 1 + Int(bytes[payload])
                    guard section + 12 <= end else { continue }
                    let sectionLength = Int(bytes[section + 1] & 0x0F) << 8 | Int(bytes[section + 2])
                    let programInfoLength = Int(bytes[section + 10] & 0x0F) << 8 | Int(bytes[section + 11])
                    var entry = section + 12 + programInfoLength
                    let sectionEnd = min(section + 3 + sectionLength - 4, end)            // less the CRC
                    while entry + 5 <= sectionEnd {
                        let streamType = bytes[entry], streamPID = Int(bytes[entry + 1] & 0x1F) << 8 | Int(bytes[entry + 2])
                        if streamType == 0x0F || streamType == 0x11 { audioPID = streamPID; break }
                        entry += 5 + (Int(bytes[entry + 3] & 0x0F) << 8 | Int(bytes[entry + 4]))
                    }
                }
            } else if pid == audioPID {
                if payloadStart { flush(); pesStarted = true }
                if pesStarted { pes.append(contentsOf: bytes[payload..<end]) }
            }
        }
        flush()
        guard audioPID >= 0 else { return nil }
        // Split the joined elementary stream into ADTS frames by their length fields.
        var position = 0
        while position + 7 <= elementary.count {
            guard elementary[position] == 0xFF, elementary[position + 1] & 0xF0 == 0xF0 else { position += 1; continue }
            let length = (Int(elementary[position + 3] & 3) << 11) | (Int(elementary[position + 4]) << 3) | Int(elementary[position + 5] >> 5)
            guard length >= 7, position + length <= elementary.count else { break }
            frames.append(Data(elementary[position..<(position + length)])); position += length
        }
        return TSSegmentInfo(audioPID: audioPID, frames: frames, firstPTS: firstPTS, patPacket: pat, pmtPacket: pmt)
    }

    /// Sets a packet's 4-bit continuity counter.
    static func setCC(_ packet: Data, _ counter: UInt8) -> Data {
        var copy = packet; copy[3] = (copy[3] & 0xF0) | (counter & 0x0F); return copy
    }

    /// The five bytes a PES header uses for a 33-bit timestamp, with marker bits.
    ///
    /// - Parameters:
    ///   - pts: The timestamp, on the 90 kHz clock.
    ///   - marker: The prefix nibble: 0x20 for a PTS alone.
    static func ptsBytes(_ pts: Int64, marker: UInt8) -> [UInt8] {
        let value = pts & ptsMask
        return [marker | UInt8((value >> 29) & 0x0E) | 1, UInt8((value >> 22) & 0xFF), UInt8(((value >> 14) & 0xFE) | 1),
                UInt8((value >> 7) & 0xFF), UInt8(((value << 1) & 0xFE) | 1)]
    }

    /// Builds a segment from ADTS frames.
    ///
    /// The audio continuity counter starts at 0, as it does in every BBC segment, so the joins look normal to a
    /// player. The first packet carries a PCR and the random-access flag.
    ///
    /// - Parameters:
    ///   - frames: ADTS frames, each 1024 samples at 48 kHz.
    ///   - startPTS: The first frame's timestamp, on the 90 kHz clock.
    ///   - prototype: A real segment, which supplies the PAT and PMT packets and the audio PID.
    ///   - patCC: The PAT packet's continuity counter.
    ///   - pmtCC: The PMT packet's continuity counter.
    ///   - framesPerPES: Frames in each PES packet.
    public static func build(frames: [Data], startPTS: Int64, prototype: TSSegmentInfo, patCC: UInt8, pmtCC: UInt8, framesPerPES: Int = 4) -> Data {
        var out = Data()
        if let pat = prototype.patPacket { out.append(setCC(pat, patCC)) }
        if let pmt = prototype.pmtPacket { out.append(setCC(pmt, pmtCC)) }
        var continuity: UInt8 = 0
        var written = 0
        var firstPacket = true
        while written < frames.count {
            let group = frames[written..<min(written + framesPerPES, frames.count)]
            let pts = startPTS + Int64(written) * ticksPerFrame
            var elementary = Data(); for frame in group { elementary.append(frame) }
            // PES header: start code, audio stream 0xC0, length, flags (aligned, PTS only), and the PTS.
            var pes = Data([0, 0, 1, 0xC0])
            let pesLength = 3 + 5 + elementary.count
            pes.append(contentsOf: [UInt8((pesLength >> 8) & 0xFF), UInt8(pesLength & 0xFF), 0x84, 0x80, 0x05])
            pes.append(contentsOf: ptsBytes(pts, marker: 0x20))
            pes.append(elementary)
            var position = 0
            var payloadStart = true
            while position < pes.count {
                var packet = Data([syncByte, (payloadStart ? 0x40 : 0) | UInt8((prototype.audioPID >> 8) & 0x1F), UInt8(prototype.audioPID & 0xFF), 0])
                var adaptation = Data()
                if firstPacket {
                    // Random access indicator and a PCR, set slightly ahead of the PTS as in the BBC's segments.
                    let pcr = (pts + 1038) & ptsMask
                    adaptation = Data([0x50, UInt8((pcr >> 25) & 0xFF), UInt8((pcr >> 17) & 0xFF), UInt8((pcr >> 9) & 0xFF),
                                       UInt8((pcr >> 1) & 0xFF), UInt8(((pcr & 1) << 7) | 0x7E), 0])
                    firstPacket = false
                }
                let room = 184 - (adaptation.isEmpty ? 0 : adaptation.count + 1)
                let take = min(room, pes.count - position)
                if take < room {
                    // The last packet: fill the space left with an adaptation field of stuffing bytes.
                    let need = room - take
                    if adaptation.isEmpty {
                        adaptation = need == 1 ? Data() : Data([0x00]) + Data(repeating: 0xFF, count: need - 2)
                        packet[3] = 0x30 | (continuity & 0x0F)
                        if need == 1 { packet.append(0) } else { packet.append(UInt8(need - 1)); packet.append(adaptation) }
                    } else {
                        adaptation.append(Data(repeating: 0xFF, count: need))
                        packet[3] = 0x30 | (continuity & 0x0F); packet.append(UInt8(adaptation.count)); packet.append(adaptation)
                    }
                } else if !adaptation.isEmpty {
                    packet[3] = 0x30 | (continuity & 0x0F); packet.append(UInt8(adaptation.count)); packet.append(adaptation)
                } else {
                    packet[3] = 0x10 | (continuity & 0x0F)                  // payload only
                }
                packet.append(pes[position..<(position + take)])
                assert(packet.count == packetSize, "bad packet \(packet.count)")
                out.append(packet)
                position += take; payloadStart = false; continuity = (continuity + 1) & 0x0F
            }
            written += group.count
        }
        return out
    }
}
