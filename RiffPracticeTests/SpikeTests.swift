import Foundation
import SwiftData
import Testing
@testable import RiffPractice

struct SpikeTests {
    @Test func pastesSupportedVideoLinks() {
        let videoID = "M7lc1UVf-VE"
        #expect(YouTubeLink.videoID(from: " https://www.youtube.com/watch?v=\(videoID)&t=6 ") == videoID)
        #expect(YouTubeLink.videoID(from: "https://youtu.be/\(videoID)?si=demo") == videoID)
        #expect(YouTubeLink.videoID(from: "https://m.youtube.com/shorts/\(videoID)") == videoID)
        #expect(YouTubeLink.videoID(from: "https://youtube.com.example.org/watch?v=\(videoID)") == nil)
        #expect(YouTubeLink.videoID(from: "https://www.youtube.com/watch?v=invalid") == nil)
        #expect(YouTubeLink.videoID(from: "https://www.youtube.com/watch?v=\(videoID)&v=invalid") == nil)
    }

    @Test func validatesLoopBounds() {
        #expect(LoopRange(start: 5, end: 6, duration: 6) != nil)
        #expect(LoopRange(start: 5, end: 5) == nil)
        #expect(LoopRange(start: -.infinity, end: 6) == nil)
        #expect(LoopRange(start: 5, end: .nan) == nil)
        #expect(LoopRange(start: 5, end: 6, duration: 5.9) == nil)
    }

    @Test func seeksOnceUntilPlaybackReturns() throws {
        let range = try #require(LoopRange(start: 5, end: 7))
        var loop = LoopExperiment(strategy: .seek, range: range)
        #expect(loop.sample(mediaTime: 7.1, uptime: 0, isPlaying: false) == nil)
        #expect(loop.sample(mediaTime: 7.1, uptime: 1, isPlaying: true) == .seekToStart)
        #expect(loop.sample(mediaTime: 7.1, uptime: 2, isPlaying: true) == nil)
        #expect(loop.sample(mediaTime: 5, uptime: 2.5, isPlaying: false) == nil)
        #expect(loop.sample(mediaTime: 5, uptime: 3, isPlaying: true) == .arrived)
        #expect(loop.sample(mediaTime: 7, uptime: 4, isPlaying: true) == .seekToStart)
        #expect(loop.sample(mediaTime: 7, uptime: 9, isPlaying: false) == .timedOut)
    }

    @Test func boundedPlaybackOnlyRepeatsAfterPlaying() throws {
        let range = try #require(LoopRange(start: 5, end: 7))
        var loop = LoopExperiment(strategy: .bounded, range: range)
        #expect(loop.reachedEnd(mediaTime: 7, uptime: 0) == nil)
        #expect(loop.sample(mediaTime: 6, uptime: 0, isPlaying: true) == nil)
        #expect(loop.reachedEnd(mediaTime: 7, uptime: 1) == .replaySegment)
        #expect(loop.reachedEnd(mediaTime: 7, uptime: 2) == nil)
    }

    @Test func cyclesThroughSelectedRanges() throws {
        let intro = try #require(LoopRange(start: 0, end: 2))
        let verse = try #require(LoopRange(start: 6, end: 8))
        let solo = try #require(LoopRange(start: 12, end: 16))
        var loop = LoopExperiment(strategy: .seek, range: intro, followingRanges: [verse, solo])
        #expect(loop.sample(mediaTime: 2, uptime: 0, isPlaying: true) == .seekToStart)
        #expect(loop.range == verse)
        #expect(loop.sample(mediaTime: 2, uptime: 0.1, isPlaying: true) == nil)
        #expect(loop.sample(mediaTime: 6, uptime: 0.2, isPlaying: true) == .arrived)
        #expect(loop.sample(mediaTime: 8, uptime: 2.2, isPlaying: true) == .seekToStart)
        #expect(loop.range == solo)
        #expect(loop.sample(mediaTime: 12, uptime: 2.4, isPlaying: true) == .arrived)
        #expect(loop.sample(mediaTime: 16, uptime: 6.3, isPlaying: true, videoDuration: 16) == nil)
        #expect(loop.reachedEnd(mediaTime: 16, uptime: 6.4) == .restartAfterEnd)
        #expect(loop.range == intro)
    }

    @Test func boundedPlaybackAdvancesToTheNextRange() throws {
        let chorus = try #require(LoopRange(start: 4, end: 6))
        let outro = try #require(LoopRange(start: 20, end: 26))
        var loop = LoopExperiment(strategy: .bounded, range: chorus, followingRanges: [outro])
        _ = loop.sample(mediaTime: 5, uptime: 0, isPlaying: true)
        #expect(loop.reachedEnd(mediaTime: 6, uptime: 1) == .replaySegment)
        #expect(loop.range == outro)
        _ = loop.sample(mediaTime: 25, uptime: 5, isPlaying: true)
        #expect(loop.reachedEnd(mediaTime: 26, uptime: 6) == .replaySegment)
        #expect(loop.range == chorus)
    }

