import Foundation
import SwiftData
import Testing

@testable import Cadenza

@Suite("Batch mutation wiring", .serialized)
@MainActor
struct BatchMutationWiringTests {
    private struct Fixture {
        let store: RecordingsStore
        let recordingIDs: Set<UUID>
        let folderID: UUID?
    }

    private enum SourceFixtureError: Error {
        case missingMarker(String)
        case injectedEncodingFailure
    }

    @Test
    func appStateTrashRefreshesAllSurfacesExactlyOnceForOneThousandRows() async throws {
        let fixture = try makeFixture(recordingCount: 1_000)
        let appState = AppState(startupPolicy: .testHost)
        appState.store = fixture.store
        appState.recordings = await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        let initialToken = appState.recordingsChangedToken

        let result: RecordingsStore.BatchMutationResult = await withCheckedContinuation {
            continuation in
            appState.deleteRecordings(recordingIDs: fixture.recordingIDs) {
                continuation.resume(returning: $0)
            }
        }

        let persistedTrash = await fixture.store.fetchTrashedRecordings()
        #expect(result.didCommit)
        #expect(result.committedCount == 1_000)
        #expect(appState.recordingsChangedToken == initialToken + 1)
        #expect(appState.recordings.isEmpty)
        #expect(appState.trashedRecordings.count == 1_000)
        #expect(persistedTrash.count == 1_000)
    }

    @Test
    func appStateTrashSaveFailureDoesNotCancelAndCanRetry() async throws {
        let fixture = try makeFixture(recordingCount: 2)
        let appState = AppState(startupPolicy: .testHost)
        appState.store = fixture.store
        appState.recordings = await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        var cancelledIDs: Set<UUID> = []
        appState.discardCancellationSinkForTesting = { recordingID in
            cancelledIDs.insert(recordingID)
        }
        var failureFeedbackCount = 0
        appState.deletionFeedbackSink = { _ in
            failureFeedbackCount += 1
        }
        await fixture.store.failNextSaveForTesting()

        let failedResult: RecordingsStore.BatchMutationResult = await withCheckedContinuation {
            continuation in
            appState.deleteRecordings(recordingIDs: fixture.recordingIDs) {
                continuation.resume(returning: $0)
            }
        }

        #expect(failedResult.failure == .persistenceFailed)
        #expect(cancelledIDs.isEmpty)
        #expect(failureFeedbackCount == 1)
        #expect(!appState.isBatchMutationInProgress)
        #expect(await fixture.store.fetchTrashedRecordings().isEmpty)

        let retryResult: RecordingsStore.BatchMutationResult = await withCheckedContinuation {
            continuation in
            appState.deleteRecordings(recordingIDs: fixture.recordingIDs) {
                continuation.resume(returning: $0)
            }
        }

        #expect(retryResult.didCommit)
        #expect(retryResult.committedCount == 2)
        #expect(cancelledIDs == fixture.recordingIDs)
        #expect(failureFeedbackCount == 1)
        #expect(!appState.isBatchMutationInProgress)
        #expect(await fixture.store.fetchTrashedRecordings().count == 2)
    }

    @Test
    func immediateMoveDuringTrashIsBlockedWithoutFeedbackOrSelectionCommit() async throws {
        let fixture = try makeFixture(recordingCount: 1, includeFolder: true)
        let folderID = try #require(fixture.folderID)
        let appState = AppState(startupPolicy: .testHost)
        appState.store = fixture.store
        appState.recordings = await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        var deletionFeedbackCount = 0
        appState.deletionFeedbackSink = { _ in
            deletionFeedbackCount += 1
        }
        var batchFailureFeedbackCount = 0
        appState.batchMutationFailureSink = {
            batchFailureFeedbackCount += 1
        }
        var trashResult: RecordingsStore.BatchMutationResult?

        appState.deleteRecordings(recordingIDs: fixture.recordingIDs) {
            trashResult = $0
        }
        #expect(appState.isBatchMutationInProgress)

        var blockedMoveResult: RecordingsStore.BatchMutationResult?
        appState.moveRecordingsToFolder(
            recordingIDs: fixture.recordingIDs,
            folderID: folderID
        ) {
            blockedMoveResult = $0
        }

        #expect(blockedMoveResult?.failure == .operationInProgress)
        #expect(blockedMoveResult?.requestedCount == 1)
        #expect(blockedMoveResult?.committedCount == 0)
        #expect(deletionFeedbackCount == 0)
        #expect(batchFailureFeedbackCount == 0)
        #expect(appState.isBatchMutationInProgress)

        for _ in 0..<10_000 {
            if trashResult != nil { break }
            await Task.yield()
        }
        let committedTrashResult = try #require(trashResult)
        #expect(committedTrashResult.didCommit)
        #expect(!appState.isBatchMutationInProgress)
        #expect(await fixture.store.fetchTrashedRecordings().count == 1)
        #expect(await fixture.store.fetchFolderDetail(folderID: folderID)?.recordings.isEmpty == true)
    }

