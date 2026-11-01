//  Playout.swift
//  InterLudeCore
//
//  The playlists InterLude serves to the player. Live, it holds a fixed delay behind the station and replaces muted
//  segments one for one, so the delay never drifts. For an earlier programme, it ticks like a live stream but leaves
//  news segments out altogether, so bulletins are skipped. Neither does I/O or keeps a clock of its own: the session
//  ticks them every 6.4 seconds, which keeps them easy to test.

import Foundation

/// Whether a listed segment is the station's own audio or a replacement (silence or the chosen sound).
public enum SegmentSource: Sendable, Equatable { case station, silence }

/// One entry in the live playlist.
public struct ListedSegment: Sendable, Equatable {
    /// The station segment's index.
    public var index: Int
    public var source: SegmentSource
}

/// The live playlist: a fixed delay behind the station and a sliding window of segments.
public struct Playout: Sendable {
    /// Segments between the newest listed segment and where a new player starts playing.
    public static let headStart = 3

    /// The delay behind the live edge [segments].
    public let delaySegments: Int
    /// Segments listed at once.
    public let windowSize: Int
    /// The longest run of muted segments before the station plays again regardless.
    public let maxMuteSegments: Int
    public private(set) var window: [ListedSegment] = []
    public private(set) var mediaSequence = 0
    /// The next station segment to list.
    public private(set) var next: Int
    /// Consecutive segments muted so far.
    private var mutedRun = 0
    /// Things worth telling the listener about, since `takeLog` was last called.
    public private(set) var log: [String] = []

    /// - Parameters:
    ///   - liveEdge: The newest segment the station lists.
    ///   - delaySeconds: How far behind live to play [s].
    ///   - windowSize: Segments listed at once.
    ///   - maxMuteSeconds: The longest a mute may last [s], a safety net in case a bulletin's end is never recognised.
    public init(liveEdge: Int, delaySeconds: Double, windowSize: Int = 6, maxMuteSeconds: Double = 480) {
        delaySegments = max(1, Int((delaySeconds / segmentDuration).rounded()))
        self.windowSize = windowSize
        maxMuteSegments = Int((maxMuteSeconds / segmentDuration).rounded(.up))
        // The player starts `headStart` segments behind the newest one listed, so list that far ahead of the delay.
        next = liveEdge - delaySegments + Playout.headStart - (windowSize - 1)
    }

    /// Lists the next segment.
    ///
    /// - Parameters:
    ///   - muteNews: Whether news is muted at all.
    ///   - isNews: The timeline's verdict on a station segment, using everything known now.
    /// - Returns: The segment just listed.
    public mutating func tick(muteNews: Bool, isNews: (Int) -> Bool) -> ListedSegment {
        var source = SegmentSource.station
        if muteNews && isNews(next) {
            if mutedRun >= maxMuteSegments { log.append("longest mute reached at \(next)") }
            else { source = .silence; mutedRun += 1 }
        } else { mutedRun = 0 }
        let segment = ListedSegment(index: next, source: source)
        window.append(segment)
        if window.count > windowSize { window.removeFirst(); mediaSequence += 1 }
        next += 1
        return segment
    }

    /// Judges again the segments the player has not fetched yet, after the timeline changed ("Not news", the news
    /// theme, the newsreader's sign-off). Segments already fetched cannot be changed.
    ///
    /// - Parameters:
    ///   - index: The first segment not yet fetched.
    ///   - isNews: The timeline's latest verdict.
    public mutating func refreshPending(from index: Int, isNews: (Int) -> Bool) {
        for i in window.indices where window[i].index >= index { window[i].source = isNews(window[i].index) ? .silence : .station }
    }

    /// Returns and clears anything worth telling the listener about.
    public mutating func takeLog() -> [String] { defer { log = [] }; return log }
}

/// One segment of an earlier programme as listed to the player.
public struct ReplaySegment: Sendable, Equatable {
    /// The output index, whose timestamps run on continuously however much news is cut.
    public var out: Int
    /// The station segment it carries.
    public var source: Int
    /// Whether it carries silence in place of news that couldn't be skipped yet.
    public var silent: Bool
}

/// A stretch of news cut out of an earlier programme.
public struct Skip: Sendable, Equatable {
    /// The output segment where the listener meets the cut.
    public var out: Int
    /// The first station segment left out.
    public var from: Int
    /// How many station segments were left out.
    public var segments: Int
    /// [s]
    public var seconds: Double { Double(segments) * segmentDuration }
}

/// The playlist for an earlier programme.
///
/// It looks like a live stream to the player, ticking in real time, but segments the detector calls news are left
/// out rather than replaced, so the bulletin is skipped. A segment can only be skipped once the analysis has passed
/// it (`frontier`), so the detector's verdict is final. If the frontier is in the way, or the programme has caught up
/// with live, news is replaced with silence instead.
public struct ReplayPlayout: Sendable {
    public let windowSize: Int
    /// The longest stretch skipped or muted at once, a safety net in case a bulletin's end is never recognised.
    public let maxSkipSegments: Int
    public private(set) var window: [ReplaySegment] = []
    public private(set) var mediaSequence = 1
    /// The next output index.
    public private(set) var nextOut = 1
    /// The next station segment to list.
    public private(set) var source: Int
    /// Every cut so far, in order.
    public private(set) var skips: [Skip] = []
    /// Consecutive segments replaced with silence so far.
    private var mutedRun = 0
    /// Things worth telling the listener about, since `takeLog` was last called.
    public private(set) var log: [String] = []

    /// - Parameters:
    ///   - start: The first station segment to play.
    ///   - windowSize: Segments listed at once.
    ///   - maxSkipSeconds: The longest stretch to skip or mute at once [s].
    public init(start: Int, windowSize: Int = 6, maxSkipSeconds: Double = 480) {
        source = start; self.windowSize = windowSize
        maxSkipSegments = Int((maxSkipSeconds / segmentDuration).rounded(.up))
    }

    /// Lists the next segment.
    ///
    /// - Parameters:
    ///   - skipNews: Whether news is skipped at all.
    ///   - frontier: The newest station segment whose verdict is final.
    ///   - isNews: The detector's verdict on a station segment.
    /// - Returns: The segment just listed.
    public mutating func tick(skipNews: Bool, frontier: Int, isNews: (Int) -> Bool) -> ReplaySegment {
        var silent = false
        if skipNews && isNews(source) {
            var end = source
            while end <= frontier && end - source < maxSkipSegments && isNews(end) { end += 1 }
            if end - source >= maxSkipSegments {
                // A safety net in case the end of a bulletin is never recognised: play it.
                log.append("longest skip reached at \(source)"); mutedRun = 0
            } else if end > frontier {
                // The analysis has not reached the end of the news yet: hold the timeline with silence.
                if mutedRun >= maxSkipSegments { log.append("longest mute reached at \(source)") } else { silent = true; mutedRun += 1 }
            } else {
                skips.append(Skip(out: nextOut, from: source, segments: end - source))
                source = end; mutedRun = 0
            }
        } else { mutedRun = 0 }
        let segment = ReplaySegment(out: nextOut, source: source, silent: silent)
        window.append(segment)
        if window.count > windowSize { window.removeFirst(); mediaSequence += 1 }
        nextOut += 1; source += 1
        return segment
    }

    /// Returns and clears anything worth telling the listener about.
    public mutating func takeLog() -> [String] { defer { log = [] }; return log }
}
