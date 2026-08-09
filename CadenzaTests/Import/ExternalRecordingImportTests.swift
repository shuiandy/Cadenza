import Foundation
import SwiftData
import Testing
@testable import Cadenza

@Suite("External Recording Import", .serialized)
struct ExternalRecordingImportTests {
    @MainActor
    private static var sharedContainer: ModelContainer?

    @MainActor
    private func makeStore() async throws -> RecordingsStore {
        let container: ModelContainer
        if let existing = Self.sharedContainer {
            container = existing
        } else {
            container = try RecordingsStore.makeContainer(inMemory: true)
            Self.sharedContainer = container
        }
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        return store
    }

    private func previewInput(
        externalID: String = "note-1",
        title: String = "Weekly sync",
        sourceUpdatedAt: Date = Date(timeIntervalSince1970: 2_000),
        transcriptCharacterCount: Int = 100,
        transcriptFingerprint: String? = nil
    ) -> ExternalRecordingPreviewInput {
        ExternalRecordingPreviewInput(
            provider: "example",
            externalID: externalID,
            title: title,
            startDate: Date(timeIntervalSince1970: 1_000),
            duration: 300,
            calendarEventID: nil,
            sourceCreatedAt: Date(timeIntervalSince1970: 900),
            sourceUpdatedAt: sourceUpdatedAt,
            transcriptCharacterCount: transcriptCharacterCount,
            transcriptSegmentCount: transcriptCharacterCount == 0 ? 0 : 1,
            hasSummary: false,
            actionItemCount: 0,
            transcriptFingerprint: transcriptFingerprint
        )
    }

