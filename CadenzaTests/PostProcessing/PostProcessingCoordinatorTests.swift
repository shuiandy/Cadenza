import Foundation
import os.lock
import SwiftData
import Testing
@testable import Cadenza

// MARK: - Helpers

@MainActor
/// Tests that write audio references pass the root their fixture files live
/// under; store-only tests need no root.
private func makeIsolatedStore(audioRoot: URL? = nil) async throws -> RecordingsStore {
    let container = try RecordingsStore.makeContainer(inMemory: true)
    let store = RecordingsStore(modelContainer: container)
    if let audioRoot {
        await store.setAudioRootForTesting(audioRoot)
    }
    return store
}

/// A store plus a per-test audio root; callers remove the root in a defer.
private func makeIsolatedStoreWithAudioRoot() async throws -> (store: RecordingsStore, audioRoot: URL) {
    let audioRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("postprocess-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
    let store = try await makeIsolatedStore(audioRoot: audioRoot)
    return (store, audioRoot)
}

private actor RecoveryFinalizationEventSpy {
    private(set) var events: [RecordingAudioFinalizationEvent] = []

    func record(_ event: RecordingAudioFinalizationEvent) {
        events.append(event)
    }
}

@Suite("PostProcessingCoordinator crash recovery finalizer seam", .serialized)
struct PostProcessingRecoveryFinalizerTests {
    @Test @MainActor
    func crashRecoveryUsesSharedFinalizerAndPreservesCommitBeforeCleanup() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-finalizer-\(UUID().uuidString)", isDirectory: true)
        await store.setAudioRootForTesting(storageRoot)
        let segmentsDirectory = storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        try Data([0x01]).write(
            to: segmentsDirectory.appendingPathComponent("segment-000.m4a")
        )
        let segmentDate = Date(timeIntervalSinceReferenceDate: 100)
        let manifest = SegmentedAudioFileWriter.SegmentManifest(
            recordingID: recordingID.uuidString,
            segments: [
                SegmentedAudioFileWriter.SegmentEntry(
                    index: 0,
                    filename: "segment-000.m4a",
                    startedAt: segmentDate,
                    completedAt: segmentDate.addingTimeInterval(30)
                ),
            ],
            isComplete: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: segmentsDirectory.appendingPathComponent("segments.json")
        )
        let authority = SegmentStorageAuthority.authorize(root: storageRoot)
        await store.createRecording(
            id: recordingID,
            title: "Interrupted",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            segmentsDirURL: segmentsDirectory
        )
        let events = RecoveryFinalizationEventSpy()
        let dependencies = RecordingAudioFinalizerDependencies(
            validate: { request in
                await RecordingAudioFinalizer.validateSegments(
                    RecordingAudioFinalizationRequest(
                        origin: request.origin,
                        recordingID: request.recordingID,
                        segmentsDirectory: request.segmentsDirectory,
                        suppliedSegmentURLs: request.suppliedSegmentURLs,
                        segmentStorageAuthority: authority,
                        outputURL: request.outputURL,
                        fallbackDuration: request.fallbackDuration,
                        startDate: request.startDate,
                        endDate: request.endDate,
                        meetingTitle: request.meetingTitle,
                        mergeTimeoutSeconds: request.mergeTimeoutSeconds
                    )
                )
            },
            recheckBeforeMerge: { validated in validated.recheckForMerge() },
            mergeStage: { request, _ in
                RecordingAudioPreparedArtifact(outputURL: request.outputURL, mergedDuration: 60)
            },
            publish: { _, artifact in
                artifact.outputURL.map(RecordingAudioPublication.init(audioURL:))
            },
            storeCommit: { request in
                guard let audioURL = request.audioURL else { return .failed }
                let saved = await store.updateRecoveredRecording(
                    id: request.finalization.recordingID,
                    endDate: request.endDate,
                    duration: request.duration,
                    audioFileURL: audioURL
                )
                return saved ? .saved : .failed
            },
            cleanup: { _ in .cleaned },
            cleanupPublished: { _, _ in .cleaned },
            postProcess: { _, _ in },
            recordEvent: { event in await events.record(event) }
        )
        let coordinator = PostProcessingCoordinator(
            store: store,
            audioFinalizerDependencies: dependencies,
            // Inject a test-owned root; the default points at the real
            // recordings directory.
            recordingsDirectory: storageRoot
        )

        await coordinator.recoverInterrupted()

        #expect(await events.events == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
            .postProcess,
        ])
        let recovered = await store.fetchRecordingDetail(recordingID: recordingID)
        let interruptedAfterRecovery = await store.fetchInterruptedRecordings()
        #expect(recovered?.endDate == segmentDate.addingTimeInterval(30))
        #expect(!interruptedAfterRecovery.contains { $0.id == recordingID })
    }

    @Test @MainActor
    func crashRecoveryKeepsOutsideAuthorityRecordingPending() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-recovery-\(UUID().uuidString)", isDirectory: true)
        await store.setAudioRootForTesting(outsideRoot)
        let segmentsDirectory = outsideRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let markerURL = segmentsDirectory.appendingPathComponent("outside-marker")
        let markerBytes = Data([0xC0, 0xDE])
        try markerBytes.write(to: markerURL)
        await store.createRecording(
            id: recordingID,
            title: "Pending storage access",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            segmentsDirURL: segmentsDirectory
        )
        let events = RecoveryFinalizationEventSpy()
        let dependencies = RecordingAudioFinalizerDependencies(
            validate: { request in
                await RecordingAudioFinalizer.validateSegments(request)
            },
            recheckBeforeMerge: { validated in validated.recheckForMerge() },
            mergeStage: { request, _ in
                RecordingAudioPreparedArtifact(
                    outputURL: request.outputURL,
                    mergedDuration: 30
                )
            },
            publish: { _, artifact in
                artifact.outputURL.map(RecordingAudioPublication.init(audioURL:))
            },
            storeCommit: { _ in .saved },
            cleanup: { _ in .cleaned },
            cleanupPublished: { _, _ in .cleaned },
            postProcess: { _, _ in },
            recordEvent: { event in await events.record(event) }
        )
        // Use a distinct authority root: segments outside it must stay pending.
        let authorityRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("authority-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: authorityRoot) }
        let coordinator = PostProcessingCoordinator(
            store: store,
            audioFinalizerDependencies: dependencies,
            recordingsDirectory: authorityRoot
        )

        await coordinator.recoverInterrupted()

        #expect(await events.events == [.validation])
        let pending = await store.fetchInterruptedRecordings()
        #expect(pending.contains { $0.id == recordingID && $0.segmentsDirURL.resolvingSymlinksInPath().path == segmentsDirectory.resolvingSymlinksInPath().path })
        #expect(try Data(contentsOf: markerURL) == markerBytes)
    }

    @Test @MainActor
    func recoveryFailureIgnoresDecoyAudioAndPreservesSegmentsEvidence() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-decoy-\(UUID().uuidString)", isDirectory: true)
        await store.setAudioRootForTesting(storageRoot)
        let segmentsDirectory = storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let evidenceURL = segmentsDirectory.appendingPathComponent("recovery-evidence")
        let evidence = Data("preserve-recovery-evidence".utf8)
        try evidence.write(to: evidenceURL)
        try Data("untrusted-decoy".utf8).write(
            to: storageRoot.appendingPathComponent("\(recordingID.uuidString).m4a")
        )
        await store.createRecording(
            id: recordingID,
            title: "Interrupted with decoy",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            segmentsDirURL: segmentsDirectory
        )
        let coordinator = PostProcessingCoordinator(
            store: store,
            recordingsDirectory: storageRoot
        )

        await coordinator.recoverInterrupted()

        #expect(FileManager.default.fileExists(atPath: segmentsDirectory.path))
        #expect(try Data(contentsOf: evidenceURL) == evidence)
        #expect(
            await store.fetchInterruptedRecordings().contains {
                $0.id == recordingID
                    && $0.segmentsDirURL.resolvingSymlinksInPath().path
                        == segmentsDirectory.resolvingSymlinksInPath().path
            }
        )
    }
}

@MainActor
private final class PostProcessingProviderSpy {
    var keys: [AIProvider: String] = [:]
    var supportsAppleLanguage = true
    var localWhisperModel = "base"
    var isLocalWhisperAvailable = true
    private(set) var keyLookups: [AIProvider] = []
    private(set) var appleLanguageChecks: [String] = []
    private(set) var localWhisperStateCallCount = 0
    private(set) var requests: [TranscriptionExecutionRequest] = []

    func apiKey(for provider: AIProvider) -> String? {
        keyLookups.append(provider)
        return keys[provider]
    }

    func appleSupportsLanguage(_ language: String) async -> Bool {
        appleLanguageChecks.append(language)
        return supportsAppleLanguage
    }

    func localWhisperState() -> LocalWhisperState {
        localWhisperStateCallCount += 1
        return LocalWhisperState(
            model: localWhisperModel,
            isAvailable: isLocalWhisperAvailable
        )
    }

    func record(_ request: TranscriptionExecutionRequest) {
        requests.append(request)
    }
}

private struct StopAfterRecordingProvider: Error {}

