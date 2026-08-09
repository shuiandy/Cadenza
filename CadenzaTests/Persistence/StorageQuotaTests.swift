import Foundation
import Testing
@testable import Cadenza

@Suite("Storage Quota", .serialized)
struct StorageQuotaTests {
    @Test @MainActor
    func untrackedRootBytesDoNotPutOwnedLibraryOverLimit() async throws {
        let store = try await makeIsolatedStore()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.setAudioRootForTesting(root)
        let audio = root.appendingPathComponent("owned.m4a")
        let external = root.appendingPathComponent("other-user-data.bin")
        try Data(repeating: 1, count: 4).write(to: audio)
        try Data(repeating: 2, count: 32).write(to: external)
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Owned", startDate: Date(), segmentsDirURL: nil))
        let finalized = await store.finalizeRecording(id: id, duration: 120, audioFileURL: audio)
        guard case .saved = finalized else {
            Issue.record("Expected owned recording to finalize")
            return
        }

        let status = await store.cleanupStorage(root: root, limitBytes: 8)

        #expect(status.usage.ownedBytes == 4)
        #expect(status.usage.externalBytes == 32)
        #expect(!status.isOverLimit)
        #expect((await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)).map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test @MainActor
    func ownedBytesOverLimitNeverDeleteActiveRecording() async throws {
        let store = try await makeIsolatedStore()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.setAudioRootForTesting(root)
        let audio = root.appendingPathComponent("active.m4a")
        try Data(repeating: 7, count: 16).write(to: audio)
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Active", startDate: Date(), segmentsDirURL: nil))
        let finalized = await store.finalizeRecording(id: id, duration: 120, audioFileURL: audio)
        guard case .saved = finalized else {
            Issue.record("Expected active recording to finalize")
            return
        }

        let status = await store.cleanupStorage(root: root, limitBytes: 8)

        #expect(status.isOverLimit)
        #expect((await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)).map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test @MainActor
    func quotaEvaluationDoesNotPurgeRecentTrash() async throws {
        let store = try await makeIsolatedStore()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.setAudioRootForTesting(root)
        let audio = root.appendingPathComponent("recent-trash.m4a")
        try Data(repeating: 9, count: 16).write(to: audio)
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Recent Trash", startDate: Date(), segmentsDirURL: nil))
        let finalized = await store.finalizeRecording(id: id, duration: 120, audioFileURL: audio)
        guard case .saved = finalized else {
            Issue.record("Expected recent trash recording to finalize")
            return
        }
        #expect(await store.deleteRecording(recordingID: id))

        let status = await store.cleanupStorage(root: root, limitBytes: 8)

        #expect(status.usage.ownedBytes == 16)
        #expect(status.usage.externalBytes == 0)
        #expect(status.isOverLimit)
        #expect((await store.fetchTrashedRecordings()).map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test @MainActor
    func softDeleteKeepsRecoverySegmentsAttributedToTrash() async throws {
        let store = try await makeIsolatedStore()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.setAudioRootForTesting(root)
        let segments = root.appendingPathComponent("segments/recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 6).write(to: segments.appendingPathComponent("segment-0001.m4a"))
        let id = UUID()
        #expect(await store.createRecording(
            id: id,
            title: "Recoverable",
            startDate: Date(),
            segmentsDirURL: segments
        ))
        #expect(await store.deleteRecording(recordingID: id))

        let status = await store.storageQuotaStatus(root: root, limitBytes: nil)

        #expect(status.usage.ownedBytes == 6)
        #expect(status.usage.externalBytes == 0)
        #expect((await store.fetchTrashedRecordings()).map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: segments.path))
    }

    @Test @MainActor
    func persistedIntMaxStorageLimitClampsConsistently() async throws {
        let suiteName = "cadenza-storage-quota-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let key = "storageLimitMB"
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Int.max, forKey: key)
        #expect(defaults.integer(forKey: key) == Int.max)
        let store = try await makeIsolatedStore()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.setAudioRootForTesting(root)
        let persistedLimitMegabytes = defaults.integer(forKey: key)

        let status = await store.storageQuotaStatus(
            root: root,
            limitMegabytes: persistedLimitMegabytes
        )
        let cleanupStatus = await store.cleanupStorage(
            root: root,
            limitMegabytes: persistedLimitMegabytes
        )

        #expect(status.limitBytes == Int64.max)
        #expect(cleanupStatus.limitBytes == Int64.max)
    }
}

@MainActor
private func makeIsolatedStore() async throws -> RecordingsStore {
    let container = try RecordingsStore.makeContainer(inMemory: true)
    return RecordingsStore(modelContainer: container)
}

private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadenza-storage-quota-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
