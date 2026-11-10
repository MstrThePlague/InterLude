//  Detector.swift
//  InterLudeCore
//
//  Decides which stretches of audio are news. The classifier scores speech and music every 1.5 s. A bulletin opens
//  when speech is sustained near a bulletin slot, or the news theme or the newsreader's opening is heard, and closes
//  when music returns or the newsreader signs off. The detector runs about a delay ahead of the listener, so it can
//  change its mind before anything is heard, and it is deterministic, so every mute can be explained from the log.

import Foundation

/// Every number the decision rule uses. Lives in the station profile file, never in code paths.
public struct DetectorConfig: Codable, Sendable, Equatable {
    /// Speech score at or above which a window counts as speech.
    public var speechThreshold = 0.6
    /// Speech that must last this long near a slot to open a bulletin [s].
    public var sustainedSpeechSeconds = 20.0
    /// The longest pause that still continues a run of speech [s].
    public var gapSeconds = 8.0
    /// Music score at or above which a window counts as music.
    public var musicThreshold = 0.5
    /// A window only counts as music if its speech score is also below this, since speech over a music bed scores
    /// highly for both.
    public var speechCeilingForMusic = 0.5
    /// Music that must last this long to close a bulletin [s].
    public var sustainedMusicSeconds = 5.0
    /// Minutes past the hour when bulletins start.
    public var slotMinutes: [Int] = [0, 30]
    /// A bulletin's speech may start from `slotBeforeMinutes` before to `slotAfterMinutes` after a slot minute.
    /// Measured 6 Music starts were 26 to 46 s after the slot; a window of ±4 minutes muted a presenter talking over
    /// a song.
    public var slotBeforeMinutes = 1.0
    public var slotAfterMinutes = 3.0
    /// Whether speech must start near a slot. Off, any sustained speech opens a bulletin.
    public var requireSlot = true
    /// Mute only when the news theme matches. Used until a station's speech rule has been checked in shadow mode.
    public var identOnly = false
    /// The longest a mute may last [s], a safety net in case a bulletin's end is never recognised.
    public var maxMuteSeconds = 480.0
    /// Bulletins shorter than this are flagged as doubtful [s].
    public var minBulletinSeconds = 90.0
    /// Bulletins longer than this are flagged as doubtful [s].
    public var maxBulletinSeconds = 360.0
    /// A handover to the news ("here's the news") near a slot opens a bulletin once speech has carried on from it
    /// this long [s].
    public var handoverSpeechSeconds = 10.0

    public init() {}

    /// Decodes tolerantly: profiles written by older versions keep working, with new fields at their defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ key: Keys, _ value: inout T) { if let found = try? container.decodeIfPresent(T.self, forKey: key) { value = found } }
        get(.speechThreshold, &speechThreshold); get(.sustainedSpeechSeconds, &sustainedSpeechSeconds); get(.gapSeconds, &gapSeconds)
        get(.musicThreshold, &musicThreshold); get(.speechCeilingForMusic, &speechCeilingForMusic); get(.sustainedMusicSeconds, &sustainedMusicSeconds)
        get(.slotMinutes, &slotMinutes); get(.slotBeforeMinutes, &slotBeforeMinutes); get(.slotAfterMinutes, &slotAfterMinutes)
        get(.requireSlot, &requireSlot); get(.identOnly, &identOnly); get(.maxMuteSeconds, &maxMuteSeconds)
        get(.minBulletinSeconds, &minBulletinSeconds); get(.maxBulletinSeconds, &maxBulletinSeconds)
        get(.handoverSpeechSeconds, &handoverSpeechSeconds)
    }

    enum Keys: String, CodingKey {
        case speechThreshold, sustainedSpeechSeconds, gapSeconds, musicThreshold, speechCeilingForMusic, sustainedMusicSeconds
        case slotMinutes, slotBeforeMinutes, slotAfterMinutes, requireSlot, identOnly, maxMuteSeconds, minBulletinSeconds, maxBulletinSeconds
        case handoverSpeechSeconds
    }
}

