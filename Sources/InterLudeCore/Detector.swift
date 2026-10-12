import Foundation

/// Every number the decision rule uses. Lives in the station profile file, never in code paths.
public struct DetectorConfig: Codable, Sendable, Equatable {
    public var speechThreshold = 0.6
    public var sustainedSpeechSeconds = 20.0
    public var gapSeconds = 8.0
    public var musicThreshold = 0.5
    public var speechCeilingForMusic = 0.5
    public var sustainedMusicSeconds = 5.0
    public var slotMinutes: [Int] = [0, 30]
    /// A bulletin's speech starts from `slotBeforeMinutes` before to `slotAfterMinutes` after a slot minute.
    /// Measured 6 Music starts were 26 to 46 s after the slot; a window of +-4 minutes muted a presenter talking over a song.
    public var slotBeforeMinutes = 1.0
    public var slotAfterMinutes = 3.0
    public var requireSlot = true
    /// Mute only when the news ident matches. Used until a station's speech rule has been checked in shadow mode.
    public var identOnly = false
    public var maxMuteSeconds = 480.0
    public var minBulletinSeconds = 90.0
    public var maxBulletinSeconds = 360.0
    public init() {}

    /// Tolerant decoding: profiles written by older versions keep working, with new fields at their defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ k: Keys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: k) { v = x } }
        get(.speechThreshold, &speechThreshold); get(.sustainedSpeechSeconds, &sustainedSpeechSeconds); get(.gapSeconds, &gapSeconds)
        get(.musicThreshold, &musicThreshold); get(.speechCeilingForMusic, &speechCeilingForMusic); get(.sustainedMusicSeconds, &sustainedMusicSeconds)
        get(.slotMinutes, &slotMinutes); get(.slotBeforeMinutes, &slotBeforeMinutes); get(.slotAfterMinutes, &slotAfterMinutes)
        get(.requireSlot, &requireSlot); get(.identOnly, &identOnly); get(.maxMuteSeconds, &maxMuteSeconds)
        get(.minBulletinSeconds, &minBulletinSeconds); get(.maxBulletinSeconds, &maxBulletinSeconds)
    }
    enum Keys: String, CodingKey {
        case speechThreshold, sustainedSpeechSeconds, gapSeconds, musicThreshold, speechCeilingForMusic, sustainedMusicSeconds
        case slotMinutes, slotBeforeMinutes, slotAfterMinutes, requireSlot, identOnly, maxMuteSeconds, minBulletinSeconds, maxBulletinSeconds
    }
}

/// One classifier window in absolute time (Unix seconds).
public struct ScoreSample: Sendable, Codable, Equatable {
    public var time: Double
    public var duration: Double
    public var speech: Double
    public var music: Double
    public init(time: Double, duration: Double = 3, speech: Double, music: Double) {
        self.time = time; self.duration = duration; self.speech = speech; self.music = music
    }
}

public struct NewsBlock: Sendable, Codable, Equatable, Identifiable {
    public var id = UUID()
    public var start: Double
    public var end: Double?          // nil while open
    public var timedOut = false
    public var doubtful = false
    public var falseStart = false
    public var evidence = ""
    /// The start was moved to the news theme.
    public var anchoredOnIdent = false
    public var isOpen: Bool { end == nil }
    public init(start: Double, end: Double? = nil, evidence: String = "") { self.start = start; self.end = end; self.evidence = evidence }
}

/// Deterministic bulletin detector. Starts are decided quickly; ends wait for music to return.
public struct NewsDetector: Sendable {
    public var config: DetectorConfig
    public private(set) var blocks: [NewsBlock] = []
    private var runStart: Double?
    private var lastSpeech: Double = 0
    private var musicRunStart: Double?
    private var suppressUntilMusic = false
    private var history: [ScoreSample] = []
    private var freshAfter: Double = 0     // speech before this time no longer counts towards a run
    /// After "Not news", speech only counts again once there has been a clear break (music, a jingle, a pause).
    private var awaitingBreak = false
    /// After the newsreader signs off, talk (trails, the presenter) does not start a new block for a while.
    private var openingsPausedUntil: Double = 0
    public private(set) var speechRuns: [(start: Double, end: Double)] = []
    public var trackPlaying: Bool = false      // evidence from the metadata poller

