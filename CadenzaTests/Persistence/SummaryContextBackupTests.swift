import Foundation
import SwiftData
import SQLite3
import Testing
@testable import Cadenza

@Suite("Summary context backup", .serialized)
struct SummaryContextBackupTests {
    @Test @MainActor func inspectorDistinguishesLegacyFromMissingDeclaredTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("summary-schema-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old.store")
        let oldSchema = Schema([Recording.self, Transcript.self, MeetingSummary.self, ExternalRecordingImport.self,
            Folder.self, SpeakerProfile.self, SpeakerVoiceSample.self, Recap.self, AgentArtifact.self, WebSyncRecord.self])
        let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(url: oldURL))
        let inspector = LiveTransferStoreInspector(fileOperations: LiveFileOperations())
        #expect(try inspector.entityCounts(at: oldURL)?["SummaryContextRecord"] == 0)
        let newURL = directory.appendingPathComponent("new.store")
        let current = try RecordingsStore.makeContainer(storeURL: newURL)
        var db: OpaquePointer?
        #expect(sqlite3_open(newURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "DROP TABLE ZSUMMARYCONTEXTRECORD", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try inspector.entityCounts(at: newURL) }
        _ = old; _ = current
    }
    @Test @MainActor func snapshotRestoresLocalMetadataAndContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("summary-backup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Cadenza.store")
        let container = try RecordingsStore.makeContainer(storeURL: url)
        let context = ModelContext(container)
        let recording = Recording(id: UUID(), title: "Fictional backup", startDate: Date())
        let summary = MeetingSummary(overview: "A pilot remains proposed.")
        summary.generationMetadataJSON = SummaryGenerationMetadata(detailLevel: "fullBreakdown", stage: .reviewed).json
        recording.summary = summary
        context.insert(recording)
        var input = SummaryContextInput(); input.focus = "Fictional access review"
        context.insert(SummaryContextRecord(recordingID: recording.id, inputJSON: input.json))
        try context.save()
        let receipt = try StoreSnapshotter.performVerifiedSnapshot(source: StoreTrioURL(base: url), into: directory,
            label: "backup", fileOperations: LiveFileOperations(), backupDriver: LiveSQLiteBackupDriver())
        #expect(receipt.entityCounts["SummaryContextRecord"] == 1)
        let restored = try RecordingsStore.makeContainer(storeURL: receipt.directory.appendingPathComponent("Cadenza.store"))
        let read = ModelContext(restored)
        let saved = try #require(read.fetch(FetchDescriptor<SummaryContextRecord>()).first)
        #expect(SummaryContextInput.decode(saved.inputJSON) == input)
        let savedSummary = try #require(read.fetch(FetchDescriptor<MeetingSummary>()).first)
        #expect(SummaryGenerationMetadata.decode(savedSummary.generationMetadataJSON)?.stage == .reviewed)
    }
}
