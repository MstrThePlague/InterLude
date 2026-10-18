import Foundation

/// Whether a listed segment is the station's own audio or a replacement (silence or the chosen sound).
public enum SegmentSource: Sendable, Equatable { case station, silence }

public struct ListedSegment: Sendable, Equatable {
    public var index: Int
    public var source: SegmentSource
}

/// Holds the fixed delay and the sliding playlist window. No I/O and no clock of its own: the session ticks it
/// every 6.4 seconds, which keeps it easy to test.
///
/// A muted bulletin is replaced segment for segment, so the delay behind live never changes.
public struct Playout: Sendable {
    public let delaySegments: Int
    public let windowSize: Int
    public let maxMuteSegments: Int
    public private(set) var window: [ListedSegment] = []
    public private(set) var mediaSequence = 0
    public private(set) var next: Int
    private var mutedRun = 0
    public private(set) var log: [String] = []

    public init(liveEdge: Int, delaySeconds: Double, windowSize: Int = 6, maxMuteSeconds: Double = 480) {
        delaySegments = max(1, Int((delaySeconds / segmentDuration).rounded()))
        self.windowSize = windowSize
        maxMuteSegments = Int((maxMuteSeconds / segmentDuration).rounded(.up))
        // The player starts about 3 segments behind the newest one listed, so list 3 segments ahead of the delay.
        next = liveEdge - delaySegments + Playout.headStart - (windowSize - 1)
    }

    /// Segments between the newest listed segment and where a new player starts playing.
    public static let headStart = 3

    /// Lists the next segment. `isNews` is the timeline's verdict using everything known now.
    public mutating func tick(muteNews: Bool, isNews: (Int) -> Bool) -> ListedSegment {
        let wantMute = muteNews && isNews(next)
        var source = SegmentSource.station
        if wantMute {
            // A safety net in case the end of a bulletin is never recognised.
            if mutedRun >= maxMuteSegments { log.append("longest mute reached at \(next)") }
            else { source = .silence; mutedRun += 1 }
        } else { mutedRun = 0 }
        let seg = ListedSegment(index: next, source: source)
        window.append(seg)
        if window.count > windowSize { window.removeFirst(); mediaSequence += 1 }
        next += 1
        return seg
    }

    /// Re-judges segments the player has not fetched yet, after the timeline changed ("Not news", the news theme,
    /// the newsreader's sign-off). Segments already fetched cannot be changed.
    public mutating func refreshPending(from index: Int, isNews: (Int) -> Bool) {
        for i in window.indices where window[i].index >= index { window[i].source = isNews(window[i].index) ? .silence : .station }
    }

    /// Returns and clears anything worth telling the user about.
    public mutating func takeLog() -> [String] { defer { log = [] }; return log }
}

/// One segment of an earlier programme as listed to the player: an output index with continuous timestamps,
/// and the station segment it stands for, played or (when the news could not be skipped yet) replaced with silence.
public struct ReplaySegment: Sendable, Equatable {
    public var out: Int
    public var source: Int
    public var silent: Bool
}

/// A stretch of news cut out of an earlier programme: where the listener meets it, and how much was left out.
public struct Skip: Sendable, Equatable {
    public var out: Int
    public var from: Int
    public var segments: Int
    public var seconds: Double { Double(segments) * segmentDuration }
}

/// The playlist for an earlier programme. It looks like a live stream to the player, ticking in real time, but
/// segments the detector calls news are left out rather than replaced, so the bulletin is skipped.
///
/// A segment can only be skipped once the analysis has passed it (`frontier`), so the detector's verdict is final.
/// If the frontier is in the way (or the programme has caught up with live), news is replaced with silence instead.
public struct ReplayPlayout: Sendable {
    public let windowSize: Int
    public let maxSkipSegments: Int
    public private(set) var window: [ReplaySegment] = []
    public private(set) var mediaSequence = 1
    public private(set) var nextOut = 1
    /// The next station segment to list.
    public private(set) var source: Int
    public private(set) var skips: [Skip] = []
    private var mutedRun = 0
    public private(set) var log: [String] = []

    public init(start: Int, windowSize: Int = 6, maxSkipSeconds: Double = 480) {
        source = start; self.windowSize = windowSize
        maxSkipSegments = Int((maxSkipSeconds / segmentDuration).rounded(.up))
    }

    /// Lists the next segment. `isNews` is the detector's verdict on a station segment; `frontier` the newest one
    /// whose verdict is final.
    public mutating func tick(skipNews: Bool, frontier: Int, isNews: (Int) -> Bool) -> ReplaySegment {
        var silent = false
        if skipNews && isNews(source) {
            var s = source
            while s <= frontier && s - source < maxSkipSegments && isNews(s) { s += 1 }
            if s - source >= maxSkipSegments {
                // A safety net in case the end of a bulletin is never recognised: play it.
                log.append("longest skip reached at \(source)"); mutedRun = 0
            } else if s > frontier {
                // The analysis has not reached the end of the news yet: hold the timeline with silence.
                if mutedRun >= maxSkipSegments { log.append("longest mute reached at \(source)") } else { silent = true; mutedRun += 1 }
            } else {
                skips.append(Skip(out: nextOut, from: source, segments: s - source))
                source = s; mutedRun = 0
            }
        } else { mutedRun = 0 }
        let seg = ReplaySegment(out: nextOut, source: source, silent: silent)
        window.append(seg)
        if window.count > windowSize { window.removeFirst(); mediaSequence += 1 }
        nextOut += 1; source += 1
        return seg
    }

    public mutating func takeLog() -> [String] { defer { log = [] }; return log }
}
