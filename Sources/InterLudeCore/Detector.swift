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
    public var slotWindowMinutes = 4.0
    public var requireSlot = true
    /// Mute only when the news ident matches. Used until a station's speech rule has been checked in shadow mode.
    public var identOnly = false
    public var maxMuteSeconds = 480.0
    public var minBulletinSeconds = 90.0
    public var maxBulletinSeconds = 360.0
    public init() {}
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
    public var isOpen: Bool { end == nil }
}

/// Deterministic bulletin detector. Starts are decided quickly; ends wait for music to return.
public struct NewsDetector: Sendable {
    public var config: DetectorConfig
    public private(set) var blocks: [NewsBlock] = []
    private var runStart: Double?
    private var lastSpeech: Double = 0
    private var musicRunStart: Double?
    private var suppressUntilMusic = false
    public private(set) var lastSpeechRun: (start: Double, end: Double)?
    public var trackPlaying: Bool = false      // evidence from the metadata poller

    public init(config: DetectorConfig = DetectorConfig()) { self.config = config }

    public var openBlock: NewsBlock? { blocks.last(where: \.isOpen) }

    func inSlot(_ t: Double) -> Bool {
        guard config.requireSlot else { return true }
        let minute = (t.truncatingRemainder(dividingBy: 3600)) / 60
        return config.slotMinutes.contains { m in
            let d = abs(minute - Double(m))
            return min(d, 60 - d) <= config.slotWindowMinutes
        }
    }

    /// Feed windows in time order.
    public mutating func ingest(_ s: ScoreSample) {
        let isSpeech = s.speech >= config.speechThreshold
        let isMusic = s.music >= config.musicThreshold && s.speech < config.speechCeilingForMusic
        if isMusic { suppressUntilMusic = false }

        if isSpeech {
            if runStart == nil || s.time - lastSpeech > config.gapSeconds { runStart = s.time }
            lastSpeech = s.time + s.duration
            lastSpeechRun = (runStart ?? s.time, lastSpeech)
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
        guard !config.identOnly, !suppressUntilMusic, !trackPlaying, let r = runStart, lastSpeech - r >= config.sustainedSpeechSeconds, inSlot(r) else { return }
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

    /// A known news ident was heard: start a block here without waiting for sustained speech.
    public mutating func identMatch(at t: Double, score: Float) {
        guard openBlock == nil, !suppressUntilMusic else { return }
        if let last = blocks.last, let e = last.end, t - e < 30 { return }     // same ident heard again
        blocks.append(NewsBlock(start: t, evidence: "news ident matched (\(String(format: "%.2f", score)))"))
        runStart = nil
    }

    /// "Not news": closes the open block now and holds off reopening until music is heard.
    public mutating func rejectOpenBlock(at t: Double) {
        guard let i = blocks.lastIndex(where: \.isOpen) else { return }
        blocks[i].falseStart = true
        close(i, at: t, timedOut: false, why: "rejected by user")
        suppressUntilMusic = true
    }

    /// "Wrong" on a recent block.
    public mutating func markFalseStart(id: UUID) {
        if let i = blocks.firstIndex(where: { $0.id == id }) { blocks[i].falseStart = true }
    }

    /// "That was news": the latest speech run becomes a block.
    @discardableResult
    public mutating func markLastSpeechAsNews() -> NewsBlock? {
        guard let r = lastSpeechRun else { return nil }
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
