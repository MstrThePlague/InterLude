import Foundation

public enum SegmentSource: Sendable, Equatable { case station, silence }

public struct ListedSegment: Sendable, Equatable {
    public var index: Int
    public var source: SegmentSource
}

/// Holds the fixed delay and the sliding playlist window. No I/O: the caller ticks it every 6.4 seconds.
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
            if mutedRun >= maxMuteSegments { log.append("longest mute reached at \(next)") }
            else { source = .silence; mutedRun += 1 }
        } else { mutedRun = 0 }
        let seg = ListedSegment(index: next, source: source)
        window.append(seg)
        if window.count > windowSize { window.removeFirst(); mediaSequence += 1 }
        next += 1
        return seg
    }

    public func clearingLog() -> Playout { var c = self; c.log = []; return c }

    public var isMuted: Bool { window.last?.source == .silence }
    /// Segments still to be fetched by the player that may be unmuted by "Not news".
    public mutating func unmutePending(from index: Int) {
        for i in window.indices where window[i].index >= index { window[i].source = .station }
        mutedRun = 0
    }
}