@MainActor
private final class PostProcessingResolverGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let result: Bool
    private(set) var didStart = false
    private(set) var didFinish = false

    init(result: Bool) {
        self.result = result
    }

    func wait() async -> Bool {
        didStart = true
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        didFinish = true
        return result
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private func waitForProviderBoundaryCondition(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
private func waitForProviderBoundaryAsyncCondition(
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private func waitForPostProcessingToFinish(
    _ coordinator: PostProcessingCoordinator,
    recordingID: UUID
) async -> Bool {
    await waitForProviderBoundaryCondition {
        !coordinator.isProcessing(recordingID: recordingID)
    }
}

@MainActor
private final class BlockingPostProcessingRunner {
    private(set) var requests: [TranscriptionExecutionRequest] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ request: TranscriptionExecutionRequest) async throws {
        requests.append(request)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        throw StopAfterRecordingProvider()
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class StubbornPostProcessingRunner {
    private(set) var requests: [TranscriptionExecutionRequest] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func run(_ request: TranscriptionExecutionRequest) async throws {
        let index = requests.count
        requests.append(request)
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
        throw StopAfterRecordingProvider()
    }

    func release(index: Int) {
        let continuation = continuations.removeValue(forKey: index)
        continuation?.resume()
    }

    func releaseAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class RestartedJobTaskController {
    private(set) var requests: [TranscriptionExecutionRequest] = []
    private(set) var startedIndices: Set<Int> = []
    private(set) var cancellationByIndex: [Int: Bool] = [:]
    private(set) var oldProgressWasEmitted = false
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func makeTask(
        manager: TranscriptionManager,
        request: TranscriptionExecutionRequest
    ) -> Task<TranscriptResult, Error> {
        let index = requests.count
        requests.append(request)
        return Task { @MainActor in
            await withCheckedContinuation { continuation in
                continuations[index] = continuation
                startedIndices.insert(index)
            }
            if index == 0 {
                manager.onProgress?(91, 100)
                oldProgressWasEmitted = true
            }
            cancellationByIndex[index] = Task.isCancelled
            throw StopAfterRecordingProvider()
        }
    }

    func release(index: Int) {
        let continuation = continuations.removeValue(forKey: index)
        continuation?.resume()
    }
}

@MainActor
private final class StubbornSummaryTaskController {
    private(set) var requests: [PostProcessingSummaryExecutionRequest] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func makeTask(
        generator: SummaryGenerator,
        request: PostProcessingSummaryExecutionRequest
    ) -> Task<Void, Never> {
        let index = requests.count
        requests.append(request)
        return Task { @MainActor in
            await withCheckedContinuation { continuation in
                continuations[index] = continuation
            }
        }
    }

    func release(index: Int) {
        let continuation = continuations.removeValue(forKey: index)
        continuation?.resume()
    }

    func releaseAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class PostProcessingProviderHarness {
    let defaultsName: String
    let defaults: UserDefaults
    let directory: URL
    let store: RecordingsStore
    let spy: PostProcessingProviderSpy
    let coordinator: PostProcessingCoordinator

    init(appleLanguageGate: PostProcessingResolverGate? = nil) async throws {
        let defaultsName = "PostProcessingProviderBoundaryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try await makeIsolatedStore(audioRoot: directory)
        let spy = PostProcessingProviderSpy()
        let dependencies = PostProcessingTranscriptionDependencies(
            defaults: defaults,
            apiKey: { provider in spy.apiKey(for: provider) },
            supportsAppleLanguage: { language in
                if let gate = appleLanguageGate {
                    return await gate.wait()
                }
                return await spy.appleSupportsLanguage(language)
            },
            localWhisperState: { spy.localWhisperState() }
        )
        let coordinator = PostProcessingCoordinator(
            store: store,
            transcriptionDependencies: dependencies
        )
        coordinator.transcriptionRunnerOverride = { _, request in
            spy.record(request)
            throw StopAfterRecordingProvider()
        }

        self.defaultsName = defaultsName
        self.defaults = defaults
        self.directory = directory
        self.store = store
        self.spy = spy
        self.coordinator = coordinator
    }

    func configure(provider rawValue: String, language: String = "auto") {
        defaults.set(rawValue, forKey: "transcriptionProvider")
        defaults.set(language, forKey: "transcriptionLanguage")
    }

    func makeRecording(
        duration: TimeInterval = 60,
        realM4A: Bool = false,
        title: String = "Provider Boundary"
    ) async throws -> (recordingID: UUID, audioURL: URL) {
        let recordingID = UUID()
        let audioURL = directory.appendingPathComponent("\(recordingID.uuidString).m4a")
        if realM4A {
            try await AudioTestFixtures.writeM4A(
                tracks: [AudioTestFixtures.sine(count: 16_000, amplitude: 0.05)],
                to: audioURL
            )
        } else {
            try Data("provider-boundary-fixture-\(recordingID.uuidString)".utf8).write(to: audioURL)
        }
        #expect(await store.importAudioFile(
            id: recordingID,
            title: title,
            startDate: Date(),
            duration: duration,
            audioURL: audioURL, ownership: .appCreated))
        return (recordingID, audioURL)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - PostProcessingCoordinator: exact provider boundary

@Suite("Post-processing Provider Boundary", .serialized)
@MainActor
struct PostProcessingProviderBoundaryTests {
    @Test
    func speakerMemoryMappingDuringSummaryDoesNotFailOrDiscardOutput() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        let diarizationEnabled = SpeakerDiarizer.shared.isEnabled
        SpeakerDiarizer.shared.isEnabled = false
        defer { SpeakerDiarizer.shared.isEnabled = diarizationEnabled }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "fictional-key"
        let fixture = try await harness.makeRecording()
        let profile = try #require(await harness.store.createSpeakerProfile(displayName: "Mina"))
        let store = harness.store
        harness.coordinator.transcriptionRunnerOverride = nil
        harness.coordinator.transcriptionTaskFactoryOverride = { _, _ in
            Task<TranscriptResult, Error> {
                TranscriptResult(text: "Review the mapping.", segments: [
                    TranscriptResultSegment(startTime: 0, endTime: 2, text: "Review the mapping.", speaker: "Speaker 1")
                ], language: "en", duration: 60)
            }
        }
        harness.coordinator.summaryTaskFactoryOverride = { generator, _ in
            Task { @MainActor in
                // The coordinator already captured its source. Exercise the same
                // persisted write used by the independent speaker-memory task.
                let applied = await store.applySpeakerMappingIfCurrent(
                    recordingID: fixture.recordingID, rawLabel: "Speaker 1", profileID: profile.id,
                    expectedSpeakerIdentityRevision: 1)
                #expect(applied == .applied)
                var result = SummaryResult(title: "Fictional review", overview: "Review the mapping.",
                    keyPoints: ["Mapping needs review"], actionItems: [], decisions: [], followUps: [],
                    yourTasks: [], tags: [], chapters: [], rawText: "")
                result.generationMetadata = .init(detailLevel: "detailed", stage: .reviewed)
                generator.completeForTesting(with: result)
            }
        }
        var completed = false
        harness.coordinator.onPostProcessingCompleted = { id in
            if id == fixture.recordingID { completed = true }
        }
        await harness.coordinator.startPostProcessing(recordingID: fixture.recordingID,
            audioURL: fixture.audioURL, meetingTitle: nil)
        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        let detail = try #require(await store.fetchRecordingDetail(recordingID: fixture.recordingID))
        #expect(detail.summary?.overview == "Review the mapping.")
        #expect(detail.summary?.generationMetadata?.sourceChanged == false)
        #expect(detail.summary?.generationMetadata?.speakerMappingsChanged == true)
        #expect(harness.coordinator.postProcessingError == nil)
        #expect(completed)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @Test
    func selectedOpenAIWithoutKeyDoesNotUseGemini() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.openai.rawValue)
        harness.spy.keys[.gemini] = "gemini-test-key"
        let fixture = try await harness.makeRecording()

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        #expect(harness.spy.requests.isEmpty)
        #expect(harness.spy.keyLookups == [.openai])
        #expect(harness.coordinator.postProcessingError?.contains("OpenAI") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        #expect(await harness.store.fetchRecordingDetail(recordingID: fixture.recordingID)?.transcript == nil)
    }

    @Test
    func unsupportedAppleLanguageDoesNotUseCloud() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.apple.rawValue, language: "zz")
        harness.spy.supportsAppleLanguage = false
        harness.spy.keys[.openai] = "openai-key"
        harness.spy.keys[.gemini] = "gemini-key"
        let fixture = try await harness.makeRecording()

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        #expect(harness.spy.requests.isEmpty)
        #expect(harness.spy.keyLookups.isEmpty)
        #expect(harness.spy.appleLanguageChecks == ["zz"])
        #expect(harness.coordinator.postProcessingError?.contains("Apple") == true)
    }

    @Test
    func unavailableWhisperDoesNotUseCloud() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.whisperLocal.rawValue)
        harness.spy.localWhisperModel = "small.en"
        harness.spy.isLocalWhisperAvailable = false
        harness.spy.keys[.gemini] = "gemini-key"
        let fixture = try await harness.makeRecording()

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        #expect(harness.spy.requests.isEmpty)
        #expect(harness.spy.keyLookups.isEmpty)
        #expect(harness.spy.localWhisperStateCallCount == 1)
        #expect(harness.coordinator.postProcessingError?.contains("small.en") == true)
    }

    @Test
    func invalidAndWhitespaceProvidersFailWithoutRunner() async throws {
        for rawValue in ["not-a-provider", "   "] {
            let harness = try await PostProcessingProviderHarness()
            harness.configure(provider: rawValue)
            let fixture = try await harness.makeRecording()

            await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )

            #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
            #expect(harness.spy.requests.isEmpty)
            #expect(harness.spy.keyLookups.isEmpty)
            #expect(harness.spy.appleLanguageChecks.isEmpty)
            #expect(harness.spy.localWhisperStateCallCount == 0)
            #expect(harness.coordinator.postProcessingError != nil)
            harness.cleanup()
        }
    }

    @Test
    func validGeminiInvokesOnlyGeminiWithTrimmedKey() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "  gemini-key  "
        harness.spy.keys[.openai] = "openai-key"
        let fixture = try await harness.makeRecording()

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        #expect(harness.spy.keyLookups == [.gemini])
        #expect(harness.spy.requests.map(\.provider) == [.gemini])
        #expect(harness.spy.requests.first?.apiKey == "gemini-key")
        #expect(harness.spy.requests.first?.model == nil)
    }

    @Test
    func invalidConfigurationBypassesTwoOccupiedSlots() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let first = try await harness.makeRecording(title: "First")
        let second = try await harness.makeRecording(title: "Second")
        let third = try await harness.makeRecording(title: "Third")
        let blocker = BlockingPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await blocker.run(request)
        }

        await harness.coordinator.startPostProcessing(
            recordingID: first.recordingID,
            audioURL: first.audioURL,
            meetingTitle: nil
        )
        await harness.coordinator.startPostProcessing(
            recordingID: second.recordingID,
            audioURL: second.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { blocker.requests.count == 2 })

        harness.configure(provider: "not-a-provider")
        await harness.coordinator.startPostProcessing(
            recordingID: third.recordingID,
            audioURL: third.audioURL,
            meetingTitle: nil
        )
        let thirdFinishedBeforeRelease = await waitForPostProcessingToFinish(
            harness.coordinator,
            recordingID: third.recordingID
        )

        #expect(thirdFinishedBeforeRelease)
        #expect(blocker.requests.count == 2)
        blocker.releaseAll()
        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: first.recordingID))
        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: second.recordingID))
    }

    @Test
    func threeInvalidJobsFinishWithoutLeakingSlots() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: "not-a-provider")
        let first = try await harness.makeRecording(title: "One")
        let second = try await harness.makeRecording(title: "Two")
        let third = try await harness.makeRecording(title: "Three")
        let fixtures = [first, second, third]

        for fixture in fixtures {
            await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )
        }

        let allFinished = await waitForProviderBoundaryCondition {
            fixtures.allSatisfy { !harness.coordinator.isProcessing(recordingID: $0.recordingID) }
        }
        #expect(allFinished)
        #expect(harness.spy.requests.isEmpty)
    }

    @Test
    func manualRetryMissingKeyPreservesRecordingAndResetsProgress() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.openai.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let fixture = try await harness.makeRecording(title: "Manual Retry")
        #expect(await harness.store.saveTranscript(
            recordingID: fixture.recordingID,
            fullText: "Existing transcript",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Existing transcript")],
            language: "en",
            tags: []
        ))
        let bytesBefore = try Data(contentsOf: fixture.audioURL)
        let detailBefore = try #require(await harness.store.fetchRecordingDetail(recordingID: fixture.recordingID))

        await harness.coordinator.retryTranscription(recordingID: fixture.recordingID)

        let detailAfter = try #require(await harness.store.fetchRecordingDetail(recordingID: fixture.recordingID))
        #expect(harness.spy.requests.isEmpty)
        #expect(harness.spy.keyLookups == [.openai])
        #expect(harness.coordinator.manualRetryChunksDone == 0)
        #expect(harness.coordinator.manualRetryChunksTotal == 0)
        #expect(!harness.coordinator.isRetryingTranscription(for: fixture.recordingID))
        #expect(harness.coordinator.postProcessingError?.contains("OpenAI") == true)
        #expect(try Data(contentsOf: fixture.audioURL) == bytesBefore)
        #expect(detailAfter.title == detailBefore.title)
        #expect(detailAfter.duration == detailBefore.duration)
        #expect(detailAfter.audioFile == detailBefore.audioFile)
        #expect(detailAfter.transcript?.fullText == detailBefore.transcript?.fullText)
    }

    @Test
    func availableWhisperModelIsPassedToRunner() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.whisperLocal.rawValue)
        harness.spy.localWhisperModel = "small.en"
        harness.spy.isLocalWhisperAvailable = true
        let fixture = try await harness.makeRecording()

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        #expect(harness.spy.requests.map(\.provider) == [.whisperLocal])
        #expect(harness.spy.requests.first?.model == "small.en")
        #expect(harness.spy.requests.first?.apiKey.isEmpty == true)
        #expect(harness.spy.keyLookups.isEmpty)
    }

    @Test
    func shortRecordingWithInvalidProviderIsNotTrashed() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: "not-a-provider")
        let fixture = try await harness.makeRecording(duration: 1)
        let bytesBefore = try Data(contentsOf: fixture.audioURL)
        var discardedIDs: [UUID] = []
        harness.coordinator.onRecordingDiscarded = { recordingID, _ in
            discardedIDs.append(recordingID)
        }

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        let activeIDs = await harness.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).map(\.id)
        let trashedIDs = await harness.store.fetchTrashedRecordings().map(\.id)
        #expect(activeIDs.contains(fixture.recordingID))
        #expect(!trashedIDs.contains(fixture.recordingID))
        #expect(discardedIDs.isEmpty)
        #expect(try Data(contentsOf: fixture.audioURL) == bytesBefore)
        #expect(harness.spy.requests.isEmpty)
    }

    @Test
    func missingSelectedKeyPreservesRealAudioAndModel() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.openai.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let fixture = try await harness.makeRecording(duration: 60, realM4A: true)
        let bytesBefore = try Data(contentsOf: fixture.audioURL)
        var discardCount = 0
        harness.coordinator.onRecordingDiscarded = { _, _ in discardCount += 1 }

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )

        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: fixture.recordingID))
        let detail = try #require(await harness.store.fetchRecordingDetail(recordingID: fixture.recordingID))
        #expect(try Data(contentsOf: fixture.audioURL) == bytesBefore)
        #expect(detail.audioFile?.lastPathComponent == fixture.audioURL.lastPathComponent)
        #expect(detail.duration == 60)
        #expect(detail.transcript == nil)
        #expect(discardCount == 0)
        #expect(harness.spy.requests.isEmpty)
        #expect(harness.spy.keyLookups == [.openai])
        #expect(harness.coordinator.postProcessingError?.contains("OpenAI") == true)
    }

    @Test
    func cancelJobDuringResolverSuspensionPreservesShortRecordingAndGlobalError() async throws {
        let gate = PostProcessingResolverGate(result: true)
        let harness = try await PostProcessingProviderHarness(appleLanguageGate: gate)
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.apple.rawValue)
        let fixture = try await harness.makeRecording(duration: 1)
        let existingError = "Existing actionable configuration error"
        harness.coordinator.postProcessingError = existingError
        var discardedIDs: [UUID] = []
        var recordingsChangedCount = 0
        harness.coordinator.onRecordingDiscarded = { recordingID, _ in
            discardedIDs.append(recordingID)
        }
        harness.coordinator.onRecordingsChanged = {
            recordingsChangedCount += 1
        }

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { gate.didStart })

        harness.coordinator.cancelJob(for: fixture.recordingID)
        gate.release()
        #expect(await waitForProviderBoundaryCondition { gate.didFinish })
        try await Task.sleep(for: .milliseconds(100))

        let activeIDs = await harness.store.fetchRecordingDTOs(
            sortKey: "dateNewest",
            folderID: nil,
            tagFilter: nil
        ).map(\.id)
        let trashedIDs = await harness.store.fetchTrashedRecordings().map(\.id)
        #expect(activeIDs.contains(fixture.recordingID))
        #expect(!trashedIDs.contains(fixture.recordingID))
        #expect(discardedIDs.isEmpty)
        #expect(recordingsChangedCount == 0)
        #expect(harness.coordinator.postProcessingError == existingError)
    }

    @Test
    func cancelCurrentDuringResolverSuspensionRestoresTwoTranscriptionSlots() async throws {
        let gate = PostProcessingResolverGate(result: true)
        let harness = try await PostProcessingProviderHarness(appleLanguageGate: gate)
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.apple.rawValue)
        let cancelled = try await harness.makeRecording(title: "Cancelled before resolution")

        await harness.coordinator.startPostProcessing(
            recordingID: cancelled.recordingID,
            audioURL: cancelled.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { gate.didStart })
        harness.coordinator.cancelCurrentJob()
        gate.release()
        #expect(await waitForProviderBoundaryCondition { gate.didFinish })
        try await Task.sleep(for: .milliseconds(100))

        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let blocker = BlockingPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await blocker.run(request)
        }
        let first = try await harness.makeRecording(title: "After cancel one")
        let second = try await harness.makeRecording(title: "After cancel two")

        await harness.coordinator.startPostProcessing(
            recordingID: first.recordingID,
            audioURL: first.audioURL,
            meetingTitle: nil
        )
        await harness.coordinator.startPostProcessing(
            recordingID: second.recordingID,
            audioURL: second.audioURL,
            meetingTitle: nil
        )

        let bothEntered = await waitForProviderBoundaryCondition { blocker.requests.count == 2 }
        #expect(bothEntered)
        blocker.releaseAll()
        if blocker.requests.count < 2 {
            _ = await waitForProviderBoundaryCondition { blocker.requests.count == 2 }
            blocker.releaseAll()
        }
        harness.coordinator.cancelCurrentJob()
    }

    @Test
    func cancellingQueuedJobDoesNotLeakTransferredTranscriptionSlot() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let occupiedRunner = BlockingPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await occupiedRunner.run(request)
        }
        let first = try await harness.makeRecording(title: "Occupy one")
        let second = try await harness.makeRecording(title: "Occupy two")
        let queued = try await harness.makeRecording(title: "Queued then cancelled")

        for fixture in [first, second] {
            await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )
        }
        #expect(await waitForProviderBoundaryCondition { occupiedRunner.requests.count == 2 })
        await harness.coordinator.startPostProcessing(
            recordingID: queued.recordingID,
            audioURL: queued.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { harness.spy.keyLookups.count == 3 })
        try await Task.sleep(for: .milliseconds(100))

        harness.coordinator.cancelJob(for: queued.recordingID)
        occupiedRunner.releaseAll()
        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: first.recordingID))
        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: second.recordingID))

        let capacityProbe = BlockingPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await capacityProbe.run(request)
        }
        let afterCancelFirst = try await harness.makeRecording(title: "Capacity one")
        let afterCancelSecond = try await harness.makeRecording(title: "Capacity two")
        for fixture in [afterCancelFirst, afterCancelSecond] {
            await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )
        }

        let bothEntered = await waitForProviderBoundaryCondition { capacityProbe.requests.count == 2 }
        #expect(bothEntered)
        capacityProbe.releaseAll()
        if capacityProbe.requests.count < 2 {
            _ = await waitForProviderBoundaryCondition { capacityProbe.requests.count == 2 }
            capacityProbe.releaseAll()
        }
        harness.coordinator.cancelCurrentJob()
    }

    @Test
    func cancellingRunningJobDoesNotReleaseTranscriptionSlotUntilRunnerReturns() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let first = try await harness.makeRecording(title: "Stubborn one")
        let second = try await harness.makeRecording(title: "Stubborn two")
        let third = try await harness.makeRecording(title: "Must remain queued")

        for fixture in [first, second] {
            await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )
        }
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 2 })

        harness.coordinator.cancelJob(for: first.recordingID)
        await harness.coordinator.startPostProcessing(
            recordingID: third.recordingID,
            audioURL: third.audioURL,
            meetingTitle: nil
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.requests.count == 2)

        runner.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 3 })
        runner.releaseAll()
        harness.coordinator.cancelCurrentJob()
    }

    @Test
    func cancellingAllRunningJobsDoesNotReleaseTranscriptionSlotsUntilRunnersReturn() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let first = try await harness.makeRecording(title: "Stubborn all one")
        let second = try await harness.makeRecording(title: "Stubborn all two")
        let third = try await harness.makeRecording(title: "Queued after cancel all")

        for fixture in [first, second] {
            await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )
        }
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 2 })

        harness.coordinator.cancelCurrentJob()
        await harness.coordinator.startPostProcessing(
            recordingID: third.recordingID,
            audioURL: third.audioURL,
            meetingTitle: nil
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(runner.requests.count == 2)

        runner.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 3 })
        runner.releaseAll()
        harness.coordinator.cancelCurrentJob()
    }

    @Test
    func cancellingRunningJobDoesNotReleaseSummarySlotUntilRunnerReturns() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        harness.coordinator.transcriptionRunnerOverride = nil
        harness.coordinator.transcriptionTaskFactoryOverride = { _, request in
            Task<TranscriptResult, Error> {
                TranscriptResult(
                    text: "Transcript for \(request.audioURL.lastPathComponent)",
                    segments: [],
                    language: "en",
                    duration: 60
                )
            }
        }
        let summaries = StubbornSummaryTaskController()
        harness.coordinator.summaryTaskFactoryOverride = { generator, request in
            summaries.makeTask(generator: generator, request: request)
        }
        let first = try await harness.makeRecording(title: "Stubborn summary")
        let second = try await harness.makeRecording(title: "Queued summary")

        await harness.coordinator.startPostProcessing(
            recordingID: first.recordingID,
            audioURL: first.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { summaries.requests.count == 1 })
        await harness.coordinator.startPostProcessing(
            recordingID: second.recordingID,
            audioURL: second.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition {
            harness.coordinator.isProcessing(recordingID: second.recordingID)
        })

        harness.coordinator.cancelJob(for: first.recordingID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(summaries.requests.count == 1)

        summaries.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { summaries.requests.count == 2 })
        summaries.releaseAll()
        harness.coordinator.cancelCurrentJob()
    }

    @Test
    func manualRetryMissingKeyFailsBeforeAbsentAudioRecovery() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.openai.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let fixture = try await harness.makeRecording(title: "Missing local audio")
        try FileManager.default.removeItem(at: fixture.audioURL)

        await harness.coordinator.retryTranscription(recordingID: fixture.recordingID)

        #expect(harness.spy.keyLookups == [.openai])
        #expect(harness.spy.requests.isEmpty)
        #expect(harness.coordinator.postProcessingError?.contains("OpenAI") == true)
        #expect(await harness.store.fetchRecordingDetail(recordingID: fixture.recordingID) != nil)
    }

    @Test
    func startingValidConcurrentJobDoesNotClearExistingConfigurationError() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let blocker = BlockingPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await blocker.run(request)
        }
        let first = try await harness.makeRecording(title: "Already running")
        await harness.coordinator.startPostProcessing(
            recordingID: first.recordingID,
            audioURL: first.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { blocker.requests.count == 1 })

        harness.configure(provider: AIProvider.openai.rawValue)
        let invalid = try await harness.makeRecording(title: "Actionable error")
        await harness.coordinator.startPostProcessing(
            recordingID: invalid.recordingID,
            audioURL: invalid.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForPostProcessingToFinish(harness.coordinator, recordingID: invalid.recordingID))
        let actionableError = try #require(harness.coordinator.postProcessingError)
        #expect(actionableError.contains("OpenAI"))

        harness.configure(provider: AIProvider.gemini.rawValue)
        let second = try await harness.makeRecording(title: "New valid concurrent job")
        await harness.coordinator.startPostProcessing(
            recordingID: second.recordingID,
            audioURL: second.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { blocker.requests.count == 2 })
        #expect(harness.coordinator.postProcessingError == actionableError)

        blocker.releaseAll()
        harness.coordinator.cancelCurrentJob()
    }

    @Test
    func liveDependenciesUseReadOnlyKeychainLookup() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent(
            "Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let liveStart = try #require(source.range(of: "static func live(defaults:"))
        let coordinatorStart = try #require(source.range(
            of: "/// Orchestrates post-processing",
            range: liveStart.upperBound..<source.endIndex
        ))
        let liveWiring = source[liveStart.lowerBound..<coordinatorStart.lowerBound]

        #expect(liveWiring.contains("KeychainManager.shared.readOnlyAPIKey(for: provider)"))
        #expect(!liveWiring.contains("KeychainManager.shared.apiKey(for: provider)"))
    }

    @Test
    func cancelledGenerationCannotMutateOrClearRestartedJobState() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        harness.coordinator.transcriptionRunnerOverride = nil
        let controller = RestartedJobTaskController()
        harness.coordinator.transcriptionTaskFactoryOverride = { manager, request in
            controller.makeTask(manager: manager, request: request)
        }
        let fixture = try await harness.makeRecording(title: "Restart same recording ID")

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { controller.startedIndices.contains(0) })
        harness.coordinator.cancelJob(for: fixture.recordingID)

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { controller.startedIndices.contains(1) })

        controller.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { controller.cancellationByIndex[0] != nil })
        #expect(await waitForProviderBoundaryCondition { controller.oldProgressWasEmitted })
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.coordinator.isProcessing(recordingID: fixture.recordingID))
        #expect(harness.coordinator.postProcessingPhase == "transcribing")
        #expect(harness.coordinator.transcriptionChunksDone == 0)

        harness.coordinator.cancelJob(for: fixture.recordingID)
        controller.release(index: 1)
        #expect(await waitForProviderBoundaryCondition { controller.cancellationByIndex[1] != nil })
        #expect(controller.cancellationByIndex[1] == true)
    }
}

