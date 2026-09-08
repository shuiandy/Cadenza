import Foundation
import Testing
import SwiftData
import os
@testable import Cadenza

@Suite("RecordingsStore", .serialized)
struct RecordingsStoreTests {

    @MainActor
    private func makeIsolatedStore() async throws -> RecordingsStore {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        return RecordingsStore(modelContainer: container)
    }

    /// For tests that write audio references: a per-test root the caller
    /// removes in a defer.
    private func makeIsolatedStoreWithAudioRoot() async throws -> (store: RecordingsStore, audioRoot: URL) {
        let store = try await makeIsolatedStore()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recordings-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(audioRoot)
        return (store, audioRoot)
    }

    private struct OwnedDeletionFixture {
        let recordingID: UUID
        let audioURL: URL
        let segmentMarkerURL: URL
    }

    @MainActor
    private func makeTrashedOwnedRecording(
        store: RecordingsStore,
        audioRoot: URL,
        name: String
    ) async throws -> OwnedDeletionFixture {
        let recordingID = UUID()
        let audioURL = audioRoot.appendingPathComponent("\(name).m4a")
        let segmentsURL = audioRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let segmentMarkerURL = segmentsURL.appendingPathComponent("segment-000.m4a")
        try FileManager.default.createDirectory(
            at: segmentsURL,
            withIntermediateDirectories: true
        )
        try Data("owned-audio".utf8).write(to: audioURL)
        try Data("recovery-segment".utf8).write(to: segmentMarkerURL)

        let imported = await store.importAudioFile(
            id: recordingID,
            title: name,
            startDate: .now,
            duration: 60,
            audioURL: audioURL,
            ownership: .appCreated
        )
        #expect(imported)
        let referencesSaved = await store.setRawAudioReferencesForTesting(
            recordingID: recordingID,
            audioFilePath: "\(name).m4a",
            segmentsDirectory: "segments/\(name)"
        )
        #expect(referencesSaved)
        #expect(await store.deleteRecording(recordingID: recordingID))
        return OwnedDeletionFixture(
            recordingID: recordingID,
            audioURL: audioURL,
            segmentMarkerURL: segmentMarkerURL
        )
    }

