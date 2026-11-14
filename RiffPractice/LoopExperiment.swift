import Foundation

enum LoopStrategy: String, CaseIterable, Identifiable {
    case seek = "Seek at B"
    case bounded = "Replay bounded segment"

    var id: Self { self }
}

struct LoopRange: Equatable {
    let start: Double
    let end: Double

    init?(start: Double, end: Double, duration: Double? = nil) {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              duration.map({ $0.isFinite && end <= $0 }) ?? true
        else { return nil }
        self.start = start
        self.end = end
    }
}

struct LoopExperiment {
    enum Action: Equatable {
        case seekToStart
        case replaySegment
        case restartAfterEnd
        case arrived
        case timedOut
    }

    let strategy: LoopStrategy
    let wholeVideo: Bool
    private let ranges: [LoopRange]
    private(set) var index = 0
    private var seekStartedAt: TimeInterval?
    private var playedSinceLoad = false

    var range: LoopRange { ranges[index] }
    var count: Int { ranges.count }

    init(strategy: LoopStrategy, range: LoopRange, followingRanges: [LoopRange] = [], wholeVideo: Bool = false) {
        self.strategy = strategy
        self.wholeVideo = wholeVideo
        ranges = [range] + followingRanges
    }

    mutating func beginSeek(at uptime: TimeInterval) {
        seekStartedAt = uptime
    }

    mutating func sample(mediaTime: Double, uptime: TimeInterval, isPlaying: Bool, videoDuration: Double? = nil) -> Action? {
        if let seekStartedAt {
            if isPlaying, mediaTime >= max(0, range.start - 2),
               mediaTime < range.end, mediaTime <= range.start + 0.5 {
                self.seekStartedAt = nil
                playedSinceLoad = true
                return .arrived
            }
            if uptime - seekStartedAt > 4 {
                self.seekStartedAt = nil
                return .timedOut
            }
            return nil
        }
        guard isPlaying else { return nil }
        playedSinceLoad = true
        guard strategy == .seek, !wholeVideo, range.end != videoDuration, mediaTime >= range.end else { return nil }
        advance()
        beginSeek(at: uptime)
        return .seekToStart
    }

    mutating func reachedEnd(mediaTime: Double, uptime: TimeInterval) -> Action? {
        guard playedSinceLoad, seekStartedAt == nil else { return nil }
        if strategy == .bounded {
            advance()
            return .replaySegment
        }
        guard wholeVideo || mediaTime >= range.end - 0.25 else { return nil }
        advance()
        beginSeek(at: uptime)
        return .restartAfterEnd
    }

    private mutating func advance() {
        index = (index + 1) % ranges.count
        playedSinceLoad = false
    }
}