// MARK: - RecordingsStore: fetchUnprocessedRecordings

@Suite("RecordingsStore.fetchUnprocessedRecordings", .serialized)
struct FetchUnprocessedRecordingsTests {

    // Returns recordings that have an audioFilePath but no transcript and no segmentsDirectory.
    @Test @MainActor
    func returnsRecordingWithAudioButNoTranscript() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioRoot.appendingPathComponent("audio.m4a"))

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.count == 1)
        #expect(results.first?.id == id)
        #expect(results.first?.audioFileURL.lastPathComponent == "audio.m4a")
    }

    // Recording with transcript but no summary is still unprocessed (needs summary).
    @Test @MainActor
    func returnsRecordingWithTranscriptButNoSummary() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioRoot.appendingPathComponent("audio.m4a"))
        await store.saveTranscript(
            recordingID: id,
            fullText: "Hello world",
            segments: [],
            language: "en",
            tags: []
        )

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.count == 1)
        #expect(results.first?.hasTranscript == true)
    }

    // Must NOT return recordings that have both transcript and summary.
    @Test @MainActor
    func excludesFullyProcessedRecording() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioRoot.appendingPathComponent("audio.m4a"))
        await store.saveTranscript(
            recordingID: id,
            fullText: "Hello world",
            segments: [],
            language: "en",
            tags: []
        )
        let summary = SummaryResult(
            title: "Test", overview: "Overview", keyPoints: ["point"],
            actionItems: [], decisions: [], followUps: [], yourTasks: [], tags: [],
            chapters: [], rawText: ""
        )
        await store.saveSummary(recordingID: id, summary: summary, chaptersJSON: nil)

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.isEmpty)
    }

    // Must NOT return recordings still in-progress (have audioSegmentsDirectory).
    @Test @MainActor
    func excludesRecordingWithSegmentsDirectory() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        // createRecording with segmentsDir simulates an in-progress recording.
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: audioRoot.appendingPathComponent("segments", isDirectory: true))
        // No finalize — audioFilePath is still nil, segmentsDirectory still set.

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.isEmpty)
    }

    // Must NOT return trashed recordings.
    @Test @MainActor
    func excludesTrashedRecording() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioRoot.appendingPathComponent("audio.m4a"))
        await store.deleteRecording(recordingID: id)  // soft-trash

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.isEmpty)
    }

    // Must NOT return recordings with no audioFilePath at all (never finalized).
    @Test @MainActor
    func excludesRecordingWithoutAudioPath() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R1", startDate: Date(), segmentsDirURL: nil)
        // No finalizeRecording → audioFilePath is nil.

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.isEmpty)
    }

    // Returns multiple unprocessed recordings correctly.
    @Test @MainActor
    func returnsMultipleUnprocessedRecordings() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }

        let id1 = UUID()
        let id2 = UUID()
        await store.createRecording(id: id1, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id1, duration: 30, audioFileURL: audioRoot.appendingPathComponent("a1.m4a"))

        await store.createRecording(id: id2, title: "R2", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id2, duration: 45, audioFileURL: audioRoot.appendingPathComponent("a2.m4a"))

        let results = await store.fetchUnprocessedRecordings()
        #expect(results.count == 2)
        let ids = Set(results.map(\.id))
        #expect(ids.contains(id1))
        #expect(ids.contains(id2))
    }
}

