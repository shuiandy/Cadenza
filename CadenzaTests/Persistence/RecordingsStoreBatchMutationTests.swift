import SwiftData
import Testing
@testable import Cadenza

@Suite("RecordingsStore batch mutation", .serialized)
@MainActor
struct RecordingsStoreBatchMutationTests {
    private struct Fixture {
        let container: ModelContainer
        let store: RecordingsStore
        let recordingIDs: Set<UUID>
        let folderID: UUID?
    }

    private func makeFixture(
        recordingCount: Int,
        includeFolder: Bool = false,
        assignRecordingsToFolder: Bool = false
    ) throws -> Fixture {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let folder: Folder?
        if includeFolder || assignRecordingsToFolder {
            let created = Folder(name: "Batch destination")
            context.insert(created)
            folder = created
        } else {
            folder = nil
        }
        var recordingIDs: Set<UUID> = []
        recordingIDs.reserveCapacity(recordingCount)
        for index in 0..<recordingCount {
            let recording = Recording(
                title: "Batch \(index)",
                startDate: Date(timeIntervalSinceReferenceDate: Double(index))
            )
            if assignRecordingsToFolder {
                recording.folder = folder
            }
            context.insert(recording)
            recordingIDs.insert(recording.id)
        }
        try context.save()
        return Fixture(
            container: container,
            store: RecordingsStore(modelContainer: container),
            recordingIDs: recordingIDs,
            folderID: folder?.id
        )
    }