    @Test @MainActor
    func storeCopyMigrationSmokeWhenPathProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["CADENZA_MIGRATION_TEST_STORE"],
              !path.isEmpty else { return }
        let config = ModelConfiguration(url: URL(fileURLWithPath: path))
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: [config]
        )
        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        let summaries = try container.mainContext.fetch(FetchDescriptor<MeetingSummary>())

        #expect(!recordings.isEmpty)
        for summary in summaries {
            for item in summary.actionItems {
                _ = item.createdAt
                _ = item.updatedAt
            }
        }
    }

    @Test @MainActor
    func createAndFetchRecording() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Test Meeting", startDate: Date(), segmentsDirURL: nil)

        let dtos = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(dtos.count == 1)
        #expect(dtos.first?.id == id)
        #expect(dtos.first?.title == "Test Meeting")
    }

    @Test @MainActor
    func finalizeRecording() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(
            id: id, title: "R1", startDate: Date(),
            segmentsDirURL: audioRoot.appendingPathComponent("segs", isDirectory: true)
        )

        await store.finalizeRecording(
            id: id,
            duration: 120,
            endDate: Date(timeIntervalSinceReferenceDate: 200),
            audioFileURL: audioRoot.appendingPathComponent("audio.m4a")
        )

        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail != nil)
        #expect(detail?.duration == 120)
        #expect(detail?.audioFile == .relative("audio.m4a"))
    }

    @Test @MainActor
    func finalizationPersistsCapturedRequestEndDate() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        let capturedEndDate = Date(timeIntervalSinceReferenceDate: 4_321)
        await store.createRecording(
            id: id,
            title: "Captured clock",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            segmentsDirURL: audioRoot.appendingPathComponent("captured-clock-segments", isDirectory: true)
        )

        let result = await store.finalizeRecording(
            id: id,
            duration: 120,
            endDate: capturedEndDate,
            audioFileURL: audioRoot.appendingPathComponent("captured-clock.m4a")
        )

        #expect(result == .saved)
        #expect(await store.fetchRecordingDetail(recordingID: id)?.endDate == capturedEndDate)
    }

    @Test @MainActor
    func injectedSaveFailureIsDeterministicAndConsumedOnce() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(
            id: id, title: "R1", startDate: Date(),
            segmentsDirURL: audioRoot.appendingPathComponent("segs", isDirectory: true)
        )

        await store.failNextSaveForTesting()
        let failed = await store.finalizeRecording(
            id: id,
            duration: 120,
            endDate: Date(timeIntervalSinceReferenceDate: 200),
            audioFileURL: audioRoot.appendingPathComponent("audio.m4a")
        )
        let afterFailure = await store.fetchRecordingDetail(recordingID: id)
        let nextSave = await store.updateTitle(recordingID: id, title: "Retry")
        let afterNextSave = await store.fetchRecordingDetail(recordingID: id)

        #expect(failed == .failed)
        #expect(afterFailure?.duration == 0)
        #expect(afterFailure?.endDate == nil)
        #expect(afterFailure?.audioFile == nil)
        #expect(
            await store.fetchInterruptedRecordings().contains {
                $0.id == id && $0.segmentsDirURL.lastPathComponent == "segs"
            }
        )
        #expect(nextSave)
        #expect(afterNextSave?.duration == 0)
        #expect(afterNextSave?.audioFile == nil)
    }

    @Test @MainActor
    func failedCreateCannotGhostCommitAndPreservesStagedBatchWork() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setSpeakerMemoryConsentForTesting(true)
        let existingID = UUID()
        let failedCreateID = UUID()
        #expect(await store.createRecording(
            id: existingID,
            title: "Existing",
            startDate: .now,
            segmentsDirURL: nil
        ))
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Staged profile")
        )
        #expect(await store.upsertVoiceSample(
            recordingID: existingID,
            rawLabel: "Speaker 1",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([0.1, 0.2, 0.3, 0.4]),
            embeddingDimension: 4,
            sampleDuration: 30,
            nonOverlapRatio: 0.8,
            qualityScore: 24,
            modelVersion: "standalone-boundary-v1"
        ))
        #expect(await store.attachSampleToProfile(
            recordingID: existingID,
            rawLabel: "Speaker 1",
            profileID: profile.id,
            persist: false
        ))

        await store.failNextSaveForTesting()
        let created = await store.createRecording(
            id: failedCreateID,
            title: "Must not appear",
            startDate: .now,
            segmentsDirURL: nil
        )
        let laterSave = await store.updateTitle(
            recordingID: existingID,
            title: "Unrelated later save"
        )

        let independentReader = RecordingsStore(modelContainer: container)
        let durableRows = await independentReader.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        let durableSamples = await independentReader.fetchConfirmedSamples(
            modelVersion: "standalone-boundary-v1"
        )

        #expect(!created)
        #expect(laterSave)
        #expect(durableRows.map(\.id) == [existingID])
        #expect(durableRows.first?.title == "Unrelated later save")
        #expect(durableSamples.contains { $0.profileID == profile.id })
    }

    @Test @MainActor
    func trackedPathFetchFailureSkipsOrphanRecoveryAndIsConsumedOnce() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let orphanURL = audioRoot.appendingPathComponent("recoverable orphan.m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 16_000 * 31, amplitude: 0.1)],
            to: orphanURL
        )

        await store.failNextTrackedAudioPathFetchForTesting()
        let skipped = await OrphanAudioRecovery.run(storageRoot: audioRoot, store: store)
        let rowsAfterFailure = await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        let catalogueAfterFailure = try await store.allTrackedAudioPaths()
        let recovered = await OrphanAudioRecovery.run(storageRoot: audioRoot, store: store)
        let rowsAfterRetry = await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )

        #expect(skipped == 0)
        #expect(rowsAfterFailure.isEmpty)
        #expect(catalogueAfterFailure.isEmpty)
        #expect(recovered == 1)
        #expect(rowsAfterRetry.map(\.title) == ["recoverable orphan"])
    }

    @Test @MainActor
    func malformedTrackedAudioReferenceFailsClosedAndSkipsOrphanRecovery() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let malformedID = UUID()
        #expect(await store.createRecording(
            id: malformedID,
            title: "Malformed reference",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: malformedID,
            audioFilePath: "../outside-root.m4a",
            segmentsDirectory: nil
        ))
        let orphanURL = audioRoot.appendingPathComponent("must not duplicate.m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 16_000 * 31, amplitude: 0.1)],
            to: orphanURL
        )

        await #expect(
            throws: RecordingsStore.TrackedAudioPathError.unresolvableReference(
                recordingID: malformedID,
                storageValue: "../outside-root.m4a"
            )
        ) {
            _ = try await store.allTrackedAudioPaths()
        }
        let recovered = await OrphanAudioRecovery.run(storageRoot: audioRoot, store: store)
        let rows = await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )

        #expect(recovered == 0)
        #expect(rows.map(\.id) == [malformedID])
    }

    @Test @MainActor
    func nilTrackedAudioReferenceRemainsAValidEmptyCatalogueEntry() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        #expect(await store.createRecording(
            id: UUID(),
            title: "No audio yet",
            startDate: .now,
            segmentsDirURL: nil
        ))

        #expect(try await store.allTrackedAudioPaths().isEmpty)
    }

    @Test @MainActor
    func autoDiscardSaveFailurePreservesRowAndEveryRecoveryArtifact() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-save-failure-\(UUID().uuidString)", isDirectory: true)
        await store.setAudioRootForTesting(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let audio = root.appendingPathComponent("published.m4a")
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let segmentMarker = segments.appendingPathComponent("segment-000.m4a")
        try Data("segment-evidence".utf8).write(to: segmentMarker)
        try Data("published-evidence".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: root) }
        await store.createRecording(
            id: id,
            title: "Short",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            segmentsDirURL: segments
        )

        await store.failNextSaveForTesting()
        let result = await store.finalizeRecording(
            id: id,
            duration: 1,
            endDate: Date(timeIntervalSinceReferenceDate: 101),
            audioFileURL: audio
        )

        #expect(result == .failed)
        #expect(await store.fetchRecordingDetail(recordingID: id) != nil)
        #expect(
            await store.fetchInterruptedRecordings().contains {
                $0.id == id && $0.segmentsDirURL.path == segments.path
            }
        )
        #expect(try Data(contentsOf: segmentMarker) == Data("segment-evidence".utf8))
        #expect(try Data(contentsOf: audio) == Data("published-evidence".utf8))
    }

    @Test @MainActor
    func recoverySaveFailureRestoresActorStateAndRecoveryPointer() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        let originalStart = Date(timeIntervalSinceReferenceDate: 100)
        let requestedEnd = Date(timeIntervalSinceReferenceDate: 999)
        await store.createRecording(
            id: id,
            title: "Interrupted",
            startDate: originalStart,
            segmentsDirURL: audioRoot.appendingPathComponent("recovery-segments", isDirectory: true)
        )

        await store.failNextSaveForTesting()
        let saved = await store.updateRecoveredRecording(
            id: id,
            endDate: requestedEnd,
            duration: 321,
            audioFileURL: audioRoot.appendingPathComponent("recovered.m4a")
        )
        let detail = await store.fetchRecordingDetail(recordingID: id)

        #expect(!saved)
        #expect(detail?.duration == 0)
        #expect(detail?.endDate == nil)
        #expect(detail?.audioFile == nil)
        #expect(
            await store.fetchInterruptedRecordings().contains {
                $0.id == id && $0.segmentsDirURL.lastPathComponent == "recovery-segments"
            }
        )
    }

    @Test @MainActor
    func softDeleteAndRestore() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)

        await store.deleteRecording(recordingID: id)

        let active = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(active.isEmpty)

        let trashed = await store.fetchTrashedRecordings()
        #expect(trashed.count == 1)

        await store.restoreRecording(recordingID: id)

        let afterRestore = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(afterRestore.count == 1)
    }

    @Test @MainActor
    func softDeleteSaveFailureRollsBackAndCannotLeakIntoALaterSave() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        #expect(await store.createRecording(
            id: id,
            title: "Keep me",
            startDate: .now,
            segmentsDirURL: nil
        ))

        await store._test_failNextSave()
        let deleted = await store.deleteRecording(recordingID: id)
        let activeAfterFailure = await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        let trashAfterFailure = await store.fetchTrashedRecordings()
        let laterSave = await store.updateTitle(recordingID: id, title: "Still here")
        let activeAfterLaterSave = await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )

        #expect(!deleted)
        #expect(activeAfterFailure.map(\.id) == [id])
        #expect(trashAfterFailure.isEmpty)
        #expect(laterSave)
        #expect(activeAfterLaterSave.map(\.id) == [id])
    }

    @Test @MainActor
    func permanentDeleteStageFailureRestoresEveryMovedFileAndKeepsRow() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let fixture = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "stage-failure"
        )

        await store.failDeletionFileOperationForTesting(
            .stageMove,
            successfulCallsBeforeFailure: 1
        )
        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: fixture.recordingID
        )
        let retainedRow = await store.fetchRecordingDetail(recordingID: fixture.recordingID)
        let pendingTransactions = await store.pendingDeletionTransactionCountForTesting()

        #expect(outcome == .failed(.fileStagingFailed))
        #expect(retainedRow != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.segmentMarkerURL.path))
        #expect(pendingTransactions == 0)
    }

    @Test @MainActor
    func permanentDeleteSaveFailureRestoresFilesAndKeepsTrashRow() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let fixture = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "save-failure"
        )

        await store._test_failNextSave()
        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: fixture.recordingID
        )
        let retainedTrash = await store.fetchTrashedRecordings()
        let pendingTransactions = await store.pendingDeletionTransactionCountForTesting()

        #expect(outcome == .failed(.persistenceFailed))
        #expect(retainedTrash.map(\.id) == [fixture.recordingID])
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.segmentMarkerURL.path))
        #expect(pendingTransactions == 0)
    }

    @Test @MainActor
    func failedRollbackStaysJournaledAndTheNextRecoveryRestoresFiles() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let fixture = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "rollback-recovery"
        )

        await store._test_failNextSave()
        await store.failDeletionFileOperationForTesting(.restoreMove)
        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: fixture.recordingID
        )
        let retainedBeforeRecovery = await store.fetchRecordingDetail(
            recordingID: fixture.recordingID
        )
        let pendingBeforeRecovery = await store.pendingDeletionTransactionCountForTesting()
        let recovered = await store.recoverPendingDeletionTransactionsForTesting()
        let pendingAfterRecovery = await store.pendingDeletionTransactionCountForTesting()

        #expect(outcome == .failed(.rollbackIncomplete))
        #expect(retainedBeforeRecovery != nil)
        #expect(pendingBeforeRecovery == 1)
        #expect(recovered)
        #expect(pendingAfterRecovery == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.segmentMarkerURL.path))
    }

    @Test @MainActor
    func committedDeleteCleanupFailureRemainsTrackedUntilRetry() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let fixture = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "cleanup-retry"
        )

        await store.failDeletionFileOperationForTesting(.cleanupPayload)
        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: fixture.recordingID
        )
        let deletedRow = await store.fetchRecordingDetail(recordingID: fixture.recordingID)
        let pendingBeforeRecovery = await store.pendingDeletionTransactionCountForTesting()
        let recovered = await store.recoverPendingDeletionTransactionsForTesting()
        let pendingAfterRecovery = await store.pendingDeletionTransactionCountForTesting()
        let audioWasNotRestored = !FileManager.default.fileExists(
            atPath: fixture.audioURL.path
        )
        let segmentsWereNotRestored = !FileManager.default.fileExists(
            atPath: fixture.segmentMarkerURL.path
        )

        #expect(outcome == .cleanupPending(count: 1))
        #expect(deletedRow == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentMarkerURL.path))
        #expect(pendingBeforeRecovery == 1)
        #expect(recovered)
        #expect(pendingAfterRecovery == 0)
        #expect(audioWasNotRestored)
        #expect(segmentsWereNotRestored)
    }

    @Test @MainActor
    func permanentDeleteSuccessRemovesOwnedFilesAndDatabaseRow() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let fixture = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "successful-delete"
        )

        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: fixture.recordingID
        )
        let deletedRow = await store.fetchRecordingDetail(recordingID: fixture.recordingID)
        let pendingTransactions = await store.pendingDeletionTransactionCountForTesting()

        #expect(outcome == .deleted(count: 1))
        #expect(deletedRow == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentMarkerURL.path))
        #expect(pendingTransactions == 0)
    }

    @Test @MainActor
    func permanentDeleteRefusesARecordingThatIsNotInTrash() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Active recording",
            startDate: .now,
            segmentsDirURL: nil
        ))

        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: recordingID
        )
        let retained = await store.fetchRecordingDetail(recordingID: recordingID)

        #expect(outcome == .nothingToDelete)
        #expect(retained != nil)
    }

    @Test @MainActor
    func permanentDeleteRemovesEveryRecapContainingTheRecording() async throws {
        let store = try await makeIsolatedStore()
        let deletedID = UUID()
        let retainedID = UUID()
        #expect(await store.createRecording(
            id: deletedID,
            title: "Delete recap source",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await store.createRecording(
            id: retainedID,
            title: "Retained source",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await store.saveRecap(Recap(
            period: "weekly",
            startDate: .now,
            endDate: .now.addingTimeInterval(7 * 86_400),
            title: "Mixed recap",
            overview: "PRIVATE-DELETED-MEETING-CONTENT",
            recordingIDs: [deletedID, retainedID],
            allActionItems: ["PRIVATE-DELETED-ACTION"],
            allDecisions: ["PRIVATE-DELETED-DECISION"]
        )))
        #expect(await store.saveRecap(Recap(
            period: "weekly",
            startDate: .now.addingTimeInterval(-7 * 86_400),
            endDate: .now,
            title: "Unrelated recap",
            overview: "Keep this recap",
            recordingIDs: [retainedID]
        )))
        #expect(await store.deleteRecording(recordingID: deletedID))

        let outcome = await store.permanentlyDeleteWithOutcome(recordingID: deletedID)
        let recaps = await store.fetchRecaps()

        #expect(outcome == .deleted(count: 1))
        #expect(recaps.map(\.title) == ["Unrelated recap"])
        #expect(!recaps.contains { $0.overview.contains("PRIVATE-DELETED") })
        #expect(await store.fetchRecordingDetail(recordingID: retainedID) != nil)
    }

    @Test @MainActor
    func permanentDeleteSaveFailureRollsBackRecapAndRecordingTogether() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Rollback recap source",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await store.saveRecap(Recap(
            period: "monthly",
            startDate: .now,
            endDate: .now.addingTimeInterval(30 * 86_400),
            title: "Rollback recap",
            overview: "Must survive rollback",
            recordingIDs: [recordingID],
            allActionItems: ["Still present"],
            allDecisions: ["Still present"]
        )))
        #expect(await store.deleteRecording(recordingID: recordingID))
        await store._test_failNextSave()

        let outcome = await store.permanentlyDeleteWithOutcome(recordingID: recordingID)
        let retainedRecording = await store.fetchRecordingDetail(recordingID: recordingID)
        let retainedRecaps = await store.fetchRecaps()

        #expect(outcome == .failed(.persistenceFailed))
        #expect(retainedRecording != nil)
        #expect(retainedRecaps.count == 1)
        #expect(retainedRecaps.first?.overview == "Must survive rollback")
        #expect(retainedRecaps.first?.recordingIDs == [recordingID])
        #expect(retainedRecaps.first?.allActionItems == ["Still present"])
        #expect(retainedRecaps.first?.allDecisions == ["Still present"])
    }

    @Test @MainActor
    func permanentDeleteRemovesBuiltinArtifactsAndPreservesExternalArtifacts() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Artifact source",
            startDate: .now,
            segmentsDirURL: nil
        ))
        let builtin = ArtifactCandidate(
            kind: .meetingPrep,
            targetType: .calendarEvent,
            targetKey: "builtin-event",
            bodyMarkdown: "PRIVATE-BUILTIN-MEETING-CONTENT",
            provenanceSource: .builtin,
            provenanceDetail: "generated",
            status: .ready,
            targetStartDate: .now,
            targetEndDate: .now.addingTimeInterval(3_600),
            targetFingerprint: "builtin-fingerprint",
            contextBuiltAt: .now,
            staleReason: nil
        )
        let external = ArtifactCandidate(
            kind: .meetingPrep,
            targetType: .calendarEvent,
            targetKey: "external-event",
            bodyMarkdown: "User-owned external artifact",
            provenanceSource: .external,
            provenanceDetail: "external",
            status: .ready,
            targetStartDate: .now,
            targetEndDate: .now.addingTimeInterval(3_600),
            targetFingerprint: "external-fingerprint",
            contextBuiltAt: .now,
            staleReason: nil
        )
        #expect(await store.writeExternalArtifact(builtin))
        #expect(await store.writeExternalArtifact(external))
        #expect(await store.deleteRecording(recordingID: recordingID))

        let outcome = await store.permanentlyDeleteWithOutcome(recordingID: recordingID)

        #expect(outcome == .deleted(count: 1))
        #expect(await store.fetchArtifact(slotKey: builtin.slotKey) == nil)
        #expect(await store.fetchArtifact(slotKey: external.slotKey)?.bodyMarkdown
            == "User-owned external artifact")
    }

    @Test @MainActor
    func permanentDeleteSaveFailureRollsBackBuiltinArtifactDeletion() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Artifact rollback source",
            startDate: .now,
            segmentsDirURL: nil
        ))
        let builtin = ArtifactCandidate(
            kind: .meetingPrep,
            targetType: .calendarEvent,
            targetKey: "rollback-event",
            bodyMarkdown: "Must survive rollback",
            provenanceSource: .builtin,
            provenanceDetail: "generated",
            status: .ready,
            targetStartDate: .now,
            targetEndDate: .now.addingTimeInterval(3_600),
            targetFingerprint: "rollback-fingerprint",
            contextBuiltAt: .now,
            staleReason: nil
        )
        #expect(await store.writeExternalArtifact(builtin))
        #expect(await store.deleteRecording(recordingID: recordingID))
        await store._test_failNextSave()

        let outcome = await store.permanentlyDeleteWithOutcome(recordingID: recordingID)

        #expect(outcome == .failed(.persistenceFailed))
        #expect(await store.fetchRecordingDetail(recordingID: recordingID) != nil)
        #expect(await store.fetchArtifact(slotKey: builtin.slotKey)?.bodyMarkdown
            == "Must survive rollback")
    }

    @Test @MainActor
    func permanentDeleteRedactsWebSyncStateToAMinimalTombstone() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Web sync deletion",
            startDate: .now,
            segmentsDirURL: nil
        ))
        var mutation = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        mutation.remoteRecordingID = "PRIVATE-REMOTE-ID"
        mutation.structuredState = WebStructuredSyncState.failed.rawValue
        mutation.structuredHash = "PRIVATE-STRUCTURED-HASH"
        mutation.structuredSourceRevision = .now
        mutation.structuredAttemptRevision = .now
        mutation.audioState = WebAudioSyncState.uploading.rawValue
        mutation.audioFingerprint = "PRIVATE-AUDIO-FINGERPRINT"
        mutation.audioProbeRevision = .now
        mutation.uploadSessionID = "PRIVATE-UPLOAD-SESSION"
        mutation.attemptCount = 7
        mutation.nextAttemptAt = .now.addingTimeInterval(3_600)
        mutation.retryDomain = WebSyncRetryDomain.audio.rawValue
        mutation.lastErrorCode = "PRIVATE-ERROR"
        mutation.syncedAt = .now
        _ = try await store.upsertWebSyncRecord(mutation)
        #expect(await store.deleteRecording(recordingID: recordingID))

        let outcome = await store.permanentlyDeleteWithOutcome(recordingID: recordingID)
        let tombstone = try #require(await store.fetchWebSyncRecord(
            userID: "user-1",
            recordingID: recordingID
        ))

        #expect(outcome == .deleted(count: 1))
        #expect(tombstone.remoteRecordingID == nil)
        #expect(tombstone.structuredState == WebStructuredSyncState.pending.rawValue)
        #expect(tombstone.structuredHash == nil)
        #expect(tombstone.structuredSourceRevision == nil)
        #expect(tombstone.structuredAttemptRevision == nil)
        #expect(tombstone.audioState == WebAudioSyncState.localOnly.rawValue)
        #expect(tombstone.audioFingerprint == nil)
        #expect(tombstone.audioProbeRevision == nil)
        #expect(tombstone.uploadSessionID == nil)
        #expect(tombstone.attemptCount == 0)
        #expect(tombstone.nextAttemptAt == nil)
        #expect(tombstone.retryDomain == nil)
        #expect(tombstone.lastErrorCode == nil)
        #expect(tombstone.lastAttemptAt == nil)
        #expect(tombstone.syncedAt == nil)
        #expect(tombstone.isDeletionTombstone)
    }

    @Test @MainActor
    func permanentDeleteKeepsOneResolverSnapshotAcrossALiveRootChange() async throws {
        let (store, originalRoot) = try await makeIsolatedStoreWithAudioRoot()
        let replacementRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-replacement-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacementRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: originalRoot)
            try? FileManager.default.removeItem(at: replacementRoot)
        }
        let fixture = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: originalRoot,
            name: "resolver-snapshot"
        )
        await store.switchDeletionRootAfterJournalForTesting(to: replacementRoot)

        let outcome = await store.permanentlyDeleteWithOutcome(
            recordingID: fixture.recordingID
        )
        let deletedRow = await store.fetchRecordingDetail(recordingID: fixture.recordingID)
        let replacementContents = try FileManager.default.contentsOfDirectory(
            at: replacementRoot,
            includingPropertiesForKeys: nil
        )
        let originalManifestDirectory = originalRoot
            .appendingPathComponent(".cadenza-delete-quarantine", isDirectory: true)
            .appendingPathComponent("manifests", isDirectory: true)
        let originalManifests = (try? FileManager.default.contentsOfDirectory(
            at: originalManifestDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        #expect(outcome == .deleted(count: 1))
        #expect(deletedRow == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.segmentMarkerURL.path))
        #expect(originalManifests.isEmpty)
        #expect(replacementContents.isEmpty)
    }

    @Test @MainActor
    func emptyTrashSaveFailureRestoresAllRowsAndAllOwnedFiles() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let first = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "empty-first"
        )
        let second = try await makeTrashedOwnedRecording(
            store: store,
            audioRoot: audioRoot,
            name: "empty-second"
        )

        await store._test_failNextSave()
        let outcome = await store.emptyTrashWithOutcome()
        let retainedTrash = await store.fetchTrashedRecordings()
        let retainedTrashIDs = Set(retainedTrash.map(\.id))
        let pendingTransactions = await store.pendingDeletionTransactionCountForTesting()

        #expect(outcome == .failed(.persistenceFailed))
        #expect(retainedTrashIDs == [first.recordingID, second.recordingID])
        #expect(FileManager.default.fileExists(atPath: first.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: first.segmentMarkerURL.path))
        #expect(FileManager.default.fileExists(atPath: second.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: second.segmentMarkerURL.path))
        #expect(pendingTransactions == 0)
    }

    @Test @MainActor
    func folderCRUD() async throws {
        let store = try await makeIsolatedStore()

        let dto = await store.createFolder(name: "Work", icon: "briefcase", iconColor: "blue")
        #expect(dto != nil)
        #expect(dto?.name == "Work")

        let folders = await store.fetchFolders()
        #expect(folders.count == 1)

        await store.updateFolder(id: dto!.id, name: "Projects", icon: "folder", iconColor: "green")
        let updated = await store.fetchFolders()
        #expect(updated.first?.name == "Projects")

        await store.deleteFolder(id: dto!.id)
        let afterDelete = await store.fetchFolders()
        #expect(afterDelete.isEmpty)
    }

    @Test @MainActor
    func moveToFolder() async throws {
        let store = try await makeIsolatedStore()
        let recID = UUID()
        await store.createRecording(id: recID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let folder = await store.createFolder(name: "F1", icon: "folder", iconColor: "")

        await store.moveToFolder(recordingID: recID, folderID: folder!.id)

        let detail = await store.fetchRecordingDetail(recordingID: recID)
        #expect(detail?.folderID == folder?.id)
    }

    @Test @MainActor
    func webSyncSnapshotUsesFullFolderPath() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let parent = Folder(name: "Work")
        let child = Folder(name: "Team")
        child.parentFolder = parent
        let recording = TestRecordingFactory.makeRecording(title: "Nested")
        recording.folder = child
        context.insert(parent)
        context.insert(child)
        context.insert(recording)
        try context.save()
        let store = RecordingsStore(modelContainer: container)

        let snapshot = try await store.fetchWebSyncSnapshot(recordingID: recording.id)

        #expect(snapshot?.folderPath == "Work/Team")
        let originalUpdatedAt = try #require(recording.updatedAt)
        try await Task.sleep(for: .milliseconds(2))
        #expect(await store.updateFolder(id: parent.id, name: "Clients", icon: "folder", iconColor: ""))
        let renamed = try await store.fetchWebSyncSnapshot(recordingID: recording.id)
        #expect(renamed?.folderPath == "Clients/Team")
        #expect((renamed?.detail.updatedAt ?? .distantPast) > originalUpdatedAt)
    }

    @Test @MainActor
    func webSyncSnapshotUsesPersistedCalendarEventNotLiveLookup() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let recording = TestRecordingFactory.makeRecording(title: "Linked")
        context.insert(recording)
        try context.save()
        let store = RecordingsStore(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let end = Date(timeIntervalSince1970: 1_780_001_800)

        #expect(await store.linkCalendarEvent(
            recordingID: recording.id,
            calendarEventID: "evt-1",
            snapshot: RecordingsStore.CalendarEventSnapshot(
                title: "Weekly sales sync", startAt: start, endAt: end
            )
        ))
        let linked = try #require(try await store.fetchWebSyncSnapshot(recordingID: recording.id))
        #expect(linked.calendarEvent?.title == "Weekly sales sync")
        #expect(linked.calendarEvent?.startAt == 1_780_000_000)
        #expect(linked.calendarEventCleared == false)

        #expect(await store.linkCalendarEvent(recordingID: recording.id, calendarEventID: nil))
        let cleared = try #require(try await store.fetchWebSyncSnapshot(recordingID: recording.id))
        #expect(cleared.calendarEvent == nil)
        #expect(cleared.calendarEventCleared == true)
    }

    @Test @MainActor
    func webSyncCandidatesContainOnlyQueueMetadataInNewestFirstOrder() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-sync-candidate-\(UUID().uuidString)", isDirectory: true)
        let consentBindingID = UUID()
        let older = TestRecordingFactory.makeRecording(
            title: "Older",
            startDate: Date(timeIntervalSince1970: 100)
        )
        let legacyCreatedAt = Date(timeIntervalSince1970: 50)
        older.createdAt = legacyCreatedAt
        older.updatedAt = nil
        older.awaitingHistoricalConsentBindingID = consentBindingID
        let newer = TestRecordingFactory.makeRecording(
            title: "Newer",
            startDate: Date(timeIntervalSince1970: 200)
        )
        newer.audioFilePath = "newer.m4a"
        context.insert(older)
        context.insert(newer)
        try context.save()
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(audioRoot)

        let candidates = try await store.fetchWebSyncCandidates(includeTrashed: true)

        #expect(candidates.map(\.recordingID) == [newer.id, older.id])
        let newerRevision = try #require(newer.updatedAt)
        #expect(candidates.map(\.contentRevision) == [newerRevision, legacyCreatedAt])
        #expect(candidates.allSatisfy { $0.trashedDate == nil })
        #expect(candidates.map(\.awaitingHistoricalConsentBindingID) == [nil, consentBindingID])
        #expect(candidates.map(\.hasAudioReference) == [true, false])
        #expect(
            try await store.fetchWebSyncAudioProbeURL(recordingID: newer.id)?.path
                == audioRoot.appendingPathComponent("newer.m4a").path
        )
        #expect(try await store.fetchWebSyncAudioProbeURL(recordingID: older.id) == nil)
    }

    @Test @MainActor
    func webSyncDiscoveryFailureThrowsAndIsConsumedOncePerInjection() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(
            await store.createRecording(
                id: recordingID,
                title: "Discovery",
                startDate: Date(timeIntervalSince1970: 100),
                segmentsDirURL: nil
            )
        )

        await store.failNextWebSyncDiscoveryForTesting()
        await #expect(throws: WebSyncPersistenceError.fetchFailed) {
            _ = try await store.fetchWebSyncCandidates(includeTrashed: true)
        }
        let candidatesAfterFailure = try await store.fetchWebSyncCandidates(includeTrashed: true)
        #expect(candidatesAfterFailure.map(\.recordingID) == [recordingID])

        var mutation = WebSyncMutation(userID: "discovery-user", recordingID: recordingID)
        mutation.structuredState = WebStructuredSyncState.pending.rawValue
        _ = try await store.upsertWebSyncRecord(mutation)

        await store.failNextWebSyncDiscoveryForTesting()
        await #expect(throws: WebSyncPersistenceError.fetchFailed) {
            _ = try await store.fetchWebSyncRecords(userID: "discovery-user")
        }
        let recordsAfterFailure = try await store.fetchWebSyncRecords(userID: "discovery-user")
        #expect(recordsAfterFailure.map(\.recordingID) == [recordingID])
    }

    @Test @MainActor
    func webSyncSnapshotFailureThrowsInsteadOfLookingLikeDeletion() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Snapshot",
            startDate: Date(timeIntervalSince1970: 100),
            segmentsDirURL: nil
        ))

        await store.failNextWebSyncSnapshotForTesting()
        await #expect(throws: WebSyncPersistenceError.fetchFailed) {
            _ = try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        }
        let snapshot = try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        #expect(snapshot?.detail.id == recordingID)
        #expect(try await store.fetchWebSyncSnapshot(recordingID: UUID()) == nil)
    }

    @Test @MainActor
    func webSyncAudioProbeOnlyAdvancesLastAttemptTime() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        let userID = "probe-user"
        let nextAttemptAt = Date(timeIntervalSince1970: 10_000)
        let syncedAt = Date(timeIntervalSince1970: 1_000)
        var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
        mutation.remoteRecordingID = "remote-probe"
        mutation.structuredState = WebStructuredSyncState.synced.rawValue
        mutation.structuredHash = "structured-hash"
        mutation.audioState = WebAudioSyncState.synced.rawValue
        mutation.audioFingerprint = "100:200"
        mutation.attemptCount = 3
        mutation.nextAttemptAt = nextAttemptAt
        mutation.syncedAt = syncedAt
        let before = try await store.upsertWebSyncRecord(mutation)
        let originalAttemptAt = try #require(before.lastAttemptAt)
        let probeDate = originalAttemptAt.addingTimeInterval(60)
        let probeRevision = Date(timeIntervalSince1970: 999)

        try await store.markWebSyncAudioProbe(
            userID: userID,
            recordingID: recordingID,
            contentRevision: probeRevision,
            at: probeDate
        )

        let after = try #require(
            await store.fetchWebSyncRecord(userID: userID, recordingID: recordingID)
        )
        let expected = WebSyncRecordDTO(
            syncKey: before.syncKey,
            userID: before.userID,
            recordingID: before.recordingID,
            remoteRecordingID: before.remoteRecordingID,
            structuredState: before.structuredState,
            structuredHash: before.structuredHash,
            structuredSourceRevision: before.structuredSourceRevision,
            structuredAttemptRevision: before.structuredAttemptRevision,
            audioState: before.audioState,
            audioFingerprint: before.audioFingerprint,
            audioProbeRevision: probeRevision,
            uploadSessionID: before.uploadSessionID,
            attemptCount: before.attemptCount,
            nextAttemptAt: before.nextAttemptAt,
            retryDomain: before.retryDomain,
            lastAttemptAt: probeDate,
            syncedAt: before.syncedAt,
            isDeletionTombstone: before.isDeletionTombstone,
            lastErrorCode: before.lastErrorCode
        )
        #expect(after == expected)

        await store.failNextSaveForTesting()
        await #expect(throws: WebSyncPersistenceError.saveFailed) {
            try await store.markWebSyncAudioProbe(
                userID: userID,
                recordingID: recordingID,
                contentRevision: probeRevision.addingTimeInterval(1),
                at: probeDate.addingTimeInterval(60)
            )
        }
        #expect(await store.fetchWebSyncRecord(userID: userID, recordingID: recordingID) == expected)
    }

    @Test @MainActor
    func updateTitle() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Old Title", startDate: Date(), segmentsDirURL: nil)

        let before = try #require(await store.fetchRecordingDetail(recordingID: id)?.updatedAt)
        try await Task.sleep(for: .milliseconds(2))

        await store.updateTitle(recordingID: id, title: "New Title")

        let dtos = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(dtos.first?.title == "New Title")
        #expect(dtos.first?.createdAt != nil)
        #expect(dtos.first?.updatedAt ?? .distantPast > before)
        #expect(dtos.first?.source == "captured")
    }

    @Test @MainActor
    func emptyTrash() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.deleteRecording(recordingID: id)

        await store.emptyTrash()

        let trashed = await store.fetchTrashedRecordings()
        #expect(trashed.isEmpty)
    }

    @Test @MainActor
    func removeTag() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)

        await store.saveTranscript(
            recordingID: id,
            fullText: "hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 1, text: "hello")],
            language: "en",
            tags: ["meeting", "review"]
        )

        await store.removeTag(recordingID: id, tag: "meeting")

        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.tags == ["review"])
    }

    // Regression: `tags.contains` inside a #Predicate compiles to a SQL string
    // search (_NSCoreDataStringSearch) that segfaulted on rows whose tags
    // column is NULL (recordings with no tags). Tag filtering must not reach
    // the SQL layer while such rows exist.
    @Test @MainActor
    func tagFilterSurvivesUntaggedRows() async throws {
        let store = try await makeIsolatedStore()
        let untagged = UUID()
        let tagged = UUID()
        await store.createRecording(id: untagged, title: "No Tags", startDate: Date(), segmentsDirURL: nil)
        await store.createRecording(id: tagged, title: "Tagged", startDate: Date(), segmentsDirURL: nil)
        _ = await store.addTag(recordingID: tagged, tag: "standup")

        let hits = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: "standup")
        #expect(hits.map(\.id) == [tagged])

        let misses = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: "nonexistent")
        #expect(misses.isEmpty)

        // folderID + tagFilter combination exercises the second predicate branch.
        let folder = await store.createFolder(name: "F", icon: "folder", iconColor: "")
        await store.moveToFolder(recordingID: tagged, folderID: folder!.id)
        await store.moveToFolder(recordingID: untagged, folderID: folder!.id)
        let scoped = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: folder!.id, tagFilter: "standup")
        #expect(scoped.map(\.id) == [tagged])
    }

    // MARK: - Search Tests

    @Test @MainActor
    func searchThousandRowsUsesOneScopedFetch() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let expectedID = UUID()
        for index in 0..<1_000 {
            let recording = Recording(
                id: index == 731 ? expectedID : UUID(),
                title: index == 731 ? "Needle Result" : "Row \(index)",
                startDate: Date(timeIntervalSince1970: Double(index))
            )
            context.insert(recording)
        }
        try context.save()
        let store = RecordingsStore(modelContainer: container)
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let fetchedRowCounts = OSAllocatedUnfairLock(initialState: [Int]())
        let visitedIDs = OSAllocatedUnfairLock(initialState: [UUID]())
        let control = RecordingsStore.SearchExecutionControl(
            didFetch: { rowCount in
                fetchCount.withLock { $0 += 1 }
                fetchedRowCounts.withLock { $0.append(rowCount) }
            },
            didVisit: { id in visitedIDs.withLock { $0.append(id) } }
        )

        let results = await store.searchRecordingDTOs(
            query: "needle",
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil,
            executionControl: control
        )

        #expect(results.map(\.id) == [expectedID])
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(fetchedRowCounts.withLock { $0 } == [1_000])
        #expect(visitedIDs.withLock { $0.count } == 1_000)
    }

    @Test @MainActor
    func searchScopesAndTagsBeforeVisitingContentAndPreservesSort() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let includedFolder = Folder(name: "Included")
        let excludedFolder = Folder(name: "Excluded")
        context.insert(includedFolder)
        context.insert(excludedFolder)

        let alphaID = UUID()
        let mikeID = UUID()
        let zuluID = UUID()
        let includedRows: [Int: (id: UUID, title: String)] = [
            7: (zuluID, "Zulu"),
            123: (alphaID, "Alpha"),
            444: (mikeID, "Mike")
        ]

        for index in 0..<1_000 {
            let included = index < 500
            let special = includedRows[index]
            let recording = Recording(
                id: special?.id ?? UUID(),
                title: special?.title ?? "Row \(index)",
                startDate: Date(timeIntervalSince1970: Double(index))
            )
            recording.folder = included ? includedFolder : excludedFolder
            recording.tags = special != nil || !included ? ["design-review"] : []
            // Every row would match by body if visited. The probe therefore
            // proves folder and tag filtering happen before relationship text.
            recording.transcript = Transcript(fullText: "body needle \(index)")
            context.insert(recording)
        }
        try context.save()

        let store = RecordingsStore(modelContainer: container)
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let fetchedRowCounts = OSAllocatedUnfairLock(initialState: [Int]())
        let visitedIDs = OSAllocatedUnfairLock(initialState: [UUID]())
        let control = RecordingsStore.SearchExecutionControl(
            didFetch: { rowCount in
                fetchCount.withLock { $0 += 1 }
                fetchedRowCounts.withLock { $0.append(rowCount) }
            },
            didVisit: { id in visitedIDs.withLock { $0.append(id) } }
        )

        let results = await store.searchRecordingDTOs(
            query: "needle",
            sortKey: "nameAZ",
            folderID: includedFolder.id,
            tagFilter: "designreview",
            executionControl: control
        )

        #expect(results.map(\.title) == ["Alpha", "Mike", "Zulu"])
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(fetchedRowCounts.withLock { $0 } == [500])
        #expect(visitedIDs.withLock { $0 } == [alphaID, mikeID, zuluID])
    }

    @Test @MainActor
    func cancelledSearchStopsAtFixedVisitCountAndReturnsNoPartialResults() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        for index in 0..<1_000 {
            context.insert(Recording(
                title: "Needle Row \(index)",
                startDate: Date(timeIntervalSince1970: Double(index))
            ))
        }
        try context.save()
        let store = RecordingsStore(modelContainer: container)
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)
        let visitCount = OSAllocatedUnfairLock(initialState: 0)
        let control = RecordingsStore.SearchExecutionControl(
            didFetch: { _ in fetchCount.withLock { $0 += 1 } },
            didVisit: { _ in
                let shouldCancel = visitCount.withLock { count in
                    count += 1
                    return count == 7
                }
                if shouldCancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        let search = Task {
            await store.searchRecordingDTOs(
                query: "needle",
                sortKey: "dateNewest",
                folderID: nil,
                tagFilter: nil,
                executionControl: control
            )
        }
        let results = await search.value

        #expect(results.isEmpty)
        #expect(fetchCount.withLock { $0 } == 1)
        #expect(visitCount.withLock { $0 } == 7)
    }

    @Test @MainActor
    func searchByTitle() async throws {
        let store = try await makeIsolatedStore()
        await store.createRecording(id: UUID(), title: "Weekly Standup", startDate: Date(), segmentsDirURL: nil)
        await store.createRecording(id: UUID(), title: "Design Review", startDate: Date(), segmentsDirURL: nil)

        let results = await store.searchRecordingDTOs(query: "standup", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(results.count == 1)
        #expect(results.first?.title == "Weekly Standup")
    }

    @Test @MainActor
    func searchByTranscriptText() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(
            recordingID: id,
            fullText: "We need to discuss the deadline for the project",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "We need to discuss the deadline for the project")],
            language: "en",
            tags: []
        )

        let results = await store.searchRecordingDTOs(query: "deadline", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(results.count == 1)
        #expect(results.first?.id == id)
    }

    @Test @MainActor
    func searchByActionItem() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Sprint Planning", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(recordingID: id, fullText: "planning", segments: [], language: "en", tags: [])
        await store.saveSummary(
            recordingID: id,
            summary: SummaryResult(
                title: "Sprint Planning",
                overview: "Sprint planning session",
                keyPoints: ["Velocity discussed"],
                actionItems: [ActionItemResult(assignee: "Alice", task: "Update the dashboard", deadline: "Friday")],
                decisions: ["Use React"],
                followUps: ["Check metrics"],
                yourTasks: [],
                tags: [],
                chapters: [],
                rawText: ""
            ),
            chaptersJSON: nil
        )

        let taskResults = await store.searchRecordingDTOs(query: "dashboard", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(taskResults.count == 1)

        let assigneeResults = await store.searchRecordingDTOs(query: "Alice", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(assigneeResults.count == 1)
    }

    @Test @MainActor
    func searchBySummaryFields() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Review", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(recordingID: id, fullText: "review notes", segments: [], language: "en", tags: [])
        await store.saveSummary(
            recordingID: id,
            summary: SummaryResult(
                title: "Review",
                overview: "Quarterly review",
                keyPoints: ["Revenue increased by 20%"],
                actionItems: [],
                decisions: ["Expand to Europe"],
                followUps: ["Schedule investor call"],
                yourTasks: [],
                tags: [],
                chapters: [],
                rawText: ""
            ),
            chaptersJSON: nil
        )

        let kpResults = await store.searchRecordingDTOs(query: "revenue", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(kpResults.count == 1)

        let decResults = await store.searchRecordingDTOs(query: "Europe", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(decResults.count == 1)

        let fuResults = await store.searchRecordingDTOs(query: "investor", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(fuResults.count == 1)
    }

    @Test @MainActor
    func searchEmptyQueryReturnsAll() async throws {
        let store = try await makeIsolatedStore()
        await store.createRecording(id: UUID(), title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.createRecording(id: UUID(), title: "R2", startDate: Date(), segmentsDirURL: nil)

        let results = await store.searchRecordingDTOs(query: "", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(results.count == 2)
    }

    @Test @MainActor
    func searchNoMatch() async throws {
        let store = try await makeIsolatedStore()
        await store.createRecording(id: UUID(), title: "Team Meeting", startDate: Date(), segmentsDirURL: nil)

        let results = await store.searchRecordingDTOs(query: "xyznonexistent", sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(results.isEmpty)
    }

    // MARK: - Folder Detail & Context

    @Test @MainActor
    func folderDetailAggregatesActionItemsWithSource() async throws {
        let store = try await makeIsolatedStore()
        let folder = await store.createFolder(name: "Gamma", icon: "folder", iconColor: "blue")!

        let rec1 = UUID()
        await store.createRecording(id: rec1, title: "Kickoff", startDate: Date(), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec1, folderID: folder.id)
        await store.saveSummary(
            recordingID: rec1,
            summary: SummaryResult(
                title: "Kickoff", overview: "Started work",
                keyPoints: [], actionItems: [.init(assignee: "Alice", task: "Design spec", deadline: "Friday")],
                decisions: ["Use Swift"], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )

        let rec2 = UUID()
        await store.createRecording(id: rec2, title: "Sprint 1", startDate: Date().addingTimeInterval(3600), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec2, folderID: folder.id)
        await store.saveSummary(
            recordingID: rec2,
            summary: SummaryResult(
                title: "Sprint 1", overview: "Progress review",
                keyPoints: [], actionItems: [.init(assignee: "Bob", task: "Fix bug", deadline: nil)],
                decisions: ["Ship v2"], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )

        let detail = await store.fetchFolderDetail(folderID: folder.id)!
        #expect(detail.recordings.count == 2)
        #expect(detail.actionItems.count == 2)
        #expect(detail.decisions.count == 2)

        let aliceItem = detail.actionItems.first { $0.item.assignee == "Alice" }
        #expect(aliceItem?.sourceRecordingTitle == "Kickoff")
        #expect(aliceItem?.sourceRecordingID == rec1)

        let swiftDecision = detail.decisions.first { $0.text == "Use Swift" }
        #expect(swiftDecision?.sourceRecordingTitle == "Kickoff")
        #expect(swiftDecision?.sourceRecordingID == rec1)
    }

    @Test @MainActor
    func deleteFolderPreservesRecordings() async throws {
        let store = try await makeIsolatedStore()
        let recID = UUID()
        await store.createRecording(id: recID, title: "Important", startDate: Date(), segmentsDirURL: nil)
        let folder = await store.createFolder(name: "TempFolder", icon: "folder", iconColor: "")!
        await store.moveToFolder(recordingID: recID, folderID: folder.id)
        let before = try #require(await store.fetchRecordingDetail(recordingID: recID)?.updatedAt)
        try await Task.sleep(for: .milliseconds(5))

        await store.deleteFolder(id: folder.id)

        let recordings = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        let recording = try #require(recordings.first { $0.id == recID })
        #expect(recording.folderID == nil)
        #expect(try #require(recording.updatedAt) > before)
    }

    @Test @MainActor
    func fetchFolderContextReturnsNilForMissing() async throws {
        let store = try await makeIsolatedStore()
        let ctx = await store.fetchFolderContext(folderID: UUID())
        #expect(ctx == nil)
    }

    @Test @MainActor
    func fetchFolderContextAssemblesData() async throws {
        let store = try await makeIsolatedStore()
        let folder = await store.createFolder(name: "ContextTest", icon: "folder", iconColor: "")!

        let rec1 = UUID()
        await store.createRecording(id: rec1, title: "Kickoff", startDate: Date(), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec1, folderID: folder.id)
        await store.saveSummary(
            recordingID: rec1,
            summary: SummaryResult(
                title: "Kickoff", overview: "Folder kickoff",
                keyPoints: ["Scope defined"],
                actionItems: [.init(assignee: "Alice", task: "Write spec", deadline: "Monday")],
                decisions: ["Use SwiftUI"],
                followUps: ["Check timeline"],
                yourTasks: [],
                tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )

        let rec2 = UUID()
        await store.createRecording(id: rec2, title: "Sprint 1", startDate: Date().addingTimeInterval(3600), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec2, folderID: folder.id)
        await store.saveSummary(
            recordingID: rec2,
            summary: SummaryResult(
                title: "Sprint 1", overview: "Sprint review",
                keyPoints: ["Velocity OK"],
                actionItems: [.init(assignee: "Bob", task: "Fix crash", deadline: nil)],
                decisions: ["Ship v2"],
                followUps: [],
                yourTasks: [],
                tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )

        let ctx = await store.fetchFolderContext(folderID: folder.id)
        #expect(ctx != nil)
        #expect(ctx?.folderName == "ContextTest")
        #expect(ctx?.totalRecordingCount == 2)
        #expect(ctx?.recentMeetings.count == 2)
        #expect(ctx?.openActionItems.count == 2)
        #expect(ctx?.recentDecisions.count == 2)
        #expect(ctx?.followUps.count == 1)
        #expect(ctx?.followUps.first?.text == "Check timeline")
    }

    @Test @MainActor
    func fetchFolderContextExcludesCompletedActionItems() async throws {
        let store = try await makeIsolatedStore()
        let folder = await store.createFolder(name: "CompletedTest", icon: "folder", iconColor: "")!

        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: recID, folderID: folder.id)
        await store.saveSummary(
            recordingID: recID,
            summary: SummaryResult(
                title: "Meeting", overview: "Review",
                keyPoints: [],
                actionItems: [
                    .init(assignee: "Alice", task: "Open task", deadline: nil),
                    .init(assignee: "Bob", task: "Done task", deadline: nil)
                ],
                decisions: [], followUps: [], yourTasks: [],
                tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )

        let detailBefore = await store.fetchFolderDetail(folderID: folder.id)!
        let bobItem = detailBefore.actionItems.first { $0.item.task == "Done task" }!
        await store.toggleActionItem(recordingID: recID, actionItemID: bobItem.item.id)

        let ctx = await store.fetchFolderContext(folderID: folder.id)
        #expect(ctx?.openActionItems.count == 1)
        #expect(ctx?.openActionItems.first?.item.task == "Open task")
    }

    @Test @MainActor
    func actionItemWritesRollbackWhenPersistenceFails() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "Rollback", startDate: Date(), segmentsDirURL: nil)
        await store.saveSummary(
            recordingID: recordingID,
            summary: SummaryResult(
                title: "Rollback",
                overview: "Test",
                keyPoints: [],
                actionItems: [.init(assignee: nil, task: "Original", deadline: nil)],
                decisions: [],
                followUps: [],
                yourTasks: [],
                tags: [],
                chapters: [],
                rawText: ""
            ),
            chaptersJSON: nil
        )
        let before = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        let itemID = try #require(before.summary?.actionItems.first?.id)

        await store._test_failNextSave()
        #expect(await store.toggleActionItem(recordingID: recordingID, actionItemID: itemID) == false)
        var after = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(after.summary?.actionItems.first?.isCompleted == false)
        #expect(after.updatedAt == before.updatedAt)

        await store._test_failNextSave()
        #expect(await store.addActionItem(recordingID: recordingID, task: "Must not persist") == false)
        after = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(after.summary?.actionItems.map(\.task) == ["Original"])
        #expect(after.updatedAt == before.updatedAt)
    }

    @Test @MainActor
    func fetchFolderContextRespectsLimit() async throws {
        let store = try await makeIsolatedStore()
        let folder = await store.createFolder(name: "LimitTest", icon: "folder", iconColor: "")!

        for i in 0..<3 {
            let recID = UUID()
            await store.createRecording(id: recID, title: "Meeting \(i)", startDate: Date().addingTimeInterval(Double(i) * 3600), segmentsDirURL: nil)
            await store.moveToFolder(recordingID: recID, folderID: folder.id)
            await store.saveSummary(
                recordingID: recID,
                summary: SummaryResult(
                    title: "Meeting \(i)", overview: "Overview \(i)",
                    keyPoints: [], actionItems: [],
                    decisions: ["Decision \(i)"], followUps: [], yourTasks: [],
                    tags: [], chapters: [], rawText: ""
                ),
                chaptersJSON: nil
            )
        }

        let ctx = await store.fetchFolderContext(folderID: folder.id, meetingLimit: 2)
        #expect(ctx?.recentMeetings.count == 2)
        #expect(ctx?.recentDecisions.count == 2)
    }

    @Test @MainActor
    func folderMemoryServiceBuildsBriefPrompt() async throws {
        let context = FolderContextDTO(
            folderName: "Test Folder",
            folderStatus: "active",
            totalRecordingCount: 2,
            recentMeetings: [
                .init(
                    recordingID: UUID(),
                    title: "Kickoff",
                    date: Date(),
                    durationMinutes: 30,
                    overview: "Folder kickoff meeting",
                    keyPoints: ["Scope defined"],
                    actionItems: [ActionItemDTO(id: UUID(), assignee: "Alice", task: "Write spec", deadline: "Friday", isCompleted: false, priority: "medium")],
                    decisions: ["Use Swift"],
                    followUps: ["Check budget"]
                )
            ],
            openActionItems: [],
            recentDecisions: [],
            followUps: [],
            knownSpeakers: ["Alice", "Bob"]
        )

        let systemPrompt = ProjectMemoryService.buildSystemPrompt(context: context)
        #expect(systemPrompt.contains("Test Folder"))
        #expect(systemPrompt.contains("Kickoff"))
        #expect(systemPrompt.contains("Scope defined"))
        #expect(systemPrompt.contains("Write spec"))
        #expect(systemPrompt.contains("Use Swift"))
        #expect(systemPrompt.contains("Check budget"))

        let briefPrompt = ProjectMemoryService.buildBriefPrompt(context: context)
        #expect(briefPrompt.contains("folder status brief"))
        #expect(briefPrompt.contains("Current Status"))
        #expect(briefPrompt.contains("Open Action Items"))

        #expect(systemPrompt.contains("Alice"))
        #expect(systemPrompt.contains("Bob"))
    }

    // MARK: - Speaker Memory (Milestone 4)

    @Test @MainActor
    func createAndFetchSpeakerProfile() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Alice", notes: "PM")
        #expect(profile != nil)
        #expect(profile?.displayName == "Alice")
        #expect(profile?.notes == "PM")

        let all = await store.fetchSpeakerProfiles()
        #expect(all.count == 1)
        #expect(all.first?.displayName == "Alice")
    }

    @Test @MainActor
    func updateSpeakerProfile() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Alice")!
        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.setSpeakerMapping(recordingID: recID, rawLabel: "Speaker 1", profileID: profile.id)
        let before = try #require(await store.fetchRecordingDetail(recordingID: recID)?.updatedAt)
        try await Task.sleep(for: .milliseconds(5))

        let updated = await store.updateSpeakerProfile(id: profile.id, displayName: "Alice W.", notes: "Tech Lead", teamOrOrg: "Eng")
        #expect(updated)

        let all = await store.fetchSpeakerProfiles()
        #expect(all.first?.displayName == "Alice W.")
        #expect(all.first?.notes == "Tech Lead")
        #expect(all.first?.teamOrOrg == "Eng")

        let detail = try #require(await store.fetchRecordingDetail(recordingID: recID))
        #expect(try #require(detail.updatedAt) > before)
        #expect(detail.speakerMappings.first?.profileName == "Alice W.")

        let after = try #require(detail.updatedAt)
        #expect(await store.updateSpeakerProfile(
            id: profile.id,
            displayName: "Alice W.",
            notes: "Tech Lead",
            teamOrOrg: "Eng"
        ))
        #expect(await store.fetchRecordingDetail(recordingID: recID)?.updatedAt == after)
    }

    @Test @MainActor
    func deleteSpeakerProfileRemovesMappings() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Bob")!

        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(
            recordingID: recID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 1, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        await store.setSpeakerMapping(recordingID: recID, rawLabel: "Speaker 1", profileID: profile.id)

        // Verify mapping exists
        let mappingsBefore = await store.speakerMappings(forRecordingID: recID)
        #expect(mappingsBefore.count == 1)

        // Delete profile
        await store.deleteSpeakerProfile(id: profile.id)

        // Mapping should be removed
        let mappingsAfter = await store.speakerMappings(forRecordingID: recID)
        #expect(mappingsAfter.isEmpty)

        let profiles = await store.fetchSpeakerProfiles()
        #expect(profiles.isEmpty)
    }

    @Test @MainActor
    func setSpeakerMappingAndResolve() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(
            recordingID: recID,
            fullText: "Hello world",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 1, text: "Hello", speaker: "Speaker 1"),
                TranscriptEntry(startTime: 1, endTime: 2, text: "World", speaker: "Speaker 2")
            ],
            language: "en",
            tags: []
        )

        // Map Speaker 1 → Alice
        await store.setSpeakerMapping(recordingID: recID, rawLabel: "Speaker 1", profileID: profile.id)

        let mappings = await store.speakerMappings(forRecordingID: recID)
        #expect(mappings.count == 1)
        #expect(mappings.first?.rawLabel == "Speaker 1")
        #expect(mappings.first?.profileName == "Alice")

        // Detail DTO includes the mapping
        let detail = await store.fetchRecordingDetail(recordingID: recID)
        #expect(detail?.speakerMappings.count == 1)
        #expect(detail?.speakerMappings.first?.profileName == "Alice")

        // Raw label still preserved in transcript
        let rawSegment = detail?.transcript?.segments.first
        #expect(rawSegment?.speaker == "Speaker 1")
    }

    @Test @MainActor
    func removeSpeakerMapping() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Bob")!

        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.setSpeakerMapping(recordingID: recID, rawLabel: "Speaker 1", profileID: profile.id)

        await store.removeSpeakerMapping(recordingID: recID, rawLabel: "Speaker 1")

        let mappings = await store.speakerMappings(forRecordingID: recID)
        #expect(mappings.isEmpty)
    }

    @Test @MainActor
    func rawSpeakerLabels() async throws {
        let store = try await makeIsolatedStore()
        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(
            recordingID: recID,
            fullText: "conversation",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 1, text: "A", speaker: "Speaker 1"),
                TranscriptEntry(startTime: 1, endTime: 2, text: "B", speaker: "Speaker 2"),
                TranscriptEntry(startTime: 2, endTime: 3, text: "C", speaker: "Speaker 1"),
                TranscriptEntry(startTime: 3, endTime: 4, text: "D")
            ],
            language: "en",
            tags: []
        )

        let labels = await store.rawSpeakerLabels(forRecordingID: recID)
        #expect(labels == ["Speaker 1", "Speaker 2"])
    }

    @Test @MainActor
    func folderContextIncludesKnownSpeakers() async throws {
        let store = try await makeIsolatedStore()
        let folder = await store.createFolder(name: "SpeakerTest", icon: "folder", iconColor: "")!
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        let recID = UUID()
        await store.createRecording(id: recID, title: "Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: recID, folderID: folder.id)
        await store.saveTranscript(
            recordingID: recID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 1, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        await store.saveSummary(
            recordingID: recID,
            summary: SummaryResult(
                title: "Meeting", overview: "Test",
                keyPoints: [], actionItems: [],
                decisions: [], followUps: [], yourTasks: [],
                tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )
        await store.setSpeakerMapping(recordingID: recID, rawLabel: "Speaker 1", profileID: profile.id)

        let ctx = await store.fetchFolderContext(folderID: folder.id)
        #expect(ctx?.knownSpeakers == ["Alice"])
    }

    @Test @MainActor
    func fetchFolderContextIncludesTranscriptOnlyRecordings() async throws {
        let store = try await makeIsolatedStore()
        let folder = await store.createFolder(name: "TranscriptOnly", icon: "folder", iconColor: "")!

        let rec1 = UUID()
        await store.createRecording(id: rec1, title: "Older Meeting", startDate: Date(), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec1, folderID: folder.id)
        await store.saveSummary(
            recordingID: rec1,
            summary: SummaryResult(
                title: "Older Meeting", overview: "Had a discussion",
                keyPoints: [], actionItems: [],
                decisions: [], followUps: [], yourTasks: [],
                tags: [], chapters: [], rawText: ""
            ),
            chaptersJSON: nil
        )

        let rec2 = UUID()
        await store.createRecording(id: rec2, title: "Latest Meeting", startDate: Date().addingTimeInterval(3600), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec2, folderID: folder.id)
        await store.saveTranscript(
            recordingID: rec2,
            fullText: "We discussed the new timeline and budget concerns",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "We discussed the new timeline")],
            language: "en",
            tags: []
        )

        let rec3 = UUID()
        await store.createRecording(id: rec3, title: "Just Started", startDate: Date().addingTimeInterval(7200), segmentsDirURL: nil)
        await store.moveToFolder(recordingID: rec3, folderID: folder.id)

        let ctx = await store.fetchFolderContext(folderID: folder.id)!

        // All 3 recordings should appear in recentMeetings
        #expect(ctx.recentMeetings.count == 3)

        // Newest first
        #expect(ctx.recentMeetings[0].title == "Just Started")
        #expect(ctx.recentMeetings[0].overview.contains("No summary or transcript"))

        #expect(ctx.recentMeetings[1].title == "Latest Meeting")
        #expect(ctx.recentMeetings[1].overview.contains("Summary pending"))
        #expect(ctx.recentMeetings[1].overview.contains("timeline"))

        #expect(ctx.recentMeetings[2].title == "Older Meeting")
        #expect(ctx.recentMeetings[2].overview == "Had a discussion")
    }

    @Test @MainActor
    func updateStartDateRebasesEndDate() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        let originalDate = Date()
        _ = await store.importAudioFile(
            id: id, title: "Imported", startDate: originalDate,
            duration: 600, audioURL: audioRoot.appendingPathComponent("a.m4a"), ownership: .appCreated)

        let newDate = originalDate.addingTimeInterval(-86400 * 30) // 30 days earlier
        let ok = await store.updateStartDate(recordingID: id, startDate: newDate)
        #expect(ok)

        let detail = await store.fetchRecordingDetail(recordingID: id)
        let startDelta = abs(detail?.startDate.timeIntervalSince(newDate) ?? .infinity)
        #expect(startDelta < 0.001)
        let expectedEnd = newDate.addingTimeInterval(600)
        let endDelta = abs(detail?.endDate?.timeIntervalSince(expectedEnd) ?? .infinity)
        #expect(endDelta < 0.001)
        #expect(detail?.duration == 600)
    }

    @Test @MainActor
    func updateStartDatePreservesIntervalLength() async throws {
        // Live recordings can have endDate - startDate != duration (pauses make the
        // wall-clock span exceed audio duration). Date edit must shift the interval,
        // not recompute it as startDate + duration.
        let store = try await makeIsolatedStore()
        let id = UUID()
        let originalDate = Date()
        await store.createRecording(id: id, title: "Paused", startDate: originalDate, segmentsDirURL: nil)
        // 900s wall-clock span, but only 600s of audio (300s paused)
        await store.updateRecoveredRecording(
            id: id, endDate: originalDate.addingTimeInterval(900),
            duration: 600, audioFileURL: nil
        )

        let newDate = originalDate.addingTimeInterval(-86400 * 7)
        let ok = await store.updateStartDate(recordingID: id, startDate: newDate)
        #expect(ok)

        let detail = await store.fetchRecordingDetail(recordingID: id)
        let expectedEnd = newDate.addingTimeInterval(900) // interval length preserved
        let endDelta = abs(detail?.endDate?.timeIntervalSince(expectedEnd) ?? .infinity)
        #expect(endDelta < 0.001)
        #expect(detail?.duration == 600)
    }

    @Test @MainActor
    func updateStartDateKeepsNilEndDate() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)

        let newDate = Date(timeIntervalSince1970: 1_700_000_000)
        let ok = await store.updateStartDate(recordingID: id, startDate: newDate)
        #expect(ok)

        let detail = await store.fetchRecordingDetail(recordingID: id)
        let delta = abs(detail?.startDate.timeIntervalSince(newDate) ?? .infinity)
        #expect(delta < 0.001)
        #expect(detail?.endDate == nil)
    }

    // MARK: - fetchAIContext query-cleaning semantics

    /// chat 的 QueryAnalyzer 传非 optional 数组,无条件时是 [] —— 空数组必须等同
    /// 「不过滤」(回归:曾被误判为 requested-but-blank 而 reject 全部 excerpts)。
    @Test @MainActor
    func fetchAIContextEmptyArraysMeanNoFilter() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Chat Source", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(recordingID: id, fullText: "hello world",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "hello world", speaker: "Speaker 1")],
            language: "en", tags: [])

        let ctx = await store.fetchAIContext(speakerQueries: [], keywords: [])
        #expect(!ctx.transcriptExcerpts.isEmpty)   // [] = 无条件,excerpts 照常返回
    }

    /// 有过滤意图(非空数组)但全是空白 → reject all,绝不回落成「不过滤」
    /// (空白 attendee name 的全库泄露防线;trim 必须生效," " 也算空白)。
    @Test @MainActor
    func fetchAIContextAllBlankQueriesRejectAll() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Leak Source", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(recordingID: id, fullText: "secret content",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "secret content", speaker: "Speaker 1")],
            language: "en", tags: [])

        let blankSpeaker = await store.fetchAIContext(speakerQueries: [" "])
        #expect(blankSpeaker.transcriptExcerpts.isEmpty)
        let blankKeyword = await store.fetchAIContext(keywords: ["", "  "])
        #expect(blankKeyword.transcriptExcerpts.isEmpty)
    }

    @Test @MainActor
    func explicitAIContextScopeReturnsCompleteTranscriptBeyondExcerptCap() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(
            id: recordingID,
            title: "Scoped 1:1",
            startDate: Date(),
            segmentsDirURL: nil
        )
        let segments: [TranscriptEntry] = (0..<214).map { index -> TranscriptEntry in
            let startTime = Double(index)
            return TranscriptEntry(
                startTime: startTime,
                endTime: startTime + 1,
                text: index == 213 ? "TAIL SENTINEL" : "Line \(index)",
                speaker: index.isMultiple(of: 2) ? "Speaker 1" : "Speaker 2"
            )
        }
        let fullText = segments.map { $0.text }.joined(separator: " ")
        await store.saveTranscript(
            recordingID: recordingID,
            fullText: fullText,
            segments: segments,
            language: "en",
            tags: []
        )

        let data = await store.fetchAIContext(
            recordingIDs: [recordingID],
            keywords: ["does-not-exist"],
            maxTranscriptEntries: 200
        )

        #expect(data.transcriptCoverage == .complete)
        #expect(data.transcriptExcerpts.count == 214)
        #expect(data.transcriptExcerpts.last?.text == "TAIL SENTINEL")
    }

    @Test @MainActor
    func latestSpeakerOneOnOneResolvesOneRecordingAndKeepsItsTail() async throws {
        let store = try await makeIsolatedStore()
        let caleb = await store.createSpeakerProfile(displayName: "Caleb")!
        let now = Date()

        let targetID = UUID()
        await store.createRecording(
            id: targetID,
            title: "Performance Review",
            startDate: now.addingTimeInterval(-3_600),
            segmentsDirURL: nil
        )
        let targetSegments: [TranscriptEntry] = (0..<220).map { index -> TranscriptEntry in
            let startTime = Double(index)
            return TranscriptEntry(
                startTime: startTime,
                endTime: startTime + 1,
                text: index == 219 ? "CALeb TAIL SENTINEL" : "Review line \(index)",
                speaker: "Speaker 1"
            )
        }
        let targetFullText = targetSegments.map { $0.text }.joined(separator: " ")
        await store.saveTranscript(
            recordingID: targetID,
            fullText: targetFullText,
            segments: targetSegments,
            language: "en",
            tags: []
        )
        await store.setSpeakerMapping(
            recordingID: targetID,
            rawLabel: "Speaker 1",
            profileID: caleb.id
        )
        await store.updateMeetingType(recordingID: targetID, meetingType: MeetingType.oneOnOne.rawValue)

        let newerStandupID = UUID()
        await store.createRecording(
            id: newerStandupID,
            title: "Daily Standup",
            startDate: now,
            segmentsDirURL: nil
        )
        await store.saveTranscript(
            recordingID: newerStandupID,
            fullText: "Standup",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 1, text: "Standup", speaker: "Speaker 1")
            ],
            language: "en",
            tags: []
        )
        await store.setSpeakerMapping(
            recordingID: newerStandupID,
            rawLabel: "Speaker 1",
            profileID: caleb.id
        )
        await store.updateMeetingType(recordingID: newerStandupID, meetingType: MeetingType.standup.rawValue)

        let data = await store.fetchAIContext(
            speakerQueries: ["Caleb"],
            keywords: ["周四", "workflow"],
            meetingType: .oneOnOne,
            mostRecentRecordingOnly: true,
            maxTranscriptEntries: 200
        )

        #expect(data.summaries.map(\.recordingID) == [targetID])
        #expect(data.transcriptCoverage == .complete)
        #expect(data.transcriptExcerpts.count == 220)
        #expect(data.transcriptExcerpts.last?.text == "CALeb TAIL SENTINEL")
    }

    @Test @MainActor
    func latestRecordingSelectorsFailClosedWhenNoRecordingMatches() async throws {
        let store = try await makeIsolatedStore()
        _ = await store.createSpeakerProfile(displayName: "Caleb")
        let unrelatedID = UUID()
        await store.createRecording(
            id: unrelatedID,
            title: "Someone Else 1on1",
            startDate: Date(),
            segmentsDirURL: nil
        )
        await store.saveTranscript(
            recordingID: unrelatedID,
            fullText: "UNRELATED SENTINEL",
            segments: [
                TranscriptEntry(
                    startTime: 0,
                    endTime: 1,
                    text: "UNRELATED SENTINEL",
                    speaker: "Speaker 1"
                )
            ],
            language: "en",
            tags: []
        )
        await store.updateMeetingType(
            recordingID: unrelatedID,
            meetingType: MeetingType.oneOnOne.rawValue
        )

        let data = await store.fetchAIContext(
            speakerQueries: ["Caleb"],
            meetingType: .oneOnOne,
            mostRecentRecordingOnly: true
        )

        #expect(data.summaries.isEmpty)
        #expect(data.transcriptExcerpts.isEmpty)
    }

    @Test @MainActor
    func recordingLevelSelectorsCanResolveMatchOlderThanTwoHundredRecordings() async throws {
        let store = try await makeIsolatedStore()
        let caleb = await store.createSpeakerProfile(displayName: "Caleb")!
        let now = Date()
        let targetID = UUID()
        await store.createRecording(
            id: targetID,
            title: "Older Caleb 1on1",
            startDate: now.addingTimeInterval(-500_000),
            segmentsDirURL: nil
        )
        await store.saveTranscript(
            recordingID: targetID,
            fullText: "OLDER TARGET SENTINEL",
            segments: [
                TranscriptEntry(
                    startTime: 0,
                    endTime: 1,
                    text: "OLDER TARGET SENTINEL",
                    speaker: "Speaker 1"
                )
            ],
            language: "en",
            tags: []
        )
        await store.setSpeakerMapping(
            recordingID: targetID,
            rawLabel: "Speaker 1",
            profileID: caleb.id
        )
        await store.updateMeetingType(
            recordingID: targetID,
            meetingType: MeetingType.oneOnOne.rawValue
        )

        for index in 0..<205 {
            await store.createRecording(
                id: UUID(),
                title: "Newer unrelated \(index)",
                startDate: now.addingTimeInterval(Double(-index)),
                segmentsDirURL: nil
            )
        }

        let data = await store.fetchAIContext(
            speakerQueries: ["Caleb"],
            meetingType: .oneOnOne,
            mostRecentRecordingOnly: true
        )

        #expect(data.summaries.map(\.recordingID) == [targetID])
        #expect(data.transcriptExcerpts.map(\.text) == ["OLDER TARGET SENTINEL"])
    }

    @Test @MainActor
    func meetingTypeFiltersNonLatestSpeakerQueries() async throws {
        let store = try await makeIsolatedStore()
        let caleb = await store.createSpeakerProfile(displayName: "Caleb")!
        let now = Date()

        func addRecording(title: String, type: MeetingType, text: String) async -> UUID {
            let id = UUID()
            await store.createRecording(id: id, title: title, startDate: now, segmentsDirURL: nil)
            await store.saveTranscript(
                recordingID: id,
                fullText: text,
                segments: [
                    TranscriptEntry(startTime: 0, endTime: 1, text: text, speaker: "Speaker 1")
                ],
                language: "en",
                tags: []
            )
            await store.setSpeakerMapping(recordingID: id, rawLabel: "Speaker 1", profileID: caleb.id)
            await store.updateMeetingType(recordingID: id, meetingType: type.rawValue)
            return id
        }

        let oneOnOneID = await addRecording(
            title: "Caleb 1on1",
            type: .oneOnOne,
            text: "performance review"
        )
        _ = await addRecording(title: "Caleb standup", type: .standup, text: "performance review")

        let data = await store.fetchAIContext(
            speakerQueries: ["Caleb"],
            keywords: ["performance"],
            meetingType: .oneOnOne
        )

        #expect(data.summaries.map(\.recordingID) == [oneOnOneID])
        #expect(Set(data.transcriptExcerpts.map(\.recordingID)) == [oneOnOneID])
    }

    @Test @MainActor
    func latestRecordingRequiresEveryNamedSpeaker() async throws {
        let store = try await makeIsolatedStore()
        let andy = await store.createSpeakerProfile(displayName: "Andy")!
        let caleb = await store.createSpeakerProfile(displayName: "Caleb")!
        let now = Date()

        let targetID = UUID()
        await store.createRecording(
            id: targetID,
            title: "Andy and Caleb one-on-one",
            startDate: now.addingTimeInterval(-3_600),
            segmentsDirURL: nil
        )
        await store.saveTranscript(
            recordingID: targetID,
            fullText: "Andy opening Caleb response",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 1, text: "Andy opening", speaker: "Speaker 1"),
                TranscriptEntry(startTime: 1, endTime: 2, text: "Caleb response", speaker: "Speaker 2"),
            ],
            language: "en",
            tags: []
        )
        await store.setSpeakerMapping(recordingID: targetID, rawLabel: "Speaker 1", profileID: andy.id)
        await store.setSpeakerMapping(recordingID: targetID, rawLabel: "Speaker 2", profileID: caleb.id)
        let newerAndyOnlyID = UUID()
        await store.createRecording(
            id: newerAndyOnlyID,
            title: "Andy and someone else 1on1",
            startDate: now,
            segmentsDirURL: nil
        )
        await store.saveTranscript(
            recordingID: newerAndyOnlyID,
            fullText: "WRONG NEWER RECORDING",
            segments: [
                TranscriptEntry(startTime: 0, endTime: 1, text: "WRONG NEWER RECORDING", speaker: "Speaker 1")
            ],
            language: "en",
            tags: []
        )
        await store.setSpeakerMapping(
            recordingID: newerAndyOnlyID,
            rawLabel: "Speaker 1",
            profileID: andy.id
        )
        await store.updateMeetingType(
            recordingID: newerAndyOnlyID,
            meetingType: MeetingType.oneOnOne.rawValue
        )

        let data = await store.fetchAIContext(
            speakerQueries: ["Andy", "Caleb"],
            meetingType: .oneOnOne,
            mostRecentRecordingOnly: true
        )

        #expect(data.summaries.map(\.recordingID) == [targetID])
        #expect(!data.transcriptExcerpts.map(\.text).contains("WRONG NEWER RECORDING"))
    }

    // MARK: - speakerMatchMode

    /// Meeting prep passes every attendee as a speaker query. With the default
    /// `.all` (chat's co-occurrence disambiguation) a 3-person meeting would only
    /// surface history where all three were in the SAME past recording — usually
    /// never — silently emptying the brief. `.any` must keep per-person history.
    @Test @MainActor
    func speakerMatchModeAnyKeepsHistoryFromSeparateRecordings() async throws {
        let store = try await makeIsolatedStore()

        let withAlice = UUID()
        await store.createRecording(id: withAlice, title: "Sync with Alice", startDate: Date(timeIntervalSince1970: 2_000), segmentsDirURL: nil)
        await store.saveTranscript(recordingID: withAlice, fullText: "alice topic",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "alice topic", speaker: "Alice")],
            language: "en", tags: [])

        let withBob = UUID()
        await store.createRecording(id: withBob, title: "Sync with Bob", startDate: Date(timeIntervalSince1970: 1_000), segmentsDirURL: nil)
        await store.saveTranscript(recordingID: withBob, fullText: "bob topic",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "bob topic", speaker: "Bob")],
            language: "en", tags: [])

        // .any — prep: each attendee's own history survives.
        let anyMode = await store.fetchAIContext(speakerQueries: ["Alice", "Bob"], speakerMatchMode: .any)
        #expect(Set(anyMode.summaries.map(\.recordingID)) == [withAlice, withBob])

        // .all — chat: neither recording has both speakers, so nothing qualifies.
        let allMode = await store.fetchAIContext(speakerQueries: ["Alice", "Bob"], speakerMatchMode: .all)
        #expect(allMode.summaries.isEmpty)
    }

}