/// One classifier window in absolute time.
public struct ScoreSample: Sendable, Codable, Equatable {
    /// The window's start, on the stream's clock [s since 1970].
    public var time: Double
    /// [s]
    public var duration: Double
    public var speech: Double
    public var music: Double
    public init(time: Double, duration: Double = 3, speech: Double, music: Double) {
        self.time = time; self.duration = duration; self.speech = speech; self.music = music
    }
}

/// A stretch the detector believes is a bulletin.
public struct NewsBlock: Sendable, Codable, Equatable, Identifiable {
    public var id = UUID()
    /// On the stream's clock [s since 1970].
    public var start: Double
    /// Nil while the bulletin is still going.
    public var end: Double?
    /// Closed by the longest-mute safety net rather than by music or a sign-off.
    public var timedOut = false
    /// Its length was outside the usual range, so it isn't learned from.
    public var doubtful = false
    /// Not news after all. Kept for the log, but never muted.
    public var falseStart = false
    /// Why the block opened and closed, in words, for the event log.
    public var evidence = ""
    /// The start was moved to the news theme or the newsreader's opening, so it is exact.
    public var anchoredOnIdent = false
    public var isOpen: Bool { end == nil }
    /// Put right by the listener: "Not news", "Wasn't news" or "News got through".
    public var correctedByHand: Bool { evidence.contains("by user") }
    public init(start: Double, end: Double? = nil, evidence: String = "") { self.start = start; self.end = end; self.evidence = evidence }
}

/// The bulletin detector.
public struct NewsDetector: Sendable {
    /// How far from a block's start a theme or opening may be heard and still belong to that block [s].
    static let anchorReach = 120.0
    /// After a sign-off, talk for this long does not start another block [s].
    static let pauseAfterSignOff = 240.0
    /// Music that must last this long to close a long bulletin, which plays clips of songs between reports [s].
    static let longBulletinMusicSeconds = 30.0
    /// Score windows kept for re-judging after "Not news": about 10 minutes.
    static let historyLength = 400

    public var config: DetectorConfig
    /// The station's long bulletins: near these, a slot opens whatever the minute, and a mute may run their length.
    public var longBulletins: [LongBulletin] = []
    public private(set) var blocks: [NewsBlock] = []
    /// When the current run of speech started, if one is going.
    private var runStart: Double?
    /// The end of the latest speech window.
    private var lastSpeech: Double = 0
    /// When the current run of music started, while a block is open.
    private var musicRunStart: Double?
    private var history: [ScoreSample] = []
    /// Speech before this time no longer counts towards a run.
    private var freshAfter: Double = 0
    /// After "Not news", speech only counts again once there has been a clear break (music, a jingle, a pause).
    private var awaitingBreak = false
    /// After the newsreader signs off, talk (trails, the presenter) does not start a new block until this time.
    private var openingsPausedUntil: Double = 0
    /// A handover to the news heard near a slot, waiting for speech to carry on from it.
    private var pendingHandover: Double?
    /// Recent runs of speech, so "News got through" can find the bulletin the listener just heard.
    public private(set) var speechRuns: [(start: Double, end: Double)] = []

    public init(config: DetectorConfig = DetectorConfig()) { self.config = config }

    /// The block still going, if any.
    public var openBlock: NewsBlock? { blocks.last(where: \.isOpen) }

    /// Whether `time` falls in a bulletin slot: by default from a minute before to three minutes after :00 or :30,
    /// or near one of the station's long bulletins.
    func inSlot(_ time: Double) -> Bool {
        guard config.requireSlot else { return true }
        if longBulletin(near: time) != nil { return true }
        let minute = (time.truncatingRemainder(dividingBy: 3600)) / 60
        return config.slotMinutes.contains { slot in
            var after = minute - Double(slot)               // minutes after the slot, wrapped to −30...30
            if after > 30 { after -= 60 } else if after < -30 { after += 60 }
            return after >= -config.slotBeforeMinutes && after <= config.slotAfterMinutes
        }
    }

