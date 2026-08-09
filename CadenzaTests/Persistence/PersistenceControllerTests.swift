import Testing
import Foundation
import SwiftData
@testable import Cadenza

/// Tests persistence logic using in-memory SwiftData containers.
/// Uses fetch-all + in-memory filter to avoid #Predicate macro issues.
@Suite("Persistence", .serialized)
struct PersistenceTests {

    @MainActor
    private func makeContext() throws -> ModelContext {
        try TestPersistence.makeFreshContext()
    }

    private func allRecordings(_ ctx: ModelContext) throws -> [Recording] {
        try ctx.fetch(FetchDescriptor<Recording>())
    }

    private func activeRecordings(_ ctx: ModelContext) throws -> [Recording] {
        try allRecordings(ctx).filter { $0.trashedDate == nil }
    }

    private func trashedRecordings(_ ctx: ModelContext) throws -> [Recording] {
        try allRecordings(ctx).filter { $0.trashedDate != nil }
    }

    // MARK: - Basic CRUD

    @MainActor @Test func insertAndFetchRecording() throws {
        let ctx = try makeContext()
        let r = TestRecordingFactory.makeRecording(title: "Test")
        ctx.insert(r)
        try ctx.save()

        let result = try allRecordings(ctx).first { $0.id == r.id }
        #expect(result != nil)
        #expect(result?.title == "Test")
    }

    @MainActor @Test func fetchNonexistentRecording() throws {
        let ctx = try makeContext()
        let result = try allRecordings(ctx).first { $0.id == UUID() }
        #expect(result == nil)
    }