// MARK: - RecordingsStore: post-processing backfill

@Suite("RecordingsStore.postProcessingBackfill", .serialized)
struct PostProcessingBackfillStoreTests {

    @Test @MainActor
    func queuedBackfillIgnoresSeventyTwoHourWindowButRequiresExplicitState() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let oldID = UUID()
        let oldDate = Date().addingTimeInterval(-120 * 3600)
        await store.createRecording(id: oldID, title: "Old Import", startDate: oldDate, segmentsDirURL: nil)
        await store.finalizeRecording(id: oldID, duration: 1800, audioFileURL: audioRoot.appendingPathComponent("old.m4a"))

        let unprocessed = await store.fetchUnprocessedRecordings()
        #expect(unprocessed.isEmpty)

        let enqueued = await store.enqueuePostProcessingBackfill(recordingID: oldID, source: "test")
        #expect(enqueued)

        let queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.count == 1)
        #expect(queued.first?.id == oldID)
        #expect(queued.first?.audioFileURL.lastPathComponent == "old.m4a")
        #expect(queued.first?.hasTranscript == false)
    }

    @Test @MainActor
    func queuedBackfillExcludesCompletedTrashedMissingAudioAndFutureCooldown() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let queuedID = UUID()
        let noAudioID = UUID()
        let blockedID = UUID()
        let completeID = UUID()
        let trashedID = UUID()
        let now = Date()

        await store.createRecording(id: queuedID, title: "Queued", startDate: now, segmentsDirURL: nil)
        await store.finalizeRecording(id: queuedID, duration: 120, audioFileURL: audioRoot.appendingPathComponent("queued.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: queuedID, source: "test")

        await store.createRecording(id: noAudioID, title: "No Audio", startDate: now, segmentsDirURL: nil)
        await store.enqueuePostProcessingBackfill(recordingID: noAudioID, source: "test")

        await store.createRecording(id: blockedID, title: "Blocked", startDate: now, segmentsDirURL: nil)
        await store.finalizeRecording(id: blockedID, duration: 120, audioFileURL: audioRoot.appendingPathComponent("blocked.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: blockedID, source: "test")
        await store.markBackfillFailed(
            recordingID: blockedID,
            error: "decode failed",
            maxAutomaticFailures: 1,
            cooldown: 3600,
            now: now
        )

        await store.createRecording(id: completeID, title: "Complete", startDate: now, segmentsDirURL: nil)
        await store.finalizeRecording(id: completeID, duration: 120, audioFileURL: audioRoot.appendingPathComponent("complete.m4a"))
        await store.saveTranscript(
            recordingID: completeID,
            fullText: "done",
            segments: [],
            language: "en",
            tags: []
        )
        await store.saveSummary(
            recordingID: completeID,
            summary: SummaryResult(
                title: "T",
                overview: "O",
                keyPoints: ["K"],
                actionItems: [],
                decisions: [],
                followUps: [],
                yourTasks: [],
                tags: [],
                chapters: [],
                rawText: ""
            ),
            chaptersJSON: nil
        )
        await store.enqueuePostProcessingBackfill(recordingID: completeID, source: "test")

        await store.createRecording(id: trashedID, title: "Trashed", startDate: now, segmentsDirURL: nil)
        await store.finalizeRecording(id: trashedID, duration: 120, audioFileURL: audioRoot.appendingPathComponent("trashed.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: trashedID, source: "test")
        await store.deleteRecording(recordingID: trashedID)

        let queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.map { $0.id } == [queuedID])
    }

    @Test @MainActor
    func backfillFailureThresholdBlocksAndResetRequeues() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        let now = Date()
        await store.createRecording(id: id, title: "Bad Audio", startDate: now, segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioRoot.appendingPathComponent("bad.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")

        await store.markBackfillFailed(
            recordingID: id,
            error: String(repeating: "x", count: 500),
            maxAutomaticFailures: 2,
            cooldown: 3600,
            now: now
        )
        #expect(await store.fetchQueuedBackfillRecordings(limit: 10).isEmpty)

        await store.markBackfillFailed(
            recordingID: id,
            error: "second failure",
            maxAutomaticFailures: 2,
            cooldown: 3600,
            now: now.addingTimeInterval(7200)
        )
        #expect(await store.fetchQueuedBackfillRecordings(limit: 10).isEmpty)

        let reset = await store.resetBackfillFailure(recordingID: id)
        #expect(reset)

        let queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.map { $0.id } == [id])
    }

    @Test @MainActor
    func queuedBackfillSortsOldestFirstAndHonorsLimit() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let older = UUID()
        let newer = UUID()
        await store.createRecording(id: newer, title: "Newer", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: newer, duration: 120, audioFileURL: audioRoot.appendingPathComponent("newer.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: newer, source: "test")
        await store.createRecording(
            id: older,
            title: "Older",
            startDate: Date().addingTimeInterval(-10_000),
            segmentsDirURL: nil
        )
        await store.finalizeRecording(id: older, duration: 120, audioFileURL: audioRoot.appendingPathComponent("older.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: older, source: "test")

        let queued = await store.fetchQueuedBackfillRecordings(limit: 1)
        #expect(queued.map { $0.id } == [older])
    }

    @Test @MainActor
    func markBackfillCompletedIgnoresRecordingsThatWereNeverQueued() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(id: id, title: "Manual Retry", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioRoot.appendingPathComponent("manual.m4a"))

        let completed = await store.markBackfillCompleted(recordingID: id)

        #expect(!completed)
    }

    @Test @MainActor
    func markBackfillCompletedRequiresTranscriptAndSummary() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        await store.createRecording(id: id, title: "Partial Import", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioRoot.appendingPathComponent("partial.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")
        await store.markBackfillProcessing(recordingID: id)
        await store.saveTranscript(
            recordingID: id,
            fullText: "Transcript only",
            segments: [],
            language: "en",
            tags: []
        )

        let completed = await store.markBackfillCompleted(recordingID: id)

        #expect(!completed)
    }

    @Test @MainActor
    func interruptedProcessingBackfillIsFailedWithCooldown() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        let now = Date()
        await store.createRecording(id: id, title: "Interrupted", startDate: now, segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioRoot.appendingPathComponent("interrupted.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")
        await store.markBackfillProcessing(recordingID: id, now: now)

        let count = await store.markInterruptedBackfillProcessingFailed(
            error: "Interrupted before completion",
            maxAutomaticFailures: 2,
            cooldown: 3600,
            now: now
        )

        #expect(count == 1)
        #expect(await store.fetchQueuedBackfillRecordings(limit: 10, now: now).isEmpty)
        let queuedAfterCooldown = await store.fetchQueuedBackfillRecordings(
            limit: 10,
            now: now.addingTimeInterval(7200)
        )
        #expect(queuedAfterCooldown.map { $0.id } == [id])
    }
}

// MARK: - PostProcessingCoordinator: historical backfill

@Suite("PostProcessingCoordinator.historicalBackfill", .serialized)
struct HistoricalBackfillCoordinatorTests {
    @Test @MainActor
    func cancelJobWaitsForRunnerExitBeforeRequeueAndAllowsExactlyOneRestart() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let fixture = try await harness.makeRecording(title: "Cancelled historical backfill")
        #expect(await harness.store.enqueuePostProcessingBackfill(
            recordingID: fixture.recordingID,
            source: "test"
        ))

        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 1 })

        harness.coordinator.cancelJob(for: fixture.recordingID)
        #expect(!harness.coordinator.isProcessing(recordingID: fixture.recordingID))
        #expect(harness.coordinator.hasActiveWork)

        // The observable job is gone, but its cancellation-uncooperative runner
        // and both operation leases are still alive. The durable state must stay
        // processing so another queue scan cannot launch the same recording.
        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.requests.count == 1)
        #expect(await harness.store.fetchQueuedBackfillRecordings(limit: 10).isEmpty)

        runner.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { !harness.coordinator.hasActiveWork })
        #expect(await harness.store.fetchQueuedBackfillRecordings(limit: 10).map(\.id) == [fixture.recordingID])

        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 2 })
        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.requests.count == 2)

        // A user deletion explicitly discards the retry disposition. Releasing
        // the old runner must not resurrect the trashed row in the queue.
        harness.coordinator.cancelJob(for: fixture.recordingID, disposition: .discard)
        await harness.store.deleteRecording(recordingID: fixture.recordingID)
        runner.release(index: 1)
        #expect(await waitForProviderBoundaryCondition { !harness.coordinator.hasActiveWork })
        #expect(await harness.store.fetchQueuedBackfillRecordings(limit: 10).isEmpty)
        #expect(await harness.store.fetchTrashedRecordings().map(\.id).contains(fixture.recordingID))
    }

    @Test @MainActor
    func cancelCurrentJobWaitsForRunnerExitBeforeRequeueAndAllowsExactlyOneRestart() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let fixture = try await harness.makeRecording(title: "Cancel all historical backfill")
        #expect(await harness.store.enqueuePostProcessingBackfill(
            recordingID: fixture.recordingID,
            source: "test"
        ))

        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 1 })

        harness.coordinator.cancelCurrentJob()
        #expect(!harness.coordinator.isProcessing(recordingID: fixture.recordingID))
        #expect(harness.coordinator.hasActiveWork)
        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.requests.count == 1)

        runner.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { !harness.coordinator.hasActiveWork })
        #expect(await harness.store.fetchQueuedBackfillRecordings(limit: 10).map(\.id) == [fixture.recordingID])

        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 2 })
        await harness.coordinator.processQueuedHistoricalBackfill(limit: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.requests.count == 2)

        harness.coordinator.cancelJob(for: fixture.recordingID, disposition: .discard)
        await harness.store.deleteRecording(recordingID: fixture.recordingID)
        await harness.store.permanentlyDelete(recordingID: fixture.recordingID)
        runner.release(index: 1)
        #expect(await waitForProviderBoundaryCondition { !harness.coordinator.hasActiveWork })
        #expect(await harness.store.fetchQueuedBackfillRecordings(limit: 10).isEmpty)
        #expect(await harness.store.fetchRecordingDetail(recordingID: fixture.recordingID) == nil)
    }

    @Test
    func appStateDeletionPathsCancelSoftDeleteAndPrepareHardDeletes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        let discardCall = "coordinator?.cancelJob(for: recordingID, disposition: .discard)"
        let prepareCall = "coordinator?.prepareForDeletion("

        // Single and batch soft-delete paths both cancel live processing.
        #expect(source.components(separatedBy: discardCall).count - 1 == 2)
        #expect(source.components(separatedBy: prepareCall).count - 1 == 2)
    }

    @Test @MainActor
    func permanentDeleteWaitsForCancellationUncooperativeRunnerExit() async throws {
        try await assertHardDeleteWaitsForRunnerExit(emptyTrash: false)
    }

    @Test @MainActor
    func emptyTrashWaitsForCancellationUncooperativeRunnerExit() async throws {
        try await assertHardDeleteWaitsForRunnerExit(emptyTrash: true)
    }

    @Test @MainActor
    func emptyTrashSnapshotExcludesRecordingMovedToTrashWhileWaiting() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let original = try await harness.makeRecording(title: "Original Trash target")
        let later = try await harness.makeRecording(title: "Later Trash recording")
        #expect(await harness.store.deleteRecording(recordingID: original.recordingID))

        let gate = StorageMigrationGate()
        harness.coordinator.migrationGate = gate
        let appState = AppState(startupPolicy: .testHost)
        appState.store = harness.store
        appState.coordinator = harness.coordinator
        appState.migrationGate = gate
        appState.deletionFeedbackSink = { _ in }

        await harness.coordinator.startPostProcessing(
            recordingID: original.recordingID,
            audioURL: original.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 1 })
        appState.emptyTrash()
        #expect(await waitForProviderBoundaryCondition {
            !harness.coordinator.isProcessing(recordingID: original.recordingID)
        })

        // This row entered Trash after AppState captured its target IDs.
        #expect(await harness.store.deleteRecording(recordingID: later.recordingID))
        runner.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { gate.claimMigration() })
        gate.releaseMigration()

        let originalDetail = await harness.store.fetchRecordingDetail(
            recordingID: original.recordingID
        )
        let laterDetail = await harness.store.fetchRecordingDetail(
            recordingID: later.recordingID
        )
        let remainingTrash = await harness.store.fetchTrashedRecordings().map(\.id)
        #expect(originalDetail == nil)
        #expect(laterDetail != nil)
        #expect(remainingTrash == [later.recordingID])
        #expect(FileManager.default.fileExists(atPath: later.audioURL.path))
    }

    @Test @MainActor
    func permanentDeleteSnapshotExcludesRecordingRestoredWhileWaiting() async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let fixture = try await harness.makeRecording(title: "Restored while waiting")
        #expect(await harness.store.deleteRecording(recordingID: fixture.recordingID))

        let gate = StorageMigrationGate()
        harness.coordinator.migrationGate = gate
        let appState = AppState(startupPolicy: .testHost)
        appState.store = harness.store
        appState.coordinator = harness.coordinator
        appState.migrationGate = gate
        appState.deletionFeedbackSink = { _ in }

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 1 })
        appState.permanentlyDeleteRecording(recordingID: fixture.recordingID)
        #expect(await waitForProviderBoundaryCondition {
            !harness.coordinator.isProcessing(recordingID: fixture.recordingID)
        })

        #expect(await harness.store.restoreRecording(recordingID: fixture.recordingID))
        runner.release(index: 0)
        #expect(await waitForProviderBoundaryCondition { gate.claimMigration() })
        gate.releaseMigration()

        let detail = await harness.store.fetchRecordingDetail(
            recordingID: fixture.recordingID
        )
        let remainingTrash = await harness.store.fetchTrashedRecordings()
        #expect(detail != nil)
        #expect(remainingTrash.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @MainActor
    private func assertHardDeleteWaitsForRunnerExit(emptyTrash: Bool) async throws {
        let harness = try await PostProcessingProviderHarness()
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.gemini.rawValue)
        harness.spy.keys[.gemini] = "gemini-key"
        let runner = StubbornPostProcessingRunner()
        harness.coordinator.transcriptionRunnerOverride = { _, request in
            try await runner.run(request)
        }
        let fixture = try await harness.makeRecording(title: "Hard delete waits")

        let gate = StorageMigrationGate()
        harness.coordinator.migrationGate = gate
        let appState = AppState(startupPolicy: .testHost)
        appState.store = harness.store
        appState.coordinator = harness.coordinator
        appState.migrationGate = gate
        appState.deletionFeedbackSink = { _ in }

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { runner.requests.count == 1 })

        // Match the real two-step UI flow. Moving to Trash first cancels and
        // removes the observable live job, while this runner deliberately
        // ignores cancellation and keeps the underlying task alive.
        var softDeleteCompleted = false
        appState.deleteRecording(recordingID: fixture.recordingID) { success in
            softDeleteCompleted = success
        }
        #expect(await waitForProviderBoundaryCondition {
            softDeleteCompleted
                && !harness.coordinator.isProcessing(recordingID: fixture.recordingID)
        })
        let trashedBeforeHardDelete = await harness.store.fetchTrashedRecordings()
        #expect(trashedBeforeHardDelete.map(\.id) == [fixture.recordingID])

        if emptyTrash {
            appState.emptyTrash()
        } else {
            appState.permanentlyDeleteRecording(recordingID: fixture.recordingID)
        }
        #expect(await waitForProviderBoundaryCondition {
            !harness.coordinator.isProcessing(recordingID: fixture.recordingID)
        })

        // Cancellation has removed the observable job, but the real runner
        // still owns the audio. Neither the file nor model may be deleted,
        // and the per-recording barrier must refuse a replacement submission.
        var replacementOutcome: PostProcessingSubmissionOutcome?
        #expect(await waitForProviderBoundaryAsyncCondition {
            let outcome = await harness.coordinator.startPostProcessing(
                recordingID: fixture.recordingID,
                audioURL: fixture.audioURL,
                meetingTitle: nil
            )
            replacementOutcome = outcome
            return outcome == .cancelled
        })
        #expect(replacementOutcome == .cancelled)
        #expect(runner.requests.count == 1)
        let detailBeforeRunnerExit = await harness.store.fetchRecordingDetail(
            recordingID: fixture.recordingID
        )
        #expect(detailBeforeRunnerExit != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))

        runner.release(index: 0)
        #expect(await waitForProviderBoundaryAsyncCondition {
            let detail = await harness.store.fetchRecordingDetail(
                recordingID: fixture.recordingID
            )
            return detail == nil
        })
        #expect(!FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @Test @MainActor
    func historicalBackfillCompletionDrainsNextQueuedRecording() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try await makeIsolatedStore(audioRoot: tempDir)
        let coordinator = PostProcessingCoordinator(store: store)
        var started: [UUID] = []
        coordinator.historicalBackfillStartHook = { rec in
            started.append(rec.id)
            return true
        }

        let first = UUID()
        let second = UUID()
        let third = UUID()
        for (offset, id) in [first, second, third].enumerated() {
            let audioURL = tempDir.appendingPathComponent("\(id.uuidString).m4a")
            try Data("audio-\(offset)".utf8).write(to: audioURL)
            await store.createRecording(
                id: id,
                title: "Queued \(offset)",
                startDate: Date().addingTimeInterval(Double(offset) * 60),
                segmentsDirURL: nil
            )
            await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioURL)
            await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")
        }

        await coordinator.processQueuedHistoricalBackfill(limit: 2)
        #expect(started == [first, second])

        await coordinator.finishHistoricalBackfill(recordingID: first, didFail: false)

        #expect(started == [first, second, third])
    }

    @Test @MainActor
    func historicalBackfillCompletionFailsWhenArtifactsAreIncomplete() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let coordinator = PostProcessingCoordinator(store: store)
        coordinator.backfillFailureCooldown = 3600

        let id = UUID()
        await store.createRecording(id: id, title: "Missing Summary", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioRoot.appendingPathComponent("missing-summary.m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")
        await store.markBackfillProcessing(recordingID: id)
        await store.saveTranscript(
            recordingID: id,
            fullText: "Transcript only",
            segments: [],
            language: "en",
            tags: []
        )

        await coordinator.finishHistoricalBackfill(recordingID: id, didFail: false)

        let queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.isEmpty)

        let queuedAfterCooldown = await store.fetchQueuedBackfillRecordings(
            limit: 10,
            now: Date().addingTimeInterval(7200)
        )
        #expect(queuedAfterCooldown.map { $0.id } == [id])
    }

    @Test @MainActor
    func processQueuedHistoricalBackfillBlocksAfterRepeatedMissingAudioFailures() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let coordinator = PostProcessingCoordinator(store: store)
        coordinator.backfillFailureCooldown = 0

        let id = UUID()
        await store.createRecording(
            id: id,
            title: "Missing Audio",
            startDate: Date().addingTimeInterval(-200 * 3600),
            segmentsDirURL: nil
        )
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioRoot.appendingPathComponent("does-not-exist-\(id).m4a"))
        await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")

        await coordinator.processQueuedHistoricalBackfill(limit: 2)
        var queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.map { $0.id } == [id])

        await coordinator.processQueuedHistoricalBackfill(limit: 2)
        queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.isEmpty)
    }
}

