import Testing
import Foundation
@testable import Cadenza

@Suite("RecordingEngine.startRecording feedback", .serialized)
@MainActor
struct RecordingEngineStartFeedbackTests {

    private func makeEngine() -> RecordingEngine {
        RecordingEngine()
    }

    private func withTranscriptionDefaults(
        provider: String,
        language: String = "auto",
        _ body: () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let prevProvider = defaults.string(forKey: "transcriptionProvider")
        let prevLanguage = defaults.string(forKey: "transcriptionLanguage")
        let prevRealtime = defaults.object(forKey: "enableRealtimeTranscription")
        defaults.set(provider, forKey: "transcriptionProvider")
        defaults.set(language, forKey: "transcriptionLanguage")
        // Keep realtime off so the test path doesn't reach network code.
        defaults.set(false, forKey: "enableRealtimeTranscription")
        defer {
            if let prevProvider { defaults.set(prevProvider, forKey: "transcriptionProvider") }
            else { defaults.removeObject(forKey: "transcriptionProvider") }
            if let prevLanguage { defaults.set(prevLanguage, forKey: "transcriptionLanguage") }
            else { defaults.removeObject(forKey: "transcriptionLanguage") }
            if let prevRealtime { defaults.set(prevRealtime, forKey: "enableRealtimeTranscription") }
            else { defaults.removeObject(forKey: "enableRealtimeTranscription") }
        }
        try await body()
    }

    // MARK: - isStarting observability

    @Test func isStarting_defaultsFalse() {
        let engine = makeEngine()
        #expect(engine.isStarting == false)
    }

    @Test func recordingActivity_isIdempotentAndReleasedByForceReset() {
        var beginCount = 0
        var endCount = 0
        let activity = NSObject()
        let engine = RecordingEngine(
            beginProcessActivity: {
                beginCount += 1
                return activity
            },
            endProcessActivity: { _ in
                endCount += 1
            }
        )

        engine._test_beginRecordingActivityIfNeeded()
        engine._test_beginRecordingActivityIfNeeded()
        #expect(beginCount == 1)
        #expect(engine._test_hasRecordingActivity)

        engine._test_setRecordingState(.recording)
        engine.pauseRecording()
        #expect(engine._test_hasRecordingActivity)

        engine.forceReset()
        engine.forceReset()
        #expect(endCount == 1)
        #expect(!engine._test_hasRecordingActivity)
    }

    @Test func recordingActivity_isReleasedExactlyOnceByNormalStop() {
        var endCount = 0
        let engine = RecordingEngine(
            beginProcessActivity: { NSObject() },
            endProcessActivity: { _ in endCount += 1 }
        )
        engine._test_beginRecordingActivityIfNeeded()
        engine._test_setRecordingState(.recording)

        engine.stopRecording()
        engine.stopRecording()

        #expect(endCount == 1)
        #expect(!engine._test_hasRecordingActivity)
    }

    // MARK: - Busy and finalization paths

    @Test func startRecording_whileStopping_surfacesFinalizationBusyState() async {
        let engine = makeEngine()
        engine._test_setStopping(true)

        await #expect(throws: RecordingStartError.finalizationInProgress) {
            try await engine.startRecording()
        }

        #expect(engine.recordingState == .idle)
        #expect(engine.recordingError == nil)
    }

    @Test func startRecording_whileStarting_returnsWithoutThrowing() async throws {
        let engine = makeEngine()
        engine._test_setStarting(true)

        try await engine.startRecording()

        #expect(engine.recordingState == .idle)
        #expect(engine.recordingError == nil)
    }

    @Test func startRecording_whilePreparingSystemAudio_returnsWithoutThrowing() async throws {
        let engine = makeEngine()
        engine._test_setPreparingSystemAudioCapture(true)

        try await engine.startRecording()

        #expect(engine.recordingState == .idle)
        #expect(engine.recordingError == nil)
    }

    @Test func startRecording_whileRecording_returnsWithoutThrowing() async throws {
        let engine = makeEngine()
        engine._test_setRecordingState(.recording)

        try await engine.startRecording()

        // Still recording, no error raised.
        #expect(engine.recordingState == .recording)
        #expect(engine.recordingError == nil)
    }

    // MARK: - Config failures throw

    @Test func startRecording_whisperModelMissing_throws() async throws {
        let engine = makeEngine()
        // A model name that is virtually guaranteed not to be downloaded in CI.
        let previousModel = WhisperModelManager.shared.selectedModel
        WhisperModelManager.shared.selectedModel = "__unavailable_test_model__"
        defer { WhisperModelManager.shared.selectedModel = previousModel }

        await withTranscriptionDefaults(provider: "whisperLocal") {
            await #expect(
                throws: TranscriptionProviderResolutionError.localModelUnavailable("__unavailable_test_model__")
            ) {
                try await engine.startRecording()
            }
        }
        #expect(engine.recordingState == .idle)
    }

    @Test func recordingStartError_hasLocalizedDescriptions() {
        #expect(RecordingStartError.languageUnsupported.errorDescription?.isEmpty == false)
        #expect(RecordingStartError.whisperModelMissing.errorDescription?.isEmpty == false)
        #expect(RecordingStartError.noTranscriptionKey.errorDescription?.isEmpty == false)
        #expect(RecordingStartError.systemAudioNotPrepared.errorDescription?.isEmpty == false)
        #expect(RecordingStartError.finalizationInProgress.errorDescription?.isEmpty == false)
    }

    // MARK: - System Audio Preparation

    @Test func freshInstall_requiresUserPreparedSystemAudioBeforeAutoStart() async {
        let suiteName = "SystemAudioFreshInstallGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let engine = makeEngine()
        engine._test_setSystemAudioPreparationDefaults(defaults)
        await #expect(throws: RecordingStartError.systemAudioNotPrepared) {
            try await engine.startRecording(
                skipPermissionPrompt: true,
                isAutoStarted: true
            )
        }
        #expect(engine.isStarting == false)
        #expect(engine.recordingState == .idle)
    }

    @Test func successfulPreparation_isDurable() {
        let suiteName = "SystemAudioCapturePreparationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!SystemAudioCapturePreparation.isPrepared(defaults: defaults))
        SystemAudioCapturePreparation.markPrepared(defaults: defaults)
        #expect(SystemAudioCapturePreparation.isPrepared(defaults: defaults))
    }

    @Test func legacyAutoRecordMigration_isGentleAndOneTime() {
        let legacySuiteName = "SystemAudioCaptureLegacyTests.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }

        SystemAudioCapturePreparation.migrateLegacyAutoRecordUser(
            legacyAutoRecordWasExplicitlyEnabled: true,
            defaults: legacyDefaults
        )
        #expect(SystemAudioCapturePreparation.isPrepared(defaults: legacyDefaults))

        let freshSuiteName = "SystemAudioCaptureFreshTests.\(UUID().uuidString)"
        let freshDefaults = UserDefaults(suiteName: freshSuiteName)!
        defer { freshDefaults.removePersistentDomain(forName: freshSuiteName) }

        SystemAudioCapturePreparation.migrateLegacyAutoRecordUser(
            legacyAutoRecordWasExplicitlyEnabled: false,
            defaults: freshDefaults
        )
        SystemAudioCapturePreparation.migrateLegacyAutoRecordUser(
            legacyAutoRecordWasExplicitlyEnabled: true,
            defaults: freshDefaults
        )
        #expect(!SystemAudioCapturePreparation.isPrepared(defaults: freshDefaults))
    }

    @Test func permissionSettingsRoutes_keepSystemAudioAndScreenSeparate() {
        #expect(
            Permissions.systemAudioRecordingSettingsURLStrings.first?.contains("Privacy_AudioCapture") == true
        )
        #expect(
            Permissions.screenRecordingSettingsURLStrings.first?.contains("Privacy_ScreenCapture") == true
        )
        #expect(
            Permissions.screenRecordingSettingsURLStrings.allSatisfy { !$0.contains("Privacy_AudioCapture") }
        )
        #expect(
            Permissions.systemAudioRecordingSettingsURLStrings.last
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )
    }

    // MARK: - presentStartError routing

    @Test func presentStartError_missingAPIKey_setsProviderOnly() {
        let engine = makeEngine()
        engine.presentStartError(TranscriptionProviderResolutionError.missingAPIKey(.openai))
        #expect(engine.missingAPIKeyProvider == .openai)
        #expect(engine.recordingError == nil)
    }

    @Test func presentStartError_otherError_setsRecordingError() {
        let engine = makeEngine()
        engine.presentStartError(
            TranscriptionProviderResolutionError.unsupportedLanguage(.apple, language: "zz")
        )
        #expect(engine.missingAPIKeyProvider == nil)
        #expect(engine.recordingError != nil)
        #expect(!engine.recordingErrorOffersSystemAudioSettings)
    }

    @Test func presentStartError_systemAudioFailures_offerSettingsAction() {
        let engine = makeEngine()

        engine.presentStartError(RecordingStartError.systemAudioNotPrepared)
        #expect(engine.recordingError != nil)
        #expect(engine.recordingErrorOffersSystemAudioSettings)

        engine.dismissRecordingError()
        #expect(engine.recordingError == nil)
        #expect(!engine.recordingErrorOffersSystemAudioSettings)

        engine.presentStartError(ProcessTapCaptureError.osStatus("AudioHardwareCreateProcessTap", -1))
        #expect(engine.recordingError != nil)
        #expect(engine.recordingErrorOffersSystemAudioSettings)
    }

    @Test func presentStartError_mapsAudioAndUnknownFailuresToStableLocalizedGuidance() {
        struct UnknownStartFailure: Error, LocalizedError {
            var errorDescription: String? { "raw untranslated implementation detail" }
        }

        let engine = makeEngine()

        engine.presentStartError(AudioMixerError.alreadyRecording)
        #expect(engine.recordingError == String(localized: "Recording in Progress"))
        #expect(!engine.recordingErrorOffersSystemAudioSettings)

        engine.presentStartError(MicrophoneCoreAudioError.invalidFormat("raw format"))
        #expect(engine.recordingError == String(
            localized: "Cadenza couldn't start the microphone. Check the selected microphone and Microphone access in System Settings, then try again."
        ))
        #expect(engine.recordingError?.contains("raw format") == false)

        engine.presentStartError(RecordingEngineError.persistenceFailed(String(
            localized: "Cadenza couldn't verify the recording storage location. Check the storage location in Settings, then try again."
        )))
        #expect(engine.recordingError == String(
            localized: "Cadenza couldn't verify the recording storage location. Check the storage location in Settings, then try again."
        ))
        #expect(engine.recordingError?.contains("authorized recording storage") == false)

        engine.presentStartError(UnknownStartFailure())
        #expect(engine.recordingError == String(
            localized: "Cadenza couldn't start recording. Try again."
        ))
        #expect(engine.recordingError?.contains("raw untranslated") == false)
    }

    @Test func recordingFailureMessagesAreLocalizedAndNeverEmbedRawSystemDetails() {
        let locale = Locale(identifier: "zh-Hans")
        let captureMessage = RecordingEngine.captureInterruptionMessage(locale: locale)
        let storageMessage = RecordingEngine.storagePreparationFailureMessage(locale: locale)

        #expect(captureMessage == "音频采集已中断。录音已保存。再次录音前，请检查音频设置。")
        #expect(!captureMessage.contains("AVAssetWriter"))
        #expect(storageMessage == "Cadenza 无法准备录音存储文件夹。请在设置中检查存储位置，然后重试。")
        #expect(!storageMessage.contains("NSCocoaErrorDomain"))
    }

    // MARK: - Realtime start timeout

    @Test func realtimeStartTimeout_firesWhenOperationHangs() async {
        var threw = false
        var wasTimeout = false
        do {
            // Operation that never finishes within the timeout.
            try await RecordingEngine._test_withRealtimeStartTimeout(seconds: 1) {
                try await Task.sleep(for: .seconds(60))
            }
        } catch {
            threw = true
            wasTimeout = RecordingEngine._test_isTimeoutError(error)
        }
        #expect(threw)
        #expect(wasTimeout)
    }

    @Test func realtimeStartTimeout_passesThroughFastSuccess() async throws {
        // Operation that completes quickly should not time out.
        try await RecordingEngine._test_withRealtimeStartTimeout(seconds: 5) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func realtimeStartTimeout_rethrowsOperationError() async {
        struct Boom: Error {}
        var caughtBoom = false
        do {
            try await RecordingEngine._test_withRealtimeStartTimeout(seconds: 5) {
                throw Boom()
            }
        } catch is Boom {
            caughtBoom = true
        } catch {
            caughtBoom = false
        }
        #expect(caughtBoom)
    }
}