    @Test
    func appStateMoveFailurePublishesOnceAndDoesNotRefresh() async throws {
        let fixture = try makeFixture(recordingCount: 1_000, includeFolder: true)
        let folderID = try #require(fixture.folderID)
        let appState = AppState(startupPolicy: .testHost)
        appState.store = fixture.store
        appState.recordings = await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )
        let initialRecordingIDs = Set(appState.recordings.map(\.id))
        let initialToken = appState.recordingsChangedToken
        var failureFeedbackCount = 0
        appState.batchMutationFailureSink = {
            failureFeedbackCount += 1
        }
        await fixture.store.failNextSaveForTesting()

        let result: RecordingsStore.BatchMutationResult = await withCheckedContinuation {
            continuation in
            appState.moveRecordingsToFolder(
                recordingIDs: fixture.recordingIDs,
                folderID: folderID
            ) {
                continuation.resume(returning: $0)
            }
        }

        let folderDetail = await fixture.store.fetchFolderDetail(folderID: folderID)
        #expect(result.failure == .persistenceFailed)
        #expect(result.committedCount == 0)
        #expect(failureFeedbackCount == 1)
        #expect(appState.recordingsChangedToken == initialToken)
        #expect(Set(appState.recordings.map(\.id)) == initialRecordingIDs)
        #expect(folderDetail?.recordings.isEmpty == true)
    }

    @Test
    func recordingsViewUsesBatchAPIsAndPreservesSelectionOnPersistenceFailure() throws {
        let viewSource = try source("Cadenza/Views/Recordings/RecordingsContentView.swift")

        #expect(!viewSource.contains("appState.deleteRecording(recordingID:"))
        #expect(!viewSource.contains("appState.moveRecordingToFolder(recordingID:"))
        #expect(!viewSource.contains("appState.pinRecordingToSmartFolder(recordingID:"))
        #expect(!viewSource.contains("appState.excludeRecordingFromSmartFolder(recordingID:"))

        #expect(occurrences(of: "appState.deleteRecordings(recordingIDs:", in: viewSource) == 2)
        #expect(occurrences(of: "appState.moveRecordingsToFolder(", in: viewSource) == 3)
        #expect(occurrences(of: "appState.pinRecordingsToSmartFolder(", in: viewSource) == 2)
        #expect(occurrences(of: "appState.excludeRecordingsFromSmartFolder(", in: viewSource) == 2)

        // Every asynchronous persistence action checks the structured store
        // outcome before subtracting its snapshotted target IDs. A failed
        // mutation therefore leaves the current selection unchanged.
        #expect(occurrences(of: "guard result.didCommit else { return }", in: viewSource) == 5)
        #expect(occurrences(of: "guard appState.pinRecordingsToSmartFolder(", in: viewSource) == 2)
        #expect(occurrences(of: "guard appState.excludeRecordingsFromSmartFolder(", in: viewSource) == 2)
        #expect(occurrences(of: "selectedIDs.subtract(targetIDs)", in: viewSource) == 9)
        #expect(occurrences(
            of: "guard !targetIDs.isEmpty, !appState.isBatchMutationInProgress else { return }",
            in: viewSource
        ) == 2)
        #expect(occurrences(
            of: ".disabled(appState.isBatchMutationInProgress)",
            in: viewSource
        ) == 5)
    }

    @Test
    func smartFolderEncodingAndWriteFailuresAreStructuredAndObservable() {
        let recordingID = UUID()
        let folderID = SmartFolderID.oneOnOnes.rawValue
        var encodingFailureWriteAttempts = 0
        let encodingFailureStore = SmartFolderOverrideStore(
            dataForKey: { _ in nil },
            setData: { _, _ in
                encodingFailureWriteAttempts += 1
                return true
            },
            encodeDocument: { _ in
                throw SourceFixtureError.injectedEncodingFailure
            }
        )

        let encodingResult = encodingFailureStore.pin(
            recordingIDs: [recordingID],
            to: folderID
        )

        #expect(encodingResult.failure == .encodingFailed)
        #expect(!encodingResult.didCommit)
        #expect(encodingResult.changedCount == 0)
        #expect(encodingFailureWriteAttempts == 0)

        var writeAttempts = 0
        let writeFailureStore = SmartFolderOverrideStore(
            dataForKey: { _ in nil },
            setData: { _, _ in
                writeAttempts += 1
                return false
            }
        )
        let appState = AppState(startupPolicy: .testHost)
        appState.setSmartFolderOverrideStoreForTesting(writeFailureStore)
        var failureFeedbackCount = 0
        appState.batchMutationFailureSink = {
            failureFeedbackCount += 1
        }
        let initialToken = appState.smartFolderOverridesChangedToken

        let didCommit = appState.pinRecordingsToSmartFolder(
            recordingIDs: [recordingID],
            smartFolderID: folderID
        )

        #expect(!didCommit)
        #expect(writeAttempts == 1)
        #expect(failureFeedbackCount == 1)
        #expect(appState.smartFolderOverridesChangedToken == initialToken)
        #expect(writeFailureStore.load() == .empty)
    }

    @Test
    func appStateBatchMethodsOwnOneTaskReconcileAndRefresh() throws {
        let appStateSource = try source("Cadenza/App/AppState.swift")
        let trash = try section(
            in: appStateSource,
            from: "    func deleteRecordings(",
            to: "    func restoreRecording("
        )
        let move = try section(
            in: appStateSource,
            from: "    func moveRecordingsToFolder(",
            to: "    func smartFolder("
        )
        let saveSmartFolder = try section(
            in: appStateSource,
            from: "    func saveSmartFolderAsFolder(",
            to: "    func createFolder("
        )

        #expect(occurrences(of: "Task {", in: trash) == 1)
        #expect(occurrences(of: "claimBatchMutation(", in: trash) == 1)
        #expect(occurrences(of: "store.trashRecordings(", in: trash) == 1)
        #expect(occurrences(of: "webSync?.reconcile()", in: trash) == 1)
        #expect(occurrences(of: "reloadBatchMutationSurfaces(", in: trash) == 1)
        #expect(!trash.contains("refreshRecordings()"))
        #expect(!trash.contains("refreshTrash()"))

        #expect(occurrences(of: "Task {", in: move) == 1)
        #expect(occurrences(of: "claimBatchMutation(", in: move) == 1)
        #expect(occurrences(of: "store.moveRecordingsToFolder(", in: move) == 1)
        #expect(occurrences(of: "webSync?.reconcile()", in: move) == 1)
        #expect(occurrences(of: "reloadBatchMutationSurfaces(", in: move) == 1)
        #expect(!move.contains("refreshRecordings()"))
        #expect(!move.contains("refreshFolders()"))

        #expect(occurrences(of: "store.moveRecordingsToFolder(", in: saveSmartFolder) == 1)
        #expect(occurrences(of: "claimBatchMutation(", in: saveSmartFolder) == 1)
        #expect(occurrences(of: "webSync?.reconcile()", in: saveSmartFolder) == 1)
        #expect(occurrences(of: "reloadBatchMutationSurfaces(", in: saveSmartFolder) == 1)
        #expect(!saveSmartFolder.contains("for recording"))
        #expect(!saveSmartFolder.contains("moveToFolder(recordingID:"))
    }

    @Test
    func appStateTrashCancellationOccursOnlyAfterPersistenceSuccess() throws {
        let appStateSource = try source("Cadenza/App/AppState.swift")
        let singleTrash = try section(
            in: appStateSource,
            from: "    func deleteRecording(",
            to: "    func deleteRecordings("
        )
        let batchTrash = try section(
            in: appStateSource,
            from: "    func deleteRecordings(",
            to: "    func restoreRecording("
        )

        let singleCommitGuard = try #require(singleTrash.range(
            of: "guard await store.deleteRecording(recordingID: recordingID) else"
        ))
        let singleCancellation = try #require(singleTrash.range(
            of: "coordinator?.cancelJob(for: recordingID, disposition: .discard)"
        ))
        #expect(singleCancellation.lowerBound > singleCommitGuard.lowerBound)

        let batchCommitGuard = try #require(batchTrash.range(of: "guard result.didCommit else"))
        let batchCancellation = try #require(batchTrash.range(
            of: "coordinator?.cancelJob(for: recordingID, disposition: .discard)"
        ))
        #expect(batchCancellation.lowerBound > batchCommitGuard.lowerBound)
    }

    private func makeFixture(
        recordingCount: Int,
        includeFolder: Bool = false
    ) throws -> Fixture {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let folder: Folder?
        if includeFolder {
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
            context.insert(recording)
            recordingIDs.insert(recording.id)
        }
        try context.save()
        return Fixture(
            store: RecordingsStore(modelContainer: container),
            recordingIDs: recordingIDs,
            folderID: folder?.id
        )
    }

    private func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker) else {
            throw SourceFixtureError.missingMarker(startMarker)
        }
        guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            throw SourceFixtureError.missingMarker(endMarker)
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