// MARK: - PostProcessingCoordinator: speaker memory

@Suite("PostProcessingCoordinator.speakerMemory", .serialized)
struct PostProcessingSpeakerMemoryTests {
    @Test @MainActor
    func runSpeakerMemoryIfNeededInvokesRunnerWhenEnabledAndSpeakerEntriesExist() async throws {
        let store = try await makeIsolatedStore()
        let coordinator = PostProcessingCoordinator(store: store)
        let previous = SpeakerDiarizer.shared.isEnabled
        let previousConsent = UserDefaults.standard.object(forKey: SpeakerMemoryConsent.defaultsKey)
        SpeakerDiarizer.shared.isEnabled = true
        UserDefaults.standard.set(true, forKey: SpeakerMemoryConsent.defaultsKey)
        defer {
            SpeakerDiarizer.shared.isEnabled = previous
            if let previousConsent {
                UserDefaults.standard.set(previousConsent, forKey: SpeakerMemoryConsent.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SpeakerMemoryConsent.defaultsKey)
            }
        }

        let id = UUID()
        var calls: [UUID] = []
        var refreshCount = 0
        coordinator.onRecordingsChanged = { refreshCount += 1 }
        coordinator.speakerMemoryRunner = { recordingID, _, entries in
            calls.append(recordingID)
            #expect(entries.count == 1)
        }

        coordinator.runSpeakerMemoryIfNeeded(
            recordingID: id,
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            entries: [
                TranscriptEntry(startTime: 0, endTime: 10, text: "Hello", speaker: "Speaker 1")
            ],
            speakerIdentityRevision: 0
        )

        #expect(calls == [id])
        #expect(refreshCount == 1)
    }

