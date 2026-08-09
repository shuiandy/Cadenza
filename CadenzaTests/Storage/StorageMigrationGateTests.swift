import Foundation
import Testing

@testable import Cadenza

/// Bidirectional exclusion between storage migration and root-dependent
/// work: the migration claim is atomic and refused while activity leases
/// exist; activity leases are refused while a migration is claimed; the
/// recording lease spans start through stop finalization.
@Suite("Storage Migration Gate")
@MainActor
struct StorageMigrationGateTests {

    @Test func migrationClaimIsExclusiveAndBlocksActivity() {
        let gate = StorageMigrationGate()
        #expect(gate.claimMigration())
        #expect(!gate.claimMigration())
        #expect(gate.claimActivity() == nil)
        gate.releaseMigration()
        #expect(gate.claimActivity() != nil)
    }

    @Test func outstandingActivityLeaseBlocksMigrationUntilReleased() {
        let gate = StorageMigrationGate()
        let leaseA = gate.claimActivity()
        let leaseB = gate.claimActivity()
        #expect(leaseA != nil && leaseB != nil)
        #expect(!gate.claimMigration())
        gate.releaseActivity(leaseA)
        #expect(!gate.claimMigration())
        gate.releaseActivity(leaseB)
        #expect(gate.claimMigration())
    }

    @Test func releasingNilLeaseIsHarmless() {
        let gate = StorageMigrationGate()
        gate.releaseActivity(nil)
        #expect(gate.claimMigration())
    }

    @Test func archiveExportRefusedWhileMigrationClaimed() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let exporter = PortableArchiveExporter()
        let gate = StorageMigrationGate()
        exporter.migrationGate = gate
        #expect(gate.claimMigration())

        await exporter.export(toParent: parent, includeVoiceEmbeddings: false)