// MARK: - Legacy provider-boundary characterization

private enum RecordingEngineBoundarySentinel: Error, Sendable {
    case captureReached
    case realtimeReached
}

private actor RecordingEngineSuspensionGate {
    private var recordingID: UUID?
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func waitForFirstRecording(_ candidate: UUID) async {
        if recordingID == nil {
            recordingID = candidate
        }
        guard recordingID == candidate else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor RecordingEngineAsyncGate {
    private var isOpen = false

    func wait() async throws {
        while !isOpen {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func open() { isOpen = true }
    func currentValue() -> Bool { isOpen }
}

private actor RecordingEngineFinalizationEventSpy {
    private(set) var events: [RecordingAudioFinalizationEvent] = []

    func record(_ event: RecordingAudioFinalizationEvent) {
        events.append(event)
    }
}

private actor RecordingEngineStoreCommitProbe {
    private(set) var duration: TimeInterval?
    private(set) var endDate: Date?

    func record(_ request: RecordingAudioStoreCommitRequest) {
        duration = request.duration
        endDate = request.endDate
    }
}

private func waitForRecordingEngineFinalizationEvents(
    _ spy: RecordingEngineFinalizationEventSpy,
    count: Int
) async -> [RecordingAudioFinalizationEvent] {
    for _ in 0..<200 {
        let snapshot = await spy.events
        if snapshot.count >= count { return snapshot }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await spy.events
}

private actor EngineOwnedRealtimeService: TranscriptionService {
    private let blocksStop: Bool
    private let failsStart: Bool
    private var stopWasReleased = false
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var streamContinuation: AsyncThrowingStream<TranscriptDelta, Error>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sentAudio: [Data] = []

    init(blocksStop: Bool, failsStart: Bool = false) {
        self.blocksStop = blocksStop
        self.failsStart = failsStart
    }

    func startRealtimeSession(language: String?) async throws -> AsyncThrowingStream<TranscriptDelta, Error> {
        startCount += 1
        if failsStart {
            throw RecordingEngineBoundarySentinel.realtimeReached
        }
        let pair = AsyncThrowingStream<TranscriptDelta, Error>.makeStream()
        streamContinuation = pair.continuation
        return pair.stream
    }

    func sendAudio(_ data: Data) async throws {
        sentAudio.append(data)
    }

    func stopRealtimeSession() async throws {
        stopCount += 1
        streamContinuation?.finish()
        guard blocksStop, !stopWasReleased else { return }
        await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
        }
    }

    func transcribeFile(at url: URL, language: String?) async throws -> TranscriptResult {
        throw TranscriptionError.notSupported("test-only realtime service")
    }

    func emit(_ text: String) {
        streamContinuation?.yield(TranscriptDelta(text: text, isFinal: true, language: "en"))
    }

    func releaseStop() {
        stopWasReleased = true
        let continuations = stopContinuations
        stopContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    var isStopWaiting: Bool {
        !stopContinuations.isEmpty
    }
}

@MainActor
private final class EngineRealtimeServiceFactory {
    private let services: [any TranscriptionService]
    private var index = 0

    init(_ services: [any TranscriptionService]) {
        self.services = services
    }

    func makeFactory() -> RealtimeTranscriptionServiceFactory {
        { [weak self] _, _, _, _ in
            guard let self, self.index < self.services.count else {
                throw TranscriptionError.notSupported("No engine test service configured")
            }
            defer { self.index += 1 }
            return self.services[self.index]
        }
    }
}

@MainActor
private final class RecordingEngineBoundarySpy {
    var keys: [AIProvider: String] = [:]
    var appleLanguageSupported = true
    var appleLanguageSupport: [String: Bool] = [:]
    var localWhisperModel = "base"
    var localWhisperAvailable = true
    var microphoneStatus: PermissionStatus = .granted
    var captureError: (any Error)?
    var realtimeError: (any Error)?
    var realtimeHandler: (@MainActor @Sendable (RealtimeStartRequest) async throws -> Void)?
    var nowValues: [Date] = []
    var startReturned = false
    var realtimeCancellationCount = 0
    var stopCaptureResult: AudioMixer.StopPhase1Result?
    var startCaptureDirectoryOverride: URL?
    let storageRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("recording-engine-\(UUID().uuidString)", isDirectory: true)

    private(set) var keyLookups: [AIProvider] = []
    private(set) var appleLanguageLookups: [String] = []
    private(set) var captureRequests: [RecordingCaptureRequest] = []
    private(set) var realtimeRequests: [RealtimeStartRequest] = []
    private(set) var stopRequests: [RealtimeStopRequest] = []
    private(set) var boundaryEvents: [RecordingEngineBoundaryEvent] = []
    private(set) var microphoneRequestCount = 0
    private var nowIndex = 0

    private func nextNow() -> Date {
        guard nowIndex < nowValues.count else {
            return Date(timeIntervalSinceReferenceDate: 123_456)
        }
        defer { nowIndex += 1 }
        return nowValues[nowIndex]
    }

    func dependencies(
        defaults: UserDefaults,
        usesInjectedRealtimeManager: Bool = false,
        realtimeStartTimeout: Duration = .seconds(5)
    ) -> RecordingEngineDependencies {
        let startRealtimeOverride: (@MainActor @Sendable (RealtimeStartRequest) async throws -> Void)?
        let stopRealtimeOverride: (@MainActor @Sendable (RealtimeStopRequest) async -> Void)?
        if usesInjectedRealtimeManager {
            startRealtimeOverride = nil
            stopRealtimeOverride = nil
        } else {
            startRealtimeOverride = { [weak self] request in
                guard let self else { throw RecordingEngineBoundarySentinel.realtimeReached }
                self.realtimeRequests.append(request)
                if let handler = self.realtimeHandler {
                    try await handler(request)
                }
                if let error = self.realtimeError { throw error }
            }
            stopRealtimeOverride = { [weak self] request in
                self?.stopRequests.append(request)
            }
        }
        let capturedStopResult = stopCaptureResult
        let capturedStorageRoot = storageRoot

        return RecordingEngineDependencies(
            defaults: defaults,
            apiKey: { [weak self] provider in
                guard let self else { return nil }
                self.keyLookups.append(provider)
                return self.keys[provider]
            },
            supportsAppleLanguage: { [weak self] language in
                guard let self else { return false }
                self.appleLanguageLookups.append(language)
                return self.appleLanguageSupport[language] ?? self.appleLanguageSupported
            },
            localWhisperState: { [weak self] in
                guard let self else { return ("base", false) }
                return (self.localWhisperModel, self.localWhisperAvailable)
            },
            microphoneStatus: { [weak self] in
                self?.microphoneStatus ?? .denied
            },
            requestMicrophone: { [weak self] in
                guard let self else { return false }
                self.microphoneRequestCount += 1
                return self.microphoneStatus == .granted
            },
            now: { [weak self] in
                self?.nextNow() ?? Date(timeIntervalSinceReferenceDate: 123_456)
            },
            storageRoot: { capturedStorageRoot },
            startCapture: { [weak self] request in
                guard let self else { throw RecordingEngineBoundarySentinel.captureReached }
                self.captureRequests.append(request)
                if let error = self.captureError { throw error }
                if let override = self.startCaptureDirectoryOverride {
                    return override.path
                }
                let segmentsDirectory = capturedStorageRoot
                    .appendingPathComponent("segments", isDirectory: true)
                    .appendingPathComponent(request.recordingID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: segmentsDirectory,
                    withIntermediateDirectories: true
                )
                return segmentsDirectory.path
            },
            stopCapture: {
                capturedStopResult
                    ?? AudioMixer.StopPhase1Result(
                        segmentURLs: [],
                        outputURL: nil,
                        segmentsDirectory: nil
                    )
            },
            startRealtime: startRealtimeOverride,
            stopRealtime: stopRealtimeOverride,
            reconnectDelay: .zero,
            realtimeStartTimeout: realtimeStartTimeout,
            recordBoundaryEvent: { [weak self] event in
                self?.boundaryEvents.append(event)
            }
        )
    }
}

@Suite("Recording Engine Provider Boundary", .serialized)
@MainActor
struct RecordingEngineProviderBoundaryTests {
    private func makeDefaults() -> (name: String, defaults: UserDefaults) {
        let name = "RecordingEngineProviderBoundaryTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    /// The engine writes segments and merged audio under the spy's storage
    /// root, so the store's audio root must match it.
    private func attachIsolatedStore(to engine: RecordingEngine, audioRoot: URL) async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(audioRoot)
        engine.store = store
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(300),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func autoStartedRecordingFailsClosedWithoutMicrophonePermission() async throws {
        for status in [PermissionStatus.denied, .notDetermined] {
            let isolated = makeDefaults()
            defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
            isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
            isolated.defaults.set("en", forKey: "transcriptionLanguage")
            isolated.defaults.set(false, forKey: "enableRealtimeTranscription")
            SystemAudioCapturePreparation.markPrepared(defaults: isolated.defaults)

            let spy = RecordingEngineBoundarySpy()
            spy.microphoneStatus = status
            let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
            engine._test_setSystemAudioPreparationDefaults(isolated.defaults)
            try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

            await #expect(throws: RecordingEngineError.self) {
                try await engine.startRecording(
                    captureMicrophone: true,
                    skipPermissionPrompt: true,
                    isAutoStarted: true
                )
            }

            #expect(spy.microphoneRequestCount == 0)
            #expect(spy.captureRequests.isEmpty)
            #expect(engine.recordingState == .idle)
        }
    }

    /// The stored auto-record intent survives a permission outage; once TCC
    /// reports granted again the next auto-start must proceed without any
    /// prompt or settings round-trip.
    @Test func autoStartedRecordingProceedsOnceMicrophonePermissionReturns() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.defaults)

        let spy = RecordingEngineBoundarySpy()
        spy.microphoneStatus = .granted
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        engine._test_setSystemAudioPreparationDefaults(isolated.defaults)
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer {
            engine.forceReset()
            try? FileManager.default.removeItem(at: spy.storageRoot)
        }

        try await engine.startRecording(
            captureMicrophone: true,
            skipPermissionPrompt: true,
            isAutoStarted: true
        )

        #expect(spy.microphoneRequestCount == 0)
        #expect(spy.captureRequests.count == 1)
        #expect(spy.captureRequests.first?.captureMicrophone == true)
        #expect(engine.recordingState == .recording)

        await engine.stopRecordingAndWait()
    }

    @Test func manualSystemAudioOnlyStartNeverRequestsMicrophonePermission() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")
        isolated.defaults.set(false, forKey: "captureMicrophone")

        let spy = RecordingEngineBoundarySpy()
        spy.microphoneStatus = .notDetermined
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer {
            engine.forceReset()
            try? FileManager.default.removeItem(at: spy.storageRoot)
        }

        try await engine.startRecording()

        #expect(spy.microphoneRequestCount == 0)
        #expect(spy.captureRequests.count == 1)
        #expect(spy.captureRequests.first?.captureMicrophone == false)
        #expect(engine.recordingState == .recording)

        await engine.stopRecordingAndWait()
    }

    @Test func activePostProcessingDoesNotBlockManualOrAutomaticStarts() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        try FileManager.default.createDirectory(
            at: spy.storageRoot,
            withIntermediateDirectories: true
        )

        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(spy.storageRoot)

        let processingRecordingID = UUID()
        let processingAudioURL = spy.storageRoot.appendingPathComponent("processing.m4a")
        try Data("post-processing-fixture".utf8).write(to: processingAudioURL)
        #expect(await store.importAudioFile(
            id: processingRecordingID,
            title: "Processing",
            startDate: Date(),
            duration: 60,
            audioURL: processingAudioURL,
            ownership: .appCreated
        ))

        let processingGate = RecordingEngineAsyncGate()
        let coordinator = PostProcessingCoordinator(
            store: store,
            transcriptionDependencies: PostProcessingTranscriptionDependencies(
                defaults: isolated.defaults,
                apiKey: { _ in nil },
                supportsAppleLanguage: { _ in true },
                localWhisperState: { LocalWhisperState(model: "base", isAvailable: true) }
            )
        )
        coordinator.transcriptionRunnerOverride = { _, _ in
            try await processingGate.wait()
        }
        await coordinator.startPostProcessing(
            recordingID: processingRecordingID,
            audioURL: processingAudioURL,
            meetingTitle: "Processing"
        )
        #expect(coordinator.isPostProcessing)

        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        engine.store = store
        engine.coordinator = coordinator
        engine._test_setSystemAudioPreparationDefaults(isolated.defaults)
        SystemAudioCapturePreparation.markPrepared(defaults: isolated.defaults)

        try await engine.startRecording(captureMicrophone: false)
        #expect(engine.recordingState == .recording)
        #expect(spy.captureRequests.count == 1)
        #expect(coordinator.isPostProcessing)
        #expect(coordinator.recordingProcessingGate.hasRecordingLease)
        #expect(coordinator.recordingProcessingGate.hasProcessingLeases)
        engine.forceReset()

        try await engine.startRecording(
            captureMicrophone: true,
            skipPermissionPrompt: true,
            isAutoStarted: true
        )
        #expect(engine.recordingState == .recording)
        #expect(spy.captureRequests.count == 2)
        #expect(coordinator.isPostProcessing)
        engine.forceReset()

        coordinator.cancelCurrentJob()
        await processingGate.open()
        #expect(await waitUntil { coordinator.recordingProcessingGate.isAllIdle })
    }

    private func verifyLateOldStopCannotAffectReplacement(
        forceReset: Bool
    ) async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set("en", forKey: "realtimeTranscriptionLanguage")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let serviceA = EngineOwnedRealtimeService(blocksStop: true)
        let serviceB = EngineOwnedRealtimeService(blocksStop: false)
        let factory = EngineRealtimeServiceFactory([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(
            dependencies: spy.dependencies(
                defaults: isolated.defaults,
                usesInjectedRealtimeManager: true
            ),
            transcriptionManager: manager
        )
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer { engine.forceReset() }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync {
            let startCount = await serviceA.startCount
            return manager.isTranscribing && startCount == 1
        })

        if forceReset {
            engine.forceReset()
        } else {
            await engine.stopRecordingAndWait()
        }
        #expect(await waitUntilAsync { await serviceA.isStopWaiting })
        #expect(engine.recordingState == .idle)
        #expect(engine.isStopping == false)

        // A's exact provider close is still suspended. B must be able to own a
        // fresh manager generation before A's async finish returns.
        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync {
            let startCount = await serviceB.startCount
            return manager.isTranscribing && startCount == 1
        })

        await serviceB.emit("B-LIVE")
        #expect(await waitUntilAsync { manager.fullText == "B-LIVE" })
        manager.sendAudio(Data([0xB0]))
        #expect(await waitUntilAsync { await serviceB.sentAudio == [Data([0xB0])] })

        // Late A callbacks and its eventual stop completion cannot mutate B.
        await serviceA.emit("STALE-A")
        await serviceA.releaseStop()
        #expect(await waitUntilAsync { await serviceA.isStopWaiting == false })
        try? await Task.sleep(for: .milliseconds(30))

        #expect(manager.realtimeProvider == .openai)
        #expect(manager.isTranscribing)
        #expect(manager.fullText == "B-LIVE")
        manager.sendAudio(Data([0xB1]))
        #expect(await waitUntilAsync {
            await serviceB.sentAudio == [Data([0xB0]), Data([0xB1])]
        })
    }

    @Test func stopRecordingLateProviderFinishCannotClearReplacementSession() async throws {
        try await verifyLateOldStopCannotAffectReplacement(forceReset: false)
    }

    @Test func forceResetLateProviderFinishCannotClearReplacementSession() async throws {
        try await verifyLateOldStopCannotAffectReplacement(forceReset: true)
    }

    @Test func staleCaptureCallbacksCannotSendIntoOrStopReplacementRecording() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let serviceA = EngineOwnedRealtimeService(blocksStop: false)
        let serviceB = EngineOwnedRealtimeService(blocksStop: false)
        let factory = EngineRealtimeServiceFactory([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(
            dependencies: spy.dependencies(
                defaults: isolated.defaults,
                usesInjectedRealtimeManager: true
            ),
            transcriptionManager: manager
        )
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer { engine.forceReset() }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync {
            let startCount = await serviceA.startCount
            return manager.isTranscribing && startCount == 1
        })
        let staleAudioCallback = try #require(engine.audioMixer.onTranscriptionAudio)
        let staleErrorCallback = try #require(engine.audioMixer.onStreamError)

        engine.forceReset()
        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync {
            let startCount = await serviceB.startCount
            return manager.isTranscribing && startCount == 1
        })
        let replacementID = try #require(engine.currentRecordingID)

        staleAudioCallback(Data([0xA0]))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await serviceB.sentAudio.isEmpty)

        staleErrorCallback("stale A capture error")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(engine.currentRecordingID == replacementID)
        #expect(engine.recordingState == .recording)
    }

    @Test func staleStartupFailureCannotStopReplacementRecording() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let serviceA = EngineOwnedRealtimeService(blocksStop: false, failsStart: true)
        let serviceB = EngineOwnedRealtimeService(blocksStop: false)
        let factory = EngineRealtimeServiceFactory([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        let dispositionGate = RecordingEngineSuspensionGate()
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(
            dependencies: spy.dependencies(
                defaults: isolated.defaults,
                usesInjectedRealtimeManager: true
            ),
            transcriptionManager: manager
        )
        engine.beforeRealtimeStartupDispositionForTesting = { recordingID in
            await dispositionGate.waitForFirstRecording(recordingID)
        }
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer {
            Task { await dispositionGate.release() }
            engine.forceReset()
        }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync { await dispositionGate.isWaiting })

        engine.forceReset()
        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync {
            let startCount = await serviceB.startCount
            return manager.isTranscribing && startCount == 1
        })
        let replacementID = try #require(engine.currentRecordingID)

        await dispositionGate.release()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(engine.currentRecordingID == replacementID)
        #expect(engine.recordingState == .recording)
        #expect(manager.isTranscribing)
        #expect(await serviceB.stopCount == 0)
    }

    @Test func staleStartupFailureCannotStopReplacementAttemptForSameRecording() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let serviceA = EngineOwnedRealtimeService(blocksStop: false, failsStart: true)
        let serviceB = EngineOwnedRealtimeService(blocksStop: false)
        let factory = EngineRealtimeServiceFactory([serviceA, serviceB])
        let manager = TranscriptionManager(realtimeServiceFactory: factory.makeFactory())
        let dispositionGate = RecordingEngineSuspensionGate()
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(
            dependencies: spy.dependencies(
                defaults: isolated.defaults,
                usesInjectedRealtimeManager: true
            ),
            transcriptionManager: manager
        )
        engine.beforeRealtimeStartupDispositionForTesting = { recordingID in
            await dispositionGate.waitForFirstRecording(recordingID)
        }
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer {
            Task { await dispositionGate.release() }
            engine.forceReset()
        }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntilAsync { await dispositionGate.isWaiting })
        let recordingID = try #require(engine.currentRecordingID)

        try await manager.startRealtime(provider: .openai, apiKey: "replacement-key")
        #expect(manager.isTranscribing)
        #expect(await serviceB.startCount == 1)

        await dispositionGate.release()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(engine.currentRecordingID == recordingID)
        #expect(engine.recordingState == .recording)
        #expect(manager.isTranscribing)
        #expect(await serviceB.stopCount == 0)
    }

    @Test func batchOpenAIMissingKeyFailsExactlyBeforeCapture() async {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("auto", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.keys[.gemini] = "gemini-key"
        spy.captureError = RecordingEngineBoundarySentinel.captureReached
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))

        var resolutionError: TranscriptionProviderResolutionError?
        do {
            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        } catch let error as TranscriptionProviderResolutionError {
            resolutionError = error
        } catch {
            Issue.record("Expected exact provider error, got \(error)")
        }

        #expect(resolutionError == .missingAPIKey(.openai))
        #expect(spy.keyLookups == [.openai])
        #expect(spy.captureRequests.isEmpty)
        #expect(spy.realtimeRequests.isEmpty)
        #expect(spy.microphoneRequestCount == 0)
    }

    @Test func realtimeOpenAIMissingKeyDoesNotUseGeminiAndRecordingContinues() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set("en", forKey: "realtimeTranscriptionLanguage")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.keys[.gemini] = "gemini-key"
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        _ = await waitUntil { engine.realtimeHint != nil || !spy.realtimeRequests.isEmpty }

        #expect(engine.recordingState == .recording)
        #expect(spy.captureRequests.count == 1)
        #expect(spy.realtimeRequests.isEmpty)
        #expect(spy.keyLookups == [.openai])
        #expect(engine.realtimeHint != nil)
        #expect(engine.showAPIKeyAlert == false)
        #expect(engine.recordingError == nil)
        engine.forceReset()
    }

    @Test func realtimeAppleCapabilityUsesEffectiveRealtimeLanguageWithoutCloudFallback() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set("zz", forKey: "realtimeTranscriptionLanguage")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.appleLanguageSupport = ["en": true, "zz": false]
        spy.keys[.openai] = "openai-key"
        spy.keys[.gemini] = "gemini-key"
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        _ = await waitUntil { engine.realtimeHint != nil || !spy.realtimeRequests.isEmpty }

        #expect(spy.appleLanguageLookups == ["zz"])
        #expect(spy.keyLookups == [.openai])
        #expect(spy.realtimeRequests.isEmpty)
        #expect(engine.realtimeHint != nil)
        #expect(engine.recordingState == .recording)
        engine.forceReset()
    }

    @Test func everyBatchConfigurationFailureStopsBeforePermissionAndCapture() async {
        struct Case {
            let rawProvider: String
            let language: String
            let expectedError: TranscriptionProviderResolutionError
            let expectedKeyLookups: [AIProvider]
            let configure: @MainActor (RecordingEngineBoundarySpy) -> Void
        }

        let cases = [
            Case(
                rawProvider: AIProvider.apple.rawValue,
                language: "zz",
                expectedError: .unsupportedLanguage(.apple, language: "zz"),
                expectedKeyLookups: [],
                configure: { spy in
                    spy.appleLanguageSupport["zz"] = false
                    spy.keys = [.openai: "openai-key", .gemini: "gemini-key"]
                }
            ),
            Case(
                rawProvider: AIProvider.gemini.rawValue,
                language: "en",
                expectedError: .missingAPIKey(.gemini),
                expectedKeyLookups: [.gemini],
                configure: { $0.keys[.openai] = "openai-key" }
            ),
            Case(
                rawProvider: AIProvider.whisperLocal.rawValue,
                language: "en",
                expectedError: .localModelUnavailable("missing-model"),
                expectedKeyLookups: [],
                configure: { spy in
                    spy.localWhisperModel = "missing-model"
                    spy.localWhisperAvailable = false
                    spy.keys = [.openai: "openai-key", .gemini: "gemini-key"]
                }
            ),
            Case(
                rawProvider: " ",
                language: "en",
                expectedError: .invalidStoredProvider(" "),
                expectedKeyLookups: [],
                configure: { _ in }
            ),
        ]

        for testCase in cases {
            let isolated = makeDefaults()
            defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
            isolated.defaults.set(testCase.rawProvider, forKey: "transcriptionProvider")
            isolated.defaults.set(testCase.language, forKey: "transcriptionLanguage")
            isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

            let spy = RecordingEngineBoundarySpy()
            spy.microphoneStatus = .notDetermined
            testCase.configure(spy)
            let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
            var caught: TranscriptionProviderResolutionError?
            do {
                try await engine.startRecording(captureMicrophone: false)
            } catch let error as TranscriptionProviderResolutionError {
                caught = error
            } catch {
                Issue.record("Expected provider resolution error, got \(error)")
            }

            #expect(caught == testCase.expectedError)
            #expect(spy.keyLookups == testCase.expectedKeyLookups)
            #expect(spy.microphoneRequestCount == 0)
            #expect(spy.captureRequests.isEmpty)
        }
    }

    @Test func captureAndPublishedStatePrecedeRealtimeStartup() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set("ja", forKey: "realtimeTranscriptionLanguage")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let startDate = Date(timeIntervalSinceReferenceDate: 456_789)
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = " openai-key "
        spy.nowValues = [startDate, startDate.addingTimeInterval(99)]
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        var stateWhenPublished: RecordingState?
        engine.onRecordingStarted = { stateWhenPublished = engine.recordingState }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        let started = await waitUntil { !spy.realtimeRequests.isEmpty }
        #expect(started)

        let captureIndex = try #require(spy.boundaryEvents.firstIndex(of: .captureStart))
        let realtimeIndex = try #require(
            spy.boundaryEvents.firstIndex(of: .realtimeStart(preserveSegments: false))
        )
        let request = try #require(spy.realtimeRequests.first)
        #expect(captureIndex < realtimeIndex)
        #expect(stateWhenPublished == .recording)
        #expect(engine.recordingState == .recording)
        #expect(engine.audioMixer.onTranscriptionAudio != nil)
        #expect(request.configuration.selection.provider == .openai)
        #expect(request.configuration.selection.apiKey == "openai-key")
        #expect(request.configuration.language == "ja")
        #expect(request.configuration.recordingStartTime == startDate)
        #expect(request.configuration.recordingStartTime == engine.recordingStartDate)
        engine.forceReset()
    }

    @Test func suspendedRealtimeStarterDoesNotDelayStartRecordingReturn() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let gate = RecordingEngineAsyncGate()
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        spy.realtimeHandler = { _ in try await gate.wait() }
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

        let startTask = Task { @MainActor in
            do {
                try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
                spy.startReturned = true
            } catch {
                Issue.record("Recording start failed: \(error)")
            }
        }

        let returnedWhileStarterWaited = await waitUntil {
            spy.startReturned && !spy.realtimeRequests.isEmpty
        }
        let gateWasStillClosed = !(await gate.currentValue())
        #expect(returnedWhileStarterWaited)
        #expect(gateWasStillClosed)
        #expect(engine.recordingState == .recording)

        await gate.open()
        await startTask.value
        engine.forceReset()
    }

    @Test func unsupportedRealtimeProvidersNeverSubstituteCloud() async throws {
        let rawValues = [
            AIProvider.whisperLocal.rawValue,
            AIProvider.claude.rawValue,
            AIProvider.minimax.rawValue,
            " invalid-provider ",
        ]

        for rawValue in rawValues {
            let isolated = makeDefaults()
            defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
            isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
            isolated.defaults.set("en", forKey: "transcriptionLanguage")
            isolated.defaults.set(rawValue, forKey: "realtimeTranscriptionProvider")
            isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

            let spy = RecordingEngineBoundarySpy()
            spy.keys = [.openai: "openai-key", .gemini: "gemini-key"]
            let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
            try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
            let failedLocally = await waitUntil { engine.realtimeHint != nil }
            #expect(failedLocally)
            #expect(engine.recordingState == .recording)
            #expect(spy.captureRequests.count == 1)
            #expect(spy.realtimeRequests.isEmpty)
            #expect(spy.keyLookups.isEmpty)
            engine.forceReset()
        }
    }

    @Test func validCloudRealtimeSelectionUsesOnlySelectedTrimmedKey() async throws {
        for provider in [AIProvider.openai, .gemini] {
            let isolated = makeDefaults()
            defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
            isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
            isolated.defaults.set("en", forKey: "transcriptionLanguage")
            isolated.defaults.set(provider.rawValue, forKey: "realtimeTranscriptionProvider")
            isolated.defaults.set("fr", forKey: "realtimeTranscriptionLanguage")
            isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

            let spy = RecordingEngineBoundarySpy()
            spy.keys[provider] = " selected-key "
            spy.keys[provider == .openai ? .gemini : .openai] = "other-key"
            let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
            try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
            let started = await waitUntil { !spy.realtimeRequests.isEmpty }
            #expect(started)
            let request = try #require(spy.realtimeRequests.first)
            #expect(spy.keyLookups == [provider])
            #expect(request.configuration.selection.provider == provider)
            #expect(request.configuration.selection.apiKey == "selected-key")
            #expect(request.configuration.language == "fr")
            engine.forceReset()
        }
    }

    @Test func reconnectReusesImmutableProviderKeyLanguageAndStartDate() async throws {
        struct StreamFailed: Error {}

        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set("ja", forKey: "realtimeTranscriptionLanguage")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let startDate = Date(timeIntervalSinceReferenceDate: 777_000)
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "original-key"
        spy.nowValues = [startDate, startDate.addingTimeInterval(500)]
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { spy.realtimeRequests.count == 1 })
        let initial = try #require(spy.realtimeRequests.first)

        isolated.defaults.set(AIProvider.gemini.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("de", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.gemini.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set("ko", forKey: "realtimeTranscriptionLanguage")
        spy.keys[.openai] = "changed-openai-key"
        spy.keys[.gemini] = "gemini-key"

        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
        #expect(await waitUntil { spy.realtimeRequests.count == 2 })
        let reconnect = try #require(spy.realtimeRequests.last)

        #expect(initial.preserveSegments == false)
        #expect(reconnect.preserveSegments == true)
        #expect(reconnect.attemptID != initial.attemptID)
        #expect(reconnect.configuration.selection.provider == initial.configuration.selection.provider)
        #expect(reconnect.configuration.selection.apiKey == initial.configuration.selection.apiKey)
        #expect(reconnect.configuration.selection.model == initial.configuration.selection.model)
        #expect(reconnect.configuration.language == initial.configuration.language)
        #expect(reconnect.configuration.recordingID == initial.configuration.recordingID)
        #expect(reconnect.configuration.recordingStartTime == initial.configuration.recordingStartTime)
        #expect(reconnect.configuration.recordingStartTime == startDate)
        #expect(spy.keyLookups == [.openai])
        #expect(spy.stopRequests.contains { $0.preserveFailureHandler })
        engine.forceReset()
    }

    @Test func failureRaisedInsideReconnectStartupIsCoalescedIntoNextReconnect() async throws {
        struct StreamFailed: Error {}

        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        spy.realtimeHandler = { [weak engine, weak spy] request in
            // The second request is reconnect B. Raise B's terminal failure
            // synchronously before startRealtime returns to reproduce the exact
            // in-flight callback window without scheduler timing assumptions.
            if request.preserveSegments, spy?.realtimeRequests.count == 2 {
                engine?._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
            }
        }
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer { engine.forceReset() }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { spy.realtimeRequests.count == 1 })

        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)

        #expect(await waitUntil(timeout: .seconds(1)) { spy.realtimeRequests.count == 3 })
        try #require(spy.realtimeRequests.count == 3)
        #expect(spy.realtimeRequests[1].attemptID != spy.realtimeRequests[2].attemptID)
        #expect(engine.recordingState == .recording)
        #expect(engine.realtimeHint == nil)
        #expect(engine._test_isReconnectingRealtime == false)
    }

    @Test func reconnectHandshakeUsesHardDeadlineAndLeavesRecordingRunning() async throws {
        struct StreamFailed: Error {}

        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let reconnectGate = RecordingEngineSuspensionGate()
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(
            dependencies: spy.dependencies(
                defaults: isolated.defaults,
                realtimeStartTimeout: .milliseconds(60)
            )
        )
        spy.realtimeHandler = { request in
            guard request.preserveSegments else { return }
            // Checked-continuation provider handshakes can ignore task
            // cancellation, so the outer deadline must return independently.
            await reconnectGate.waitForFirstRecording(request.configuration.recordingID)
        }
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer {
            Task { await reconnectGate.release() }
            engine.forceReset()
        }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { spy.realtimeRequests.count == 1 })

        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
        #expect(await waitUntil { spy.realtimeRequests.count == 2 })
        #expect(await waitUntilAsync { await reconnectGate.isWaiting })

        #expect(await waitUntil(timeout: .milliseconds(500)) {
            engine.realtimeHint != nil && !engine._test_isReconnectingRealtime
        })
        #expect(engine.recordingState == .recording)
        #expect(spy.stopRequests.count >= 2)
    }

    @Test func provenHealthyStreamRefillsReconnectBudget() async throws {
        struct StreamFailed: Error {}

        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer { engine.forceReset() }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { spy.realtimeRequests.count == 1 })

        // Three terminal failures consume the whole reconnect budget.
        for expected in 2...4 {
            engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
            #expect(await waitUntil {
                spy.realtimeRequests.count == expected && !engine._test_isReconnectingRealtime
            })
        }
        #expect(engine._test_realtimeReconnectCount == 3)

        // A content delta proves the stream healthy end to end; scattered
        // faults across a long recording must not accumulate into the cap.
        engine._test_triggerRealtimeStreamHealthy()
        #expect(engine._test_realtimeReconnectCount == 0)

        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
        #expect(await waitUntil {
            spy.realtimeRequests.count == 5 && !engine._test_isReconnectingRealtime
        })
        #expect(engine.realtimeHint == nil)
        #expect(engine.recordingState == .recording)
    }

    @Test func speechResumeRearmsRealtimeAfterReconnectsExhausted() async throws {
        struct StreamFailed: Error {}

        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer { engine.forceReset() }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { spy.realtimeRequests.count == 1 })

        for expected in 2...4 {
            engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
            #expect(await waitUntil {
                spy.realtimeRequests.count == expected && !engine._test_isReconnectingRealtime
            })
        }

        // Budget exhausted: the next failure gives up without dialing again,
        // shows the interruption hint, and arms the speech retry.
        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
        #expect(engine.realtimeHint != nil)
        #expect(engine._test_hasQueuedRealtimeSpeechRetry)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(spy.realtimeRequests.count == 4)

        // Resumed speech replays the saved failure and re-dials exactly once.
        engine._test_simulateSpeechResumed()
        #expect(await waitUntil {
            spy.realtimeRequests.count == 5 && !engine._test_isReconnectingRealtime
        })
        let retried = try #require(spy.realtimeRequests.last)
        #expect(retried.preserveSegments == true)
        #expect(engine.realtimeHint == nil)
        #expect(!engine._test_hasQueuedRealtimeSpeechRetry)
        #expect(engine.recordingState == .recording)

        // Another terminal failure re-queues, but the interval floor blocks an
        // immediate second redial (the spy clock never advances).
        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
        #expect(engine._test_hasQueuedRealtimeSpeechRetry)
        engine._test_simulateSpeechResumed()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(spy.realtimeRequests.count == 5)
        #expect(engine._test_hasQueuedRealtimeSpeechRetry)
    }

    @Test func contentDeltaClearsStaleInterruptionHint() async throws {
        struct StreamFailed: Error {}

        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        defer { engine.forceReset() }

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { spy.realtimeRequests.count == 1 })

        for expected in 2...4 {
            engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
            #expect(await waitUntil {
                spy.realtimeRequests.count == expected && !engine._test_isReconnectingRealtime
            })
        }
        engine._test_triggerRealtimeFailure(StreamFailed(), provider: .openai)
        #expect(engine.realtimeHint != nil)
        #expect(engine._test_hasQueuedRealtimeSpeechRetry)

        // The give-up branch leaves its stream open, so a first delta can
        // arrive with no reconnect in between. The session has recovered on
        // its own: the interruption banner must come down with the queue.
        engine._test_triggerRealtimeStreamHealthy()
        #expect(engine.realtimeHint == nil)
        #expect(!engine._test_hasQueuedRealtimeSpeechRetry)
        #expect(engine._test_realtimeReconnectCount == 0)
        #expect(engine.recordingState == .recording)
    }

    @Test func forceResetCancelsHungRealtimeStartup() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let gate = RecordingEngineAsyncGate()
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        spy.realtimeHandler = { [weak spy] _ in
            do {
                try await gate.wait()
            } catch {
                spy?.realtimeCancellationCount += 1
                throw error
            }
        }
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { !spy.realtimeRequests.isEmpty })
        engine.forceReset()
        #expect(await waitUntil { spy.realtimeCancellationCount == 1 })
        #expect(engine.recordingState == .idle)
        await gate.open()
    }

    @Test func stopRecordingCancelsHungRealtimeStartup() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "realtimeTranscriptionProvider")
        isolated.defaults.set(true, forKey: "enableRealtimeTranscription")

        let gate = RecordingEngineAsyncGate()
        let spy = RecordingEngineBoundarySpy()
        spy.keys[.openai] = "openai-key"
        spy.realtimeHandler = { [weak spy] _ in
            do {
                try await gate.wait()
            } catch {
                spy?.realtimeCancellationCount += 1
                throw error
            }
        }
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(await waitUntil { !spy.realtimeRequests.isEmpty })
        await engine.stopRecordingAndWait()
        #expect(await waitUntil { spy.realtimeCancellationCount == 1 })
        #expect(engine.recordingState == .idle)
        await gate.open()
    }

    @Test func startRecordingRefusedWhileMigrationClaimed() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        let migrationGate = StorageMigrationGate()
        engine.migrationGate = migrationGate
        #expect(migrationGate.claimMigration())

        await #expect(throws: RecordingStartError.storageMigrationInProgress) {
            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        }
        #expect(spy.captureRequests.isEmpty)
        #expect(engine.recordingState == .idle)
        migrationGate.releaseMigration()
    }

    /// The activity lease spans start through stop finalization: a migration
    /// claim is refused while recording and while the stop lifecycle is
    /// still finalizing, and succeeds only after the stop fully completes.
    @Test func recordingLeaseBlocksMigrationUntilStopFinalizationCompletes() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        let migrationGate = StorageMigrationGate()
        engine.migrationGate = migrationGate

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(!migrationGate.claimMigration())

        await engine.stopRecordingAndWait()
        #expect(engine.recordingState == .idle)
        #expect(migrationGate.claimMigration())
        migrationGate.releaseMigration()
    }

    /// The last-resort reset bypasses the normal stop lifecycle; it must
    /// still release the migration lease or claims fail until relaunch.
    @Test func forceResetReleasesMigrationLease() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        let migrationGate = StorageMigrationGate()
        engine.migrationGate = migrationGate

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        #expect(!migrationGate.claimMigration())

        engine.forceReset()
        #expect(engine.recordingState == .idle)
        #expect(migrationGate.claimMigration())
        migrationGate.releaseMigration()
    }

    @Test func presentStartErrorOwnsProviderAlertAndDismissalClearsContext() async {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.openai.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let spy = RecordingEngineBoundarySpy()
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        var caught: Error?
        do {
            try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        } catch {
            caught = error
        }

        #expect(engine.missingAPIKeyProvider == nil)
        #expect(engine.showAPIKeyAlert == false)
        guard let caught else {
            Issue.record("Expected batch configuration failure")
            return
        }
        engine.presentStartError(caught)
        #expect(engine.missingAPIKeyProvider == .openai)
        #expect(engine.showAPIKeyAlert)
        #expect(engine.recordingError == nil)

        engine.showAPIKeyAlert = false
        #expect(engine.missingAPIKeyProvider == nil)
        engine.presentStartError(
            TranscriptionProviderResolutionError.unsupportedLanguage(.apple, language: "zz")
        )
        #expect(engine.missingAPIKeyProvider == nil)
        #expect(engine.recordingError != nil)
    }

    @Test func normalStopUsesSharedFinalizerWithoutAudioHardware() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let recordingID = UUID()
        let segmentsDirectory = URL(fileURLWithPath: "/tmp/segments-\(recordingID)")
        let outputURL = URL(fileURLWithPath: "/tmp/recording-\(recordingID).m4a")
        let spy = RecordingEngineBoundarySpy()
        let capturedStartDate = Date(timeIntervalSinceReferenceDate: 100)
        let capturedStopDate = Date(timeIntervalSinceReferenceDate: 160)
        spy.nowValues = [capturedStartDate, capturedStopDate]
        spy.stopCaptureResult = AudioMixer.StopPhase1Result(
            segmentURLs: [segmentsDirectory.appendingPathComponent("segment-000.m4a")],
            outputURL: outputURL,
            segmentsDirectory: segmentsDirectory
        )
        let events = RecordingEngineFinalizationEventSpy()
        let storeCommit = RecordingEngineStoreCommitProbe()
        let processingRunnerGate = RecordingEngineAsyncGate()
        let exclusionGate = RecordingProcessingGate()
        var allIdleNotifications = 0
        _ = exclusionGate.observeAllIdle {
            allIdleNotifications += 1
        }
        let finalizerDependencies = RecordingAudioFinalizerDependencies(
            validate: { request in
                guard let authority = request.segmentStorageAuthority else {
                    return .trustFailure("Missing test authority")
                }
                let trustedDirectory = authority.expectedSegmentsDirectory(
                    recordingID: request.recordingID
                )
                do {
                    try FileManager.default.createDirectory(
                        at: trustedDirectory,
                        withIntermediateDirectories: true
                    )
                    let segmentURL = trustedDirectory
                        .appendingPathComponent("segment-000.m4a")
                    try Data([0x01]).write(to: segmentURL)
                    let now = Date(timeIntervalSinceReferenceDate: 100)
                    let manifest = SegmentedAudioFileWriter.SegmentManifest(
                        recordingID: request.recordingID.uuidString,
                        segments: [
                            SegmentedAudioFileWriter.SegmentEntry(
                                index: 0,
                                filename: "segment-000.m4a",
                                startedAt: now,
                                completedAt: now.addingTimeInterval(30)
                            ),
                        ],
                        isComplete: true
                    )
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(manifest).write(
                        to: trustedDirectory.appendingPathComponent("segments.json")
                    )
                    return await RecordingAudioFinalizer.validateSegments(
                        RecordingAudioFinalizationRequest(
                            origin: request.origin,
                            recordingID: request.recordingID,
                            segmentsDirectory: trustedDirectory,
                            suppliedSegmentURLs: [segmentURL],
                            segmentStorageAuthority: authority,
                            outputURL: request.outputURL,
                            fallbackDuration: request.fallbackDuration,
                            startDate: request.startDate,
                            endDate: request.endDate,
                            meetingTitle: request.meetingTitle,
                            mergeTimeoutSeconds: request.mergeTimeoutSeconds
                        )
                    )
                } catch {
                    return .trustFailure("Failed to prepare trusted test fixture")
                }
            },
            recheckBeforeMerge: { validated in validated.recheckForMerge() },
            mergeStage: { request, _ in
                RecordingAudioPreparedArtifact(outputURL: request.outputURL, mergedDuration: 30)
            },
            publish: { _, artifact in
                if let outputURL = artifact.outputURL {
                    try? Data("durable-output".utf8).write(to: outputURL)
                }
                return artifact.outputURL.map(RecordingAudioPublication.init(audioURL:))
            },
            storeCommit: { request in
                await storeCommit.record(request)
                return .saved
            },
            cleanup: { _ in .cleaned },
            cleanupPublished: { _, _ in .cleaned },
            postProcess: { _, _ in },
            recordEvent: { event in await events.record(event) }
        )
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.defaults),
            audioFinalizerDependencies: finalizerDependencies,
            recordingProcessingGate: exclusionGate
        )
        try await attachIsolatedStore(to: engine, audioRoot: spy.storageRoot)
        let store = try #require(engine.store)
        let coordinator = PostProcessingCoordinator(
            store: store,
            transcriptionDependencies: PostProcessingTranscriptionDependencies(
                defaults: isolated.defaults,
                apiKey: { _ in nil },
                supportsAppleLanguage: { _ in true },
                localWhisperState: { LocalWhisperState(model: "base", isAvailable: true) }
            ),
            recordingProcessingGate: exclusionGate
        )
        coordinator.transcriptionRunnerOverride = { _, _ in
            try await processingRunnerGate.wait()
        }
        engine.coordinator = coordinator

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        await engine.stopRecordingAndWait()

        #expect(await waitForRecordingEngineFinalizationEvents(events, count: 6) == [
            .validation,
            .mergeStage,
            .publish,
            .storeCommit,
            .cleanup,
            .postProcess,
        ])
        #expect(await storeCommit.duration == 30)
        #expect(await storeCommit.endDate == capturedStopDate)
        #expect(engine.isStopping == false)
        #expect(await waitUntil { coordinator.postProcessingPhase == "transcribing" })
        #expect(!engine._test_hasRecordingProcessingClaim)
        #expect(exclusionGate.hasProcessingLeases)
        let concurrentRecordingLease = exclusionGate.claimRecording()
        #expect(concurrentRecordingLease != nil)
        exclusionGate.releaseRecording(concurrentRecordingLease)
        #expect(allIdleNotifications == 0)

        await processingRunnerGate.open()
        #expect(await waitUntil { exclusionGate.isAllIdle })
        #expect(allIdleNotifications == 1)
    }

    @Test func normalStopTrustFailureKeepsRecoveryPointerAndClearsStopping() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-outside-stop-\(UUID().uuidString)", isDirectory: true)
        let outsideSegments = outsideRoot.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideSegments,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }

        let spy = RecordingEngineBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        spy.stopCaptureResult = AudioMixer.StopPhase1Result(
            segmentURLs: [outsideSegments.appendingPathComponent("segment-000.m4a")],
            outputURL: outsideRoot.appendingPathComponent("output.m4a"),
            segmentsDirectory: outsideSegments
        )
        let events = RecordingEngineFinalizationEventSpy()
        let finalizerDependencies = RecordingAudioFinalizerDependencies(
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
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: isolated.defaults),
            audioFinalizerDependencies: finalizerDependencies
        )
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(spy.storageRoot)
        engine.store = store

        try await engine.startRecording(captureMicrophone: false, skipPermissionPrompt: true)
        let recordingID = try #require(spy.captureRequests.first?.recordingID)
        await engine.stopRecordingAndWait()

        #expect(await events.events == [.validation])
        #expect(engine.isStopping == false)
        let pending = await store.fetchInterruptedRecordings()
        let expectedSegments = spy.storageRoot
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        #expect(
            pending.contains {
                $0.id == recordingID && $0.segmentsDirURL.path == expectedSegments.path
            }
        )
    }

    @Test func startRejectsCaptureDirectoryOutsideLockedAuthority() async throws {
        let isolated = makeDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        isolated.defaults.set(AIProvider.apple.rawValue, forKey: "transcriptionProvider")
        isolated.defaults.set("en", forKey: "transcriptionLanguage")
        isolated.defaults.set(false, forKey: "enableRealtimeTranscription")

        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-outside-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let markerURL = outsideRoot.appendingPathComponent("marker")
        let markerBytes = Data([0xA1, 0xB2])
        try markerBytes.write(to: markerURL)

        let spy = RecordingEngineBoundarySpy()
        defer { try? FileManager.default.removeItem(at: spy.storageRoot) }
        spy.startCaptureDirectoryOverride = outsideRoot
        let engine = RecordingEngine(dependencies: spy.dependencies(defaults: isolated.defaults))
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.setAudioRootForTesting(spy.storageRoot)
        engine.store = store

        await #expect(throws: RecordingEngineError.self) {
            try await engine.startRecording(
                captureMicrophone: false,
                skipPermissionPrompt: true
            )
        }

        #expect(engine.recordingState == .idle)
        #expect(await store.fetchInterruptedRecordings().isEmpty)
        #expect(try Data(contentsOf: markerURL) == markerBytes)
    }
}