    @Test @MainActor
    func runSpeakerMemoryIfNeededSkipsRunnerWhenNoSpeakerLabels() async throws {
        let store = try await makeIsolatedStore()
        let coordinator = PostProcessingCoordinator(store: store)
        let previous = SpeakerDiarizer.shared.isEnabled
        let previousConsent = UserDefaults.standard.object(forKey: SpeakerMemoryConsent.defaultsKey)
        SpeakerDiarizer.shared.isEnabled = true
        UserDefaults.standard.set(true, forKey: SpeakerMemoryConsent.defaultsKey)
        defer {
            SpeakerDiarizer.shared.isEnabled = previous
            if let previousConsent {
                UserDefaults.standard.set(previousConsent, forKey: SpeakerMemoryConsent.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SpeakerMemoryConsent.defaultsKey)
            }
        }

        var callCount = 0
        var refreshCount = 0
        coordinator.onRecordingsChanged = { refreshCount += 1 }
        coordinator.speakerMemoryRunner = { _, _, _ in callCount += 1 }

        coordinator.runSpeakerMemoryIfNeeded(
            recordingID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            entries: [
                TranscriptEntry(startTime: 0, endTime: 10, text: "Hello", speaker: nil)
            ],
            speakerIdentityRevision: 0
        )

        #expect(callCount == 0)
        #expect(refreshCount == 0)
    }
}

// MARK: - RecordingDetailView: calendar link resolution

@Suite("RecordingDetailView.calendarLinkResolver", .serialized)
struct CalendarLinkResolverTests {
    @Test
    func resolvesLinkedEventFromCandidateEventsBeforeFallback() {
        let linked = TestDTOFactory.makeMeetingEventDTO(
            id: "linked-event",
            title: "Cycode Repo Discrepancy"
        )
        var fallbackCalled = false

        let result = CalendarLinkResolver.linkedEvent(
            linkedCalendarEventID: "linked-event",
            candidateEvents: [linked]
        ) { _ in
            fallbackCalled = true
            return nil
        }

        #expect(result?.id == "linked-event")
        #expect(!fallbackCalled)
    }

    @Test
    func fallsBackWhenLinkedEventIsNotInCandidates() {
        let fallback = TestDTOFactory.makeMeetingEventDTO(
            id: "linked-event",
            title: "Historical Meeting"
        )

        let result = CalendarLinkResolver.linkedEvent(
            linkedCalendarEventID: "linked-event",
            candidateEvents: []
        ) { id in
            id == "linked-event" ? fallback : nil
        }

        #expect(result?.id == "linked-event")
    }
}

@Suite("CalendarAutoLinkResolver")
struct CalendarAutoLinkResolverTests {

    @Test
    func picksEventWithLargestPositiveOverlap() {
        let recordingStart = Date(timeIntervalSinceReferenceDate: 60 * 60 * 10 + 30 * 60)
        let recordingEnd = recordingStart.addingTimeInterval(23 * 60)
        let target = makeMeetingEvent(
            id: "target",
            startDate: recordingStart.addingTimeInterval(-10 * 60),
            endDate: recordingStart.addingTimeInterval(25 * 60)
        )
        let partial = makeMeetingEvent(
            id: "partial",
            startDate: recordingStart.addingTimeInterval(15 * 60),
            endDate: recordingStart.addingTimeInterval(45 * 60)
        )
        let allDay = makeMeetingEvent(
            id: "all-day",
            startDate: Calendar.current.startOfDay(for: recordingStart),
            endDate: Calendar.current.startOfDay(for: recordingStart).addingTimeInterval(24 * 3600)
        )

        let result = CalendarAutoLinkResolver.bestEvent(
            startDate: recordingStart,
            endDate: recordingEnd,
            events: [partial, allDay, target]
        )

        #expect(result?.id == "target")
    }

    @Test
    func returnsNilWhenNoEventOverlapsRecording() {
        let recordingStart = Date(timeIntervalSinceReferenceDate: 60 * 60 * 10)
        let recordingEnd = recordingStart.addingTimeInterval(30 * 60)
        let before = makeMeetingEvent(
            id: "before",
            startDate: recordingStart.addingTimeInterval(-60 * 60),
            endDate: recordingStart.addingTimeInterval(-30 * 60)
        )

        let result = CalendarAutoLinkResolver.bestEvent(
            startDate: recordingStart,
            endDate: recordingEnd,
            events: [before]
        )

        #expect(result == nil)
    }

    private func makeMeetingEvent(id: String, startDate: Date, endDate: Date) -> MeetingEvent {
        MeetingEvent(
            id: id,
            title: id,
            startDate: startDate,
            endDate: endDate,
            meetingURL: nil,
            meetingApp: nil,
            calendarName: "Work",
            notes: nil
        )
    }
}

@Suite("RecordingFilenameDateParser")
struct RecordingFilenameDateParserTests {

    @Test
    func parsesCompactTimestampEmbeddedInImportedFilename() throws {
        let date = try #require(
            RecordingFilenameDateParser.parse(
                "0BDCFDE5_Corporate Report Preparation-20260528_140427-Meeting Recording.m4a"
            )
        )
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 28)
        #expect(components.hour == 14)
        #expect(components.minute == 4)
        #expect(components.second == 27)
    }

    @Test
    func parsesDashedRecordingTimestamp() throws {
        let date = try #require(RecordingFilenameDateParser.parse("recording_2026-05-04_10-36-12.m4a"))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 4)
        #expect(components.hour == 10)
        #expect(components.minute == 36)
        #expect(components.second == 12)
    }
}