    private func stageAttachedSpeakerSample(
        store: RecordingsStore,
        recordingID: UUID,
        modelVersion: String
    ) async throws -> UUID {
        await store.setSpeakerMemoryConsentForTesting(true)
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Staged profile")
        )
        #expect(await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([0.1, 0.2, 0.3, 0.4]),
            embeddingDimension: 4,
            sampleDuration: 30,
            nonOverlapRatio: 0.8,
            qualityScore: 24,
            modelVersion: modelVersion
        ))
        #expect(await store.attachSampleToProfile(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id,
            persist: false
        ))
        return profile.id
    }

    @Test(arguments: [false, true])
    func privateContextFailuresPreserveEarlierStagedChanges(personalResult: Bool) async throws {
        let fixture = try makeFixture(recordingCount: 1)
        let id = try #require(fixture.recordingIDs.first)
        let input = SummaryContextInput()
        var output: PersonalRelevance?
        if personalResult {
            let summary = SummaryResult(title: "Fictional", overview: "Access review", keyPoints: ["Review pending"],
                actionItems: [], decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
            #expect(await fixture.store.saveSummary(recordingID: id, summary: summary, chaptersJSON: nil) == .saved)
            #expect(await fixture.store.saveSummaryContext(recordingID: id, input: input))
            let detail = try #require(await fixture.store.fetchSummaryContextDetail(recordingID: id))
            let source = try #require(SummaryContextSnapshot.build(detail: detail, input: input, userName: "Nora", jobTitle: "",
                defaultFocus: "Access", event: nil, history: []))
            output = try #require(PersonalRelevance.parse("{}", snapshot: source))
        }
        let version = "private-context-mutation"
        let profileID = try await stageAttachedSpeakerSample(store: fixture.store, recordingID: id, modelVersion: version)
        await fixture.store.failNextSaveForTesting()
        if let output { #expect(await fixture.store.savePersonalRelevance(recordingID: id, result: output) == false) }
        else { #expect(await fixture.store.saveSummaryContext(recordingID: id, input: input) == false) }
        let reader = RecordingsStore(modelContainer: fixture.container)
        #expect(await reader.fetchConfirmedSamples(modelVersion: version).contains { $0.profileID == profileID })
        #expect(await reader.fetchSummaryContext(recordingID: id).1 == nil)
    }

    @Test
    func trashCommitsOneThousandRowsAsOneBatch() async throws {
        let fixture = try makeFixture(
            recordingCount: 1_000,
            assignRecordingsToFolder: true
        )
        var requestedIDs = fixture.recordingIDs
        requestedIDs.insert(UUID())

        let result = await fixture.store.trashRecordings(
            recordingIDs: requestedIDs,
            reason: "batch-test"
        )

        #expect(result == RecordingsStore.BatchMutationResult(
            requestedCount: 1_001,
            matchedCount: 1_000,
            committedCount: 1_000,
            failure: nil
        ))
        let trashed = await fixture.store.fetchTrashedRecordings()
        #expect(trashed.count == 1_000)
        #expect(trashed.allSatisfy { $0.folderID == nil })
        #expect(await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).isEmpty)
    }

    @Test
    func trashSaveFailureRollsBackEveryRowAndCannotLeakIntoLaterSave() async throws {
        let fixture = try makeFixture(
            recordingCount: 1_000,
            assignRecordingsToFolder: true
        )
        let folderID = try #require(fixture.folderID)
        await fixture.store.failNextSaveForTesting()

        let result = await fixture.store.trashRecordings(
            recordingIDs: fixture.recordingIDs,
            reason: "batch-test"
        )

        #expect(result.failure == .persistenceFailed)
        #expect(result.matchedCount == 1_000)
        #expect(result.committedCount == 0)
        #expect(await fixture.store.fetchTrashedRecordings().isEmpty)
        #expect(await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).count == 1_000)
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.count == 1_000)

        #expect(await fixture.store.createRecording(
            id: UUID(),
            title: "Later save",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await fixture.store.fetchTrashedRecordings().isEmpty)
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.count == 1_000)
        #expect(await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).count == 1_001)
    }

    @Test
    func trashFailurePreservesPreviouslyStagedWork() async throws {
        let fixture = try makeFixture(recordingCount: 1, assignRecordingsToFolder: true)
        let recordingID = try #require(fixture.recordingIDs.first)
        let modelVersion = "batch-trash-standalone-boundary-v1"
        let profileID = try await stageAttachedSpeakerSample(
            store: fixture.store,
            recordingID: recordingID,
            modelVersion: modelVersion
        )
        await fixture.store.failNextSaveForTesting()

        let result = await fixture.store.trashRecordings(
            recordingIDs: [recordingID],
            reason: "staged-work-regression"
        )

        #expect(result.failure == .persistenceFailed)
        let reader = RecordingsStore(modelContainer: fixture.container)
        #expect(
            await reader.fetchConfirmedSamples(modelVersion: modelVersion)
                .contains { $0.profileID == profileID }
        )
        #expect(await reader.fetchTrashedRecordings().isEmpty)
        #expect(await fixture.store.updateTitle(recordingID: recordingID, title: "Later save"))
        let readerAfterLaterSave = RecordingsStore(modelContainer: fixture.container)
        #expect(await readerAfterLaterSave.fetchTrashedRecordings().isEmpty)
    }

    @Test
    func folderMoveCommitsOneThousandRowsAsOneBatch() async throws {
        let fixture = try makeFixture(recordingCount: 1_000, includeFolder: true)
        let folderID = try #require(fixture.folderID)

        let result = await fixture.store.moveRecordingsToFolder(
            recordingIDs: fixture.recordingIDs,
            folderID: folderID
        )

        #expect(result.didCommit)
        #expect(result.requestedCount == 1_000)
        #expect(result.matchedCount == 1_000)
        #expect(result.committedCount == 1_000)
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.count == 1_000)
    }

    @Test
    func folderMoveSaveFailureRollsBackEveryRowAndCannotLeakIntoLaterSave() async throws {
        let fixture = try makeFixture(recordingCount: 1_000, includeFolder: true)
        let folderID = try #require(fixture.folderID)
        await fixture.store.failNextSaveForTesting()

        let result = await fixture.store.moveRecordingsToFolder(
            recordingIDs: fixture.recordingIDs,
            folderID: folderID
        )

        #expect(result.failure == .persistenceFailed)
        #expect(result.matchedCount == 1_000)
        #expect(result.committedCount == 0)
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.isEmpty == true)

        #expect(await fixture.store.createRecording(
            id: UUID(),
            title: "Later save",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.isEmpty == true)
    }

    @Test
    func folderMoveFailurePreservesPreviouslyStagedWork() async throws {
        let fixture = try makeFixture(recordingCount: 1, includeFolder: true)
        let recordingID = try #require(fixture.recordingIDs.first)
        let folderID = try #require(fixture.folderID)
        let modelVersion = "batch-move-standalone-boundary-v1"
        let profileID = try await stageAttachedSpeakerSample(
            store: fixture.store,
            recordingID: recordingID,
            modelVersion: modelVersion
        )
        await fixture.store.failNextSaveForTesting()

        let result = await fixture.store.moveRecordingsToFolder(
            recordingIDs: [recordingID],
            folderID: folderID
        )

        #expect(result.failure == .persistenceFailed)
        let reader = RecordingsStore(modelContainer: fixture.container)
        #expect(
            await reader.fetchConfirmedSamples(modelVersion: modelVersion)
                .contains { $0.profileID == profileID }
        )
        #expect(await reader.fetchFolderDetail(folderID: folderID)?.recordings.isEmpty == true)
        #expect(await fixture.store.updateTitle(recordingID: recordingID, title: "Later save"))
        let readerAfterLaterSave = RecordingsStore(modelContainer: fixture.container)
        #expect(
            await readerAfterLaterSave.fetchFolderDetail(folderID: folderID)?.recordings.isEmpty
                == true
        )
    }

    @Test
    func folderMoveDoesNotReattachTrashedRecording() async throws {
        let fixture = try makeFixture(recordingCount: 1, includeFolder: true)
        let recordingID = try #require(fixture.recordingIDs.first)
        let folderID = try #require(fixture.folderID)

        let trashResult = await fixture.store.trashRecordings(
            recordingIDs: [recordingID],
            reason: "batch-test"
        )
        let moveResult = await fixture.store.moveRecordingsToFolder(
            recordingIDs: [recordingID],
            folderID: folderID
        )

        #expect(trashResult.committedCount == 1)
        #expect(moveResult.didCommit)
        #expect(moveResult.requestedCount == 1)
        #expect(moveResult.matchedCount == 0)
        #expect(moveResult.committedCount == 0)
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.isEmpty == true)
        let trashed = await fixture.store.fetchTrashedRecordings()
        #expect(trashed.map(\.id) == [recordingID])
        #expect(trashed.first?.folderID == nil)
    }
}
