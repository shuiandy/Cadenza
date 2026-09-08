import Foundation
import Testing
@testable import Cadenza

private enum RecordingProcessingExclusionSentinel: Error {
    case stopAfterBoundary
}

private actor RecordingProcessingLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RecordingProcessingMultiLatch {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entryCounts: [String: Int] = [:]
    private var isOpen = false

    func wait(key: String) async {
        entryCounts[key, default: 0] += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func count(for key: String) -> Int {
        entryCounts[key, default: 0]
    }

    func open() {
        isOpen = true
        let waiters = continuations
        continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }
}

@MainActor
private final class RecordingProcessingBoundarySpy {
    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("recording-processing-\(UUID().uuidString)", isDirectory: true)

    var appleLanguageResult = true
    var appleLanguageLatch: RecordingProcessingLatch?
    var microphoneStatus: PermissionStatus = .granted
    private(set) var providerChecks = 0
    private(set) var permissionRequests = 0
    private(set) var captureRequests: [RecordingCaptureRequest] = []

    func dependencies(defaults: UserDefaults) -> RecordingEngineDependencies {
        let storageRoot = storageRoot
        return RecordingEngineDependencies(
            defaults: defaults,
            apiKey: { _ in nil },
            supportsAppleLanguage: { [weak self] _ in
                guard let self else { return false }
                self.providerChecks += 1
                if let latch = self.appleLanguageLatch {
                    await latch.wait()
                }
                return self.appleLanguageResult
            },
            localWhisperState: { ("base", true) },
            microphoneStatus: { [weak self] in self?.microphoneStatus ?? .denied },
            requestMicrophone: { [weak self] in
                guard let self else { return false }
                self.permissionRequests += 1
                return self.microphoneStatus == .granted
            },
            now: { Date(timeIntervalSinceReferenceDate: 123_456) },
            storageRoot: { storageRoot },
            startCapture: { [weak self] request in
                guard let self else { throw RecordingProcessingExclusionSentinel.stopAfterBoundary }
                self.captureRequests.append(request)
                let directory = storageRoot
                    .appendingPathComponent("segments", isDirectory: true)
                    .appendingPathComponent(request.recordingID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                return directory.path
            },
            stopCapture: {
                AudioMixer.StopPhase1Result(
                    segmentURLs: [],
                    outputURL: nil,
                    segmentsDirectory: nil
                )
            },
            startRealtime: { _ in },
            stopRealtime: { _ in },
            reconnectDelay: .zero,
            realtimeStartTimeout: .seconds(1),
            recordBoundaryEvent: { _ in }
        )
    }
}

@Suite("Recording and post-processing exclusion", .serialized)
@MainActor
struct RecordingProcessingExclusionTests {
    private func makeDefaults() -> (name: String, value: UserDefaults) {
        let name = "RecordingProcessingExclusionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        defaults.set("en", forKey: "transcriptionLanguage")
        defaults.set(false, forKey: "enableRealtimeTranscription")
        defaults.set(true, forKey: "autoRecordMeetings")
        defaults.set(false, forKey: "captureMicrophone")
        return (name, defaults)
    }

    private func makeStore(root: URL) async throws -> RecordingsStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(root)
        return store
    }

    private func makeCoordinator(
        store: RecordingsStore,
        defaults: UserDefaults,
        gate: RecordingProcessingGate
    ) -> PostProcessingCoordinator {
        let coordinator = PostProcessingCoordinator(
            store: store,
            transcriptionDependencies: PostProcessingTranscriptionDependencies(
                defaults: defaults,
                apiKey: { _ in nil },
                supportsAppleLanguage: { _ in true },
                localWhisperState: { LocalWhisperState(model: "base", isAvailable: true) }
            ),
            recordingProcessingGate: gate
        )
        coordinator.migrationGate = StorageMigrationGate()
        return coordinator
    }

    private func importProcessingFixture(
        store: RecordingsStore,
        root: URL,
        title: String = "Processing Fixture"
    ) async throws -> (id: UUID, audioURL: URL) {
        let id = UUID()
        let audioURL = root.appendingPathComponent("\(id.uuidString).m4a")
        try Data("processing-fixture".utf8).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: id,
            title: title,
            startDate: Date(),
            duration: 60,
            audioURL: audioURL,
            ownership: .appCreated
        ))
        return (id, audioURL)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func recordingClaimsBeforeFirstAwaitAndRefusesInsertedJob() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)

        let providerLatch = RecordingProcessingLatch()
        spy.appleLanguageLatch = providerLatch
        spy.appleLanguageResult = false
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        let startTask = Task { @MainActor in
            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        }
        #expect(await waitUntil { await providerLatch.entered })
        #expect(gate.hasRecordingLease)

        let rejectedID = UUID()
        await coordinator.startPostProcessing(
            recordingID: rejectedID,
            audioURL: spy.storageRoot.appendingPathComponent("rejected.m4a"),
            meetingTitle: "Rejected"
        )
        #expect(!coordinator.isProcessing(recordingID: rejectedID))
        #expect(spy.permissionRequests == 0)
        #expect(spy.captureRequests.isEmpty)
        #expect(await store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).isEmpty)

        await providerLatch.open()
        await #expect(throws: TranscriptionProviderResolutionError.self) {
            try await startTask.value
        }
        #expect(await waitUntil { gate.isAllIdle })
        #expect(spy.permissionRequests == 0)
        #expect(spy.captureRequests.isEmpty)
    }

    @Test func recordingDefersImportRecoveryAndBackfillThenSubmitsEachExactlyOnce() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let runnerLatch = RecordingProcessingMultiLatch()
        coordinator.transcriptionRunnerOverride = { _, request in
            await runnerLatch.wait(key: request.audioURL.lastPathComponent)
            throw RecordingProcessingExclusionSentinel.stopAfterBoundary
        }

        let imported = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Deferred Import"
        )
        let recovered = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Deferred Recovery"
        )
        let backfill = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Deferred Backfill"
        )
        #expect(await store.enqueuePostProcessingBackfill(
            recordingID: backfill.id,
            source: "recording-exclusion-test"
        ))

        let recordingLease = try #require(gate.claimRecording())
        let importOutcome = await coordinator.startPostProcessing(
            recordingID: imported.id,
            audioURL: imported.audioURL,
            meetingTitle: "Deferred Import",
            origin: .importedAudio
        )
        let duplicateImportOutcome = await coordinator.startPostProcessing(
            recordingID: imported.id,
            audioURL: imported.audioURL,
            meetingTitle: "Deferred Import",
            origin: .importedAudio
        )
        let recoveryOutcome = await coordinator.startPostProcessing(
            recordingID: recovered.id,
            audioURL: recovered.audioURL,
            meetingTitle: "Deferred Recovery",
            origin: .crashRecovery
        )
        let duplicateRecoveryOutcome = await coordinator.startPostProcessing(
            recordingID: recovered.id,
            audioURL: recovered.audioURL,
            meetingTitle: "Deferred Recovery",
            origin: .crashRecovery
        )
        await coordinator.processQueuedHistoricalBackfill(limit: 10)
        await coordinator.processQueuedHistoricalBackfill(limit: 10)

        #expect(importOutcome == .deferredForActiveRecording)
        #expect(duplicateImportOutcome == .duplicate)
        #expect(recoveryOutcome == .deferredForActiveRecording)
        #expect(duplicateRecoveryOutcome == .duplicate)
        #expect(!coordinator.isProcessing(recordingID: imported.id))
        #expect(!coordinator.isProcessing(recordingID: recovered.id))
        #expect(!coordinator.isProcessing(recordingID: backfill.id))
        let queuedBeforeRelease = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queuedBeforeRelease.map(\.id).contains(backfill.id))

        gate.releaseRecording(recordingLease)

        #expect(await waitUntil {
            coordinator.isProcessing(recordingID: imported.id)
                && coordinator.isProcessing(recordingID: recovered.id)
                && coordinator.isProcessing(recordingID: backfill.id)
        })
        let queuedAfterRelease = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(!queuedAfterRelease.map(\.id).contains(backfill.id))

        await runnerLatch.open()
        #expect(await waitUntil {
            let importedCount = await runnerLatch.count(for: imported.audioURL.lastPathComponent)
            let recoveredCount = await runnerLatch.count(for: recovered.audioURL.lastPathComponent)
            let backfillCount = await runnerLatch.count(for: backfill.audioURL.lastPathComponent)
            return importedCount == 1 && recoveredCount == 1 && backfillCount == 1
        })
        #expect(await waitUntil { gate.isAllIdle })
        #expect(await runnerLatch.count(for: imported.audioURL.lastPathComponent) == 1)
        #expect(await runnerLatch.count(for: recovered.audioURL.lastPathComponent) == 1)
        #expect(await runnerLatch.count(for: backfill.audioURL.lastPathComponent) == 1)
    }

    @Test func cancellingDeferredSubmissionPreventsRetryAfterRecordingStops() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let runnerLatch = RecordingProcessingMultiLatch()
        coordinator.transcriptionRunnerOverride = { _, request in
            await runnerLatch.wait(key: request.audioURL.lastPathComponent)
            throw RecordingProcessingExclusionSentinel.stopAfterBoundary
        }
        let fixture = try await importProcessingFixture(store: store, root: spy.storageRoot)
        let recordingLease = try #require(gate.claimRecording())

        let outcome = await coordinator.startPostProcessing(
            recordingID: fixture.id,
            audioURL: fixture.audioURL,
            meetingTitle: "Cancelled Deferred Import",
            origin: .importedAudio
        )
        #expect(outcome == .deferredForActiveRecording)
        #expect(coordinator.hasActiveWork)

        coordinator.cancelJob(for: fixture.id)
        #expect(!coordinator.hasActiveWork)
        gate.releaseRecording(recordingLease)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!coordinator.isProcessing(recordingID: fixture.id))
        #expect(await runnerLatch.count(for: fixture.audioURL.lastPathComponent) == 0)
        #expect(gate.isAllIdle)
    }

    @Test func submittedJobDoesNotBlockManualOrAutomaticStart() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let fixture = try await importProcessingFixture(store: store, root: spy.storageRoot)
        let runnerLatch = RecordingProcessingLatch()
        coordinator.transcriptionRunnerOverride = { _, _ in
            await runnerLatch.wait()
            throw RecordingProcessingExclusionSentinel.stopAfterBoundary
        }
        await coordinator.startPostProcessing(
            recordingID: fixture.id,
            audioURL: fixture.audioURL,
            meetingTitle: "Processing Fixture"
        )
        #expect(await waitUntil { await runnerLatch.entered })
        #expect(gate.hasProcessingLeases)

        SystemAudioCapturePreparation.markPrepared(defaults: isolated.value)
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine._test_setSystemAudioPreparationDefaults(isolated.value)
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(engine.recordingState == .recording)
        #expect(spy.captureRequests.count == 1)
        #expect(gate.hasRecordingLease)
        #expect(gate.hasProcessingLeases)
        #expect(coordinator.isProcessing(recordingID: fixture.id))
        engine.forceReset()
        #expect(!gate.hasRecordingLease)

        try await engine.startRecording(
            captureMicrophone: true,
            skipPermissionPrompt: true,
            isAutoStarted: true
        )
        #expect(engine.recordingState == .recording)
        #expect(spy.captureRequests.count == 2)
        #expect(gate.hasRecordingLease)
        #expect(gate.hasProcessingLeases)
        engine.forceReset()

        await runnerLatch.open()
        #expect(await waitUntil { gate.isAllIdle })
    }

    @Test func manualSummaryLeaseDoesNotBlockManualOrDetectedAutoCapture() async throws {
        try await verifyManualProcessingLease(.manualSummary)
    }

    @Test func manualRetryLeaseDoesNotBlockManualOrDetectedAutoCapture() async throws {
        try await verifyManualProcessingLease(.manualTranscriptionRetry)
    }

    private func verifyManualProcessingLease(
        _ operation: PostProcessingLeaseOperation
    ) async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.value)
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let manualLatch = RecordingProcessingLatch()
        coordinator.afterManualProcessingClaimForTesting = { claimedOperation in
            guard claimedOperation == operation else { return }
            await manualLatch.wait()
        }
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine._test_setSystemAudioPreparationDefaults(isolated.value)
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        let manualTask = Task { @MainActor in
            switch operation {
            case .manualSummary:
                await coordinator.generateSummary(
                    recordingID: UUID(),
                    provider: AIProvider.apple.rawValue,
                    language: "en"
                )
            case .manualTranscriptionRetry:
                await coordinator.retryTranscription(recordingID: UUID())
            }
        }
        #expect(await waitUntil { await manualLatch.entered })
        #expect(gate.hasProcessingLeases)

        // A detected meeting starts capture immediately even though the manual
        // processing lease is still held.
        engine.handleMeetingActivity(bundleID: "com.example.meeting", appName: "Meeting")
        #expect(await waitUntil {
            engine.recordingState == .recording && gate.hasRecordingLease
        })
        #expect(spy.captureRequests.count == 1)
        #expect(gate.hasProcessingLeases)
        engine.forceReset()
        #expect(!gate.hasRecordingLease)

        // So does a manual start.
        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(engine.recordingState == .recording)
        #expect(spy.captureRequests.count == 2)
        #expect(gate.hasProcessingLeases)
        engine.forceReset()

        await manualLatch.open()
        await manualTask.value
        #expect(await waitUntil { gate.isAllIdle })
    }

    @Test func pendingMeetingSurvivesPriorTriggerTerminationAndStartsDespiteActiveProcessing() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.value)
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let fixture = try await importProcessingFixture(store: store, root: spy.storageRoot)
        let runnerLatch = RecordingProcessingLatch()
        coordinator.transcriptionRunnerOverride = { _, _ in
            await runnerLatch.wait()
            throw RecordingProcessingExclusionSentinel.stopAfterBoundary
        }

        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine._test_setSystemAudioPreparationDefaults(isolated.value)
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        await coordinator.startPostProcessing(
            recordingID: fixture.id,
            audioURL: fixture.audioURL,
            meetingTitle: "Processing Fixture"
        )
        #expect(await waitUntil { await runnerLatch.entered })

        engine._test_setTriggeringMeetingBundleID("com.example.prior")
        engine._test_setStopping(true)
        engine.handleMeetingActivity(bundleID: "com.example.live", appName: "Live Meeting")
        #expect(engine._test_pendingMeetingAutoStart?.bundleID == "com.example.live")

        // Meeting A owns the recording being finalized, while meeting B is the
        // detector's current live session. Repeated late termination callbacks
        // for A must remain idempotent and must not erase B.
        engine.handleMeetingTerminated(bundleID: "com.example.prior")
        engine.handleMeetingTerminated(bundleID: "com.example.prior")
        #expect(engine.isMeetingCurrentlyActive)
        #expect(engine.triggeringMeetingBundleID == nil)
        #expect(engine.detectedMeetingBundleID == "com.example.live")
        #expect(engine.detectedMeetingAppName == "Live Meeting")
        #expect(engine._test_pendingMeetingAutoStart?.bundleID == "com.example.live")

        engine._test_completeStopLifecycle()

        // The pending meeting starts as soon as finalization completes even
        // though the prior job's processing lease is still held.
        #expect(engine.isStopping == false)
        #expect(await waitUntil { !spy.captureRequests.isEmpty })
        #expect(engine._test_pendingMeetingAutoStart == nil)
        #expect(spy.captureRequests.count == 1)
        #expect(engine.recordingState == .recording)
        #expect(gate.hasRecordingLease)
        #expect(gate.hasProcessingLeases)

        await runnerLatch.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(spy.captureRequests.count == 1)
        engine.forceReset()
        #expect(await waitUntil { gate.isAllIdle })
        #expect(spy.captureRequests.count == 1)
    }

    @Test func failedManualStartRestoresSupersededAutoStart() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.value)
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)

        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine._test_setSystemAudioPreparationDefaults(isolated.value)
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        // A meeting queues behind stop finalization, then the stop window
        // closes without consuming it.
        engine._test_setStopping(true)
        engine.handleMeetingActivity(bundleID: "com.example.super", appName: "Superseded Meeting")
        #expect(engine._test_pendingMeetingAutoStart?.bundleID == "com.example.super")
        engine._test_setStopping(false)

        // A manual start supersedes the queued auto-start and then fails at
        // provider resolution. The meeting is still active, so the pending
        // auto-start must be restored rather than silently lost.
        spy.appleLanguageResult = false
        await #expect(throws: (any Error).self) {
            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        }
        #expect(engine.recordingState == .idle)
        #expect(engine._test_pendingMeetingAutoStart?.bundleID == "com.example.super")

        // The restore schedules its own retry; once the provider recovers,
        // the meeting records without any new detector callback.
        spy.appleLanguageResult = true
        #expect(await waitUntil { !spy.captureRequests.isEmpty })
        // The capture request lands before startRecording publishes the state,
        // so the state assertion must wait on its own.
        #expect(await waitUntil { engine.recordingState == .recording })
        #expect(engine._test_pendingMeetingAutoStart == nil)
        engine.forceReset()
        #expect(await waitUntil { gate.isAllIdle })
    }

    @Test func pendingMeetingIntentPreemptsDeferredDrainUntilRecordingReleases() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.value)
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let active = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Active Processing"
        )
        let deferred = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Deferred Processing"
        )
        let runnerLatch = RecordingProcessingMultiLatch()
        coordinator.transcriptionRunnerOverride = { _, request in
            await runnerLatch.wait(key: request.audioURL.lastPathComponent)
            throw RecordingProcessingExclusionSentinel.stopAfterBoundary
        }

        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine._test_setSystemAudioPreparationDefaults(isolated.value)
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        await coordinator.startPostProcessing(
            recordingID: active.id,
            audioURL: active.audioURL,
            meetingTitle: "Active Processing"
        )
        #expect(await waitUntil {
            await runnerLatch.count(for: active.audioURL.lastPathComponent) == 1
        })

        engine.handleMeetingActivity(bundleID: "com.example.priority", appName: "Priority Meeting")
        #expect(engine._test_pendingMeetingAutoStart?.bundleID == "com.example.priority")
        #expect(gate.hasRecordingIntent)

        let deferredOutcome = await coordinator.startPostProcessing(
            recordingID: deferred.id,
            audioURL: deferred.audioURL,
            meetingTitle: "Deferred Processing",
            origin: .importedAudio
        )
        #expect(deferredOutcome == .deferredForActiveRecording)

        // The reserved intent becomes a live recording without waiting for the
        // active job's processing lease to release.
        #expect(await waitUntil {
            engine.recordingState == .recording && gate.hasRecordingLease
        })
        #expect(spy.captureRequests.count == 1)
        #expect(gate.hasProcessingLeases)
        #expect(await runnerLatch.count(for: deferred.audioURL.lastPathComponent) == 0)
        #expect(!coordinator.isProcessing(recordingID: deferred.id))

        // The active job finishing does not let the deferred submission
        // overtake the live recording.
        await runnerLatch.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await runnerLatch.count(for: deferred.audioURL.lastPathComponent) == 0)

        engine.forceReset()
        #expect(await waitUntil {
            await runnerLatch.count(for: deferred.audioURL.lastPathComponent) == 1
        })
        #expect(await waitUntil { gate.isAllIdle })
        #expect(await runnerLatch.count(for: deferred.audioURL.lastPathComponent) == 1)
        #expect(spy.captureRequests.count == 1)
    }

    @Test func endedPendingMeetingIsNotRetriedWhenLifecycleGoesIdle() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let manualLatch = RecordingProcessingLatch()
        coordinator.afterManualProcessingClaimForTesting = { operation in
            guard operation == .manualTranscriptionRetry else { return }
            await manualLatch.wait()
        }
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        let manualTask = Task { @MainActor in
            await coordinator.retryTranscription(recordingID: UUID())
        }
        #expect(await waitUntil { await manualLatch.entered })
        engine._test_setStopping(true)
        engine.handleMeetingActivity(bundleID: "com.example.ended", appName: "Ended Meeting")
        #expect(engine._test_pendingMeetingAutoStart != nil)
        #expect(gate.hasRecordingIntent)

        engine.handleMicDeactivated()
        #expect(engine._test_pendingMeetingAutoStart == nil)
        #expect(!gate.hasRecordingIntent)
        #expect(!engine.isMeetingCurrentlyActive)

        engine._test_completeStopLifecycle()
        await manualLatch.open()
        await manualTask.value
        #expect(await waitUntil { gate.isAllIdle })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(spy.captureRequests.isEmpty)
    }

    @Test func disablingAutoRecordReleasesIntentAndDrainsDeferredExactlyOnce() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let active = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Active Before Disable"
        )
        let deferred = try await importProcessingFixture(
            store: store,
            root: spy.storageRoot,
            title: "Deferred After Disable"
        )
        let runnerLatch = RecordingProcessingMultiLatch()
        coordinator.transcriptionRunnerOverride = { _, request in
            await runnerLatch.wait(key: request.audioURL.lastPathComponent)
            throw RecordingProcessingExclusionSentinel.stopAfterBoundary
        }
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        await coordinator.startPostProcessing(
            recordingID: active.id,
            audioURL: active.audioURL,
            meetingTitle: "Active Before Disable"
        )
        #expect(await waitUntil {
            await runnerLatch.count(for: active.audioURL.lastPathComponent) == 1
        })
        engine._test_setStopping(true)
        engine.handleMeetingActivity(bundleID: "com.example.disabled", appName: "Disabled Meeting")
        #expect(gate.hasRecordingIntent)
        isolated.value.set(false, forKey: "autoRecordMeetings")

        let deferredOutcome = await coordinator.startPostProcessing(
            recordingID: deferred.id,
            audioURL: deferred.audioURL,
            meetingTitle: "Deferred After Disable",
            origin: .importedAudio
        )
        #expect(deferredOutcome == .deferredForActiveRecording)
        engine._test_completeStopLifecycle()
        #expect(engine._test_pendingMeetingAutoStart == nil)
        #expect(!gate.hasRecordingIntent)
        await runnerLatch.open()

        #expect(await waitUntil {
            await runnerLatch.count(for: deferred.audioURL.lastPathComponent) == 1
        })
        #expect(await waitUntil { gate.isAllIdle })
        #expect(spy.captureRequests.isEmpty)
        #expect(await runnerLatch.count(for: deferred.audioURL.lastPathComponent) == 1)
    }

    @Test func repeatedActivityForSameMeetingStartsOnlyOnce() async throws {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.value)
        let gate = RecordingProcessingGate()
        let spy = RecordingProcessingBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        let store = try await makeStore(root: spy.storageRoot)
        let coordinator = makeCoordinator(store: store, defaults: isolated.value, gate: gate)
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine._test_setSystemAudioPreparationDefaults(isolated.value)
        engine.migrationGate = StorageMigrationGate()
        engine.store = store
        engine.coordinator = coordinator

        engine.handleMeetingActivity(bundleID: "com.example.repeated", appName: "Repeated Meeting")
        engine.handleMeetingActivity(bundleID: "com.example.repeated", appName: "Repeated Meeting")
        #expect(gate.hasRecordingIntent)

        #expect(await waitUntil {
            engine.recordingState == .recording && gate.hasRecordingLease
        })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(spy.captureRequests.count == 1)
        #expect(!gate.hasRecordingIntent)
        engine.forceReset()
        #expect(gate.isAllIdle)
    }

    @Test func pendingIntentIsCancelledWhenEngineDeinitializes() {
        let isolated = makeDefaults()
        defer { isolated.value.removePersistentDomain(forName: isolated.name) }
        let gate = RecordingProcessingGate()
        let processingLease = gate.claimProcessing()
        #expect(processingLease != nil)
        let spy = RecordingProcessingBoundarySpy()
        var engine: RecordingEngine? = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.value),
            recordingProcessingGate: gate
        )
        engine?._test_setStopping(true)
        engine?.handleMeetingActivity(bundleID: "com.example.deinit", appName: "Deinit Meeting")
        #expect(gate.hasRecordingIntent)

        engine = nil

        #expect(!gate.hasRecordingIntent)
        gate.releaseProcessing(processingLease)
        #expect(gate.isAllIdle)
    }

    @Test func recordingToProcessingTransitionHasNoAllIdleGap() {
        let gate = RecordingProcessingGate()
        var allIdleNotifications = 0
        _ = gate.observeAllIdle {
            allIdleNotifications += 1
        }
        let recordingLease = gate.claimRecording()
        #expect(recordingLease != nil)

        let processingLease = recordingLease.flatMap {
            gate.transitionRecordingToProcessing($0)
        }
        #expect(processingLease != nil)
        #expect(!gate.hasRecordingLease)
        #expect(gate.hasProcessingLeases)
        #expect(allIdleNotifications == 0)

        // The next recording claims straight through the handed-off
        // processing lease, and its release is not an all-idle edge while
        // that lease is still held.
        let nextRecordingLease = gate.claimRecording()
        #expect(nextRecordingLease != nil)
        gate.releaseRecording(nextRecordingLease)
        #expect(allIdleNotifications == 0)

        gate.releaseProcessing(processingLease)
        #expect(gate.isAllIdle)
        #expect(allIdleNotifications == 1)
    }

    @Test func processingLeasesNeverRefuseARecordingClaim() throws {
        let gate = RecordingProcessingGate()
        let firstProcessing = try #require(gate.claimProcessing())
        let secondProcessing = try #require(gate.claimProcessing())

        let recordingLease = try #require(gate.claimRecording())
        // Capture wins both ways: new processing claims defer to the live
        // recording, and a second recording cannot double-claim.
        #expect(gate.claimProcessing() == nil)
        #expect(gate.claimRecording() == nil)

        gate.releaseRecording(recordingLease)
        gate.releaseProcessing(firstProcessing)
        gate.releaseProcessing(secondProcessing)
        #expect(gate.isAllIdle)
    }

    @Test func reservedIntentConsumesWhileProcessingLeasesAreActive() throws {
        let gate = RecordingProcessingGate()
        let processingLease = try #require(gate.claimProcessing())
        let intent = try #require(gate.reserveRecordingIntent())
        // The reserved intent keeps its priority over new processing claims…
        #expect(gate.claimProcessing() == nil)

        // …and converts into a live recording without waiting for the
        // in-flight processing lease.
        let recordingLease = try #require(gate.claimRecording(consuming: intent))
        #expect(gate.hasRecordingLease)
        #expect(gate.hasProcessingLeases)

        gate.releaseRecording(recordingLease)
        gate.releaseProcessing(processingLease)
        #expect(gate.isAllIdle)
    }
}