@Suite("RecordingEngine.handleMeetingActivity", .serialized)
@MainActor
struct RecordingEngineMeetingTests {

    private static let defaultsSuiteName = "RecordingEngineMeetingTests.\(UUID().uuidString)"
    private static let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    private static let boundarySpy = RecordingEngineBoundarySpy()

    private func makeEngine() -> RecordingEngine {
        Self.defaults.removePersistentDomain(forName: Self.defaultsSuiteName)
        return RecordingEngine(
            dependencies: Self.boundarySpy.dependencies(defaults: Self.defaults)
        )
    }

    // MARK: - Guard Ordering: isStopping checked before cooldown

    @Test func whileStopping_storesPendingEvenDuringCooldown() {
        let engine = makeEngine()

        // Simulate: stopRecording() armed cooldown AND isStopping is true
        engine._test_setStopping(true)
        engine._test_setCooldown(Date().addingTimeInterval(10))

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")

        // isStopping should be checked FIRST, storing pending before cooldown rejects
        let pending = engine._test_pendingMeetingAutoStart
        #expect(pending != nil)
        #expect(pending?.bundleID == "us.zoom.xos")
        #expect(pending?.appName == "Zoom")
    }

    @Test func whileStopping_noCooldown_storesPending() {
        let engine = makeEngine()
        engine._test_setStopping(true)

        engine.handleMeetingActivity(bundleID: "com.microsoft.teams2", appName: "Teams")

        let pending = engine._test_pendingMeetingAutoStart
        #expect(pending != nil)
        #expect(pending?.bundleID == "com.microsoft.teams2")
    }

