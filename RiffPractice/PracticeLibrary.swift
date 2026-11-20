import CloudKit
import CoreData
import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftData

@Model
final class PracticeSection {
    var id: String = UUID().uuidString
    var link: String = ""
    var name: String = ""
    var start: Double = 0
    var end: Double = 0
    var rate: Double = 1
    var updatedAt: Date = Date()
    var removed: Bool = false

    var videoID: String? { YouTubeLink.videoID(from: link) }
    var range: LoopRange? { LoopRange(start: start, end: end) }

    init(link: String, name: String, start: Double, end: Double, rate: Double) {
        self.link = link
        self.name = name
        self.start = start
        self.end = end
        self.rate = rate
    }

    static func visible(in records: [PracticeSection]) -> [PracticeSection] {
        Dictionary(grouping: records, by: \.id).values.compactMap { copies in
            copies.max {
                if $0.updatedAt == $1.updatedAt { return !$0.removed && $1.removed }
                return $0.updatedAt < $1.updatedAt
            }
        }.filter { !$0.removed }
    }

    static func sections(for videoID: String?, in records: [PracticeSection]) -> [PracticeSection] {
        guard let videoID else { return [] }
        return visible(in: records).filter { $0.videoID == videoID }.sorted {
            ($0.start, $0.end, $0.name, $0.id) < ($1.start, $1.end, $1.name, $1.id)
        }
    }
}

@Model
final class VideoSession {
    var videoID: String = ""
    var title: String = ""
    var rate: Double = 1
    var updatedAt: Date = Date()

    init(videoID: String, title: String, rate: Double = 1) {
        self.videoID = videoID
        self.title = title
        self.rate = rate
    }

    static func latest(in sessions: [VideoSession]) -> [String: VideoSession] {
        Dictionary(grouping: sessions, by: \.videoID).compactMapValues {
            $0.max { ($0.updatedAt, $0.title) < ($1.updatedAt, $1.title) }
        }
    }
}

@Model
final class LibraryImportReceipt {
    var fingerprint: String = ""

    init(fingerprint: String) { self.fingerprint = fingerprint }
}

struct LibraryBackup: Codable {
    struct Section: Codable {
        let link: String
        let name: String
        let start: Double
        let end: Double
        let rate: Double
    }

    let sections: [Section]
    let titles: [String: String]