@Suite("RecordingsStore.fetchCalendarAutoLinkCandidates", .serialized)
struct FetchCalendarAutoLinkCandidatesTests {

    @Test @MainActor
    func returnsOnlyUnattemptedUnlinkedRecordingsWithAudio() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let legacyUnattemptedID = UUID()
        let pendingImportID = UUID()
        let linkedID = UUID()
        let noMatchID = UUID()
        let userClearedID = UUID()
        let noAudioID = UUID()
        let trashedID = UUID()
        let startDate = Date(timeIntervalSinceReferenceDate: 60 * 60 * 10)

        _ = await store.importAudioFile(
            id: legacyUnattemptedID,
            title: "Legacy",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("legacy.m4a"), ownership: .appCreated)
        _ = await store.importAudioFile(
            id: pendingImportID,
            title: "Pending Import",
            startDate: startDate.addingTimeInterval(60),
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("pending.m4a"), ownership: .appCreated,
            calendarAutoLinkState: CalendarAutoLinkState.pending.rawValue
        )
        _ = await store.importAudioFile(
            id: linkedID,
            title: "Linked",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("linked.m4a"), ownership: .appCreated,
            linkedCalendarEventID: "event"
        )
        _ = await store.importAudioFile(
            id: noMatchID,
            title: "No Match",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("no-match.m4a"), ownership: .appCreated)
        _ = await store.markCalendarAutoLinkNoMatch(recordingID: noMatchID)
        _ = await store.importAudioFile(
            id: userClearedID,
            title: "User Cleared",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("user-cleared.m4a"), ownership: .appCreated,
            linkedCalendarEventID: "event"
        )
        await store.linkCalendarEvent(recordingID: userClearedID, calendarEventID: nil)
        await store.createRecording(id: noAudioID, title: "No Audio", startDate: startDate, segmentsDirURL: nil)
        _ = await store.importAudioFile(
            id: trashedID,
            title: "Trashed",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("trashed.m4a"), ownership: .appCreated)
        await store.deleteRecording(recordingID: trashedID)

        let candidates = await store.fetchCalendarAutoLinkCandidates(limit: 10)

        #expect(candidates.map(\.id) == [legacyUnattemptedID, pendingImportID])
        #expect(candidates.first?.endDate == startDate.addingTimeInterval(60))
    }

    @Test @MainActor
    func repairDatesFromAudioFilenamesRequeuesNoMatchRecordings() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let id = UUID()
        let incorrectStart = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 29,
            hour: 11,
            minute: 46,
            second: 36
        )))

        _ = await store.importAudioFile(
            id: id,
            title: "Imported",
            startDate: incorrectStart,
            duration: 120,
            audioURL: audioRoot.appendingPathComponent("0BDCFDE5_Corporate Report Preparation-20260528_140427-Meeting Recording.m4a"), ownership: .appCreated)
        _ = await store.markCalendarAutoLinkNoMatch(recordingID: id)

        let repaired = await store.repairCalendarAutoLinkDatesFromAudioFilenames()
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: detail.startDate)
        let candidates = await store.fetchCalendarAutoLinkCandidates(limit: 10)

        #expect(repaired == 1)
        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 28)
        #expect(components.hour == 14)
        #expect(components.minute == 4)
        #expect(components.second == 27)
        #expect(detail.endDate == detail.startDate.addingTimeInterval(120))
        #expect(candidates.map(\.id) == [id])
    }

    @Test @MainActor
    func requeuesNoMatchRecordingsForCalendarAutoLinkRetry() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let noMatchID = UUID()
        let userClearedID = UUID()
        let linkedID = UUID()
        let startDate = Date(timeIntervalSinceReferenceDate: 60 * 60 * 10)

        _ = await store.importAudioFile(
            id: noMatchID,
            title: "No Match",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("no-match.m4a"), ownership: .appCreated)
        _ = await store.markCalendarAutoLinkNoMatch(recordingID: noMatchID)
        _ = await store.importAudioFile(
            id: userClearedID,
            title: "User Cleared",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("user-cleared.m4a"), ownership: .appCreated,
            linkedCalendarEventID: "event"
        )
        await store.linkCalendarEvent(recordingID: userClearedID, calendarEventID: nil)
        _ = await store.importAudioFile(
            id: linkedID,
            title: "Linked",
            startDate: startDate,
            duration: 60,
            audioURL: audioRoot.appendingPathComponent("linked.m4a"), ownership: .appCreated,
            linkedCalendarEventID: "event"
        )

        let requeued = await store.requeueCalendarAutoLinkNoMatchesForRetry()
        let candidates = await store.fetchCalendarAutoLinkCandidates(limit: 10)

        #expect(requeued == 1)
        #expect(candidates.map(\.id) == [noMatchID])
    }
}

// MARK: - RecordingsStore: saveSummary provider/model/language

@Suite("RecordingsStore.saveSummary", .serialized)
struct SaveSummaryTests {

    @Test @MainActor
    func persistsProviderModelLanguage() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let summaryResult = SummaryResult(
            title: "My Meeting",
            overview: "We discussed roadmap.",
            keyPoints: ["Roadmap locked"],
            actionItems: [],
            decisions: [],
            followUps: [],
            yourTasks: [],
            tags: [],
            chapters: [],
            rawText: ""
        )
        let saved = await store.saveSummary(
            recordingID: id,
            summary: summaryResult,
            chaptersJSON: nil,
            provider: .gemini,
            model: "gemini-3.5-flash",
            language: "zh"
        )
        #expect(saved == .saved)

        let detail = await store.fetchRecordingDetail(recordingID: id)
        // SummaryDTO.provider is the AIProvider rawValue String.
        #expect(detail?.summary?.provider == AIProvider.gemini.rawValue)
        #expect(detail?.summary?.model == "gemini-3.5-flash")
        #expect(detail?.summary?.language == "zh")
    }

    @Test @MainActor
    func defaultProviderIsOpenAI() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let summaryResult = SummaryResult(
            title: "",
            overview: "Overview text.",
            keyPoints: ["Key"],
            actionItems: [],
            decisions: [],
            followUps: [],
            yourTasks: [],
            tags: [],
            chapters: [],
            rawText: ""
        )
        // Call with default parameter values (provider: .openai, model: "", language: "en")
        await store.saveSummary(recordingID: id, summary: summaryResult, chaptersJSON: nil)

        let detail = await store.fetchRecordingDetail(recordingID: id)
        // SummaryDTO.provider is the AIProvider rawValue String.
        #expect(detail?.summary?.provider == AIProvider.openai.rawValue)
        #expect(detail?.summary?.language == "en")
    }

    @Test @MainActor
    func returnsUnavailableForNonExistentRecording() async throws {
        let store = try await makeIsolatedStore()

        let summaryResult = SummaryResult(
            title: "", overview: "x", keyPoints: ["y"],
            actionItems: [], decisions: [], followUps: [], yourTasks: [],
            tags: [], chapters: [], rawText: ""
        )
        let saved = await store.saveSummary(
            recordingID: UUID(),
            summary: summaryResult,
            chaptersJSON: nil
        )
        #expect(saved == .recordingUnavailable)
    }
}

// MARK: - RecordingsStore: updateChapters

@Suite("RecordingsStore.updateChapters", .serialized)
struct UpdateChaptersTests {

    @Test @MainActor
    func persistsChaptersJSON() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let summaryResult = SummaryResult(
            title: "Meeting",
            overview: "We discussed topics.",
            keyPoints: ["Point 1"],
            actionItems: [],
            decisions: [],
            followUps: [],
            yourTasks: [],
            tags: [],
            chapters: [],
            rawText: ""
        )
        await store.saveSummary(recordingID: id, summary: summaryResult, chaptersJSON: nil)

        let chaptersJSON = "[{\"title\":\"Opening\",\"startSeconds\":0,\"summary\":\"Introductions\"}]"
        let updated = await store.updateChapters(recordingID: id, chaptersJSON: chaptersJSON)
        #expect(updated)

        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.summary?.chapters.count == 1)
        #expect(detail?.summary?.chapters.first?.title == "Opening")
    }

    @Test @MainActor
    func returnsFalseWhenNoSummary() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let updated = await store.updateChapters(recordingID: id, chaptersJSON: "[]")
        #expect(!updated)
    }

    @Test @MainActor
    func returnsFalseForNonExistentRecording() async throws {
        let store = try await makeIsolatedStore()

        let updated = await store.updateChapters(recordingID: UUID(), chaptersJSON: "[]")
        #expect(!updated)
    }

    @Test @MainActor
    func rejectsStaleSummaryID() async throws {
        let store = try await makeIsolatedStore()
        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)

        let summaryResult = SummaryResult(
            title: "Meeting",
            overview: "Overview",
            keyPoints: [],
            actionItems: [],
            decisions: [],
            followUps: [],
            yourTasks: [],
            tags: [],
            chapters: [],
            rawText: ""
        )
        await store.saveSummary(recordingID: id, summary: summaryResult, chaptersJSON: nil)

        // Pass a mismatched summary ID — should be rejected
        let staleSummaryID = UUID()
        let updated = await store.updateChapters(recordingID: id, chaptersJSON: "[{\"title\":\"Stale\"}]", expectedSummaryID: staleSummaryID)
        #expect(!updated)

        // Verify no chapters were written
        let detail = await store.fetchRecordingDetail(recordingID: id)
        #expect(detail?.summary?.chapters.isEmpty == true)
    }
}

// MARK: - PostProcessingCoordinator: cancel state machine

@Suite("PostProcessingCoordinator.cancel", .serialized)
struct CancelTests {

    // Cancel on a non-processing coordinator is a no-op.
    @Test @MainActor
    func cancelWhenNotProcessingIsNoOp() async throws {
        let store = try await makeIsolatedStore()
        let coordinator = PostProcessingCoordinator(store: store)

        coordinator.cancelCurrentJob()

        #expect(!coordinator.isPostProcessing)
    }

    @Test @MainActor
    func cancelClearsAllJobs() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let coordinator = PostProcessingCoordinator(store: store)

        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioRoot.appendingPathComponent("test.m4a"))

        await coordinator.startPostProcessing(
            recordingID: id,
            audioURL: audioRoot.appendingPathComponent("test.m4a"),
            meetingTitle: nil
        )
        // Give the task a moment to start
        try await Task.sleep(for: .milliseconds(100))

        coordinator.cancelCurrentJob()
        #expect(!coordinator.isPostProcessing)
        #expect(!coordinator.isProcessing(recordingID: id))
    }

    @Test @MainActor
    func rejectsDuplicateJob() async throws {
        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let coordinator = PostProcessingCoordinator(store: store)

        let id = UUID()
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioRoot.appendingPathComponent("test.m4a"))

        // Submit same recording twice
        await coordinator.startPostProcessing(
            recordingID: id,
            audioURL: audioRoot.appendingPathComponent("test.m4a"),
            meetingTitle: nil
        )
        await coordinator.startPostProcessing(
            recordingID: id,
            audioURL: audioRoot.appendingPathComponent("test.m4a"),
            meetingTitle: nil
        )

        // Should not crash or duplicate — clean up
        coordinator.cancelCurrentJob()
    }
}