    public init(config: DetectorConfig = DetectorConfig()) { self.config = config }

    public var openBlock: NewsBlock? { blocks.last(where: \.isOpen) }

    func inSlot(_ t: Double) -> Bool {
        guard config.requireSlot else { return true }
        let minute = (t.truncatingRemainder(dividingBy: 3600)) / 60
        return config.slotMinutes.contains { m in
            var d = minute - Double(m)                 // minutes after the slot, wrapped to -30...30
            if d > 30 { d -= 60 } else if d < -30 { d += 60 }
            return d >= -config.slotBeforeMinutes && d <= config.slotAfterMinutes
        }
    }

    /// Feed windows in time order.
    public mutating func ingest(_ s: ScoreSample) {
        history.append(s)
        if history.count > 400 { history.removeFirst(history.count - 400) }     // about 10 minutes
        process(s)
    }

    private mutating func process(_ s: ScoreSample) {
        if awaitingBreak && s.time >= freshAfter && s.speech < 0.4 { awaitingBreak = false }
        let isSpeech = s.speech >= config.speechThreshold && s.time >= freshAfter && !awaitingBreak
        let isMusic = s.music >= config.musicThreshold && s.speech < config.speechCeilingForMusic
        if isMusic { suppressUntilMusic = false }

        if isSpeech {
            if runStart == nil || s.time - lastSpeech > config.gapSeconds { runStart = s.time }
            lastSpeech = s.time + s.duration
            let start = runStart ?? s.time
            if let last = speechRuns.last, abs(last.start - start) < 0.001 { speechRuns[speechRuns.count - 1].end = lastSpeech }
            else { speechRuns.append((start, lastSpeech)); if speechRuns.count > 30 { speechRuns.removeFirst() } }
        } else if let r = runStart, s.time - lastSpeech > config.gapSeconds { _ = r; runStart = nil }

        if let i = blocks.lastIndex(where: \.isOpen) {
            if isMusic { if musicRunStart == nil { musicRunStart = s.time } } else { musicRunStart = nil }
            if let m = musicRunStart, s.time + s.duration - m >= config.sustainedMusicSeconds {
                close(i, at: m + s.duration / 2, timedOut: false, why: "music returned")
            } else if s.time - blocks[i].start > config.maxMuteSeconds {
                close(i, at: s.time, timedOut: true, why: "longest mute reached")
            }
            return
        }
        musicRunStart = nil
        guard !config.identOnly, !suppressUntilMusic, !trackPlaying, s.time >= openingsPausedUntil, let r = runStart, lastSpeech - r >= config.sustainedSpeechSeconds, inSlot(r) else { return }
        blocks.append(NewsBlock(start: r, evidence: "speech>=\(config.speechThreshold) for \(Int(lastSpeech - r))s near a slot"))
    }

    private mutating func close(_ i: Int, at end: Double, timedOut: Bool, why: String) {
        blocks[i].end = end
        blocks[i].timedOut = timedOut
        let len = end - blocks[i].start
        blocks[i].doubtful = len < config.minBulletinSeconds || len > config.maxBulletinSeconds
        blocks[i].evidence += "; closed: \(why), \(Int(len))s"
        runStart = nil; musicRunStart = nil
    }