    @MainActor
    init(records: [PracticeRecord], titles: [String: String]) {
        sections = records.sorted { ($0.link, $0.name, $0.start, $0.end, $0.rate) < ($1.link, $1.name, $1.start, $1.end, $1.rate) }
            .map { Section(link: $0.link, name: $0.name, start: $0.start, end: $0.end, rate: $0.rate) }
        self.titles = titles
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    func importOnce(into context: ModelContext) throws {
        let fingerprint = "v2-" + Self.digest(try encoded())
        let receipts = try context.fetch(FetchDescriptor<LibraryImportReceipt>())
        guard !receipts.contains(where: { $0.fingerprint == fingerprint }) else { return }
        let existing = Set(try context.fetch(FetchDescriptor<PracticeSection>()).map(\.id))
        var occurrences: [String: Int] = [:]
        for section in sections {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let key = Self.digest(try encoder.encode(section))
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let id = "legacy-\(key)-\(occurrence)"
            guard !existing.contains(id) else { continue }
            let record = PracticeSection(link: section.link, name: section.name, start: section.start, end: section.end, rate: section.rate)
            record.id = id
            record.updatedAt = .distantPast
            context.insert(record)
        }
        let sessions = VideoSession.latest(in: try context.fetch(FetchDescriptor<VideoSession>()))
        for (videoID, title) in titles {
            let rate = sections.filter { YouTubeLink.videoID(from: $0.link) == videoID }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.first?.rate ?? 1
            if let session = sessions[videoID] {
                if session.updatedAt == .distantPast { session.rate = rate }
            } else {
                let session = VideoSession(videoID: videoID, title: title, rate: rate)
                session.updatedAt = .distantPast
                context.insert(session)
            }
        }
        context.insert(LibraryImportReceipt(fingerprint: fingerprint))
        try context.save()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class PracticeLibrary {
    static let cloudContainerID = "iCloud.com.jamesdunn.riffpractice"
    @ObservationIgnored private let logger = Logger(subsystem: "com.jamesdunn.riffpractice", category: "Library")
    private(set) var container: ModelContainer?
    private(set) var error: String?
    private(set) var syncStatus = "Opening library…"
    private(set) var backupURL: URL?

    var cloudEnabled: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "RiffPracticeCloudSyncEnabled")
        return (value as? Bool) ?? (value as? String).map { ($0 as NSString).boolValue } ?? false
    }

    func open() {
        guard container == nil else { return }
        error = nil
        do {
            let schema = Schema([PracticeSection.self, VideoSession.self, LibraryImportReceipt.self])
            let isTesting = NSClassFromString("XCTestCase") != nil
            if isTesting {
                container = try ModelContainer(for: schema, configurations: [
                    ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                ])
                syncStatus = "Test library"
                return
            }
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
            let configuration = ModelConfiguration(
                "PracticeLibrary", schema: schema, url: directory.appending(path: "PracticeLibrary.store"),
                cloudKitDatabase: cloudEnabled ? .private(Self.cloudContainerID) : .none
            )
            let library = try ModelContainer(for: schema, configurations: [configuration])
            let legacyConfiguration = ModelConfiguration(cloudKitDatabase: .none)
            if FileManager.default.fileExists(atPath: legacyConfiguration.url.path) {
                let legacy = try ModelContainer(for: PracticeRecord.self, configurations: legacyConfiguration)
                let records = try legacy.mainContext.fetch(FetchDescriptor<PracticeRecord>())
                let titles = try UserDefaults.standard.data(forKey: "videoSessionTitles").map {
                    try JSONDecoder().decode([String: String].self, from: $0)
                } ?? [:]
                let archive = LibraryBackup(records: records, titles: titles)
                let backups = directory.appending(path: "Marker Backups", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                let backup = backups.appending(path: "Before iCloud.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try archive.encoded().write(to: backup, options: .atomic)
                }
                backupURL = backup
                try archive.importOnce(into: library.mainContext)
            }
            let count = PracticeSection.visible(in: try library.mainContext.fetch(FetchDescriptor<PracticeSection>())).count
            container = library
            syncStatus = cloudEnabled ? "iCloud enabled · checking account…" : "Saved on this device · iCloud setup required"
            logger.notice("Library opened with \(count) sections. iCloud enabled: \(self.cloudEnabled).")
        } catch {
            self.error = "Could not open your library. \(error.localizedDescription)"
            logger.error("Library open failed: \(error.localizedDescription)")
        }
    }

    func refreshAccount() async {
        guard container != nil, cloudEnabled, NSClassFromString("XCTestCase") == nil else { return }
        do {
            let status = try await CKContainer(identifier: Self.cloudContainerID).accountStatus()
            logger.notice("iCloud account status: \(status.rawValue).")
            switch status {
            case .available: syncStatus = "iCloud enabled · changes sync automatically"
            case .noAccount: syncStatus = "Sign in to iCloud in System Settings to sync"
            case .restricted: syncStatus = "iCloud is restricted on this device"
            case .temporarilyUnavailable: syncStatus = "iCloud temporarily unavailable · changes saved locally"
            default: syncStatus = "iCloud unavailable · changes saved locally"
            }
        } catch {
            syncStatus = "iCloud unavailable · \(error.localizedDescription)"
        }
    }

    func receivedCloudEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
        if let error = event.error {
            syncStatus = "iCloud needs attention · \(error.localizedDescription)"
        } else if event.endDate == nil {
            syncStatus = "Syncing with iCloud…"
        } else if event.type != .setup, event.succeeded {
            syncStatus = "Last iCloud transfer \(event.endDate?.formatted(date: .omitted, time: .shortened) ?? "")"
            logger.notice("iCloud transfer completed. Event type: \(event.type.rawValue).")
        }
    }
}