        guard case .failed = exporter.phase else {
            Issue.record("expected refusal, got \(exporter.phase)")
            return
        }
        gate.releaseMigration()
    }

    /// The import task claims before its first await and releases when the
    /// whole task ends — a migration claim is refused mid-import and
    /// succeeds afterwards.
    @Test func importHoldsItsLeaseAcrossAwaits() async throws {
        let appState = AppState()
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        appState.store = store
        let importRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: importRoot) }
        await store.setAudioRootForTesting(importRoot)
        appState.storageRootProvider = { importRoot }
        let gate = StorageMigrationGate()
        appState.migrationGate = gate
        let latch = AsyncTestLatch()
        appState.importAwaitHookForTesting = { await latch.wait() }

        appState.importAudioFiles(urls: [
            URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).m4a")
        ])
        #expect(await pollUntil { latch.didStart })
        #expect(!gate.claimMigration())

        latch.release()
        #expect(await pollUntil { gate.claimMigration() })
        gate.releaseMigration()
    }

    @Test func permanentDeleteHoldsItsLeaseAcrossTheStoreTransaction() async throws {
        try await assertHardDeleteHoldsMigrationLease { appState, recordingID in
            appState.permanentlyDeleteRecording(recordingID: recordingID)
        }
    }

    @Test func emptyTrashHoldsItsLeaseAcrossTheStoreTransaction() async throws {
        try await assertHardDeleteHoldsMigrationLease { appState, _ in
            appState.emptyTrash()
        }
    }

    @Test func cleanupPendingKeepsMigrationBlockedUntilJournalRecoveryFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-recovery-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(root)
        let recordingID = UUID()
        let audioURL = root.appendingPathComponent("\(recordingID.uuidString).m4a")
        try Data("delete-recovery".utf8).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Recovery gate",
            startDate: .now,
            duration: 60,
            audioURL: audioURL,
            ownership: .appCreated
        ))
        #expect(await store.deleteRecording(recordingID: recordingID))
        await store.failDeletionFileOperationForTesting(.cleanupPayload)

        let appState = AppState(startupPolicy: .testHost)
        let gate = StorageMigrationGate()
        let recoveryLatch = AsyncTestLatch()
        var feedback: [RecordingDeletionFeedback] = []
        appState.store = store
        appState.migrationGate = gate
        appState.deletionFeedbackSink = { feedback.append($0) }
        appState.deletionRecoveryAwaitHookForTesting = { await recoveryLatch.wait() }

        appState.permanentlyDeleteRecording(recordingID: recordingID)

        #expect(await pollUntil { recoveryLatch.didStart })
        #expect(feedback.contains(.secureCleanupPending))
        #expect(!gate.claimMigration())
        let pendingBeforeRecovery = await store.pendingDeletionTransactionCountForTesting()
        let detailBeforeRecovery = await store.fetchRecordingDetail(recordingID: recordingID)
        #expect(pendingBeforeRecovery == 1)
        #expect(detailBeforeRecovery == nil)
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))

        recoveryLatch.release()
        #expect(await pollUntil { gate.claimMigration() })
        gate.releaseMigration()
        let pendingAfterRecovery = await store.pendingDeletionTransactionCountForTesting()
        #expect(pendingAfterRecovery == 0)
    }

    private func assertHardDeleteHoldsMigrationLease(
        action: @MainActor (AppState, UUID) -> Void
    ) async throws {
        let appState = AppState(startupPolicy: .testHost)
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        appState.store = store
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Delete gate",
            startDate: .now,
            segmentsDirURL: nil
        ))
        #expect(await store.deleteRecording(recordingID: recordingID))
        let gate = StorageMigrationGate()
        let latch = AsyncTestLatch()
        appState.migrationGate = gate
        appState.deletionAwaitHookForTesting = { await latch.wait() }

        action(appState, recordingID)
        #expect(await pollUntil { latch.didStart })
        #expect(!gate.claimMigration())

        latch.release()
        #expect(await pollUntil { gate.claimMigration() })
        gate.releaseMigration()
        #expect(await store.fetchRecordingDetail(recordingID: recordingID) == nil)
    }

    private func pollUntil(
        timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Single-shot suspension latch for holding an async operation open.
@MainActor
private final class AsyncTestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didStart = false

    func wait() async {
        didStart = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Audio Import Outcomes", .serialized)
@MainActor
struct AudioImportOutcomeTests {

    @Test func presentationDistinguishesSuccessPartialFailureAndMigrationBusy() {
        let zhHans = Locale(identifier: "zh-Hans")

        let success = AudioImportToastPresentation.make(
            for: .completed(importedCount: 3, totalCount: 3),
            locale: zhHans
        )
        #expect(success.kind == .success)
        #expect(success.title == "已导入 3 条录音。")

        let singularSuccess = AudioImportToastPresentation.make(
            for: .completed(importedCount: 1, totalCount: 1),
            locale: Locale(identifier: "en_US")
        )
        #expect(singularSuccess.kind == .success)
        #expect(singularSuccess.title == "Imported 1 recording.")

        let partial = AudioImportToastPresentation.make(
            for: .completed(importedCount: 2, totalCount: 5),
            locale: zhHans
        )
        #expect(partial.kind == .error)
        #expect(partial.title == "已导入 5 条录音中的 2 条。")

        let allFailed = AudioImportToastPresentation.make(
            for: .completed(importedCount: 0, totalCount: 2),
            locale: zhHans
        )
        #expect(allFailed.kind == .error)
        #expect(allFailed.title == "没有导入任何录音。请重试。")

        let migrationBusy = AudioImportToastPresentation.make(
            for: .blockedByStorageMigration(totalCount: 2),
            locale: zhHans
        )
        #expect(migrationBusy.kind == .info)
        #expect(migrationBusy.title == "正在移动存储位置，暂时无法导入。请等待移动完成后重试。")
    }

    @Test func completedImportReportsPartialCountForEverySkippedFile() async throws {
        let fixture = try await makeImportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let validSource = fixture.parent.appendingPathComponent("valid-source.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: validSource)
        let missingSource = fixture.parent.appendingPathComponent("PRIVATE-PATH-CANARY.m4a")
        var outcomes: [AudioImportOutcome] = []
        fixture.appState.importOutcomeSink = { outcomes.append($0) }

        fixture.appState.importAudioFiles(urls: [validSource, missingSource])

        #expect(await pollUntil { outcomes.count == 1 })
        #expect(outcomes == [.completed(importedCount: 1, totalCount: 2)])
        let presentation = AudioImportToastPresentation.make(for: try #require(outcomes.first))
        #expect(!presentation.title.contains("PRIVATE-PATH-CANARY"))
        #expect(!presentation.title.contains(missingSource.path))
    }

    @Test func multiDropTwoSuccessfulLoadsProduceOneTwoOfTwoOutcome() async throws {
        let fixture = try await makeImportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let firstSource = fixture.parent.appendingPathComponent("first-drop.m4a")
        let secondSource = fixture.parent.appendingPathComponent("second-drop.m4a")
        try Data([0x10]).write(to: firstSource)
        try Data([0x20]).write(to: secondSource)
        var batches: [AudioImportDropBatch] = []
        let collector = AudioImportDropBatchCollector(itemCount: 2) { batches.append($0) }

        collector.resolve(firstSource, at: 0)
        #expect(batches.isEmpty)
        collector.resolve(secondSource, at: 1)

        let batch = try #require(batches.first)
        #expect(batches.count == 1)
        #expect(batch == AudioImportDropBatch(
            urls: [firstSource, secondSource],
            failedCount: 0
        ))
        var outcomes: [AudioImportOutcome] = []
        fixture.appState.importOutcomeSink = { outcomes.append($0) }

        fixture.appState.importAudioFiles(
            urls: batch.urls,
            rejectedCount: batch.failedCount
        )

        #expect(await pollUntil { outcomes.count == 1 })
        #expect(outcomes == [.completed(importedCount: 2, totalCount: 2)])
    }

    @Test func multiDropLoadFailureAndSuccessProduceOnePartialOutcome() async throws {
        let fixture = try await makeImportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let validSource = fixture.parent.appendingPathComponent("valid-drop.m4a")
        try Data([0x30]).write(to: validSource)
        var batches: [AudioImportDropBatch] = []
        let collector = AudioImportDropBatchCollector(itemCount: 2) { batches.append($0) }

        collector.resolve(nil, at: 0)
        #expect(batches.isEmpty)
        collector.resolve(validSource, at: 1)

        let batch = try #require(batches.first)
        #expect(batches.count == 1)
        #expect(batch == AudioImportDropBatch(urls: [validSource], failedCount: 1))
        var outcomes: [AudioImportOutcome] = []
        fixture.appState.importOutcomeSink = { outcomes.append($0) }

        fixture.appState.importAudioFiles(
            urls: batch.urls,
            rejectedCount: batch.failedCount
        )

        #expect(await pollUntil { outcomes.count == 1 })
        #expect(outcomes == [.completed(importedCount: 1, totalCount: 2)])
    }

    @Test func persistenceSaveFailureRollsBackRowAndAppCreatedCopy() async throws {
        let fixture = try await makeImportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let source = fixture.parent.appendingPathComponent("save-failure.m4a")
        try Data([0x03, 0x04]).write(to: source)
        await fixture.store.failNextSaveForTesting()
        var outcomes: [AudioImportOutcome] = []
        fixture.appState.importOutcomeSink = { outcomes.append($0) }

        fixture.appState.importAudioFiles(urls: [source])

        #expect(await pollUntil { outcomes.count == 1 })
        #expect(outcomes == [.completed(importedCount: 0, totalCount: 1)])
        #expect(AudioImportToastPresentation.make(for: try #require(outcomes.first)).kind == .error)
        #expect((await fixture.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        )).isEmpty)
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.storageRoot,
            includingPropertiesForKeys: nil
        )
        #expect(storedFiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedImportRollbackNeverDeletesUserOwnedOriginal() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-owned-import-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("user-original.m4a")
        try Data([0x40]).write(to: source)

        AppState.rollbackCreatedImportFile(
            at: source,
            ownership: .userOwned,
            recordingID: UUID()
        )

        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func migrationBusyReachesTheLiveToastCenterWithoutSensitiveInput() async throws {
        ToastCenter.shared.dismiss()
        defer { ToastCenter.shared.dismiss() }
        let appState = AppState()
        let gate = StorageMigrationGate()
        #expect(gate.claimMigration())
        appState.migrationGate = gate
        defer { gate.releaseMigration() }
        let sensitiveURL = URL(fileURLWithPath: "/PRIVATE-PATH-CANARY/secret-recording.m4a")

        appState.importAudioFiles(urls: [sensitiveURL])

        #expect(await pollUntil { ToastCenter.shared.current != nil })
        let toast = try #require(ToastCenter.shared.current)
        let expected = AudioImportToastPresentation.make(
            for: .blockedByStorageMigration(totalCount: 1)
        )
        #expect(toast.kind == .info)
        #expect(toast.title == expected.title)
        #expect(!toast.title.contains("PRIVATE-PATH-CANARY"))
        #expect(!toast.title.contains("secret-recording"))
    }

    private func makeImportFixture() async throws -> (
        appState: AppState,
        store: RecordingsStore,
        parent: URL,
        storageRoot: URL
    ) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-outcome-\(UUID().uuidString)", isDirectory: true)
        let storageRoot = parent.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(storageRoot)
        let appState = AppState()
        appState.store = store
        appState.migrationGate = StorageMigrationGate()
        appState.storageRootProvider = { storageRoot }
        return (appState, store, parent, storageRoot)
    }

    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
