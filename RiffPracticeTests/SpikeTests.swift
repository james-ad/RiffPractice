import Foundation
import CoreData
import SwiftData
import Testing
@testable import RiffPractice

struct SpikeTests {
    @Test func panelSizingKeepsControlsUsableAndRemembersPlacement() {
        #expect(SectionsPanelSizing.width(100) == 280)
        #expect(SectionsPanelSizing.width(300) == 300)
        #expect(SectionsPanelSizing.width(500) == 320)
        #expect(SectionsPanelSizing.width(.nan) == 320)
        #expect(SectionsPanelSizing.items(placement: .left, visible: true, sideBySide: true) == [.sections, .video])
        #expect(SectionsPanelSizing.items(placement: .right, visible: true, sideBySide: true) == [.video, .sections])
        #expect(SectionsPanelSizing.items(placement: .below, visible: true, sideBySide: false) == [.video, .sections])
        #expect(SectionsPanelSizing.items(placement: .left, visible: true, sideBySide: false) == [.video, .sections])
        #expect(SectionsPanelSizing.items(placement: .right, visible: false, sideBySide: true) == [.video])
    }

    @Test func nearbyMarkersRemainIndividuallyReachable() throws {
        let sections = try (0..<12).map { index in
            TimelineSection(id: "marker-\(index)", name: "Part \(index)",
                            range: try #require(LoopRange(start: Double(index), end: Double(index + 1))))
        }
        let groups = TimelineMarkerGroup.arrange(sections, duration: 120, width: 600)
        for endpoint in TimelineEndpoint.allCases {
            let row = groups.filter { $0.endpoint == endpoint }
            #expect(Set(row.flatMap(\.sections).map(\.id)) == Set(sections.map(\.id)))
            let times = row.map(\.time)
            for (first, next) in zip(times, times.dropFirst()) {
                #expect((next - first) * (600 - 48) / 120 >= 44)
            }
        }
        #expect(TimelineEndpoint.start.row < TimelineEndpoint.end.row)
    }

    @Test func videoSizeKeepsItsDefaultAspectAndFitsFullScreen() {
        #expect(VideoViewport.editorHeight(width: 800, scale: 1) == 450)
        #expect(VideoViewport.editorHeight(width: 800, scale: 0) == 292.5)
        let fitted = VideoViewport.fitted(in: CGSize(width: 1200, height: 700))
        #expect(fitted.width == 1200)
        #expect(fitted.height == 675)
        #expect(VideoViewport.fitted(in: CGSize(width: 1200, height: 500)).height == 500)
    }

    @Test func fullScreenControlsStayAvailableWhenPausedOrInteracting() {
        #expect(FullScreenControls.shouldHide(playing: true, pointerOverControls: false, voiceOver: false))
        #expect(!FullScreenControls.shouldHide(playing: false, pointerOverControls: false, voiceOver: false))
        #expect(!FullScreenControls.shouldHide(playing: true, pointerOverControls: true, voiceOver: false))
        #expect(!FullScreenControls.shouldHide(playing: true, pointerOverControls: false, voiceOver: true))
    }

    @Test func pausedLoopCanResumeAtItsCurrentSection() throws {
        let range = try #require(LoopRange(start: 5, end: 10))
        var loop = LoopExperiment(strategy: .seek, range: range)
        loop.beginSeek(at: 0)
        loop.prepareToResume()
        #expect(loop.sample(mediaTime: 7, uptime: 60, isPlaying: true) == nil)
        #expect(loop.sample(mediaTime: 10, uptime: 63, isPlaying: true) == .seekToStart)
    }

    @Test func contiguousSectionsPlayAsOneRangeForBothLoopMethods() throws {
        let intro = try #require(LoopRange(start: 0, end: 5))
        let verse = try #require(LoopRange(start: 5, end: 10))
        let chorus = try #require(LoopRange(start: 9, end: 15))
        for strategy in LoopStrategy.allCases {
            var loop = LoopExperiment(strategy: strategy, range: intro, followingRanges: [verse, chorus])
            #expect(loop.count == 1)
            #expect(loop.range == LoopRange(start: 0, end: 15))
            #expect(loop.sample(mediaTime: 5.04, uptime: 1, isPlaying: true) == nil)
            #expect(loop.sample(mediaTime: 10.04, uptime: 2, isPlaying: true) == nil)
            #expect(loop.sample(mediaTime: 15, uptime: 3, isPlaying: true) == (strategy == .seek ? .seekToStart : nil))
        }
        let separate = try #require(LoopRange(start: 20, end: 24))
        #expect(LoopRange.continuousRanges([separate, verse, intro]).count == 2)
    }

    @Test func draggedEndpointsStayWithinTheVideoAndDoNotCross() throws {
        let range = try #require(LoopRange(start: 5, end: 10))
        #expect(range.movingStart(to: -5, duration: 30)?.start == 0)
        #expect(range.movingStart(to: 15, duration: 30)?.start == 9.95)
        #expect(range.movingEnd(to: 3, duration: 30)?.end == 5.05)
        #expect(range.movingEnd(to: 40, duration: 30)?.end == 30)
        #expect(range.movingStart(to: 6.25, duration: 30) == LoopRange(start: 6.25, end: 10))
    }

    @Test @MainActor func legacyImportPreservesMarkersAndIsSafeToRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldConfiguration = ModelConfiguration(url: directory.appending(path: "old.store"), cloudKitDatabase: .none)
        let legacy = try ModelContainer(for: PracticeRecord.self, configurations: oldConfiguration)
        legacy.mainContext.insert(PracticeRecord(link: "https://youtu.be/M7lc1UVf-VE", name: "Intro", start: 0.5, end: 5, rate: 0.75))
        legacy.mainContext.insert(PracticeRecord(link: "https://youtu.be/M7lc1UVf-VE", name: "Verse", start: 5, end: 12, rate: 0.75))
        try legacy.mainContext.save()
        let original = try legacy.mainContext.fetch(FetchDescriptor<PracticeRecord>())
        let snapshot = LibraryBackup(records: original, titles: ["M7lc1UVf-VE": "My song"])
        let backup = directory.appending(path: "backup.json")
        try snapshot.encoded().write(to: backup)
        let decoded = try JSONDecoder().decode(LibraryBackup.self, from: Data(contentsOf: backup))
        let schema = Schema([PracticeSection.self, VideoSession.self, LibraryImportReceipt.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "new.store"), cloudKitDatabase: .none)
        do {
            let library = try ModelContainer(for: schema, configurations: [configuration])
            try decoded.importOnce(into: library.mainContext)
            try decoded.importOnce(into: library.mainContext)
            let imported = try library.mainContext.fetch(FetchDescriptor<PracticeSection>())
            #expect(imported.count == 2)
            let intro = try #require(imported.first { $0.name == "Intro" })
            intro.start = 1.25
            intro.updatedAt = Date()
            let verse = try #require(imported.first { $0.name == "Verse" })
            verse.removed = true
            verse.updatedAt = Date()
            try library.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        try decoded.importOnce(into: reopened.mainContext)
        let visible = PracticeSection.visible(in: try reopened.mainContext.fetch(FetchDescriptor<PracticeSection>()))
        #expect(visible.map(\.name) == ["Intro"])
        #expect(visible.first?.start == 1.25)
        #expect(visible.first?.end == 5)
        #expect(visible.first?.rate == 0.75)
        let sessions = try reopened.mainContext.fetch(FetchDescriptor<VideoSession>())
        #expect(sessions.first?.title == "My song")
        #expect(sessions.first?.rate == 0.75)
        #expect(try legacy.mainContext.fetchCount(FetchDescriptor<PracticeRecord>()) == 2)
        #expect(original.first { $0.name == "Intro" }?.start == 0.5)
    }

    @Test @MainActor func concurrentCopiesResolveToLatestEditAndDeletion() {
        let original = PracticeSection(link: "https://youtu.be/M7lc1UVf-VE", name: "Intro", start: 0, end: 5, rate: 1)
        let remote = PracticeSection(link: original.link, name: "New name", start: 1, end: 5, rate: 1)
        remote.id = original.id
        original.updatedAt = .distantPast
        remote.updatedAt = Date()
        #expect(PracticeSection.visible(in: [original, remote]).map(\.name) == ["New name"])
        remote.removed = true
        #expect(PracticeSection.visible(in: [original, remote]).isEmpty)
    }

    @Test @MainActor func syncSchemaHasDefaultsAndNoUniqueConstraints() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(
            for: [PracticeSection.self, VideoSession.self, LibraryImportReceipt.self]))
        for entity in model.entities {
            #expect(entity.uniquenessConstraints.isEmpty)
            for attribute in entity.attributesByName.values where !attribute.isOptional {
                #expect(attribute.defaultValue != nil)
            }
        }
    }

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
        let verse = PracticeSection(link: "https://youtu.be/\(videoID)", name: "Verse", start: 8, end: 12, rate: 0.75)
        let intro = PracticeSection(link: "https://www.youtube.com/watch?v=\(videoID)", name: "Intro", start: 0, end: 4, rate: 0.75)
        let records = [verse, intro]

        let before = SavedVideoSession.all(sections: records, titles: [:])
        #expect(before.map(\.title) == ["Intro"])

        let renamed = SavedVideoSession.all(sections: records, titles: [videoID: "Practice song", namedOnlyID: "New session"])
        #expect(renamed.map(\.title) == ["New session", "Practice song"])
        let session = try #require(renamed.first { $0.id == videoID })
        #expect(session.rate == 0.75)
        let reopenedLink = try #require(YouTubeLink.watchURL(for: session.id))
        let restoredMarkers = PracticeSection.sections(for: YouTubeLink.videoID(from: reopenedLink.absoluteString), in: records)
        #expect(restoredMarkers.map(\.name) == ["Intro", "Verse"])
        #expect(restoredMarkers.map(\.start) == [0, 8])
        #expect(restoredMarkers.map(\.end) == [4, 12])
    }
}
