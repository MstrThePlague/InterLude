import Foundation

/// Minimal MPEG-TS handling: enough to read the BBC's audio-only segments and to build matching silent ones.
public struct TSSegmentInfo: Sendable {
    public var audioPID: Int
    public var frames: [Data]            // ADTS frames
    public var firstPTS: Int64?
    public var patPacket: Data?
    public var pmtPacket: Data?
}

public enum TS {
    /// Reads one segment: finds the audio stream through the PAT and PMT, joins its PES payloads and splits the
    /// result into ADTS frames. The BBC's frames straddle PES boundaries, so frames are only split after joining.
    public static func parse(_ d: Data) -> TSSegmentInfo? {
        let b = [UInt8](d)
        guard b.count >= 188, b[0] == 0x47 else { return nil }
        var pmtPID = -1, audioPID = -1
        var pat: Data?, pmt: Data?
        var pes = [UInt8](), started = false
        var frames: [Data] = [], firstPTS: Int64?
        var es = [UInt8]()

        func flush() {
            guard started, pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { pes = []; return }
            let hdr = 9 + Int(pes[8])
            if firstPTS == nil, pes[7] & 0x80 != 0, pes.count >= 14 {
                let v = (Int64(pes[9] >> 1) & 7) << 30 | Int64(pes[10]) << 22 | Int64(pes[11] >> 1) << 15 | Int64(pes[12]) << 7 | Int64(pes[13] >> 1)
                firstPTS = v
            }
            if pes.count > hdr { es.append(contentsOf: pes[hdr...]) }
            pes = []
        }

        var off = 0
        while off + 188 <= b.count {
            defer { off += 188 }
            guard b[off] == 0x47 else { continue }
            let pusi = b[off + 1] & 0x40 != 0
            let pid = Int(b[off + 1] & 0x1F) << 8 | Int(b[off + 2])
            let afc = (b[off + 3] >> 4) & 3
            var p = off + 4
            if afc & 2 != 0 { p += 1 + Int(b[off + 4]) }
            let end = off + 188
            if afc & 1 == 0 || p >= end { continue }
            if pid == 0 {
                if pat == nil { pat = Data(b[off..<end]) }
                if pusi, pmtPID < 0 {
                    let q = p + 1 + Int(b[p])      // skip pointer field
                    if q + 12 <= end { pmtPID = Int(b[q + 10] & 0x1F) << 8 | Int(b[q + 11]) }
                }
            } else if pid == pmtPID {
                if pmt == nil { pmt = Data(b[off..<end]) }
                if pusi, audioPID < 0 {
                    let q = p + 1 + Int(b[p])
                    guard q + 12 <= end else { continue }
                    let secLen = Int(b[q + 1] & 0x0F) << 8 | Int(b[q + 2])
                    var r = q + 12 + (Int(b[q + 10] & 0x0F) << 8 | Int(b[q + 11]))
                    let secEnd = min(q + 3 + secLen - 4, end)
                    while r + 5 <= secEnd {
                        let st = b[r], epid = Int(b[r + 1] & 0x1F) << 8 | Int(b[r + 2])
                        if st == 0x0F || st == 0x11 { audioPID = epid; break }
                        r += 5 + (Int(b[r + 3] & 0x0F) << 8 | Int(b[r + 4]))
                    }
                }
            } else if pid == audioPID {
                if pusi { flush(); started = true }
                if started { pes.append(contentsOf: b[p..<end]) }
            }
        }
        flush()
        guard audioPID >= 0 else { return nil }
        // ADTS frames straddle PES boundaries, so split the concatenated elementary stream.
        var i = 0
        while i + 7 <= es.count {
            guard es[i] == 0xFF, es[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let len = (Int(es[i + 3] & 3) << 11) | (Int(es[i + 4]) << 3) | Int(es[i + 5] >> 5)
            guard len >= 7, i + len <= es.count else { break }
            frames.append(Data(es[i..<(i + len)])); i += len
        }
        return TSSegmentInfo(audioPID: audioPID, frames: frames, firstPTS: firstPTS, patPacket: pat, pmtPacket: pmt)
    }

    /// Sets a packet's continuity counter.
    static func setCC(_ packet: Data, _ cc: UInt8) -> Data {
        var p = packet; p[3] = (p[3] & 0xF0) | (cc & 0x0F); return p
    }

    /// The five bytes a PES header uses for a 33-bit timestamp.
    static func ptsBytes(_ pts: Int64, marker: UInt8) -> [UInt8] {
        let v = pts & 0x1_FFFF_FFFF
        return [marker | UInt8((v >> 29) & 0x0E) | 1, UInt8((v >> 22) & 0xFF), UInt8(((v >> 14) & 0xFE) | 1),
                UInt8((v >> 7) & 0xFF), UInt8(((v << 1) & 0xFE) | 1)]
    }

    /// Builds a segment from ADTS frames. `prototype` supplies PAT and PMT packets and the audio PID.
    /// The audio continuity counter starts at 0, as it does in every BBC segment, so joins look normal to a player.
    /// PTS of the first frame is `startPTS`; each frame lasts 1920 ticks of the 90 kHz clock (1024 samples at 48 kHz).
    public static func build(frames: [Data], startPTS: Int64, prototype: TSSegmentInfo, patCC: UInt8, pmtCC: UInt8, framesPerPES: Int = 4) -> Data {
        var out = Data()
        if let pat = prototype.patPacket { out.append(setCC(pat, patCC)) }
        if let pmt = prototype.pmtPacket { out.append(setCC(pmt, pmtCC)) }
        var cc: UInt8 = 0
        var n = 0
        var first = true
        while n < frames.count {
            let group = frames[n..<min(n + framesPerPES, frames.count)]
            let pts = startPTS + Int64(n) * 1920
            var es = Data(); for f in group { es.append(f) }
            var pes = Data([0, 0, 1, 0xC0])
            let plen = 3 + 5 + es.count
            pes.append(contentsOf: [UInt8((plen >> 8) & 0xFF), UInt8(plen & 0xFF), 0x84, 0x80, 0x05])
            pes.append(contentsOf: ptsBytes(pts, marker: 0x20))
            pes.append(es)
            var pos = 0
            var pusi = true
            while pos < pes.count {
                var pkt = Data([0x47, (pusi ? 0x40 : 0) | UInt8((prototype.audioPID >> 8) & 0x1F), UInt8(prototype.audioPID & 0xFF), 0])
                var af = Data()
                if first {            // random access + PCR on the first packet of the segment
                    let pcr = (pts + 1038) & 0x1_FFFF_FFFF
                    af = Data([0x50, UInt8((pcr >> 25) & 0xFF), UInt8((pcr >> 17) & 0xFF), UInt8((pcr >> 9) & 0xFF),
                               UInt8((pcr >> 1) & 0xFF), UInt8(((pcr & 1) << 7) | 0x7E), 0])
                    first = false
                }
                let room = 184 - (af.isEmpty ? 0 : af.count + 1)
                let take = min(room, pes.count - pos)
                if take < room {        // stuff the last packet through an adaptation field
                    let need = room - take
                    if af.isEmpty {
                        af = need == 1 ? Data() : Data([0x00]) + Data(repeating: 0xFF, count: need - 2)
                        pkt[3] = 0x30 | (cc & 0x0F)
                        if need == 1 { pkt.append(0) } else { pkt.append(UInt8(need - 1)); pkt.append(af) }
                    } else {
                        af.append(Data(repeating: 0xFF, count: need))
                        pkt[3] = 0x30 | (cc & 0x0F); pkt.append(UInt8(af.count)); pkt.append(af)
                    }
                } else if !af.isEmpty {
                    pkt[3] = 0x30 | (cc & 0x0F); pkt.append(UInt8(af.count)); pkt.append(af)
                } else {
                    pkt[3] = 0x10 | (cc & 0x0F)
                }
                pkt.append(pes[pos..<(pos + take)])
                assert(pkt.count == 188, "bad packet \(pkt.count)")
                out.append(pkt)
                pos += take; pusi = false; cc = (cc + 1) & 0x0F
            }
            n += group.count
        }
        return out
    }
}