    @Test func wholeVideoWaitsForPlaybackToFinish() throws {
        let track = try #require(LoopRange(start: 0, end: 12))
        var loop = LoopExperiment(strategy: .seek, range: track, wholeVideo: true)
        #expect(loop.sample(mediaTime: 12, uptime: 0, isPlaying: true) == nil)
        #expect(loop.reachedEnd(mediaTime: 12, uptime: 1) == .restartAfterEnd)
        #expect(loop.sample(mediaTime: 0, uptime: 2, isPlaying: true) == .arrived)
        #expect(loop.reachedEnd(mediaTime: 12, uptime: 14) == .restartAfterEnd)
    }

    @Test @MainActor func reopensPracticeRecordFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appending(path: "practice.store"))
        let link = "https://youtu.be/M7lc1UVf-VE"
        do {
            let store = try ModelContainer(for: PracticeRecord.self, configurations: configuration)
            store.mainContext.insert(PracticeRecord(link: link, name: "First riff", start: 5.5, end: 7.5, rate: 0.75))
            try store.mainContext.save()
        }
        let store = try ModelContainer(for: PracticeRecord.self, configurations: configuration)
        let records = try store.mainContext.fetch(FetchDescriptor<PracticeRecord>())
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.link == link)
        #expect(record.name == "First riff")
        #expect(record.start == 5.5)
        #expect(record.end == 7.5)
        #expect(record.rate == 0.75)
    }

    @Test @MainActor func persistsMultipleSectionsInSongOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appending(path: "sections.store"))
        do {
            let store = try ModelContainer(for: PracticeRecord.self, configurations: configuration)
            store.mainContext.insert(PracticeRecord(link: "https://youtu.be/M7lc1UVf-VE", name: "Solo", start: 24, end: 30, rate: 1))
            store.mainContext.insert(PracticeRecord(link: "https://www.youtube.com/watch?v=M7lc1UVf-VE", name: "Intro", start: 0, end: 5, rate: 1))
            store.mainContext.insert(PracticeRecord(link: "https://youtu.be/abcdefghijk", name: "Other video", start: 2, end: 4, rate: 1))
            try store.mainContext.save()
        }
        let store = try ModelContainer(for: PracticeRecord.self, configurations: configuration)
        let records = try store.mainContext.fetch(FetchDescriptor<PracticeRecord>())
        let sections = PracticeRecord.sections(for: "M7lc1UVf-VE", in: records)
        #expect(sections.map(\.name) == ["Intro", "Solo"])
        let intro = try #require(sections.first)
        store.mainContext.delete(intro)
        try store.mainContext.save()
        let remaining = try store.mainContext.fetch(FetchDescriptor<PracticeRecord>())
        #expect(PracticeRecord.sections(for: "M7lc1UVf-VE", in: remaining).map(\.name) == ["Solo"])
        #expect(PracticeRecord.sections(for: "abcdefghijk", in: remaining).map(\.name) == ["Other video"])
    }

    @Test @MainActor func sessionNamesLeaveExistingMarkersIntact() throws {
        let videoID = "M7lc1UVf-VE"
        let namedOnlyID = "abcdefghijk"
        let verse = PracticeRecord(link: "https://youtu.be/\(videoID)", name: "Verse", start: 8, end: 12, rate: 0.75)
        let intro = PracticeRecord(link: "https://www.youtube.com/watch?v=\(videoID)", name: "Intro", start: 0, end: 4, rate: 0.75)
        let records = [verse, intro]

        let before = SavedVideoSession.all(sections: records, titles: [:])
        #expect(before.map(\.title) == ["Intro"])

        let renamed = SavedVideoSession.all(sections: records, titles: [videoID: "Practice song", namedOnlyID: "New session"])
        #expect(renamed.map(\.title) == ["New session", "Practice song"])
        let session = try #require(renamed.first { $0.id == videoID })
        #expect(session.rate == 0.75)
        let reopenedLink = try #require(YouTubeLink.watchURL(for: session.id))
        let restoredMarkers = PracticeRecord.sections(for: YouTubeLink.videoID(from: reopenedLink.absoluteString), in: records)
        #expect(restoredMarkers.map(\.name) == ["Intro", "Verse"])
        #expect(restoredMarkers.map(\.start) == [0, 8])
        #expect(restoredMarkers.map(\.end) == [4, 12])
    }
}