    @MainActor @Test func insertAndFetchFolder() throws {
        let ctx = try makeContext()
        let f = TestRecordingFactory.makeFolder(name: "Work")
        ctx.insert(f)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Folder>()).first
        #expect(fetched?.name == "Work")
    }

    @MainActor @Test func allFoldersSorted() throws {
        let ctx = try makeContext()
        ctx.insert(Folder(name: "B", icon: "b", sortOrder: 2))
        ctx.insert(Folder(name: "A", icon: "a", sortOrder: 1))
        ctx.insert(Folder(name: "C", icon: "c", sortOrder: 3))
        try ctx.save()

        let folders = try ctx.fetch(FetchDescriptor<Folder>()).sorted { $0.sortOrder < $1.sortOrder }
        #expect(folders.count == 3)
        #expect(folders[0].name == "A")
        #expect(folders[1].name == "B")
        #expect(folders[2].name == "C")
    }

    // MARK: - Sorting

    @MainActor @Test func sortByDateNewest() throws {
        let ctx = try makeContext()
        ctx.insert(TestRecordingFactory.makeRecording(title: "Old", startDate: Date(timeIntervalSinceReferenceDate: 100)))
        ctx.insert(TestRecordingFactory.makeRecording(title: "New", startDate: Date(timeIntervalSinceReferenceDate: 200)))
        try ctx.save()

        let sorted = try activeRecordings(ctx).sorted { $0.startDate > $1.startDate }
        #expect(sorted[0].title == "New")
        #expect(sorted[1].title == "Old")
    }

    @MainActor @Test func sortByDateOldest() throws {
        let ctx = try makeContext()
        ctx.insert(TestRecordingFactory.makeRecording(title: "Old", startDate: Date(timeIntervalSinceReferenceDate: 100)))
        ctx.insert(TestRecordingFactory.makeRecording(title: "New", startDate: Date(timeIntervalSinceReferenceDate: 200)))
        try ctx.save()

        let sorted = try activeRecordings(ctx).sorted { $0.startDate < $1.startDate }
        #expect(sorted[0].title == "Old")
        #expect(sorted[1].title == "New")
    }

    @MainActor @Test func sortByNameAZ() throws {
        let ctx = try makeContext()
        ctx.insert(TestRecordingFactory.makeRecording(title: "Zebra"))
        ctx.insert(TestRecordingFactory.makeRecording(title: "Apple"))
        try ctx.save()

        let sorted = try activeRecordings(ctx).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        #expect(sorted[0].title == "Apple")
        #expect(sorted[1].title == "Zebra")
    }

    @MainActor @Test func sortByNameZA() throws {
        let ctx = try makeContext()
        ctx.insert(TestRecordingFactory.makeRecording(title: "Apple"))
        ctx.insert(TestRecordingFactory.makeRecording(title: "Zebra"))
        try ctx.save()

        let sorted = try activeRecordings(ctx).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        #expect(sorted[0].title == "Zebra")
        #expect(sorted[1].title == "Apple")
    }

    @MainActor @Test func sortByRecentlyAccessed() throws {
        let ctx = try makeContext()
        let r1 = TestRecordingFactory.makeRecording(title: "Old access")
        r1.lastAccessedDate = Date(timeIntervalSinceReferenceDate: 100)
        let r2 = TestRecordingFactory.makeRecording(title: "Recent access")
        r2.lastAccessedDate = Date(timeIntervalSinceReferenceDate: 200)
        let r3 = TestRecordingFactory.makeRecording(title: "No access")
        ctx.insert(r1)
        ctx.insert(r2)
        ctx.insert(r3)
        try ctx.save()

        let sorted = try activeRecordings(ctx).sorted { ($0.lastAccessedDate ?? .distantPast) > ($1.lastAccessedDate ?? .distantPast) }
        #expect(sorted[0].title == "Recent access")
    }

    // MARK: - Filtering

    @MainActor @Test func filterByFolder() throws {
        let ctx = try makeContext()
        let folder = TestRecordingFactory.makeFolder(name: "Work")
        let r1 = TestRecordingFactory.makeRecording(title: "In Folder")
        let r2 = TestRecordingFactory.makeRecording(title: "No Folder")
        ctx.insert(folder)
        ctx.insert(r1)
        ctx.insert(r2)
        r1.folder = folder
        try ctx.save()

        let results = try activeRecordings(ctx).filter { $0.folder?.id == folder.id }
        #expect(results.count == 1)
        #expect(results[0].title == "In Folder")
    }

    @MainActor @Test func filterByTag() throws {
        let ctx = try makeContext()
        let r1 = TestRecordingFactory.makeRecording(title: "Tagged")
        r1.tags = ["work"]
        let r2 = TestRecordingFactory.makeRecording(title: "Not tagged")
        ctx.insert(r1)
        ctx.insert(r2)
        try ctx.save()

        let results = try activeRecordings(ctx).filter { $0.tags.contains("work") }
        #expect(results.count == 1)
        #expect(results[0].title == "Tagged")
    }

    @MainActor @Test func filterByFolderAndTag() throws {
        let ctx = try makeContext()
        let folder = TestRecordingFactory.makeFolder()
        let r1 = TestRecordingFactory.makeRecording(title: "Both")
        let r2 = TestRecordingFactory.makeRecording(title: "Folder only")
        let r3 = TestRecordingFactory.makeRecording(title: "Tag only")
        r3.tags = ["work"]
        ctx.insert(folder)
        ctx.insert(r1)
        ctx.insert(r2)
        ctx.insert(r3)
        r1.folder = folder
        r1.tags = ["work"]
        r2.folder = folder
        try ctx.save()

        let results = try activeRecordings(ctx).filter { $0.folder?.id == folder.id && $0.tags.contains("work") }
        #expect(results.count == 1)
        #expect(results[0].title == "Both")
    }

    // MARK: - Trash

    @MainActor @Test func trashedExcludedFromActive() throws {
        let ctx = try makeContext()
        ctx.insert(TestRecordingFactory.makeRecording(title: "Active"))
        let trashed = TestRecordingFactory.makeRecording(title: "Trashed")
        trashed.trashedDate = Date()
        ctx.insert(trashed)
        try ctx.save()

        let active = try activeRecordings(ctx)
        #expect(active.count == 1)
        #expect(active[0].title == "Active")
    }

    @MainActor @Test func fetchTrashedRecordings() throws {
        let ctx = try makeContext()
        ctx.insert(TestRecordingFactory.makeRecording(title: "Active"))
        let trashed = TestRecordingFactory.makeRecording(title: "Trashed")
        trashed.trashedDate = Date()
        ctx.insert(trashed)
        try ctx.save()

        let results = try trashedRecordings(ctx)
        #expect(results.count == 1)
        #expect(results[0].title == "Trashed")
    }

    @MainActor @Test func purgeExpiredTrash() throws {
        let ctx = try makeContext()
        let expired = TestRecordingFactory.makeRecording(title: "Expired")
        expired.trashedDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())
        ctx.insert(expired)
        try ctx.save()

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let toDelete = try trashedRecordings(ctx).filter { $0.trashedDate! < cutoff }
        #expect(toDelete.count == 1)

        for r in toDelete { ctx.delete(r) }
        try ctx.save()

        #expect(try allRecordings(ctx).isEmpty)
    }

    @MainActor @Test func purgeKeepsRecentTrash() throws {
        let ctx = try makeContext()
        let recent = TestRecordingFactory.makeRecording(title: "Recent trash")
        recent.trashedDate = Calendar.current.date(byAdding: .day, value: -5, to: Date())
        ctx.insert(recent)
        try ctx.save()

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let toDelete = try trashedRecordings(ctx).filter { $0.trashedDate! < cutoff }
        #expect(toDelete.isEmpty)
    }

    // MARK: - DTO Conversion Patterns

    @MainActor @Test func recordingToDTOPattern() throws {
        let ctx = try makeContext()
        let r = TestRecordingFactory.makeRecording(title: "DTO Test")
        r.duration = 120
        r.meetingApp = "Zoom"
        r.tags = ["work"]
        r.transcript = TestRecordingFactory.makeTranscript(fullText: "Hello")
        r.summary = TestRecordingFactory.makeSummary(overview: "Brief")
        ctx.insert(r)
        try ctx.save()

        let dto = RecordingDTO(
            id: r.id, title: r.title, startDate: r.startDate, endDate: r.endDate,
            duration: r.duration, meetingApp: r.meetingApp, meetingURL: r.meetingURL,
            language: r.language, tags: r.tags, meetingType: r.meetingType,
            lastAccessedDate: r.lastAccessedDate, trashedDate: r.trashedDate,
            folderID: r.folder?.id,
            hasTranscript: r.transcript != nil, hasSummary: r.summary != nil,
            transcriptPreview: r.transcript.map { String($0.fullText.prefix(200)) },
            summaryPreview: r.summary.map { String($0.overview.prefix(200)) },
            audioFile: r.audioFileReference
        )
        #expect(dto.title == "DTO Test")
        #expect(dto.duration == 120)
        #expect(dto.hasTranscript == true)
        #expect(dto.hasSummary == true)
        #expect(dto.transcriptPreview == "Hello")
    }

    @MainActor @Test func previewTruncatesAt200() throws {
        let ctx = try makeContext()
        let longText = String(repeating: "a", count: 500)
        let r = TestRecordingFactory.makeRecording()
        r.transcript = TestRecordingFactory.makeTranscript(fullText: longText)
        r.summary = TestRecordingFactory.makeSummary(overview: longText)
        ctx.insert(r)
        try ctx.save()

        let transcriptPreview = r.transcript.map { String($0.fullText.prefix(200)) }
        let summaryPreview = r.summary.map { String($0.overview.prefix(200)) }
        #expect(transcriptPreview!.count == 200)
        #expect(summaryPreview!.count == 200)
    }

    @MainActor @Test func folderRecordingCount() throws {
        let ctx = try makeContext()
        let folder = TestRecordingFactory.makeFolder(name: "Work")
        let r1 = TestRecordingFactory.makeRecording()
        let r2 = TestRecordingFactory.makeRecording()
        ctx.insert(folder)
        ctx.insert(r1)
        ctx.insert(r2)
        r1.folder = folder
        r2.folder = folder
        try ctx.save()

        #expect(folder.recordings.count == 2)
    }

    // MARK: - Empty Store

    @MainActor @Test func emptyStoreReturnsEmpty() throws {
        let ctx = try makeContext()
        #expect(try allRecordings(ctx).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Folder>()).isEmpty)
    }

    // MARK: - Cascade Delete

    @MainActor @Test func deletingRecordingCascadesTranscript() throws {
        let ctx = try makeContext()
        let r = TestRecordingFactory.makeRecording()
        r.transcript = TestRecordingFactory.makeTranscript()
        ctx.insert(r)
        try ctx.save()

        ctx.delete(r)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<Transcript>()).isEmpty)
    }

    @MainActor @Test func deletingRecordingCascadesSummary() throws {
        let ctx = try makeContext()
        let r = TestRecordingFactory.makeRecording()
        r.summary = TestRecordingFactory.makeSummary()
        ctx.insert(r)
        try ctx.save()

        ctx.delete(r)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<MeetingSummary>()).isEmpty)
    }

    @MainActor @Test func deletingFolderNullifiesRecording() throws {
        let ctx = try makeContext()
        let folder = TestRecordingFactory.makeFolder()
        let r = TestRecordingFactory.makeRecording()
        ctx.insert(folder)
        ctx.insert(r)
        r.folder = folder
        try ctx.save()

        ctx.delete(folder)
        try ctx.save()

        let recordings = try allRecordings(ctx)
        #expect(recordings.count == 1)
        #expect(recordings.first?.folder == nil)
    }

    // MARK: - Multiple Records

    @MainActor @Test func multipleRecordings() throws {
        let ctx = try makeContext()
        for i in 0..<10 {
            ctx.insert(TestRecordingFactory.makeRecording(title: "R\(i)"))
        }
        try ctx.save()
        #expect(try allRecordings(ctx).count == 10)
    }
}