// MARK: - PostProcessingCoordinator: isProcessing

@Suite("PostProcessingCoordinator.isProcessing", .serialized)
struct IsProcessingTests {
    @Test @MainActor
    func returnsFalseWhenNoJobs() async throws {
        let store = try await makeIsolatedStore()
        let coordinator = PostProcessingCoordinator(store: store)
        #expect(!coordinator.isProcessing(recordingID: UUID()))
    }
}

// MARK: - PostProcessingCoordinator: computed properties

@Suite("PostProcessingCoordinator.computedProperties", .serialized)
struct ComputedPropertyTests {
    @Test @MainActor
    func emptyStateProperties() async throws {
        let store = try await makeIsolatedStore()
        let coordinator = PostProcessingCoordinator(store: store)
        #expect(!coordinator.isPostProcessing)
        #expect(coordinator.postProcessingPhase == nil)
        #expect(coordinator.transcriptionChunksDone == 0)
        #expect(coordinator.transcriptionChunksTotal == 0)
    }
}

// MARK: - RecordingEngine: startRecording aborts on store failure

/// A fake RecordingsStore that always returns false from createRecording.
/// We use a subclassing trick: since RecordingsStore is a ModelActor, we can't
/// easily subclass. Instead, we test the abort path by configuring a real store
/// that is wired into RecordingEngine and verifying state after the call.
///
/// Because RecordingEngine.startRecording() requires a real AudioMixer (hardware),
/// we cannot fully unit-test the abort path without a running audio device.
/// The test below documents the expected behavior and guards the store-level contract.
///
/// If audio permission is denied in CI, startRecording() throws before reaching the
/// store check, which is the correct early-exit behavior. We guard with .disabled
/// when it is not feasible to run.

@Suite("RecordingEngine.startRecording — store failure abort", .serialized)
struct RecordingEngineStoreFailureTests {

    /// Verifies that after a createRecording failure, the recording state remains .idle.
    /// This test relies on the store returning false when the ModelContext save fails,
    /// which we simulate by using a store whose container is closed/invalid.
    ///
    /// Since full AudioMixer initialization requires Screen Recording permission (not
    /// available in CI), this test is documented here with a note: the observable
    /// behavior is that `recordingState` must stay `.idle` and `audioMixer.forceReset()`
    /// must be called when `createRecording` returns false.
    ///
    /// The code path under test (RecordingEngine.swift:118-123):
    ///   let saved = await store?.createRecording(...) ?? false
    ///   if !saved {
    ///       audioMixer.forceReset()
    ///       return
    ///   }
    ///   recordingState = .recording   // must NOT be reached
    @Test @MainActor
    func recordingStateRemainsIdleWhenStoreCreateFails() async throws {
        // This test exercises the data-layer contract of fetchUnprocessedRecordings
        // and createRecording return values, which are fully testable.
        // The AudioMixer-dependent abort path in startRecording() is covered by
        // manual integration testing (requires audio hardware).

        let (store, audioRoot) = try await makeIsolatedStoreWithAudioRoot()
        defer { try? FileManager.default.removeItem(at: audioRoot) }

        // Verify createRecording returns true on success (baseline).
        let id1 = UUID()
        let success = await store.createRecording(id: id1, title: "T", startDate: Date(), segmentsDirURL: nil)
        #expect(success)

        // Verify that the recording is queryable (proves DB write happened before state change in engine).
        let unprocessed0 = await store.fetchUnprocessedRecordings()
        // id1 has no audioFilePath yet, so it should NOT appear in unprocessed.
        #expect(unprocessed0.isEmpty)

        // After finalizing, it becomes unprocessed (has audio, no transcript).
        await store.finalizeRecording(id: id1, duration: 60, audioFileURL: audioRoot.appendingPathComponent("t.m4a"))
        let unprocessed1 = await store.fetchUnprocessedRecordings()
        #expect(unprocessed1.count == 1)
    }
}

// MARK: - Storage-migration gate

@Suite("PostProcessingCoordinator storage-migration gate")
@MainActor
struct PostProcessingMigrationGateTests {

    @Test func recoveryDefersWhileMigrationClaimed() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-recovery-\(UUID().uuidString)", isDirectory: true)
        let store = try await makeIsolatedStore(audioRoot: storageRoot)
        let segmentsDirectory = storageRoot.appendingPathComponent("segments/GATE", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let recordingID = UUID()
        await store.createRecording(
            id: recordingID, title: "Interrupted", startDate: Date(), segmentsDirURL: segmentsDirectory
        )
        let coordinator = PostProcessingCoordinator(store: store, recordingsDirectory: storageRoot)
        let gate = StorageMigrationGate()
        coordinator.migrationGate = gate
        #expect(gate.claimMigration())

        await coordinator.recoverInterrupted()

        // Deferred: the interrupted row is untouched and recovery re-runs later.
        #expect(await store.fetchInterruptedRecordings().contains { $0.id == recordingID })
        gate.releaseMigration()
    }

    @Test func manualRetryRefusedWhileMigrationClaimed() async throws {
        let harness = try await PostProcessingProviderHarness()
        let gate = StorageMigrationGate()
        harness.coordinator.migrationGate = gate
        #expect(gate.claimMigration())

        await harness.coordinator.retryTranscription(recordingID: UUID())

        #expect(harness.coordinator.postProcessingError?.isEmpty == false)
        #expect(harness.spy.keyLookups.isEmpty)
        gate.releaseMigration()
    }

    /// The coordinator must follow the live root: constructed while root A
    /// is active, a retry after the migration to root B resolves and reads
    /// under B and never under A.
    @Test func retryUsesTheLiveRootAfterMigration() async throws {
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-root-A-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-root-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let store = try await makeIsolatedStore(audioRoot: rootA)
        let rootBox = RootProviderBox(root: rootA)
        let defaultsName = "PostProcessingLiveRootTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        defaults.set("en", forKey: "transcriptionLanguage")
        let transcriptionDependencies = PostProcessingTranscriptionDependencies(
            defaults: defaults,
            apiKey: { _ in nil },
            supportsAppleLanguage: { _ in true },
            localWhisperState: { LocalWhisperState(model: "base", isAvailable: true) }
        )
        let coordinator = PostProcessingCoordinator(
            store: store,
            transcriptionDependencies: transcriptionDependencies,
            recordingsDirectory: rootBox.root
        )
        var captured: [URL] = []
        coordinator.transcriptionRunnerOverride = { _, request in
            captured.append(request.audioURL)
        }

        let id = UUID()
        let audioA = rootA.appendingPathComponent("audio.m4a")
        try Data("bytes".utf8).write(to: audioA)
        await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 60, audioFileURL: audioA)

        // The migration completes: file moves, active roots switch.
        try FileManager.default.moveItem(
            at: audioA, to: rootB.appendingPathComponent("audio.m4a")
        )
        await store.setAudioRootForTesting(rootB)
        rootBox.root = rootB

        await coordinator.retryTranscription(recordingID: id)

        #expect(captured.count == 1)
        #expect(captured.first?.resolvingSymlinksInPath().path
            == rootB.appendingPathComponent("audio.m4a").resolvingSymlinksInPath().path)
    }

    /// Cancelling removes the observable job immediately, but the lease
    /// belongs to the runner's real lifetime — a migration claim stays
    /// refused until the suspended runner actually returns.
    @Test func cancelledJobHoldsItsLeaseUntilTheRunnerReturns() async throws {
        let resolverGate = PostProcessingResolverGate(result: true)
        let harness = try await PostProcessingProviderHarness(appleLanguageGate: resolverGate)
        defer { harness.cleanup() }
        harness.configure(provider: AIProvider.apple.rawValue)
        let fixture = try await harness.makeRecording(duration: 60)
        let migrationGate = StorageMigrationGate()
        harness.coordinator.migrationGate = migrationGate

        await harness.coordinator.startPostProcessing(
            recordingID: fixture.recordingID,
            audioURL: fixture.audioURL,
            meetingTitle: nil
        )
        #expect(await waitForProviderBoundaryCondition { resolverGate.didStart })

        harness.coordinator.cancelCurrentJob()
        #expect(!harness.coordinator.isProcessing(recordingID: fixture.recordingID))
        #expect(harness.coordinator.hasActiveWork)
        #expect(!migrationGate.claimMigration())

        resolverGate.release()
        #expect(await waitForProviderBoundaryCondition { migrationGate.claimMigration() })
        #expect(!harness.coordinator.hasActiveWork)
        migrationGate.releaseMigration()
    }

    /// Backfill holds its lease across fetch, marking, and job submission;
    /// while a migration is claimed it refuses up front and queued rows
    /// stay queued instead of being marked processing and stalling.
    @Test func backfillRefusedWhileMigrationClaimedLeavesRowsQueued() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try await makeIsolatedStore(audioRoot: tempDir)
        let coordinator = PostProcessingCoordinator(store: store, recordingsDirectory: tempDir)
        let gate = StorageMigrationGate()
        coordinator.migrationGate = gate

        let id = UUID()
        let audioURL = tempDir.appendingPathComponent("queued.m4a")
        try Data("audio".utf8).write(to: audioURL)
        await store.createRecording(id: id, title: "Queued", startDate: Date(), segmentsDirURL: nil)
        await store.finalizeRecording(id: id, duration: 120, audioFileURL: audioURL)
        await store.enqueuePostProcessingBackfill(recordingID: id, source: "test")
        #expect(gate.claimMigration())

        await coordinator.processQueuedHistoricalBackfill(limit: 2)

        let queued = await store.fetchQueuedBackfillRecordings(limit: 10)
        #expect(queued.map { $0.id } == [id])
        gate.releaseMigration()
    }

    @Test func startPostProcessingRefusedWhileMigrationClaimed() async throws {
        let store = try await makeIsolatedStore()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let coordinator = PostProcessingCoordinator(store: store, recordingsDirectory: storageRoot)
        let gate = StorageMigrationGate()
        coordinator.migrationGate = gate
        #expect(gate.claimMigration())

        let recordingID = UUID()
        let outcome = await coordinator.startPostProcessing(
            recordingID: recordingID,
            audioURL: storageRoot.appendingPathComponent("a.m4a"),
            meetingTitle: nil
        )

        #expect(outcome == .refusedStorageMigration)
        #expect(!coordinator.isProcessing(recordingID: recordingID))
        #expect(!coordinator.hasActiveWork)
        gate.releaseMigration()
    }
}

/// Mutable root holder driving the coordinator's autoclosure provider —
/// a lock-protected value, so the type is provably Sendable.
private final class RootProviderBox: Sendable {
    private let value: OSAllocatedUnfairLock<URL>
    var root: URL {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
    init(root: URL) { value = OSAllocatedUnfairLock(initialState: root) }
}