    @Test func notStopping_duringCooldown_storesPendingForRetry() {
        let engine = makeEngine()
        engine._test_setCooldown(Date().addingTimeInterval(10))

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")

        let pending = engine._test_pendingMeetingAutoStart
        #expect(pending != nil)
        #expect(pending?.bundleID == "us.zoom.xos")
        #expect(pending?.appName == "Zoom")
        engine.resetMeetingDetectionState()
    }

    @Test func notStopping_duringShortCooldown_retriesPendingAfterCooldown() async {
        let engine = makeEngine()
        engine._test_setCooldown(Date().addingTimeInterval(0.05))

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")

        #expect(engine.showMicPrompt == false)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(engine.showMicPrompt == true)
        #expect(engine._test_pendingMeetingAutoStart == nil)
    }

    @Test func notStopping_noCooldown_idle_showsMicPrompt() {
        let engine = makeEngine()
        let keyLookupCount = Self.boundarySpy.keyLookups.count
        let captureRequestCount = Self.boundarySpy.captureRequests.count

        // autoRecordMeetings not set → defaults to false → should show mic prompt
        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")

        #expect(engine.showMicPrompt == true)
        #expect(Self.boundarySpy.keyLookups.count == keyLookupCount)
        #expect(Self.boundarySpy.captureRequests.count == captureRequestCount)
    }