    /// The news theme was heard at `t` (already moved back to where the theme begins).
    /// Inside a block that speech opened, the start moves to the theme, so the presenter's handover is not muted.
    /// Otherwise it opens a block, without waiting for sustained speech.
    public mutating func identMatch(at t: Double, score: Float) {
        guard inSlot(t) else { return }
        if let i = blocks.lastIndex(where: { !$0.falseStart && abs($0.start - t) <= 120 && ($0.end.map { t < $0 } ?? true) }) {
            guard !blocks[i].anchoredOnIdent else { return }
            blocks[i].evidence += "; start moved \(Int(t - blocks[i].start)) s to the news theme (\(String(format: "%.2f", score)))"
            blocks[i].start = t
            blocks[i].anchoredOnIdent = true
            return
        }
        guard openBlock == nil, !suppressUntilMusic else { return }
        if let last = blocks.last, let e = last.end, t - e < 30 { return }
        var b = NewsBlock(start: t, evidence: "news theme heard (\(String(format: "%.2f", score)))")
        b.anchoredOnIdent = true
        blocks.append(b)
        runStart = nil
    }

    /// The newsreader's opening was heard: like the theme, it marks where the bulletin really starts.
    public mutating func anchorStart(at t: Double, why: String) {
        guard let i = blocks.lastIndex(where: { !$0.falseStart && abs($0.start - t) <= 120 && ($0.end.map { t < $0 } ?? true) }),
              !blocks[i].anchoredOnIdent else { return }
        blocks[i].evidence += "; start moved \(Int(t - blocks[i].start)) s: \(why)"
        blocks[i].start = t
        blocks[i].anchoredOnIdent = true
    }

    /// The newsreader signed off at `t`: the bulletin ends there, even if the presenter talks on.
    /// Talk for the next four minutes does not start another block.
    public mutating func endBlock(at t: Double, why: String) {
        guard let i = blocks.lastIndex(where: { !$0.falseStart && $0.start < t && ($0.end.map { $0 > t } ?? true) }) else { return }
        if blocks[i].isOpen { close(i, at: t, timedOut: false, why: why) }
        else {
            blocks[i].evidence += "; end moved \(Int((blocks[i].end ?? t) - t)) s earlier: \(why)"
            blocks[i].end = t
        }
        openingsPausedUntil = t + 240
    }

    /// "Not news": the block ends at `t`, the point the listener has reached. The detector is already about a delay
    /// ahead of the listener, so audio after `t` is judged again from scratch. Talk that simply carries on stays
    /// unmuted (the listener said it was not news), but after a clear break, such as a jingle or music, sustained
    /// speech can start a new block, so a bulletin that follows presenter chat is still caught.
    public mutating func rejectOpenBlock(at t: Double) {
        guard let i = blocks.lastIndex(where: \.isOpen) else { return }
        blocks[i].falseStart = true
        close(i, at: t, timedOut: false, why: "rejected by user")
        suppressUntilMusic = false
        freshAfter = t
        awaitingBreak = true
        runStart = nil; musicRunStart = nil
        for s in history where s.time >= t { process(s) }
    }

    /// "Wrong" on a recent block.
    public mutating func markFalseStart(id: UUID) {
        if let i = blocks.firstIndex(where: { $0.id == id }) { blocks[i].falseStart = true }
    }

    /// "That was news": the listener has just heard a bulletin that was not muted. The detector is about a delay ahead
    /// of the listener, so look at speech the listener has reached (`listenerTime`), not the newest speech analysed.
    /// Prefers the latest run of at least 30 s, since a bulletin is longer than presenter chat.
    @discardableResult
    public mutating func markNewsHeard(listenerTime: Double) -> NewsBlock? {
        let heard = speechRuns.filter { $0.start <= listenerTime }
        guard let r = heard.last(where: { $0.end - $0.start >= 30 }) ?? heard.last else { return nil }
        let b = NewsBlock(start: r.start, end: r.end, evidence: "marked by user")
        blocks.append(b)
        return b
    }

    /// Whether the audio of the segment [start, start+6.4) should be silenced.
    public func isNews(segmentStart: Double) -> Bool {
        let end = segmentStart + segmentDuration
        return blocks.contains { b in !b.falseStart && b.start < end && (b.end ?? .infinity) > segmentStart }
    }
}