    private func upsertInput(
        externalID: String = "note-1",
        title: String = "Weekly sync",
        sourceUpdatedAt: Date = Date(timeIntervalSince1970: 2_000),
        transcript: String = "A complete imported transcript."
    ) -> ExternalRecordingUpsertInput {
        ExternalRecordingUpsertInput(
            provider: "example",
            externalID: externalID,
            title: title,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 1_300),
            duration: 300,
            language: "en",
            meetingApp: "External Import",
            meetingURL: nil,
            calendarEventID: nil,
            sourceCreatedAt: Date(timeIntervalSince1970: 900),
            sourceUpdatedAt: sourceUpdatedAt,
            tags: ["sync"],
            transcript: ExternalTranscriptInput(
                fullText: transcript,
                segments: [],
                detectedLanguage: "en"
            ),
            summary: nil
        )
    }

    @Test @MainActor
    func replayingSameExternalNoteCreatesOneRecording() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)

        var recordingID: UUID?
        for iteration in 0..<10 {
            let result = await service.upsert(upsertInput())
            #expect(result.status == (iteration == 0 ? .imported : .unchanged))
            recordingID = result.recordingID
        }

        let recordings = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(recordings.count == 1)
        #expect(recordings.first?.id == recordingID)
        #expect(recordings.first?.source == RecordingSource.external.rawValue)
        #expect(recordings.first?.audioFile == nil)
        #expect(await store.countExternalRecordingImports() == 1)
    }

    @Test @MainActor
    func ignoredItemRemainsAuditableAndCanBeReconsidered() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let input = previewInput(
            externalID: "empty-test",
            title: "Mic test",
            transcriptCharacterCount: 0
        )

        let ignored = await service.setDisposition(
            previewInput: input,
            disposition: .ignored,
            reason: "Confirmed empty test recording"
        )
        #expect(ignored.status == .ignored)
        let ignoredPreview = await service.preview([input])
        #expect(ignoredPreview.first?.status == .ignored)
        #expect(ignoredPreview.first?.qualitySignals.contains(.likelyEmpty) == true)
        #expect(ignoredPreview.first?.qualitySignals.contains(.likelyTest) == true)

        let reconsidered = await service.setDisposition(
            previewInput: input,
            disposition: .pending,
            reason: "User asked to reconsider"
        )
        #expect(reconsidered.status == .pending)
        let reconsideredPreview = await service.preview([input])
        #expect(reconsideredPreview.first?.status == .new)
        #expect(await store.countExternalRecordingImports() == 1)
    }

    @Test @MainActor
    func localEditBlocksNewerSourceFromOverwriting() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let first = await service.upsert(upsertInput())
        let recordingID = try #require(first.recordingID)
        #expect(await store.updateTitle(recordingID: recordingID, title: "My local title"))

        let newer = upsertInput(
            title: "Source changed title",
            sourceUpdatedAt: Date(timeIntervalSince1970: 3_000),
            transcript: "Source changed transcript."
        )
        let result = await service.upsert(newer)

        #expect(result.status == .conflict)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.title == "My local title")
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.transcript?.fullText == "A complete imported transcript.")
    }

    @Test @MainActor
    func newerSourceUpdatesWhenLocalRecordingIsUnchangedAndRejectsStaleReplay() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let first = await service.upsert(upsertInput())
        let recordingID = try #require(first.recordingID)

        let newer = upsertInput(
            title: "Weekly sync updated",
            sourceUpdatedAt: Date(timeIntervalSince1970: 3_000),
            transcript: "A newer imported transcript."
        )
        let updated = await service.upsert(newer)
        #expect(updated.status == .updated)
        #expect(updated.recordingID == recordingID)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.title == "Weekly sync updated")
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.transcript?.fullText == "A newer imported transcript.")

        let stale = await service.upsert(upsertInput())
        #expect(stale.status == .stale)
        let stalePreview = await service.preview([previewInput()])
        #expect(stalePreview.first?.status == .conflict)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.title == "Weekly sync updated")
    }

    @Test @MainActor
    func conflictRequiresExplicitReconsiderationBeforeApplyingSourceContent() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let first = await service.upsert(upsertInput())
        let recordingID = try #require(first.recordingID)
        let changedWithoutVersion = upsertInput(transcript: "Changed without a source version bump.")

        let firstConflict = await service.upsert(changedWithoutVersion)
        #expect(firstConflict.status == .conflict)
        let repeatedConflict = await service.upsert(changedWithoutVersion)
        #expect(repeatedConflict.status == .conflict)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.transcript?.fullText == "A complete imported transcript.")

        let reconsidered = await service.setDisposition(
            previewInput: previewInput(),
            disposition: .pending,
            reason: "User approved the changed source content"
        )
        #expect(reconsidered.status == .pending)
        let updated = await service.upsert(changedWithoutVersion)
        #expect(updated.status == .updated)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.transcript?.fullText == "Changed without a source version bump.")
    }

    @Test @MainActor
    func ignoredLedgerDoesNotRegressWhenOlderSourceIsSeen() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let current = previewInput(sourceUpdatedAt: Date(timeIntervalSince1970: 3_000))
        _ = await service.setDisposition(
            previewInput: current,
            disposition: .ignored,
            reason: "Keep ignored"
        )

        let older = upsertInput(
            title: "Older source title",
            sourceUpdatedAt: Date(timeIntervalSince1970: 2_000),
            transcript: "Older source transcript."
        )
        let ignored = await service.upsert(older)
        #expect(ignored.status == .ignored)
        let ledger = try #require(await store.fetchExternalRecordingImport(provider: "example", externalID: "note-1"))
        #expect(ledger.sourceUpdatedAt == Date(timeIntervalSince1970: 3_000))
        #expect(ledger.disposition == .ignored)
        #expect(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).isEmpty)
    }

    @Test @MainActor
    func possibleDuplicateDoesNotCreateOrMergeRecording() async throws {
        let store = try await makeStore()
        let existingID = UUID()
        let startDate = Date(timeIntervalSince1970: 1_000)
        #expect(await store.createRecording(id: existingID, title: "Weekly sync", startDate: startDate, segmentsDirURL: nil))

        let service = ExternalRecordingImportService(store: store)
        let preview = await service.preview([previewInput()])
        #expect(preview.first?.status == .possibleDuplicate)
        #expect(preview.first?.matchedRecordingID == existingID)

        let upsert = await service.upsert(upsertInput())
        #expect(upsert.status == .possibleDuplicate)
        #expect(upsert.recordingID == nil)
        #expect(upsert.matchedRecordingID == existingID)
        let recordings = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(recordings.count == 1)
        #expect(await store.countExternalRecordingImports() == 0)
    }

    @Test @MainActor
    func portableTranscriptFingerprintFindsPossibleDuplicate() async throws {
        let store = try await makeStore()
        let existingID = UUID()
        #expect(await store.createRecording(
            id: existingID,
            title: "Different title",
            startDate: Date(timeIntervalSince1970: 5_000),
            segmentsDirURL: nil
        ))
        #expect(await store.saveTranscript(
            recordingID: existingID,
            fullText: "abc",
            segments: [],
            language: "en",
            tags: []
        ))
        let standardSHA256 = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        #expect(ExternalRecordingFingerprint.transcript("abc") == standardSHA256.lowercased())

        let service = ExternalRecordingImportService(store: store)
        let result = await service.preview([
            previewInput(title: "Unrelated external title", transcriptFingerprint: standardSHA256),
        ])
        #expect(result.first?.status == .possibleDuplicate)
        #expect(result.first?.matchedRecordingID == existingID)
    }

    @Test @MainActor
    func transcriptStagingBoundsActiveUploadsAndReleasesExpiredSlots() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let startedAt = Date(timeIntervalSince1970: 10_000)

        for _ in 0..<ExternalRecordingImportService.maxActiveUploads {
            let result = await service.stageTranscriptChunk(
                ExternalTranscriptChunkInput(
                    uploadID: UUID(),
                    index: 0,
                    totalChunks: 2,
                    text: "held",
                    chunkSHA256: nil,
                    transcriptSHA256: nil
                ),
                now: startedAt
            )
            #expect(result.status == .staged)
        }
        let rejected = await service.stageTranscriptChunk(
            ExternalTranscriptChunkInput(
                uploadID: UUID(),
                index: 0,
                totalChunks: 2,
                text: "over capacity",
                chunkSHA256: nil,
                transcriptSHA256: nil
            ),
            now: startedAt
        )
        #expect(rejected.status == .rejected)

        let afterExpiry = await service.stageTranscriptChunk(
            ExternalTranscriptChunkInput(
                uploadID: UUID(),
                index: 0,
                totalChunks: 2,
                text: "new slot",
                chunkSHA256: nil,
                transcriptSHA256: nil
            ),
            now: startedAt.addingTimeInterval(ExternalRecordingImportService.uploadLifetime + 1)
        )
        #expect(afterExpiry.status == .staged)
    }

    @Test @MainActor
    func incompleteChunkUploadCannotCreatePartialTranscript() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let uploadID = UUID()

        let first = await service.stageTranscriptChunk(
            ExternalTranscriptChunkInput(
                uploadID: uploadID,
                index: 0,
                totalChunks: 2,
                text: "First half. ",
                chunkSHA256: nil,
                transcriptSHA256: nil
            )
        )
        #expect(first.status == .staged)
        let incomplete = await service.upsert(upsertInput(transcript: ""), transcriptUploadID: uploadID)
        #expect(incomplete.status == .incompleteUpload)
        #expect(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).isEmpty)

        let duplicate = await service.stageTranscriptChunk(
            ExternalTranscriptChunkInput(
                uploadID: uploadID,
                index: 0,
                totalChunks: 2,
                text: "First half. ",
                chunkSHA256: nil,
                transcriptSHA256: nil
            )
        )
        #expect(duplicate.status == .alreadyStaged)
        let changedDuplicate = await service.stageTranscriptChunk(
            ExternalTranscriptChunkInput(
                uploadID: uploadID,
                index: 0,
                totalChunks: 2,
                text: "Different first half. ",
                chunkSHA256: nil,
                transcriptSHA256: nil
            )
        )
        #expect(changedDuplicate.status == .rejected)

        _ = await service.stageTranscriptChunk(
            ExternalTranscriptChunkInput(
                uploadID: uploadID,
                index: 1,
                totalChunks: 2,
                text: "Second half.",
                chunkSHA256: nil,
                transcriptSHA256: nil
            )
        )
        var stagedInput = upsertInput(transcript: "placeholder")
        stagedInput.transcript?.segments = [
            ExternalTranscriptSegmentInput(
                startTime: 0,
                endTime: 1,
                text: "Segment that does not describe the staged transcript.",
                speaker: "Speaker 1"
            ),
        ]
        let committed = await service.upsert(stagedInput, transcriptUploadID: uploadID)
        let recordingID = try #require(committed.recordingID)
        #expect(committed.status == .imported)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.transcript?.fullText == "First half. Second half.")
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.transcript?.segments.isEmpty == true)
    }

    @Test @MainActor
    func failedSaveRollsBackRecordingAndImportLedger() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        await store._test_failNextSave()

        let result = await service.upsert(upsertInput())

        #expect(result.status == .failed)
        #expect(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).isEmpty)
        #expect(await store.countExternalRecordingImports() == 0)
    }

    @Test @MainActor
    func failedSourceUpdateRollsBackRecordingAndLedgerTogether() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let first = await service.upsert(upsertInput())
        let recordingID = try #require(first.recordingID)
        await store._test_failNextSave()

        let newer = upsertInput(
            title: "New source title",
            sourceUpdatedAt: Date(timeIntervalSince1970: 3_000),
            transcript: "New source transcript."
        )
        let failed = await service.upsert(newer)
        #expect(failed.status == .failed)
        let detailAfterFailure = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detailAfterFailure.title == "Weekly sync")
        #expect(detailAfterFailure.transcript?.fullText == "A complete imported transcript.")
        let ledgerAfterFailure = try #require(
            await store.fetchExternalRecordingImport(provider: "example", externalID: "note-1")
        )
        #expect(ledgerAfterFailure.sourceUpdatedAt == Date(timeIntervalSince1970: 2_000))
        #expect(ledgerAfterFailure.disposition == .imported)

        let retried = await service.upsert(newer)
        #expect(retried.status == .updated)
        #expect((await store.fetchRecordingDetail(recordingID: recordingID))?.title == "New source title")
    }

    @Test @MainActor
    func permanentlyDeletedRecordingLeavesOnlyAReplayBlockingTombstone() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let imported = await service.upsert(upsertInput())
        let recordingID = try #require(imported.recordingID)
        #expect(await store.deleteRecording(recordingID: recordingID))
        #expect(await store.permanentlyDelete(recordingID: recordingID))

        let ledger = try #require(await store.fetchExternalRecordingImport(provider: "example", externalID: "note-1"))
        #expect(ledger.externalKey.hasPrefix("deleted:"))
        #expect(ledger.externalKey.count == "deleted:".count + 64)
        #expect(!ledger.externalKey.contains("note-1"))
        #expect(ledger.provider == "example")
        #expect(ledger.externalID.isEmpty)
        #expect(ledger.recordingID == nil)
        #expect(ledger.sourceCreatedAt == nil)
        #expect(ledger.sourceUpdatedAt == Date(timeIntervalSince1970: 0))
        #expect(ledger.lastAppliedAt == nil)
        #expect(ledger.contentFingerprint == nil)
        #expect(ledger.lastAppliedLocalFingerprint == nil)
        #expect(ledger.disposition == .ignored)
        #expect(ledger.reason == RecordingsStore.userDeletedExternalImportReason)
        #expect(ledger.qualitySignals.isEmpty)
        #expect(await store.countExternalRecordingImports() == 1)
        let preview = await service.preview([previewInput()])
        #expect(preview.first?.status == .ignored)

        let replay = await service.upsert(upsertInput(
            title: "PRIVATE-REPLAY-TITLE",
            sourceUpdatedAt: Date(timeIntervalSince1970: 9_000),
            transcript: "PRIVATE-REPLAY-TRANSCRIPT"
        ))
        #expect(replay.status == .ignored)
        #expect(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).isEmpty)
        let scrubbed = try #require(await store.externalImportDeletionSnapshotForTesting(
            provider: "example",
            externalID: "note-1"
        ))
        #expect(scrubbed.externalKey == ledger.externalKey)
        #expect(scrubbed.provider == "example")
        #expect(scrubbed.externalID.isEmpty)
        #expect(scrubbed.recordingID == nil)
        #expect(scrubbed.sourceTitle.isEmpty)
        #expect(scrubbed.sourceStartDate == Date(timeIntervalSince1970: 0))
        #expect(scrubbed.sourceDuration == 0)
        #expect(scrubbed.sourceCalendarEventID == nil)
        #expect(scrubbed.sourceCreatedAt == nil)
        #expect(scrubbed.sourceUpdatedAt == Date(timeIntervalSince1970: 0))
        #expect(scrubbed.lastAppliedAt == nil)
        #expect(scrubbed.contentFingerprint == nil)
        #expect(scrubbed.transcriptFingerprint == nil)
        #expect(scrubbed.lastAppliedSourceFingerprint == nil)
        #expect(scrubbed.lastAppliedLocalFingerprint == nil)
        #expect(scrubbed.disposition == ExternalImportDisposition.ignored.rawValue)
        #expect(scrubbed.reason == RecordingsStore.userDeletedExternalImportReason)
        #expect(scrubbed.qualitySignals.isEmpty)
    }

    @Test @MainActor
    func explicitReconsiderationRestoresHashedDeletionIdentityAndAllowsImport() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let imported = await service.upsert(upsertInput())
        let recordingID = try #require(imported.recordingID)
        #expect(await store.deleteRecording(recordingID: recordingID))
        #expect(await store.permanentlyDelete(recordingID: recordingID))

        let reconsidered = await service.setDisposition(
            previewInput: previewInput(
                title: "Reconsidered title",
                sourceUpdatedAt: Date(timeIntervalSince1970: 8_000)
            ),
            disposition: .pending,
            reason: "User explicitly reconsidered"
        )
        let restoredIdentity = try #require(
            await store.fetchExternalRecordingImport(provider: "example", externalID: "note-1")
        )
        let restored = await service.upsert(upsertInput(
            title: "Reconsidered title",
            sourceUpdatedAt: Date(timeIntervalSince1970: 8_000),
            transcript: "Explicitly restored transcript"
        ))

        #expect(reconsidered.status == .pending)
        #expect(restoredIdentity.externalKey == "example:note-1")
        #expect(restoredIdentity.externalID == "note-1")
        #expect(restored.status == .imported)
        #expect(restored.recordingID != nil)
        #expect(await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).count == 1)
    }

    @Test @MainActor
    func permanentDeleteSaveFailureRollsBackExternalLedgerScrub() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        let imported = await service.upsert(upsertInput())
        let recordingID = try #require(imported.recordingID)
        #expect(await store.deleteRecording(recordingID: recordingID))
        let before = try #require(await store.externalImportDeletionSnapshotForTesting(
            provider: "example",
            externalID: "note-1"
        ))
        await store._test_failNextSave()

        let outcome = await store.permanentlyDeleteWithOutcome(recordingID: recordingID)
        let after = try #require(await store.externalImportDeletionSnapshotForTesting(
            provider: "example",
            externalID: "note-1"
        ))

        #expect(outcome == .failed(.persistenceFailed))
        #expect(await store.fetchRecordingDetail(recordingID: recordingID) != nil)
        #expect(after == before)
    }

    @Test @MainActor
    func orphanCleanupPreservesExplicitExternalNoteWithoutAudioOrContent() async throws {
        let store = try await makeStore()
        let service = ExternalRecordingImportService(store: store)
        var empty = upsertInput(
            externalID: "empty-but-explicit",
            title: "External placeholder",
            transcript: ""
        )
        empty.endDate = nil
        empty.duration = 0
        empty.transcript = nil

        let imported = await service.upsert(empty)
        let recordingID = try #require(imported.recordingID)
        #expect(imported.status == .imported)
        #expect(await store.purgeOrphanedEmptyRecordings() == 0)
        #expect(await store.fetchRecordingDetail(recordingID: recordingID) != nil)
        #expect(await store.countExternalRecordingImports() == 1)
    }

}