    // MARK: - Meeting State Tracking

    @Test func handleMeetingActivity_setsMeetingState() {
        let engine = makeEngine()
        engine._test_setStopping(true) // prevent actual recording start

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")

        #expect(engine.isMeetingCurrentlyActive == true)
        #expect(engine.detectedMeetingBundleID == "us.zoom.xos")
        #expect(engine.detectedMeetingAppName == "Zoom")
    }

    @Test func handleMeetingActivity_cancelsPendingAutoStopForRapidReconnect() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("us.zoom.xos")
        engine._test_setCurrentRecordingIsAutoStarted(true)

        engine.handleMicDeactivated()
        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)

        engine.handleMeetingActivity(bundleID: "com.microsoft.teams2", appName: "Teams")

        #expect(engine.recordingState == .recording)
        #expect(engine.isMeetingCurrentlyActive)
        #expect(engine.triggeringMeetingBundleID == "com.microsoft.teams2")
        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
        #expect(engine.autoStopCountdown == 0)

        // Termination of the previous app must not stop the new session.
        engine.handleMeetingTerminated(bundleID: "us.zoom.xos")
        #expect(engine.recordingState == .recording)
        #expect(engine.isMeetingCurrentlyActive)
    }

    @Test func sameTeamsHeuristicActivityPreservesAuthoritativeDeadline() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("com.microsoft.teams2")
        engine._test_setCurrentRecordingIsAutoStarted(true)

        engine.handleMeetingActivity(bundleID: "com.microsoft.teams2", appName: "Teams")
        engine.handleMeetingEnding(.init(
            detectedAt: Date(),
            reason: .teamsCallAssertionReleased
        ))
        let originalDeadline = engine._test_autoStopDeadline

        engine.handleMeetingActivity(bundleID: "com.microsoft.teams2", appName: "Teams")

        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)
        #expect(engine._test_autoStopDeadline == originalDeadline)
        #expect(engine.triggeringMeetingBundleID == "com.microsoft.teams2")
    }

    @Test func sameTeamsAssertionActivityCancelsPriorAuthoritativeDeadline() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("com.microsoft.teams2")
        engine._test_setCurrentRecordingIsAutoStarted(true)

        engine.handleMeetingActivity(bundleID: "com.microsoft.teams2", appName: "Teams")
        engine.handleMeetingEnding(.init(
            detectedAt: Date(),
            reason: .teamsCallAssertionReleased
        ))
        #expect(engine._test_hasPendingAutoStop)

        engine.handleMeetingActivity(
            bundleID: "com.microsoft.teams2",
            appName: "Teams",
            reason: .teamsCallAssertionActive
        )

        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func handleMeetingActivity_doesNotMarkManualRecordingAsMeetingTriggered() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)

        engine.handleMicDeactivated()
        #expect(engine._test_hasPendingAutoStop)

        engine.handleMeetingActivity(bundleID: "com.microsoft.teams2", appName: "Teams")

        #expect(engine.recordingState == .recording)
        #expect(engine.triggeringMeetingBundleID == nil)
        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func handleMeetingTerminated_clearsMeetingState() {
        let engine = makeEngine()
        engine._test_setStopping(true)

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")
        engine.handleMeetingTerminated(bundleID: "us.zoom.xos")

        #expect(engine.isMeetingCurrentlyActive == false)
        #expect(engine.detectedMeetingBundleID == nil)
        #expect(engine.detectedMeetingAppName == nil)
    }

    @Test func handleMeetingTerminated_clearsPendingAutoStart() {
        let engine = makeEngine()
        engine._test_setStopping(true)

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")
        #expect(engine._test_pendingMeetingAutoStart != nil)

        engine.handleMeetingTerminated(bundleID: "us.zoom.xos")
        #expect(engine._test_pendingMeetingAutoStart == nil)
    }

    @Test func handleMeetingTerminated_currentDetectedBundleClearsOnlyThatBundle() {
        let engine = makeEngine()
        engine._test_setTriggeringMeetingBundleID("com.example.prior")
        engine._test_setStopping(true)

        engine.handleMeetingActivity(bundleID: "com.example.current", appName: "Current Meeting")
        #expect(engine._test_pendingMeetingAutoStart?.bundleID == "com.example.current")

        engine.handleMeetingTerminated(bundleID: "com.example.current")

        #expect(!engine.isMeetingCurrentlyActive)
        #expect(engine.detectedMeetingBundleID == nil)
        #expect(engine.detectedMeetingAppName == nil)
        #expect(engine._test_pendingMeetingAutoStart == nil)
        #expect(engine.triggeringMeetingBundleID == "com.example.prior")
    }

    @Test func handleMeetingTerminated_stopsMatchingAutoStartedRecording() async {
        let isolatedName = "RecordingEngineMeetingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: isolatedName)!
        defer { defaults.removePersistentDomain(forName: isolatedName) }
        defaults.set(true, forKey: "autoStopOnMicClose")
        let spy = RecordingEngineBoundarySpy()
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: defaults)
        )
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("com.example.trigger")
        engine._test_setCurrentRecordingIsAutoStarted(true)

        engine.handleMeetingTerminated(bundleID: "com.example.trigger")

        #expect(engine.recordingState == .idle)
        await engine.stopRecordingAndWait()
        #expect(!engine.isStopping)
    }

    @Test func repeatedPriorTerminationDoesNotStopPromptStartedCurrentMeeting() {
        let isolatedName = "RecordingEngineMeetingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: isolatedName)!
        defer { defaults.removePersistentDomain(forName: isolatedName) }
        defaults.set(true, forKey: "autoStopOnMicClose")
        defaults.set(false, forKey: "autoRecordMeetings")
        let spy = RecordingEngineBoundarySpy()
        let engine = RecordingEngine(
            dependencies: spy.dependencies(defaults: defaults)
        )
        engine._test_setTriggeringMeetingBundleID("com.example.prior")
        engine._test_setStopping(true)
        engine.handleMeetingActivity(bundleID: "com.example.current", appName: "Current Meeting")

        engine.handleMeetingTerminated(bundleID: "com.example.prior")
        #expect(engine.triggeringMeetingBundleID == nil)
        #expect(engine.detectedMeetingBundleID == "com.example.current")

        // Simulate finalization completing and the user accepting B's prompt.
        engine._test_setStopping(false)
        engine.handleMeetingActivity(bundleID: "com.example.current", appName: "Current Meeting")
        #expect(engine.showMicPrompt)
        engine._test_setRecordingState(.recording)
        engine._test_setCurrentRecordingIsAutoStarted(false)

        engine.handleMeetingTerminated(bundleID: "com.example.prior")

        #expect(engine.recordingState == .recording)
        #expect(engine.isMeetingCurrentlyActive)
        #expect(engine.detectedMeetingBundleID == "com.example.current")
        engine.forceReset()
    }

    @Test func handleMeetingTerminated_wrongBundleID_isIgnored() {
        let engine = makeEngine()
        engine._test_setStopping(true)

        engine.handleMeetingActivity(bundleID: "us.zoom.xos", appName: "Zoom")

        // Terminate a different app — should be ignored
        engine.handleMeetingTerminated(bundleID: "com.microsoft.teams2")
        #expect(engine.isMeetingCurrentlyActive == true)
        #expect(engine._test_pendingMeetingAutoStart != nil)
    }

    @Test func definitiveMeetingEnding_armsDeadlineFromDetectionTime() async throws {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }

        engine._test_setRecordingState(.recording)

        let detectedAt = Date().addingTimeInterval(-2)
        engine.handleMeetingEnding(.init(
            detectedAt: detectedAt,
            reason: .teamsCallAssertionReleased
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.autoStopCountdown == 0)
        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)
        #expect(engine._test_autoStopDeadline == detectedAt.addingTimeInterval(8))
    }

    @Test func secondDefinitiveEndingRebasesDeadlineToLatestRelease() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)

        let firstRelease = Date().addingTimeInterval(-1)
        engine.handleMeetingEnding(.init(
            detectedAt: firstRelease,
            reason: .teamsCallAssertionReleased
        ))
        let firstDeadline = engine._test_autoStopDeadline

        let secondRelease = Date()
        engine.handleMeetingEnding(.init(
            detectedAt: secondRelease,
            reason: .teamsCallAssertionReleased
        ))

        #expect(firstDeadline == firstRelease.addingTimeInterval(8))
        #expect(engine._test_autoStopDeadline == secondRelease.addingTimeInterval(8))
        #expect(engine._test_autoStopDeadline.map { deadline in
            firstDeadline.map { deadline > $0 } ?? false
        } == true)
    }

    @Test func heuristicMeetingEnding_waitsForDetectorGraceConfirmation() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)

        engine.handleMeetingEnding(.init(detectedAt: Date(), reason: .signalDrop))

        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func handleMeetingRecovered_preservesAuthoritativeDeadlineDuringGrace() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)

        engine.handleMeetingEnding(.init(
            detectedAt: Date(),
            reason: .teamsCallAssertionReleased
        ))
        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)

        engine.handleMeetingRecovered()

        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)
        #expect(engine._test_autoStopDeadline != nil)
    }

    @Test func handleMeetingRecovered_cancelsHeuristicDeadline() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)

        engine.handleMicDeactivated()
        #expect(engine._test_hasPendingAutoStop)

        engine.handleMeetingRecovered()

        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
        #expect(engine._test_autoStopDeadline == nil)
    }

    @Test func handleMeetingRecovered_assertionActiveCancelsAuthoritativeDeadline() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)

        engine.handleMeetingEnding(.init(
            detectedAt: Date(),
            reason: .teamsCallAssertionReleased
        ))
        #expect(engine._test_hasPendingAutoStop)

        engine.handleMeetingRecovered(.teamsCallAssertionActive)

        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func handleMicDeactivated_doesNotExtendDeadlineRegisteredAtEnding() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)

        engine.handleMeetingEnding(.init(
            detectedAt: Date(),
            reason: .teamsCallAssertionReleased
        ))
        let originalDeadline = engine._test_autoStopDeadline
        engine.handleMicDeactivated()

        #expect(engine._test_autoStopDeadline == originalDeadline)
    }

    @Test func elapsedDefinitiveDeadline_stopsOnNextActorTurn() async throws {
        let engine = makeEngine()
        engine.confirmMeetingEndedBeforeAuthoritativeStop = { .ended }
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)

        engine.handleMeetingEnding(.init(
            detectedAt: Date().addingTimeInterval(-9),
            reason: .teamsCallAssertionReleased
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordingState == .idle)
        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func elapsedDefinitiveDeadline_isCancelledWhenFreshSignalsRecovered() async throws {
        let engine = makeEngine()
        var confirmationCallCount = 0
        engine.confirmMeetingEndedBeforeAuthoritativeStop = {
            confirmationCallCount += 1
            return .ongoing
        }
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)

        engine.handleMeetingEnding(.init(
            detectedAt: Date().addingTimeInterval(-9),
            reason: .teamsCallAssertionReleased
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(confirmationCallCount == 1)
        #expect(engine.recordingState == .recording)
        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func unavailableConfirmationRetriesWithoutDiscardingObservedRelease() async throws {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)
        var confirmationCallCount = 0
        engine.confirmMeetingEndedBeforeAuthoritativeStop = {
            confirmationCallCount += 1
            return confirmationCallCount == 1 ? .unavailable : .ended
        }

        engine.handleMeetingEnding(.init(
            detectedAt: Date().addingTimeInterval(-9),
            reason: .teamsCallAssertionReleased
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordingState == .recording)
        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)
        #expect(confirmationCallCount == 1)

        try await Task.sleep(for: .milliseconds(1_100))

        #expect(confirmationCallCount == 2)
        #expect(engine.recordingState == .idle)
        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func unavailableConfirmationThenActiveCancelsBeforeFallbackStop() async throws {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer { Self.defaults.removeObject(forKey: "autoStopOnMicClose") }
        engine._test_setRecordingState(.recording)
        var confirmationCallCount = 0
        engine.confirmMeetingEndedBeforeAuthoritativeStop = {
            confirmationCallCount += 1
            return confirmationCallCount == 1 ? .unavailable : .ongoing
        }

        engine.handleMeetingEnding(.init(
            detectedAt: Date().addingTimeInterval(-9),
            reason: .teamsCallAssertionReleased
        ))
        try await Task.sleep(for: .milliseconds(50))

        #expect(confirmationCallCount == 1)
        #expect(engine.recordingState == .recording)
        #expect(engine._test_hasPendingAutoStop)

        try await Task.sleep(for: .milliseconds(1_100))

        #expect(confirmationCallCount == 2)
        #expect(engine.recordingState == .recording)
        #expect(!engine._test_hasPendingAutoStop)
        #expect(!engine._test_hasAutoStopTask)
    }

    @Test func handleMicDeactivated_startsCountdownAfterDetectorGrace() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }

        engine._test_setRecordingState(.recording)
        engine._test_disableAutoStopTimer()

        engine.handleMicDeactivated()

        #expect(engine.autoStopCountdown == 5)
    }

    @Test func keepRecordingPreventsRepeatedAutoStopForCurrentRecording() {
        let engine = makeEngine()
        Self.defaults.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            Self.defaults.removeObject(forKey: "autoStopOnMicClose")
        }

        engine._test_setRecordingState(.recording)
        engine._test_disableAutoStopTimer()

        engine.handleMicDeactivated()
        #expect(engine.autoStopCountdown == 5)

        engine.keepRecordingAndCancelAutoStop()
        #expect(engine.autoStopCountdown == 0)
        #expect(engine._test_autoStopSuppressedForCurrentRecording)

        engine.handleMicDeactivated()
        #expect(engine.autoStopCountdown == 0)
        #expect(engine.isMeetingCurrentlyActive)
    }
}