    /// UK time, which long bulletins are given in.
    static let ukCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// The long bulletin whose slot `time` falls in, as for any other slot, if any.
    public func longBulletin(near time: Double) -> LongBulletin? {
        guard !longBulletins.isEmpty else { return nil }
        let parts = Self.ukCalendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: time))
        let minute = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        return longBulletins.first { bulletin in
            guard let start = bulletin.minuteOfDay else { return false }
            var after = minute - Double(start)              // minutes after it, wrapped to −720...720
            if after > 720 { after -= 1440 } else if after < -720 { after += 1440 }
            return after >= -config.slotBeforeMinutes && after <= config.slotAfterMinutes
        }
    }

    /// The longest a block starting at `start` may stay muted [s]: the usual limit, or a long bulletin's length
    /// with two minutes to spare.
    public func maxMute(forBlockAt start: Double) -> Double {
        longBulletin(near: start).map { max(config.maxMuteSeconds, $0.minutes * 60 + 120) } ?? config.maxMuteSeconds
    }

    /// The latest real block that a theme or opening heard at `time` belongs to: one that started within
    /// `anchorReach` of it and hadn't ended by then.
    private func blockIndex(around time: Double) -> Int? {
        blocks.lastIndex { !$0.falseStart && abs($0.start - time) <= Self.anchorReach && ($0.end.map { time < $0 } ?? true) }
    }

    /// Takes the next classifier window. Windows must arrive in time order.
    public mutating func ingest(_ sample: ScoreSample) {
        history.append(sample)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        process(sample)
    }

    private mutating func process(_ sample: ScoreSample) {
        if awaitingBreak && sample.time >= freshAfter && sample.speech < 0.4 { awaitingBreak = false }
        let isSpeech = sample.speech >= config.speechThreshold && sample.time >= freshAfter && !awaitingBreak
        let isMusic = sample.music >= config.musicThreshold && sample.speech < config.speechCeilingForMusic

        // Follow runs of speech, bridging pauses up to `gapSeconds`.
        if isSpeech {
            if runStart == nil || sample.time - lastSpeech > config.gapSeconds { runStart = sample.time }
            lastSpeech = sample.time + sample.duration
            let start = runStart ?? sample.time
            if let last = speechRuns.last, abs(last.start - start) < 0.001 { speechRuns[speechRuns.count - 1].end = lastSpeech }
            else { speechRuns.append((start, lastSpeech)); if speechRuns.count > 30 { speechRuns.removeFirst() } }
        } else if runStart != nil, sample.time - lastSpeech > config.gapSeconds { runStart = nil }

        // An open block closes when music has lasted long enough, or when it has gone on too long.
        if let open = blocks.lastIndex(where: \.isOpen) {
            if isMusic { if musicRunStart == nil { musicRunStart = sample.time } } else { musicRunStart = nil }
            let musicNeeded = longBulletin(near: blocks[open].start) != nil
                ? max(config.sustainedMusicSeconds, Self.longBulletinMusicSeconds) : config.sustainedMusicSeconds
            if let musicStart = musicRunStart, sample.time + sample.duration - musicStart >= musicNeeded {
                close(open, at: musicStart + sample.duration / 2, timedOut: false, why: "music returned")
            } else if sample.time - blocks[open].start > maxMute(forBlockAt: blocks[open].start) {
                close(open, at: sample.time, timedOut: true, why: "longest mute reached")
            }
            return
        }

        // Otherwise a handover followed by speech opens one, or sustained speech that started near a slot.
        musicRunStart = nil
        if let cue = pendingHandover, isMusic || sample.time - cue > 60 { pendingHandover = nil }
        if openOnHandover() { return }
        guard !config.identOnly, sample.time >= openingsPausedUntil, let start = runStart,
              lastSpeech - start >= config.sustainedSpeechSeconds, inSlot(start) else { return }
        blocks.append(NewsBlock(start: start, evidence: "speech>=\(config.speechThreshold) for \(Int(lastSpeech - start))s near a slot"))
    }

    private mutating func close(_ index: Int, at end: Double, timedOut: Bool, why: String) {
        blocks[index].end = end
        blocks[index].timedOut = timedOut
        let length = end - blocks[index].start
        let longest = longBulletin(near: blocks[index].start).map { $0.minutes * 60 * 1.3 } ?? config.maxBulletinSeconds
        blocks[index].doubtful = length < config.minBulletinSeconds || length > longest
        blocks[index].evidence += "; closed: \(why), \(Int(length))s"
        runStart = nil; musicRunStart = nil; pendingHandover = nil
    }

    /// The news theme was heard.
    ///
    /// Inside a block that speech opened, the start moves to the theme, so the presenter's handover is not muted.
    /// Otherwise, near a slot, it opens a block without waiting for sustained speech.
    ///
    /// - Parameters:
    ///   - time: Where the theme begins, already moved back by `IdentMatcher.leadSeconds` [s since 1970].
    ///   - score: The match's score, for the log.
    public mutating func identMatch(at time: Double, score: Float) {
        guard inSlot(time) else { return }
        if let index = blockIndex(around: time) {
            guard !blocks[index].anchoredOnIdent else { return }
            blocks[index].evidence += "; start moved \(Int(time - blocks[index].start)) s to the news theme (\(String(format: "%.2f", score)))"
            blocks[index].start = time
            blocks[index].anchoredOnIdent = true
            return
        }
        guard openBlock == nil else { return }
        if let last = blocks.last, let end = last.end, time - end < 30 { return }      // the tail of the last bulletin
        var block = NewsBlock(start: time, evidence: "news theme heard (\(String(format: "%.2f", score)))")
        block.anchoredOnIdent = true
        blocks.append(block)
        runStart = nil
    }

    /// Moves the start of the block around `time` there, as the theme does, unless its start is already exact.
    ///
    /// - Parameters:
    ///   - time: Where the bulletin really starts [s since 1970].
    ///   - why: For the log.
    public mutating func anchorStart(at time: Double, why: String) {
        guard let index = blockIndex(around: time), !blocks[index].anchoredOnIdent else { return }
        blocks[index].evidence += "; start moved \(Int(time - blocks[index].start)) s: \(why)"
        blocks[index].start = time
        blocks[index].anchoredOnIdent = true
    }

    /// The newsreader's opening was heard.
    ///
    /// Inside a block it anchors the start; otherwise, near a slot, it opens one, as the theme does. This catches a
    /// bulletin the presenter talked straight into, where the speech began before the slot and so never counted as
    /// starting near one.
    ///
    /// - Parameter time: Where the opening starts [s since 1970].
    public mutating func newsreaderOpening(at time: Double) {
        if blockIndex(around: time) != nil { anchorStart(at: time, why: "newsreader's opening heard"); return }
        guard inSlot(time), openBlock == nil, !config.identOnly else { return }
        var block = NewsBlock(start: time, evidence: "newsreader's opening heard near a slot")
        block.anchoredOnIdent = true
        blocks.append(block)
        runStart = nil
    }

    /// A presenter's handover to the news was heard, such as "here's the news with …".
    ///
    /// Presenters mention the news for other reasons too, so near a slot this opens a block only once speech has
    /// carried on from it for `handoverSpeechSeconds`, now or as later windows arrive. Like the newsreader's opening,
    /// it catches a presenter talking straight into the bulletin. The block's start is not taken as exact, so once the
    /// station's theme is known, a block with neither theme nor opening is still released as presenter talk.
    ///
    /// - Parameter time: Where the handover starts [s since 1970].
    public mutating func newsHandover(at time: Double) {
        guard inSlot(time), openBlock == nil, !config.identOnly, !awaitingBreak, time >= openingsPausedUntil else { return }
        if let last = blocks.last, let end = last.end, time - end < 30 { return }      // the tail of the last bulletin
        pendingHandover = time
        openOnHandover()
    }

    /// Opens a block at the pending handover if speech has carried on from it long enough.
    @discardableResult
    private mutating func openOnHandover() -> Bool {
        guard let cue = pendingHandover, openBlock == nil, let start = runStart, start <= cue + config.gapSeconds,
              lastSpeech - cue >= config.handoverSpeechSeconds else { return false }
        blocks.append(NewsBlock(start: cue, evidence: "handover to the news heard near a slot, then speech for \(Int(lastSpeech - cue))s"))
        pendingHandover = nil
        runStart = nil
        return true
    }

    /// The newsreader signed off: the bulletin ends there, even if the presenter talks on, and talk for the next
    /// `pauseAfterSignOff` seconds does not start another block.
    ///
    /// - Parameters:
    ///   - time: The end of the sign-off [s since 1970].
    ///   - why: For the log.
    public mutating func endBlock(at time: Double, why: String) {
        guard let index = blocks.lastIndex(where: { !$0.falseStart && $0.start < time && ($0.end.map { $0 > time } ?? true) }) else { return }
        if blocks[index].isOpen { close(index, at: time, timedOut: false, why: why) }
        else {
            blocks[index].evidence += "; end moved \(Int((blocks[index].end ?? time) - time)) s earlier: \(why)"
            blocks[index].end = time
        }
        openingsPausedUntil = time + Self.pauseAfterSignOff
    }

    /// "Not news": the open block ends where the listener has reached.
    ///
    /// The detector is already about a delay ahead of the listener, so audio after `time` is judged again from
    /// scratch. Talk that simply carries on stays unmuted (the listener said it was not news), but after a clear
    /// break, such as a jingle or music, sustained speech can start a new block, so a bulletin that follows
    /// presenter chat is still caught.
    ///
    /// - Parameters:
    ///   - time: Where the listener has reached [s since 1970].
    ///   - why: For the log.
    public mutating func rejectOpenBlock(at time: Double, why: String = "rejected by user") {
        guard let index = blocks.lastIndex(where: \.isOpen) else { return }
        blocks[index].falseStart = true
        close(index, at: time, timedOut: false, why: why)
        freshAfter = time
        awaitingBreak = true
        runStart = nil; musicRunStart = nil
        for sample in history where sample.time >= time { process(sample) }
    }

    /// "Wasn't news" on a recent block.
    public mutating func markFalseStart(id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), !blocks[index].falseStart else { return }
        blocks[index].falseStart = true
        blocks[index].evidence += "; marked wrong by user"
    }

    /// "News got through": the listener has just heard a bulletin that was not muted.
    ///
    /// The detector is about a delay ahead of the listener, so this looks at speech the listener has reached, not the
    /// newest speech analysed, and prefers the latest run of at least 30 s, since a bulletin is longer than chat.
    ///
    /// - Parameter listenerTime: What the listener is hearing now [s since 1970].
    /// - Returns: The block added, or nil if no speech has been heard.
    @discardableResult
    public mutating func markNewsHeard(listenerTime: Double) -> NewsBlock? {
        let heard = speechRuns.filter { $0.start <= listenerTime }
        guard let run = heard.last(where: { $0.end - $0.start >= 30 }) ?? heard.last else { return nil }
        let block = NewsBlock(start: run.start, end: run.end, evidence: "marked by user")
        blocks.append(block)
        return block
    }

    /// Whether the segment starting at `segmentStart` overlaps any real block, and so should be silenced.
    ///
    /// - Parameter segmentStart: On the stream's clock [s since 1970].
    public func isNews(segmentStart: Double) -> Bool {
        let end = segmentStart + segmentDuration
        return blocks.contains { !$0.falseStart && $0.start < end && ($0.end ?? .infinity) > segmentStart }
    }
}
