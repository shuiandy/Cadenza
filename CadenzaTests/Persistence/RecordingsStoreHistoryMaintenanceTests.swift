import Foundation
import SwiftData
import Testing
@testable import Cadenza

@Suite("Persistent history retention", .serialized)
struct RecordingsStoreHistoryMaintenanceTests {

    private func makeFileBackedStore() throws -> (RecordingsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("Cadenza.store")
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        return (RecordingsStore(modelContainer: container), directory)
    }

    @Test func pruningRemovesOnlyTransactionsOlderThanTheCutoff() async throws {
        let (store, directory) = try makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "First", startDate: Date(), segmentsDirURL: nil
        ))
        #expect(await store.updateTitle(recordingID: recordingID, title: "Second"))
        #expect(await store.updateTitle(recordingID: recordingID, title: "Third"))

        let before = await store.historyTransactionCount()
        #expect(before >= 3)

        // A cutoff in the past keeps everything.
        let untouched = await store.pruneHistory(olderThan: Date(timeIntervalSince1970: 0))
        #expect(untouched.slicesDeleted == 0)
        #expect(await store.historyTransactionCount() == before)

        // A cutoff in the future clears it all, in bounded slices.
        let pruned = await store.pruneHistory(
            olderThan: Date().addingTimeInterval(60), sliceLength: 60 * 60
        )
        #expect(pruned.slicesDeleted >= 1)
        #expect(pruned.oldestRemaining == nil)
        #expect(await store.historyTransactionCount() == 0)

        // The data itself is untouched: history is bookkeeping, not content.
        let detail = await store.fetchRecordingDetail(recordingID: recordingID)
        #expect(detail?.title == "Third")
    }

    @Test func sliceAPIDeletesOneSlicePerCallAndReportsCompletion() async throws {
        let (store, directory) = try makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingID = UUID()
        #expect(await store.createRecording(id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil))
        #expect(await store.updateTitle(recordingID: recordingID, title: "Two"))
        #expect(await store.historyTransactionCount() >= 2)

        let future = Date().addingTimeInterval(60)
        // All of today's history falls in one day-sized slice.
        #expect(await store.pruneHistorySlice(olderThan: future) == .deleted)
        #expect(await store.historyTransactionCount() == 0)
        #expect(await store.pruneHistorySlice(olderThan: future) == .nothingToDo)
        // Nothing older than the epoch: no work, no failure.
        #expect(await store.pruneHistorySlice(olderThan: Date(timeIntervalSince1970: 0)) == .nothingToDo)
    }

    @Test func pruningIsIdempotentOnAnEmptyHistory() async throws {
        let (store, directory) = try makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = await store.pruneHistory(olderThan: Date())
        #expect(outcome == RecordingsStore.HistoryPruneOutcome(slicesDeleted: 0, oldestRemaining: nil))
    }
}
