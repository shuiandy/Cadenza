import Foundation
import Testing
@testable import Cadenza

@Suite("Web sync persistence", .serialized)
struct WebSyncPersistenceTests {
    @Test @MainActor
    func failedStateSaveThrowsAndRollsBackMutation() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        var mutation = WebSyncMutation(userID: "user-a", recordingID: recordingID)
        mutation.structuredState = WebStructuredSyncState.synced.rawValue

        await store.failNextSaveForTesting()

        await #expect(throws: WebSyncPersistenceError.self) {
            _ = try await store.upsertWebSyncRecord(mutation)
        }
        #expect(await store.fetchWebSyncRecord(userID: "user-a", recordingID: recordingID) == nil)
    }

    @Test @MainActor
    func accountKeysAreIsolatedAndHardDeleteKeepsTombstone() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "History", startDate: Date(), segmentsDirURL: nil))

        var first = WebSyncMutation(userID: "user-a", recordingID: id)
        first.structuredState = WebStructuredSyncState.synced.rawValue
        _ = try await store.upsertWebSyncRecord(first)
        var second = WebSyncMutation(userID: "user-b", recordingID: id)
        second.structuredState = WebStructuredSyncState.pending.rawValue
        _ = try await store.upsertWebSyncRecord(second)

        let firstRecord = await store.fetchWebSyncRecord(userID: "user-a", recordingID: id)
        let secondRecord = await store.fetchWebSyncRecord(userID: "user-b", recordingID: id)
        #expect(firstRecord?.syncKey != secondRecord?.syncKey)

        #expect(await store.deleteRecording(recordingID: id))
        #expect(await store.permanentlyDelete(recordingID: id))
        let tombstone = await store.fetchWebSyncRecord(userID: "user-a", recordingID: id)
        #expect(tombstone?.isDeletionTombstone == true)
        #expect(try await store.fetchWebSyncSnapshot(recordingID: id) == nil)
    }

    @Test @MainActor
    func initialNotFoundRecoveryIsAccountScopedAndPreservesOtherFailures() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()

        let affectedID = UUID()
        var affected = WebSyncMutation(userID: "user-a", recordingID: affectedID)
        affected.structuredState = WebStructuredSyncState.failed.rawValue
        affected.audioState = WebAudioSyncState.failed.rawValue
        affected.attemptCount = 1
        affected.nextAttemptAt = .distantFuture
        affected.lastErrorCode = "server(status: 404)"
        _ = try await store.upsertWebSyncRecord(affected)

        let otherAccountID = UUID()
        var otherAccount = WebSyncMutation(userID: "user-b", recordingID: otherAccountID)
        otherAccount.structuredState = WebStructuredSyncState.failed.rawValue
        otherAccount.audioState = WebAudioSyncState.failed.rawValue
        otherAccount.attemptCount = 1
        otherAccount.nextAttemptAt = .distantFuture
        otherAccount.lastErrorCode = "server(status: 404)"
        _ = try await store.upsertWebSyncRecord(otherAccount)

        let otherFailureID = UUID()
        var otherFailure = WebSyncMutation(userID: "user-a", recordingID: otherFailureID)
        otherFailure.structuredState = WebStructuredSyncState.failed.rawValue
        otherFailure.audioState = WebAudioSyncState.failed.rawValue
        otherFailure.attemptCount = 2
        otherFailure.nextAttemptAt = .distantFuture
        otherFailure.lastErrorCode = "server(status: 400)"
        _ = try await store.upsertWebSyncRecord(otherFailure)

        let syncedID = UUID()
        var synced = WebSyncMutation(userID: "user-a", recordingID: syncedID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.audioState = WebAudioSyncState.failed.rawValue
        synced.attemptCount = 1
        synced.nextAttemptAt = .distantFuture
        synced.lastErrorCode = "server(status: 404)"
        _ = try await store.upsertWebSyncRecord(synced)

        let serverFailureID = UUID()
        var serverFailure = WebSyncMutation(userID: "user-a", recordingID: serverFailureID)
        serverFailure.structuredState = WebStructuredSyncState.failed.rawValue
        serverFailure.audioState = WebAudioSyncState.failed.rawValue
        serverFailure.attemptCount = 3
        serverFailure.nextAttemptAt = .distantFuture
        serverFailure.lastErrorCode = "server(status: 500)"
        _ = try await store.upsertWebSyncRecord(serverFailure)

        let count = try await store.requeueInitialWebSyncNotFoundFailures(userID: "user-a")

        #expect(count == 1)
        let recovered = await store.fetchWebSyncRecord(userID: "user-a", recordingID: affectedID)
        #expect(recovered?.structuredState == WebStructuredSyncState.pending.rawValue)
        #expect(recovered?.audioState == WebAudioSyncState.pending.rawValue)
        #expect(recovered?.attemptCount == 0)
        #expect(recovered?.nextAttemptAt == nil)

        let preservedAccount = await store.fetchWebSyncRecord(userID: "user-b", recordingID: otherAccountID)
        #expect(preservedAccount?.structuredState == WebStructuredSyncState.failed.rawValue)
        #expect(preservedAccount?.nextAttemptAt == .distantFuture)

        let preservedFailure = await store.fetchWebSyncRecord(userID: "user-a", recordingID: otherFailureID)
        #expect(preservedFailure?.attemptCount == 2)
        #expect(preservedFailure?.nextAttemptAt == .distantFuture)

        let preservedSynced = await store.fetchWebSyncRecord(userID: "user-a", recordingID: syncedID)
        #expect(preservedSynced?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(preservedSynced?.remoteRecordingID == "remote-1")

        let serverCount = try await store.requeueInitialWebSyncServerFailures(userID: "user-a")
        #expect(serverCount == 1)
        let recoveredServer = await store.fetchWebSyncRecord(userID: "user-a", recordingID: serverFailureID)
        #expect(recoveredServer?.structuredState == WebStructuredSyncState.pending.rawValue)
        #expect(recoveredServer?.attemptCount == 0)
        #expect(recoveredServer?.nextAttemptAt == nil)
    }
}
