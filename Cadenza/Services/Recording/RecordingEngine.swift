import Foundation
import AVFoundation
import os

enum RecordingEngineError: LocalizedError {
    case persistenceFailed(String)
    case microphonePermissionRequired

    var errorDescription: String? {
        switch self {
        case .persistenceFailed(let msg): return msg
        case .microphonePermissionRequired:
            return String(localized: "Microphone access is required for automatic meeting recording. Enable it in System Settings, then try again.")
        }
    }
}

/// Configuration-level failures that prevent a recording from starting.
/// Thrown by `startRecording()` so the caller (menubar / main window button)
/// can surface a visible alert instead of the call silently `return`-ing.
enum RecordingStartError: LocalizedError, Equatable {
    /// Apple transcription doesn't support the chosen language and no cloud key is configured as fallback.
    case languageUnsupported
    /// The selected local Whisper model has not been downloaded yet.
    case whisperModelMissing
    /// The selected cloud transcription provider requires an API key, but none is configured.
    case noTranscriptionKey
    /// Automatic recording cannot be the first action that starts a Core Audio tap.
    case systemAudioNotPrepared
    /// A storage-directory migration holds the root; recording cannot start
    /// until it completes.
    case storageMigrationInProgress
    /// The previous recording still owns capture finalization resources.
    case finalizationInProgress

    var errorDescription: String? {
        switch self {
        case .languageUnsupported:
            return String(localized: "Apple transcription does not support the selected language, and no cloud fallback API key is configured. Choose another language or add an OpenAI or Gemini API key in Settings → Transcription.")
        case .whisperModelMissing:
            return String(localized: "The local Whisper model has not been downloaded. Download a model in Settings → Transcription first.")
        case .noTranscriptionKey:
            return String(localized: "No API key is configured for the selected transcription provider. Add an OpenAI or Gemini API key in Settings before recording.")
        case .systemAudioNotPrepared:
            return String(localized: "Enable System Audio Recording in Cadenza Settings before using automatic recording.")
        case .storageMigrationInProgress:
            return String(localized: "Recording is unavailable while the storage location is being changed.")
        case .finalizationInProgress:
            return String(localized: "The previous recording is still being saved. Wait a moment, then start again.")
        }
    }
}

// MARK: - Injectable Recording Boundaries

struct RecordingCaptureRequest: Sendable, Equatable {
    let recordingID: UUID
    let targetBundleID: String?
    let captureMicrophone: Bool
}

struct RealtimeTranscriptionConfiguration: Sendable {
    let selection: TranscriptionProviderSelection
    let language: String?
    let recordingID: UUID
    let recordingStartTime: Date
}

struct RealtimeStartRequest: Sendable {
    let configuration: RealtimeTranscriptionConfiguration
    let preserveSegments: Bool
    let attemptID: RealtimeAttemptID
}

struct RealtimeStopRequest: Sendable, Equatable {
    let preserveFailureHandler: Bool
    let preserveRealtimeError: Bool
    let awaitFinalDeltas: Bool
    let abandonStartup: Bool

    init(
        preserveFailureHandler: Bool = false,
        preserveRealtimeError: Bool = false,
        awaitFinalDeltas: Bool = false,
        abandonStartup: Bool = false
    ) {
        self.preserveFailureHandler = preserveFailureHandler
        self.preserveRealtimeError = preserveRealtimeError
        self.awaitFinalDeltas = awaitFinalDeltas
        self.abandonStartup = abandonStartup
    }
}

enum RecordingEngineBoundaryEvent: Sendable, Equatable {
    case captureStart
    case realtimeStart(preserveSegments: Bool)
    case realtimeStop
}

private enum RealtimeStopOperation {
    case manager(RealtimeStopHandle, RealtimeStopRequest)
    case dependency(RealtimeStopRequest)
}

@MainActor
struct RecordingEngineDependencies {
    let defaults: UserDefaults
    let apiKey: @MainActor @Sendable (AIProvider) -> String?
    let supportsAppleLanguage: @MainActor @Sendable (String) async -> Bool
    let localWhisperState: @MainActor @Sendable () -> (model: String, isAvailable: Bool)
    let microphoneStatus: @MainActor @Sendable () -> PermissionStatus
    let requestMicrophone: @MainActor @Sendable () async -> Bool
    let now: @MainActor @Sendable () -> Date
    let storageRoot: @MainActor @Sendable () -> URL
    let startCapture: (@MainActor @Sendable (RecordingCaptureRequest) async throws -> String?)?
    let stopCapture: (@Sendable () async -> AudioMixer.StopPhase1Result)?
    let startRealtime: (@MainActor @Sendable (RealtimeStartRequest) async throws -> Void)?
    let stopRealtime: (@MainActor @Sendable (RealtimeStopRequest) async -> Void)?
    let reconnectDelay: Duration
    let realtimeStartTimeout: Duration
    let recordBoundaryEvent: @MainActor @Sendable (RecordingEngineBoundaryEvent) -> Void

    static func live(defaults: UserDefaults = .standard) -> Self {
        Self(
            defaults: defaults,
            apiKey: { KeychainManager.shared.readOnlyAPIKey(for: $0) },
            supportsAppleLanguage: { await AppleSpeechFactory.supportsLanguage($0) },
            localWhisperState: {
                let manager = WhisperModelManager.shared
                let model = manager.selectedModel
                return (model, manager.isAvailable(model))
            },
            microphoneStatus: { Permissions.microphoneStatus },
            requestMicrophone: { await Permissions.requestMicrophone() },
            now: { Date() },
            storageRoot: { StorageLocationManager.recordingsDirectory },
            startCapture: nil,
            stopCapture: nil,
            startRealtime: nil,
            stopRealtime: nil,
            reconnectDelay: .seconds(2),
            realtimeStartTimeout: .seconds(5),
            recordBoundaryEvent: { _ in }
        )
    }
}

/// Owns the recording state machine and AudioMixer in the main process.
/// Direct method calls replace XPC round-trips for recording control.
/// AppState wires MeetingDetector callbacks to this engine.
@Observable @MainActor
final class RecordingEngine {

    // MARK: - Logging

    /// os.Logger — NSLog is not persisted at default level on macOS 26.
    @ObservationIgnored
    private let log = Logger(subsystem: "com.shuiandy.Cadenza", category: "RecordingEngine")

    @ObservationIgnored
    private let dependencies: RecordingEngineDependencies
    @ObservationIgnored
    private let audioFinalizerDependenciesOverride: RecordingAudioFinalizerDependencies?
    @ObservationIgnored
    private var currentSegmentStorageAuthority: SegmentStorageAuthority?

    // MARK: - Observed State

    private(set) var recordingState: RecordingState = .idle
    private(set) var currentRecordingID: UUID?
    private(set) var currentMeetingName: String?
    private(set) var recordingStartDate: Date?
    private(set) var recordingDuration: TimeInterval = 0

    /// Start of the current active segment (reset on resume). Used for pause-aware timing.
    private(set) var currentSegmentStart: Date?
    /// Duration accumulated before the current segment (sum of all completed segments).
    private(set) var pauseAccumulatedDuration: TimeInterval = 0
    private(set) var audioLevel: Float = 0
    var showMicPrompt: Bool = false
    private(set) var missingAPIKeyProvider: AIProvider?
    var showAPIKeyAlert: Bool {
        get { missingAPIKeyProvider != nil }
        set {
            if !newValue { missingAPIKeyProvider = nil }
        }
    }
    var recordingError: String?
    private(set) var recordingErrorOffersSystemAudioSettings = false
    private(set) var hasPreparedSystemAudioCapture = SystemAudioCapturePreparation.isPrepared()
    private(set) var isPreparingSystemAudioCapture = false
    /// Injectable so tests never touch the developer's real `.standard` domain.
    @ObservationIgnored private var systemAudioPreparationDefaults: UserDefaults = .standard
    private(set) var autoStopCountdown: Int = 0
    private(set) var liveTranscriptSegments: [TranscriptSegmentDTO] = []
    private(set) var realtimeHint: String?
    /// Latest raw segments waiting for throttle flush. Stored as lightweight reference,
    /// DTO mapping deferred to flush time to avoid O(n) work on every delta callback.
    private var _pendingRawSegments: [TranscriptSegment]?
    private var _throttleTask: Task<Void, Never>?


    // MARK: - Settings (read directly — no XPC sync needed)

    private var autoRecordEnabled: Bool {
        dependencies.defaults.bool(forKey: "autoRecordMeetings")
    }
    private var defaultCaptureMicrophone: Bool {
        dependencies.defaults.bool(forKey: "captureMicrophone")
    }
    private var effectiveRealtimeTranscriptionLanguage: String {
        dependencies.defaults.string(forKey: "realtimeTranscriptionLanguage")
            ?? dependencies.defaults.string(forKey: "transcriptionLanguage")
            ?? "auto"
    }
    private var autoStopEnabled: Bool {
        dependencies.defaults.bool(forKey: "autoStopOnMicClose")
    }
    private var silenceWatchdogMinutes: Int {
        dependencies.defaults.integer(forKey: "silenceWatchdogMinutes")
    }

    // MARK: - Audio

    let audioMixer = AudioMixer()
    private let transcriptionManager: TranscriptionManager

    // MARK: - Local Store + Post-Processing

    /// Set by AppState after ModelContainer is created.
    var store: RecordingsStore?
    /// Set by AppState after PostProcessingCoordinator is created.
    var coordinator: PostProcessingCoordinator? {
        didSet {
            bindAllIdleObserver(to: recordingProcessingGateForNewRecording)
            rebindPendingMeetingRecordingIntentIfNeeded()
        }
    }

    // MARK: - Timers

    private var durationTimer: DispatchSourceTimer?
    private var autoStopTask: Task<Void, Never>?
    private var autoStopDeadline: Date?
    private var autoStopRequiresMeetingEndConfirmation = false
    private static let authoritativeConfirmationRetryInterval: Duration = .seconds(1)
    private static let maxAuthoritativeConfirmationUnavailableAttempts = 5
    private var audioLevelTimer: DispatchSourceTimer?
#if DEBUG
    private var autoStopTimerDisabledForTesting = false
#endif

    // MARK: - Process Activity

    @ObservationIgnored private let beginProcessActivity: @MainActor () -> any NSObjectProtocol
    @ObservationIgnored private let endProcessActivity: @MainActor (any NSObjectProtocol) -> Void
    @ObservationIgnored private var recordingActivity: (any NSObjectProtocol)?

    /// Refreshes app-owned lifecycle evidence immediately before an
    /// authoritative deadline stops recording.
    @ObservationIgnored var confirmMeetingEndedBeforeAuthoritativeStop: (@MainActor () -> AuthoritativeMeetingEndConfirmation)?

    // MARK: - Meeting Detection State

    private(set) var isMeetingCurrentlyActive = false
    private(set) var detectedMeetingBundleID: String?
    private(set) var detectedMeetingAppName: String?
    private(set) var triggeringMeetingBundleID: String?
    private var detectionCooldownUntil: Date?
    @ObservationIgnored private var autoStopSuppressedForCurrentRecording = false

    /// Latched at start: true iff THIS recording was started by meeting
    /// detection. Deliberately not derived from triggeringMeetingBundleID —
    /// that survives stopRecording() and would misclassify a later manual
    /// recording as auto-started.
    @ObservationIgnored private(set) var currentRecordingIsAutoStarted = false
    /// Which path armed the current auto-stop countdown.
    enum AutoStopSource { case meetingDetection, silenceWatchdog }
    @ObservationIgnored private var autoStopSource: AutoStopSource?
    /// Wired by AppState → MeetingDetector.perProcessMicEverDetectedInSession.
    @ObservationIgnored var isPerProcessMicSessionEverActive: (() -> Bool)?

    /// True iff a recording is currently in flight AND was started by meeting detection.
    /// Used by AppState to decide whether disabling detection should also stop the recording.
    var isCurrentRecordingMeetingTriggered: Bool {
        recordingState != .idle && triggeringMeetingBundleID != nil
    }
    /// Meeting detected while previous recording was still finalizing.
    /// Retried automatically when isStopping clears.
    private var pendingMeetingAutoStart: (bundleID: String, appName: String)?
    @MainActor
    private final class PendingMeetingRecordingIntent {
        let gate: RecordingProcessingGate
        let intent: RecordingProcessingGate.RecordingIntent
        private var isArmed = true

        init(
            gate: RecordingProcessingGate,
            intent: RecordingProcessingGate.RecordingIntent
        ) {
            self.gate = gate
            self.intent = intent
        }

        func disarmForConsumption() -> RecordingProcessingGate.RecordingIntent {
            isArmed = false
            return intent
        }

        func cancel() {
            guard isArmed else { return }
            isArmed = false
            gate.cancelRecordingIntent(intent)
        }

        isolated deinit {
            if isArmed {
                gate.cancelRecordingIntent(intent)
            }
        }
    }
    @ObservationIgnored private var pendingMeetingRecordingIntent: PendingMeetingRecordingIntent?
    @ObservationIgnored private var pendingMeetingAutoStartGeneration: UUID?
    @ObservationIgnored private var scheduledPendingMeetingAutoStartGeneration: UUID?
    @ObservationIgnored private var pendingMeetingAutoStartRetryTask: Task<Void, Never>?

    // MARK: - Start/Stop Guards

    /// Prevents concurrent calls to startRecording() during the async gap
    /// before recordingState is set to .recording. Observable so the UI can
    /// show a "Starting…" affordance during the (potentially multi-second)
    /// window before recordingState flips to .recording.
    private(set) var isStarting = false
    private(set) var isStopping = false

    /// Storage-migration exclusion. The activity lease spans start through
    /// stop finalization; tests inject an isolated gate.
    @ObservationIgnored var migrationGate: StorageMigrationGate = .shared
    @ObservationIgnored private var activityLease: UUID?

    private struct RecordingProcessingClaim {
        let gate: RecordingProcessingGate
        let lease: RecordingProcessingGate.RecordingLease
    }

    /// Standalone engines (primarily focused tests) remain isolated. Once a
    /// coordinator is wired, both services use the coordinator-owned gate.
    @ObservationIgnored private let standaloneRecordingProcessingGate: RecordingProcessingGate
    @ObservationIgnored private var recordingProcessingClaim: RecordingProcessingClaim?
    @ObservationIgnored private weak var observedRecordingProcessingGate: RecordingProcessingGate?
    @ObservationIgnored private var allIdleObserverID: UUID?

    // MARK: - Realtime Reconnect

    private var realtimeReconnectCount = 0
    private let maxRealtimeReconnects = 3
    private var isReconnectingRealtime = false
    @ObservationIgnored private var realtimeStartupTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var currentRealtimeAttemptID: RealtimeAttemptID?
    @ObservationIgnored private var queuedRealtimeFailure: (
        error: any Error,
        provider: AIProvider,
        attemptID: RealtimeAttemptID
    )?
    /// Set when the reconnect budget is exhausted. The failed attempt keeps
    /// ownership of the manager so the saved failure can be replayed through
    /// onRealtimeFailure once speech resumes, granting one fresh attempt
    /// instead of writing off live captions for the rest of the recording.
    @ObservationIgnored private var queuedRealtimeSpeechRetry: (
        error: any Error,
        provider: AIProvider,
        attemptID: RealtimeAttemptID
    )?
    @ObservationIgnored private var lastRealtimeSpeechRetryAt: Date?
    /// Floor between speech-triggered retries so a persistently failing
    /// provider cannot be redialed on every audible poll tick.
    private static let realtimeSpeechRetryMinInterval: TimeInterval = 30
    /// Audio younger than this counts as resumed speech for the retry gate.
    private static let realtimeSpeechRetrySilenceCeiling: TimeInterval = 1.0
    /// The no-delta watchdog only suppresses its failure when the captured
    /// audio was silent for at least this long when it fires — most of the
    /// 8-second watchdog window. Any speech inside the window would have
    /// produced deltas on a healthy stream, so a shorter silence means the
    /// connection is half-open and the failure must be reported.
    private static let realtimeWatchdogSilenceFloor: TimeInterval = 6.0
#if DEBUG
    /// Deterministic scheduling seam for ownership-race regression tests.
    /// Release builds never contain or execute this hook.
    @ObservationIgnored
    var beforeRealtimeStartupDispositionForTesting: (@MainActor @Sendable (UUID) async -> Void)?
#endif
    /// Continuations waiting for the current stop to fully complete (finalize + post-process kick-off).
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    // MARK: - Lifecycle Callbacks (wired by AppState)

    /// Called after recording state transitions to .recording.
    var onRecordingStarted: (() -> Void)?
    /// Called after recording state transitions to .idle.
    var onRecordingStopped: (() -> Void)?

    // MARK: - Init

    init(
        dependencies: RecordingEngineDependencies = .live(),
        transcriptionManager: TranscriptionManager = TranscriptionManager(),
        audioFinalizerDependencies: RecordingAudioFinalizerDependencies? = nil,
        recordingProcessingGate: RecordingProcessingGate = RecordingProcessingGate(),
        beginProcessActivity: @escaping @MainActor () -> any NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Recording meeting audio and monitoring call lifecycle"
            )
        },
        endProcessActivity: @escaping @MainActor (any NSObjectProtocol) -> Void = { activity in
            ProcessInfo.processInfo.endActivity(activity)
        }
    ) {
        self.dependencies = dependencies
        self.transcriptionManager = transcriptionManager
        self.audioFinalizerDependenciesOverride = audioFinalizerDependencies
        self.standaloneRecordingProcessingGate = recordingProcessingGate
        self.beginProcessActivity = beginProcessActivity
        self.endProcessActivity = endProcessActivity
        bindAllIdleObserver(to: recordingProcessingGate)
    }
}

// MARK: - Recording Control

extension RecordingEngine {

    private var recordingProcessingGateForNewRecording: RecordingProcessingGate {
        coordinator?.recordingProcessingGate ?? standaloneRecordingProcessingGate
    }

    private func bindAllIdleObserver(to gate: RecordingProcessingGate) {
        if observedRecordingProcessingGate === gate { return }
        observedRecordingProcessingGate?.removeAllIdleObserver(allIdleObserverID)
        observedRecordingProcessingGate = gate
        allIdleObserverID = gate.observeAllIdle { [weak self, weak gate] in
            guard let self, let gate,
                  self.recordingProcessingGateForNewRecording === gate else { return }
            self.retryPendingMeetingAutoStartIfNeeded()
        }
    }

    private func rebindPendingMeetingRecordingIntentIfNeeded() {
        guard pendingMeetingAutoStart != nil else {
            releasePendingMeetingRecordingIntent()
            return
        }
        guard autoRecordEnabled else {
            releasePendingMeetingRecordingIntent()
            return
        }
        let gate = recordingProcessingGateForNewRecording
        if pendingMeetingRecordingIntent?.gate === gate { return }
        releasePendingMeetingRecordingIntent()
        guard let intent = gate.reserveRecordingIntent() else { return }
        pendingMeetingRecordingIntent = PendingMeetingRecordingIntent(
            gate: gate,
            intent: intent
        )
    }

    private func setPendingMeetingAutoStart(bundleID: String, appName: String) {
        let isSamePendingMeeting = pendingMeetingAutoStart?.bundleID == bundleID
        if !isSamePendingMeeting {
            clearPendingMeetingAutoStart()
            pendingMeetingAutoStartGeneration = UUID()
        } else if pendingMeetingAutoStartGeneration == nil {
            pendingMeetingAutoStartGeneration = UUID()
        }
        pendingMeetingAutoStart = (bundleID: bundleID, appName: appName)
        let gate = recordingProcessingGateForNewRecording
        bindAllIdleObserver(to: gate)
        rebindPendingMeetingRecordingIntentIfNeeded()
    }

    private func releasePendingMeetingRecordingIntent() {
        guard let claim = pendingMeetingRecordingIntent else { return }
        pendingMeetingRecordingIntent = nil
        claim.cancel()
    }

    private func clearPendingMeetingAutoStart() {
        pendingMeetingAutoStart = nil
        pendingMeetingAutoStartGeneration = nil
        scheduledPendingMeetingAutoStartGeneration = nil
        releasePendingMeetingRecordingIntent()
        cancelPendingMeetingAutoStartRetry()
    }

    private func takePendingMeetingAutoStart(
        matching bundleID: String,
        generation: UUID
    ) -> (
        meeting: (bundleID: String, appName: String),
        intent: RecordingProcessingGate.RecordingIntent?
    )? {
        guard let pending = pendingMeetingAutoStart,
              pending.bundleID == bundleID,
              pendingMeetingAutoStartGeneration == generation else { return nil }
        let currentGate = recordingProcessingGateForNewRecording
        guard pendingMeetingRecordingIntent?.gate === currentGate else {
            rebindPendingMeetingRecordingIntentIfNeeded()
            guard pendingMeetingRecordingIntent?.gate === currentGate else {
                clearPendingMeetingAutoStart()
                return nil
            }
            return takePendingMeetingAutoStart(
                matching: bundleID,
                generation: generation
            )
        }

        let intent = pendingMeetingRecordingIntent?.disarmForConsumption()
        pendingMeetingAutoStart = nil
        pendingMeetingAutoStartGeneration = nil
        scheduledPendingMeetingAutoStartGeneration = nil
        pendingMeetingRecordingIntent = nil
        cancelPendingMeetingAutoStartRetry()
        return (pending, intent)
    }

    private func releaseRecordingProcessingClaim() {
        guard let claim = recordingProcessingClaim else { return }
        recordingProcessingClaim = nil
        claim.gate.releaseRecording(claim.lease)
    }

    /// Called by the durable finalizer only after the recording row and audio
    /// publication have committed. The gate handoff is synchronous on the
    /// MainActor, so no third operation can observe an all-idle gap.
    private func transferRecordingToPostProcessing(
        coordinator: PostProcessingCoordinator,
        recordingID: UUID,
        audioURL: URL,
        meetingTitle: String?
    ) async {
        guard let claim = recordingProcessingClaim else {
            NSLog("[RecordingEngine] missing recording lease at post-processing handoff")
            await coordinator.startPostProcessing(
                recordingID: recordingID,
                audioURL: audioURL,
                meetingTitle: meetingTitle
            )
            return
        }
        guard claim.gate === coordinator.recordingProcessingGate else {
            NSLog("[RecordingEngine] coordinator gate changed during recording; refusing non-atomic handoff")
            return
        }
        guard let processingLease = claim.gate.transitionRecordingToProcessing(claim.lease) else {
            NSLog("[RecordingEngine] recording-to-processing lease handoff failed")
            return
        }
        recordingProcessingClaim = nil
        await coordinator.startPostProcessing(
            recordingID: recordingID,
            audioURL: audioURL,
            meetingTitle: meetingTitle,
            inheritedProcessingLease: processingLease
        )
    }

    private var providerResolver: TranscriptionProviderResolver {
        TranscriptionProviderResolver(
            apiKey: dependencies.apiKey,
            supportsAppleLanguage: dependencies.supportsAppleLanguage,
            localWhisperState: {
                let state = self.dependencies.localWhisperState()
                return LocalWhisperState(model: state.model, isAvailable: state.isAvailable)
            }
        )
    }

    func resolveConfiguredBatchTranscriptionProvider(
        language: String
    ) async throws -> TranscriptionProviderSelection {
        try await providerResolver.resolve(
            storedProviderRawValue: dependencies.defaults.string(forKey: "transcriptionProvider"),
            defaultProvider: .apple,
            mode: .postProcessing,
            language: language
        )
    }

    private func startCapture(_ request: RecordingCaptureRequest) async throws -> String? {
        dependencies.recordBoundaryEvent(.captureStart)
        if let override = dependencies.startCapture {
            return try await override(request)
        }
        try await audioMixer.startRecording(
            recordingID: request.recordingID,
            targetBundleID: request.targetBundleID,
            captureMicrophone: request.captureMicrophone
        )
        return audioMixer.currentSegmentsDirectory?.path
    }

    private func startRealtime(_ request: RealtimeStartRequest) async throws {
        dependencies.recordBoundaryEvent(.realtimeStart(preserveSegments: request.preserveSegments))
        if let override = dependencies.startRealtime {
            try await override(request)
            return
        }
        try await transcriptionManager.startRealtime(
            provider: request.configuration.selection.provider,
            apiKey: request.configuration.selection.apiKey ?? "",
            language: request.configuration.language,
            preserveSegments: request.preserveSegments,
            recordingStartTime: request.configuration.recordingStartTime,
            attemptID: request.attemptID
        )
    }

    private func beginRealtimeStop(_ request: RealtimeStopRequest) -> RealtimeStopOperation {
        dependencies.recordBoundaryEvent(.realtimeStop)
        if dependencies.stopRealtime != nil {
            return .dependency(request)
        }
        let handle = transcriptionManager.beginRealtimeStop(
            preserveFailureHandler: request.preserveFailureHandler,
            preserveRealtimeError: request.preserveRealtimeError,
            awaitFinalDeltas: request.awaitFinalDeltas && !request.abandonStartup
        )
        return .manager(handle, request)
    }

    private func finishRealtimeStop(_ operation: RealtimeStopOperation) async {
        switch operation {
        case .manager(let handle, let request):
            await transcriptionManager.finishRealtimeStop(
                handle,
                abandonStartup: request.abandonStartup
            )
        case .dependency(let request):
            await dependencies.stopRealtime?(request)
        }
    }

    private func stopRealtime(_ request: RealtimeStopRequest) async {
        let operation = beginRealtimeStop(request)
        await finishRealtimeStop(operation)
    }

    /// Atomically checks recording ownership and captures the matching realtime
    /// teardown before the next suspension point. A stale startup task must never
    /// perform a delayed global lookup that can discover a replacement session.
    private func beginRealtimeStop(
        ifRecordingIsActive recordingID: UUID,
        matching attemptID: RealtimeAttemptID,
        request: RealtimeStopRequest
    ) -> RealtimeStopOperation? {
        guard isActiveRealtimeRecording(recordingID) else { return nil }
        if dependencies.stopRealtime != nil {
            guard currentRealtimeAttemptID == attemptID else { return nil }
            return beginRealtimeStop(request)
        }

        dependencies.recordBoundaryEvent(.realtimeStop)
        guard let handle = transcriptionManager.beginRealtimeStop(
            matching: attemptID,
            preserveFailureHandler: request.preserveFailureHandler,
            preserveRealtimeError: request.preserveRealtimeError,
            awaitFinalDeltas: request.awaitFinalDeltas && !request.abandonStartup
        ) else { return nil }
        return .manager(handle, request)
    }

    private var realtimeOwnerAttemptID: RealtimeAttemptID? {
        dependencies.stopRealtime != nil
            ? currentRealtimeAttemptID
            : transcriptionManager.currentRealtimeAttemptID
    }

    private func isRealtimeOwner(_ attemptID: RealtimeAttemptID) -> Bool {
        realtimeOwnerAttemptID == attemptID
    }

    private func hasRealtimeOwnerDifferent(from attemptID: RealtimeAttemptID) -> Bool {
        realtimeOwnerAttemptID.map { $0 != attemptID } ?? false
    }

    private func cleanUpRealtimeAttemptIfStillRelevant(
        _ attemptID: RealtimeAttemptID,
        recordingID: UUID,
        request: RealtimeStopRequest
    ) async -> Bool {
        guard isActiveRealtimeRecording(recordingID),
              !hasRealtimeOwnerDifferent(from: attemptID) else { return false }

        if let cleanup = beginRealtimeStop(
            ifRecordingIsActive: recordingID,
            matching: attemptID,
            request: request
        ) {
            await finishRealtimeStop(cleanup)
        }

        guard isActiveRealtimeRecording(recordingID),
              !hasRealtimeOwnerDifferent(from: attemptID) else { return false }
        return true
    }

    func startRecording(
        meetingName: String? = nil,
        captureMicrophone: Bool? = nil,
        skipPermissionPrompt: Bool = false,
        isAutoStarted: Bool = false,
        reservedRecordingIntent: RecordingProcessingGate.RecordingIntent? = nil
    ) async throws {
        let recordingProcessingGate = recordingProcessingGateForNewRecording
        defer {
            // Once consumed this is a no-op. Every pre-claim refusal and failed
            // start releases an unconsumed intent so processing cannot deadlock.
            recordingProcessingGate.cancelRecordingIntent(reservedRecordingIntent)
        }
        // stopRecording() publishes `.idle` before durable audio finalization
        // completes. A manual start during that window must not disappear as a
        // silent no-op while the UI says Ready.
        if isStopping {
            log.notice("startRecording blocked: previous recording is still finalizing")
            throw RecordingStartError.finalizationInProgress
        }

        // Busy paths already represented by visible UI state remain no-ops.
        guard recordingState == .idle, !isStarting, !isPreparingSystemAudioCapture else {
            log.notice("startRecording ignored: already active or starting (state=\(String(describing: self.recordingState), privacy: .public) isStarting=\(self.isStarting, privacy: .public) isStopping=\(self.isStopping, privacy: .public) isPreparingSystemAudio=\(self.isPreparingSystemAudioCapture, privacy: .public))")
            return
        }
        hasPreparedSystemAudioCapture = SystemAudioCapturePreparation.isPrepared(defaults: systemAudioPreparationDefaults)
        guard !isAutoStarted || hasPreparedSystemAudioCapture else {
            log.notice("auto-record blocked until system audio is prepared by a user action")
            throw RecordingStartError.systemAudioNotPrepared
        }

        // Storage-migration exclusion: the lease is held from here until
        // completeStopLifecycle so the root stays stable through the whole
        // recording, including stop finalization.
        guard let lease = migrationGate.claimActivity() else {
            log.notice("startRecording blocked: storage migration in progress")
            throw RecordingStartError.storageMigrationInProgress
        }
        activityLease = lease

        // Claim recording before the first suspension point. The MainActor
        // claim decides ordering against reserved auto-start intents and other
        // recording claims; post-processing already in flight never refuses a
        // new recording, and new processing claims defer until this lease
        // releases.
        let claimedRecordingLease: RecordingProcessingGate.RecordingLease
        var supersededPendingMeetingAutoStart: (bundleID: String, appName: String)?
        if let reservedRecordingIntent {
            guard let recordingLease = recordingProcessingGate.claimRecording(
                consuming: reservedRecordingIntent
            ) else {
                log.notice("startRecording blocked: reserved recording intent cannot be claimed")
                migrationGate.releaseActivity(activityLease)
                activityLease = nil
                throw RecordingStartError.finalizationInProgress
            }
            claimedRecordingLease = recordingLease
        } else {
            // A manual start supersedes a queued auto-start on the same gate:
            // the user is taking over capture right now. MeetingDetector only
            // fires its activity callback on the idle→active transition, so a
            // failed manual start restores the superseded pending meeting
            // below — the ongoing meeting would never re-queue it on its own.
            if !isAutoStarted, pendingMeetingRecordingIntent != nil {
                supersededPendingMeetingAutoStart = pendingMeetingAutoStart
                clearPendingMeetingAutoStart()
            }
            guard let recordingLease = recordingProcessingGate.claimRecording() else {
                log.notice("startRecording blocked: another recording claim is pending")
                migrationGate.releaseActivity(activityLease)
                activityLease = nil
                throw RecordingStartError.finalizationInProgress
            }
            claimedRecordingLease = recordingLease
        }
        recordingProcessingClaim = RecordingProcessingClaim(
            gate: recordingProcessingGate,
            lease: claimedRecordingLease
        )
        var recordingDidStart = false
        defer {
            if !recordingDidStart {
                releaseRecordingProcessingClaim()
                migrationGate.releaseActivity(activityLease)
                activityLease = nil
                // The manual start that superseded a queued auto-start never
                // became a recording. If that meeting is still running, put the
                // pending auto-start back so the meeting isn't silently lost,
                // and schedule the retry explicitly: the gate's all-idle edge
                // fired before this restore, and the detector will not repeat
                // its activity callback for a meeting that is already active.
                // The short delay also keeps a doomed retry from stacking a
                // second error dialog straight onto the manual start's failure.
                if let superseded = supersededPendingMeetingAutoStart,
                   pendingMeetingAutoStart == nil,
                   isMeetingCurrentlyActive {
                    setPendingMeetingAutoStart(
                        bundleID: superseded.bundleID,
                        appName: superseded.appName
                    )
                    schedulePendingMeetingAutoStartRetry(
                        after: dependencies.now().addingTimeInterval(5)
                    )
                }
            }
        }

        cancelRealtimeTasks()
        isStarting = true
        defer { isStarting = false }

        let language = dependencies.defaults.string(forKey: "transcriptionLanguage") ?? "auto"
        _ = try await resolveConfiguredBatchTranscriptionProvider(language: language)

        let wantsMic: Bool
        if let requested = captureMicrophone {
            wantsMic = requested
        } else {
            wantsMic = defaultCaptureMicrophone
        }

        // Request microphone permission only when this recording is meant to
        // include the microphone. A user who turned microphone capture off is
        // explicitly asking for system-audio-only recording and must not see an
        // unrelated TCC prompt. Auto-record still never prompts in the background.
        if wantsMic,
           !skipPermissionPrompt,
           dependencies.microphoneStatus() == .notDetermined {
            let granted = await dependencies.requestMicrophone()
            log.notice("first-time microphone permission: \(granted ? "granted" : "denied", privacy: .public)")
        }

        // Auto-record is an explicit microphone-capture promise. Background
        // meeting detection must never prompt for TCC permission, and silently
        // producing a system-audio-only recording breaks that promise. Fail
        // before touching capture or persistence until the user grants access
        // from Settings or the menu-bar toggle.
        if isAutoStarted, wantsMic, dependencies.microphoneStatus() != .granted {
            throw RecordingEngineError.microphonePermissionRequired
        }

        var shouldCaptureMic = false
        if wantsMic {
            switch dependencies.microphoneStatus() {
            case .granted:
                shouldCaptureMic = true
            case .notDetermined:
                shouldCaptureMic = false
            case .denied:
                log.notice("microphone permission denied, recording without mic")
                recordingError = String(localized: "Microphone access was denied. Enable Cadenza in System Settings → Privacy & Security → Microphone.")
            }
        }

        let recordingID = UUID()
        let title = meetingName
            ?? dependencies.defaults.string(forKey: "_currentCalendarMeetingTitle")
            ?? String(localized: "Untitled Meeting")
        let startDate = dependencies.now()
        let storageRoot = dependencies.storageRoot()
        do {
            try FileManager.default.createDirectory(
                at: storageRoot,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[RecordingEngine] failed to prepare recording storage: %@", error.localizedDescription)
            throw RecordingEngineError.persistenceFailed(
                Self.storagePreparationFailureMessage()
            )
        }
        guard let segmentStorageAuthority = SegmentStorageAuthority.authorize(root: storageRoot) else {
            throw RecordingEngineError.persistenceFailed(
                String(localized: "Cadenza could not authorize the recording storage location.")
            )
        }

        // Clear stale optional-live-transcription feedback from a previous session.
        realtimeHint = nil

        // AudioMixer snapshots this callback when capture starts, so install it
        // before authoritative disk capture. It continues to drop frames until the
        // optional realtime session reports that it is ready.
        let realtimeEnabled = dependencies.defaults.bool(forKey: "enableRealtimeTranscription")
        if realtimeEnabled {
            audioMixer.onTranscriptionAudio = { [weak self, recordingID] data in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.currentRecordingID == recordingID,
                          self.recordingState == .recording || self.recordingState == .paused,
                          self.transcriptionManager.isTranscribing else { return }
                    self.transcriptionManager.sendAudio(data)
                }
            }
        } else {
            audioMixer.onTranscriptionAudio = nil
        }

        // Wire capture error callback to preserve recorded audio instead of losing it.
        audioMixer.onStreamError = { [weak self, recordingID] message in
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentRecordingID == recordingID,
                      self.recordingState == .recording || self.recordingState == .paused else { return }
                self.log.error("audio capture error during recording, triggering graceful stop: \(message, privacy: .public)")
                self.recordingError = Self.captureInterruptionMessage()
                self.stopRecording()
            }
        }

        // Start audio capture (may throw on permission denial)
        // Forward detected meeting app bundle ID so the process tap targets the meeting app.
        let targetBundle = triggeringMeetingBundleID ?? detectedMeetingBundleID
        let segmentsDirectoryPath: String?
        do {
            segmentsDirectoryPath = try await startCapture(
                RecordingCaptureRequest(
                    recordingID: recordingID,
                    targetBundleID: targetBundle,
                    captureMicrophone: shouldCaptureMic
                )
            )
        } catch {
            // Clean up realtime transcription session on audio capture failure
            await stopRealtime(RealtimeStopRequest())
            audioMixer.onTranscriptionAudio = nil
            throw error
        }
        if let segmentsDirectoryPath,
           !segmentStorageAuthority.authorizes(
                segmentsDirectory: URL(fileURLWithPath: segmentsDirectoryPath),
                recordingID: recordingID
           ) {
            await stopRealtime(RealtimeStopRequest())
            audioMixer.onTranscriptionAudio = nil
            audioMixer.forceReset()
            throw RecordingEngineError.persistenceFailed(
                String(
                    localized: "Cadenza couldn't verify the recording storage location. Check the storage location in Settings, then try again."
                )
            )
        }

        // A manual start is a user action. Record preparation only after the
        // process tap has successfully reached AudioDeviceStart.
        if !isAutoStarted {
            SystemAudioCapturePreparation.markPrepared(defaults: systemAudioPreparationDefaults)
            hasPreparedSystemAudioCapture = true
        }

        // Persist Recording to local SwiftData before publishing UI state. Capture has
        // already reached AudioDeviceStart, so a process exit during this await can
        // still leave an unowned segments directory. Closing that crash window safely
        // requires a separate two-phase durable-start design; do not treat UI ordering
        // as recovery coverage.
        let saved = await store?.createRecording(
            id: recordingID,
            title: title,
            startDate: startDate,
            language: language,
            segmentsDirURL: segmentsDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ) ?? false
        if !saved {
            log.error("startRecording: createRecording failed, aborting")
            await stopRealtime(RealtimeStopRequest())
            audioMixer.onTranscriptionAudio = nil
            audioMixer.forceReset()
            throw RecordingEngineError.persistenceFailed(
                String(localized: "The recording could not be created in the database.")
            )
        }

        // Update state — synchronous, no XPC round-trip
        currentRecordingID = recordingID
        currentSegmentStorageAuthority = segmentStorageAuthority
        currentMeetingName = title
        recordingStartDate = startDate
        recordingDuration = 0
        currentSegmentStart = startDate
        pauseAccumulatedDuration = 0
        autoStopSuppressedForCurrentRecording = false
        currentRecordingIsAutoStarted = isAutoStarted
        recordingState = .recording
        recordingDidStart = true
        beginRecordingActivityIfNeeded()
        _throttleTask?.cancel()
        _throttleTask = nil
        _pendingRawSegments = nil
        liveTranscriptSegments = []

        startDurationTimer()
        startAudioLevelPolling()
        onRecordingStarted?()

        // title is the calendar event / meeting name — privacy-sensitive, keep it
        // out of the always-on unified log (it still lands in the opt-in private
        // diagnostics artifact). IDs and flags stay public for debugging.
        log.notice("started: id=\(recordingID.uuidString, privacy: .public) title=\(title, privacy: .private) mic=\(shouldCaptureMic ? 1 : 0, privacy: .public)")

        if realtimeEnabled {
            launchRealtimeStartup(recordingID: recordingID, recordingStartTime: startDate)
        }
    }

    /// Stop recording. Returns immediately (UI sees idle).
    /// Use `stopRecordingAndWait()` to await full finalization.
    func stopRecording() {
        guard recordingState == .recording || recordingState == .paused else {
            NSLog("[RecordingEngine] stopRecording: not recording")
            return
        }
        guard !isStopping else {
            NSLog("[RecordingEngine] stopRecording: already stopping")
            return
        }

        isStopping = true
        cancelRealtimeTasks()
        endRecordingActivityIfNeeded()

        let capturedID = currentRecordingID
        let capturedDuration = recordingDuration
        let capturedMeetingName = currentMeetingName
        let capturedStartDate = recordingStartDate ?? dependencies.now()
        let capturedEndDate = dependencies.now()
        let capturedSegmentStorageAuthority = currentSegmentStorageAuthority

        // Set cooldown so MeetingDetector doesn't immediately re-trigger
        detectionCooldownUntil = Date().addingTimeInterval(10)

        // Revoke this exact realtime generation before scheduling async close.
        // A replacement recording can start while the old provider is flushing.
        let realtimeStop = beginRealtimeStop(RealtimeStopRequest())
        currentRealtimeAttemptID = nil
        transcriptionManager.reset()
        Task { @MainActor [self] in
            await finishRealtimeStop(realtimeStop)
        }

        // Stop timers
        stopDurationTimer()
        stopAudioLevelPolling()
        cancelAutoStop()
        autoStopSuppressedForCurrentRecording = false
        currentRecordingIsAutoStarted = false

        // Update state — UI sees idle immediately (synchronous, no await)
        recordingState = .idle
        currentRecordingID = nil
        currentSegmentStorageAuthority = nil
        currentMeetingName = nil
        recordingStartDate = nil
        onRecordingStopped?()

        NSLog("[RecordingEngine] stopping audio, id=%@", capturedID?.uuidString ?? "nil")

        // Synchronously extract references from AudioMixer (clears its observable state).
        // This keeps UI responsive — no await on MainActor.
        let stopCaptureOverride = dependencies.stopCapture
        let pendingStop = stopCaptureOverride == nil ? audioMixer.beginStop() : nil
        let audioFinalizer = makeNormalStopAudioFinalizer()

        // Audio stop + merge runs off MainActor so the UI is not blocked.
        Task.detached { [weak self] in
            // Phase 1: stop capture + writers (runs off MainActor)
            let phase1Result: AudioMixer.StopPhase1Result
            if let stopCaptureOverride {
                phase1Result = await stopCaptureOverride()
            } else if let pending = pendingStop {
                phase1Result = await AudioMixer.finishStop(pending)
            } else {
                phase1Result = AudioMixer.StopPhase1Result(segmentURLs: [], outputURL: nil, segmentsDirectory: nil)
            }

            guard let id = capturedID else {
                await MainActor.run { [weak self] in
                    self?.completeStopLifecycle()
                }
                return
            }

            let outcome = await audioFinalizer.finalize(
                RecordingAudioFinalizationRequest(
                    origin: .normalStop,
                    recordingID: id,
                    segmentsDirectory: phase1Result.segmentsDirectory,
                    suppliedSegmentURLs: phase1Result.segmentURLs,
                    segmentStorageAuthority: capturedSegmentStorageAuthority,
                    outputURL: phase1Result.outputURL,
                    fallbackDuration: capturedDuration,
                    startDate: capturedStartDate,
                    endDate: capturedEndDate,
                    meetingTitle: capturedMeetingName,
                    mergeTimeoutSeconds: max(120, phase1Result.segmentURLs.count * 5)
                )
            )

            await MainActor.run { [weak self] in
                self?.completeStopLifecycle()
                guard let self else { return }
                NSLog("[RecordingEngine] stopped: id=%@ duration=%.1f audioPath=%@",
                      id.uuidString, outcome.duration, outcome.audioURL?.path ?? "nil")
                if let cleanupWarning = outcome.cleanupWarning {
                    NSLog("[RecordingEngine] exact cleanup preserved recovery evidence: %@", cleanupWarning)
                }
                switch outcome.commitResult {
                case .saved:
                    break
                case .discarded:
                    self.coordinator?.notifyRecordingDiscarded(
                        id: id,
                        reason: String(localized: "The recording was too short and was discarded.")
                    )
                case .failed:
                    self.recordingError = String(localized: "Audio finalization failed. The recording segments are preserved and will be recovered on next launch.")
                }
            }
        }
    }

    private func makeNormalStopAudioFinalizer() -> RecordingAudioFinalizer {
        let store = store
        let coordinator = coordinator
        let baseDependencies = audioFinalizerDependenciesOverride
            ?? RecordingAudioFinalizerDependencies.legacy(
                storeCommit: { request in
                    let result = await store?.finalizeRecording(
                        id: request.finalization.recordingID,
                        duration: request.duration,
                        endDate: request.endDate,
                        audioFileURL: request.audioURL
                    ) ?? .failed
                    switch result {
                    case .saved: return .saved
                    case .discarded: return .discarded
                    case .failed: return .failed
                    }
                },
                postProcess: { _, _ in }
            )
        let wrappedDependencies = RecordingAudioFinalizerDependencies(
            validate: baseDependencies.validate,
            recheckBeforeMerge: baseDependencies.recheckBeforeMerge,
            mergeStage: baseDependencies.mergeStage,
            publish: baseDependencies.publish,
            storeCommit: baseDependencies.storeCommit,
            cleanup: baseDependencies.cleanup,
            cleanupPublished: baseDependencies.cleanupPublished,
            postProcess: { [self] request, audioURL in
                // Preserve an injected finalizer's observation seam, then make
                // the real lifecycle handoff exactly once in the engine.
                await baseDependencies.postProcess(request, audioURL)
                guard let coordinator else { return }
                await self.transferRecordingToPostProcessing(
                    coordinator: coordinator,
                    recordingID: request.recordingID,
                    audioURL: audioURL,
                    meetingTitle: request.meetingTitle
                )
            },
            recordEvent: baseDependencies.recordEvent
        )

        return RecordingAudioFinalizer(dependencies: wrappedDependencies)
    }

    private func completeStopLifecycle() {
        isStopping = false
        migrationGate.releaseActivity(activityLease)
        activityLease = nil
        // Saved recordings transfer this lease to their processing job inside
        // the finalizer. Discard/failure/no-coordinator paths release it here,
        // after durable finalization has returned.
        releaseRecordingProcessingClaim()
        resumeStopContinuations()
        retryPendingMeetingAutoStartIfNeeded()
    }

    /// Stop recording and wait for audio stop + merge + finalize + post-process kick-off.
    func stopRecordingAndWait() async {
        if recordingState == .recording || recordingState == .paused {
            stopRecording()
        }
        guard isStopping else { return }
        await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
        }
    }

    private func resumeStopContinuations() {
        let continuations = stopContinuations
        stopContinuations.removeAll()
        for c in continuations { c.resume() }
    }

    func pauseRecording() {
        guard recordingState == .recording else { return }
        // Accumulate the current segment's duration before pausing
        if let segStart = currentSegmentStart {
            pauseAccumulatedDuration += Date().timeIntervalSince(segStart)
        }
        currentSegmentStart = nil
        recordingState = .paused
        audioMixer.isPaused = true
        stopDurationTimer()
    }

    func resumeRecording() {
        guard recordingState == .paused else { return }
        currentSegmentStart = Date()
        recordingState = .recording
        audioMixer.isPaused = false
        audioMixer.resetSilenceTracking()
        startDurationTimer()
    }

    func dismissMicPrompt() {
        showMicPrompt = false
    }

    /// Prime the process tap from an explicit user action without creating a
    /// recording. There is intentionally no public authorization preflight.
    func prepareSystemAudioCapture() async throws {
        guard recordingState == .idle, !isStarting, !isStopping else {
            throw ProcessTapCaptureError.operationFailed(
                String(localized: "Stop the current recording before setting up System Audio Recording.")
            )
        }
        guard !isPreparingSystemAudioCapture else { return }

        isPreparingSystemAudioCapture = true
        defer { isPreparingSystemAudioCapture = false }

        try await audioMixer.prepareSystemAudioCapture()
        SystemAudioCapturePreparation.markPrepared(defaults: systemAudioPreparationDefaults)
        hasPreparedSystemAudioCapture = true
        log.notice("system audio preparation succeeded from a user action")
    }

    func refreshSystemAudioCapturePreparation() {
        hasPreparedSystemAudioCapture = SystemAudioCapturePreparation.isPrepared(defaults: systemAudioPreparationDefaults)
    }

    /// Surface a `startRecording` failure to the user via the right channel.
    /// `noTranscriptionKey` already raised the dedicated "需要 API Key" sheet
    /// (via `showAPIKeyAlert`) inside `startRecording`, so we must NOT also set
    /// `recordingError` for it — that would stack two alerts. Everything else
    /// goes through the generic `recordingError` alert.
    func presentStartError(_ error: Error) {
        recordingErrorOffersSystemAudioSettings = false
        if let resolutionError = error as? TranscriptionProviderResolutionError,
           case .missingAPIKey(let provider) = resolutionError {
            recordingError = nil
            missingAPIKeyProvider = provider
            return
        }

        if let startError = error as? RecordingStartError, startError == .noTranscriptionKey {
            // showAPIKeyAlert already set; nothing more to do.
            return
        }

        missingAPIKeyProvider = nil
        if let startError = error as? RecordingStartError,
           startError == .systemAudioNotPrepared {
            recordingErrorOffersSystemAudioSettings = true
            recordingError = startError.localizedDescription
            return
        }

        if let startError = error as? RecordingStartError {
            recordingError = startError.localizedDescription
            return
        }

        if let resolutionError = error as? TranscriptionProviderResolutionError {
            recordingError = resolutionError.localizedDescription
            return
        }

        if let engineError = error as? RecordingEngineError {
            recordingError = engineError.localizedDescription
            return
        }

        if error is AudioMixerError {
            recordingError = String(localized: "Recording in Progress")
            return
        }

        if error is ProcessTapCaptureError {
            recordingErrorOffersSystemAudioSettings = true
            recordingError = String(
                localized: "Cadenza couldn't start system audio capture. Check System Audio Recording access in System Settings, then try again."
            )
            return
        }

        if error is MicrophoneCoreAudioError || error is AudioCaptureError {
            recordingError = String(
                localized: "Cadenza couldn't start the microphone. Check the selected microphone and Microphone access in System Settings, then try again."
            )
            return
        }

        // The raw fallback often contains AVFoundation implementation detail
        // or an untranslated OSStatus operation name. Keep that detail in the
        // log, but show stable localized guidance at the user boundary.
        NSLog("[RecordingEngine] start failed: %@", error.localizedDescription)
        recordingError = String(localized: "Cadenza couldn't start recording. Try again.")
    }

    func dismissRecordingError() {
        recordingError = nil
        recordingErrorOffersSystemAudioSettings = false
    }

    static func captureInterruptionMessage(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "Audio capture was interrupted. The recording was saved. Check your audio settings before recording again.",
            locale: locale
        )
    }

    static func storagePreparationFailureMessage(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "Cadenza couldn't prepare the recording storage folder. Check the storage location in Settings, then try again.",
            locale: locale
        )
    }

    func cancelAutoStop() {
        if autoStopDeadline != nil || autoStopCountdown > 0 {
            writeAutoStopDiagnostic("cancelAutoStop countdown=\(autoStopCountdown) state=\(recordingState)")
        }
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopDeadline = nil
        autoStopRequiresMeetingEndConfirmation = false
        autoStopCountdown = 0
        autoStopSource = nil
    }

    func keepRecordingAndCancelAutoStop() {
        if recordingState == .recording || recordingState == .paused {
            autoStopSuppressedForCurrentRecording = true
            isMeetingCurrentlyActive = true
            NSLog("[RecordingEngine] keepRecording: auto-stop suppressed for current recording")
            writeAutoStopDiagnostic("keepRecording suppressAutoStop state=\(recordingState) countdown=\(autoStopCountdown)")
        }
        cancelAutoStop()
    }

    /// Last-resort reset — clears all state and stops audio capture.
    func forceReset() {
        cancelRealtimeTasks()
        let realtimeStop = beginRealtimeStop(RealtimeStopRequest())
        currentRealtimeAttemptID = nil
        transcriptionManager.reset()
        endRecordingActivityIfNeeded()
        stopDurationTimer()
        stopAudioLevelPolling()
        cancelAutoStop()
        audioMixer.forceReset()
        Task { @MainActor [self] in
            await finishRealtimeStop(realtimeStop)
        }
        _throttleTask?.cancel()
        _throttleTask = nil
        _pendingRawSegments = nil
        liveTranscriptSegments = []
        realtimeHint = nil
        realtimeReconnectCount = 0
        recordingState = .idle
        currentRecordingID = nil
        currentSegmentStorageAuthority = nil
        currentMeetingName = nil
        recordingStartDate = nil
        recordingDuration = 0
        currentSegmentStart = nil
        pauseAccumulatedDuration = 0
        audioLevel = 0
        isStopping = false
        // The last-resort reset bypasses completeStopLifecycle, so the
        // migration lease is released here as well. Releasing twice is
        // harmless: the lease is nil-ed on release and releasing nil is a
        // no-op, which also keeps the start-failure defer safe.
        migrationGate.releaseActivity(activityLease)
        activityLease = nil
        clearPendingMeetingAutoStart()
        releaseRecordingProcessingClaim()
        autoStopSuppressedForCurrentRecording = false
        currentRecordingIsAutoStarted = false
    }

    // MARK: - Realtime Transcription

    private func launchRealtimeStartup(recordingID: UUID, recordingStartTime: Date) {
        realtimeStartupTask?.cancel()
        realtimeStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startRealtimeTranscription(
                recordingID: recordingID,
                recordingStartTime: recordingStartTime
            )
        }
    }

    private func cancelRealtimeTasks() {
        realtimeStartupTask?.cancel()
        realtimeStartupTask = nil
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        isReconnectingRealtime = false
        queuedRealtimeFailure = nil
        queuedRealtimeSpeechRetry = nil
        lastRealtimeSpeechRetryAt = nil
    }

    /// Called from the audio-level poll. When reconnects were exhausted during
    /// silence, resumed speech re-arms exactly one attempt: the saved terminal
    /// failure is replayed with the budget rewound to one below the cap. If the
    /// revived stream delivers a delta, onRealtimeStreamHealthy refills the
    /// budget in full; if it fails again, the give-up branch re-queues here.
    /// `sustainedSilence` is the system-track duration: only audio the provider
    /// actually receives counts as resumed speech worth redialing for.
    private func retryRealtimeOnSpeechIfNeeded(sustainedSilence: TimeInterval) {
        guard recordingState == .recording,
              let retry = queuedRealtimeSpeechRetry,
              sustainedSilence < Self.realtimeSpeechRetrySilenceCeiling else { return }
        let now = dependencies.now()
        if let last = lastRealtimeSpeechRetryAt,
           now.timeIntervalSince(last) < Self.realtimeSpeechRetryMinInterval {
            return
        }
        queuedRealtimeSpeechRetry = nil
        lastRealtimeSpeechRetryAt = now
        realtimeReconnectCount = maxRealtimeReconnects - 1
        log.notice("speech resumed after realtime gave up, retrying live transcription")
        transcriptionManager.onRealtimeFailure?(retry.error, retry.provider, retry.attemptID)
    }

    private func isActiveRealtimeRecording(_ recordingID: UUID) -> Bool {
        currentRecordingID == recordingID
            && (recordingState == .recording || recordingState == .paused)
    }

    private func awaitRealtimeStartupDispositionForTesting(_ recordingID: UUID) async {
#if DEBUG
        await beforeRealtimeStartupDispositionForTesting?(recordingID)
#endif
    }

    private func startRealtimeTranscription(
        recordingID: UUID,
        recordingStartTime: Date
    ) async {
        defer {
            if currentRecordingID == recordingID {
                realtimeStartupTask = nil
            }
        }
        guard !Task.isCancelled, isActiveRealtimeRecording(recordingID) else { return }

        let language = effectiveRealtimeTranscriptionLanguage
        let configuration: RealtimeTranscriptionConfiguration
        do {
            configuration = try await resolveConfiguredRealtimeConfiguration(
                recordingID: recordingID,
                recordingStartTime: recordingStartTime,
                language: language
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isActiveRealtimeRecording(recordingID) else { return }
            log.notice("realtime provider configuration unavailable: \(error.localizedDescription, privacy: .public)")
            realtimeHint = realtimeUnavailableHint(error.localizedDescription)
            return
        }

        guard !Task.isCancelled, isActiveRealtimeRecording(recordingID) else { return }
        transcriptionManager.onSegmentsChanged = { [weak self] segments in
            guard let self else { return }
            // Stash raw segments (cheap copy of struct array). DTO mapping deferred to flush.
            self._pendingRawSegments = segments
            // Throttle UI flush to once per second
            if self._throttleTask == nil {
                self._throttleTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    if let raw = self._pendingRawSegments {
                        self.liveTranscriptSegments = raw.enumerated().map { index, seg in
                            TranscriptSegmentDTO(
                                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index))")!,
                                timestamp: seg.timestamp,
                                text: seg.text, isFinal: seg.isFinal, speaker: seg.speaker
                            )
                        }
                    }
                    self._pendingRawSegments = nil
                    self._throttleTask = nil
                }
            }
        }

        transcriptionManager.onRealtimeStreamHealthy = { [weak self] in
            guard let self,
                  self.isActiveRealtimeRecording(configuration.recordingID) else { return }
            // A delta proves this stream works end to end. Refill the budget so
            // scattered one-off faults across a long recording never accumulate
            // into the reconnect cap. The give-up branch leaves its stream open,
            // so a session can recover this way with the interruption hint still
            // showing — clear it, the banner is stale the moment text arrives.
            self.realtimeReconnectCount = 0
            self.queuedRealtimeSpeechRetry = nil
            self.realtimeHint = nil
        }

        transcriptionManager.realtimeAudioIsSilent = { [weak self] in
            guard let self else { return true }
            // System track only: it is the sole track fed to the provider, so
            // local mic noise must not read as "speech went untranscribed".
            return self.audioMixer.systemAudioSustainedSilenceDuration >= Self.realtimeWatchdogSilenceFloor
        }

        transcriptionManager.onRealtimeFailure = { [weak self] error, failedProvider, failedAttemptID in
            guard let self,
                  failedProvider == configuration.selection.provider,
                  self.isActiveRealtimeRecording(configuration.recordingID) else { return }

            guard self.isRealtimeOwner(failedAttemptID) else {
                self.log.notice("stale realtime failure ignored because another attempt owns the manager")
                return
            }

            guard !self.isReconnectingRealtime else {
                // A replacement stream can terminate before its start call has
                // returned. Coalesce that exact terminal event and replay it once
                // the current reconnect task releases its in-flight guard.
                self.queuedRealtimeFailure = (error, failedProvider, failedAttemptID)
                self.log.notice("realtime failure queued (reconnect already in-flight)")
                return
            }

            guard self.realtimeReconnectCount < self.maxRealtimeReconnects else {
                self.log.error("max realtime reconnect attempts reached, pausing until speech resumes — recording unaffected")
                self.realtimeHint = String(localized: "Live transcription interrupted. It will retry when the conversation resumes. Recording continues normally.")
                self.queuedRealtimeSpeechRetry = (error, failedProvider, failedAttemptID)
                return
            }
            self.realtimeReconnectCount += 1
            self.isReconnectingRealtime = true

            self.log.notice("realtime stream failed (\(failedProvider.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .private), reconnect \(self.realtimeReconnectCount, privacy: .public)/\(self.maxRealtimeReconnects, privacy: .public)")

            self.realtimeReconnectTask?.cancel()
            self.realtimeReconnectTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.currentRecordingID == configuration.recordingID {
                        self.isReconnectingRealtime = false
                        self.realtimeReconnectTask = nil
                        if let queuedFailure = self.queuedRealtimeFailure {
                            self.queuedRealtimeFailure = nil
                            self.transcriptionManager.onRealtimeFailure?(
                                queuedFailure.error,
                                queuedFailure.provider,
                                queuedFailure.attemptID
                            )
                        }
                    } else {
                        self.queuedRealtimeFailure = nil
                    }
                }
                do {
                    try await Task.sleep(for: self.dependencies.reconnectDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.isActiveRealtimeRecording(configuration.recordingID) else { return }

                guard let failedAttemptStop = self.beginRealtimeStop(
                    ifRecordingIsActive: configuration.recordingID,
                    matching: failedAttemptID,
                    request: RealtimeStopRequest(preserveFailureHandler: true)
                ) else {
                    self.log.notice("realtime reconnect abandoned because the failed attempt no longer owns the manager")
                    return
                }
                await self.finishRealtimeStop(failedAttemptStop)
                guard !Task.isCancelled,
                      self.isActiveRealtimeRecording(configuration.recordingID) else { return }
                let reconnectAttemptID = RealtimeAttemptID()
                self.currentRealtimeAttemptID = reconnectAttemptID
                do {
                    let request = RealtimeStartRequest(
                        configuration: configuration,
                        preserveSegments: true,
                        attemptID: reconnectAttemptID
                    )
                    try await Self.withRealtimeStartTimeout(
                        timeout: self.dependencies.realtimeStartTimeout
                    ) { [weak self] in
                        guard let self else { return }
                        try await self.startRealtime(request)
                    }
                    guard !Task.isCancelled,
                          self.isActiveRealtimeRecording(configuration.recordingID),
                          !self.hasRealtimeOwnerDifferent(from: reconnectAttemptID),
                          self.queuedRealtimeFailure?.attemptID != reconnectAttemptID else { return }
                    self.log.notice("realtime transcription reconnected with \(configuration.selection.provider.rawValue, privacy: .public)")
                    self.realtimeHint = nil
                } catch is RealtimeSessionBusyError {
                    self.log.notice("realtime reconnect skipped because another session already owns the manager")
                } catch is CancellationError {
                    return
                } catch is RealtimeStartTimeout {
                    self.log.error("realtime reconnect timed out — recording unaffected")
                    guard await self.cleanUpRealtimeAttemptIfStillRelevant(
                        reconnectAttemptID,
                        recordingID: configuration.recordingID,
                        request: RealtimeStopRequest(
                            preserveFailureHandler: true,
                            abandonStartup: true
                        )
                    ) else { return }
                    self.realtimeHint = String(localized: "Live transcription disconnected. Recording continues normally.")
                } catch {
                    self.log.error("realtime reconnect failed: \(error.localizedDescription, privacy: .private) — recording unaffected")
                    guard await self.cleanUpRealtimeAttemptIfStillRelevant(
                        reconnectAttemptID,
                        recordingID: configuration.recordingID,
                        request: RealtimeStopRequest(
                            preserveFailureHandler: true,
                            abandonStartup: true
                        )
                    ) else { return }
                    self.realtimeHint = String(localized: "Live transcription disconnected. Recording continues normally.")
                }
            }
        }

        let attemptID = RealtimeAttemptID()
        currentRealtimeAttemptID = attemptID
        let request = RealtimeStartRequest(
            configuration: configuration,
            preserveSegments: false,
            attemptID: attemptID
        )
        do {
            try await Self.withRealtimeStartTimeout(
                timeout: dependencies.realtimeStartTimeout
            ) { [weak self] in
                guard let self else { return }
                try await self.startRealtime(request)
            }
            await awaitRealtimeStartupDispositionForTesting(recordingID)
            guard !Task.isCancelled, isActiveRealtimeRecording(recordingID) else {
                if let cleanup = beginRealtimeStop(
                    ifRecordingIsActive: recordingID,
                    matching: attemptID,
                    request: RealtimeStopRequest(abandonStartup: true)
                ) {
                    await finishRealtimeStop(cleanup)
                }
                return
            }
            currentRealtimeAttemptID = attemptID
            realtimeReconnectCount = 0
            log.notice("realtime transcription started with \(configuration.selection.provider.rawValue, privacy: .public)")
        } catch is RealtimeSessionBusyError {
            // A duplicate/stale startup must not report success, clear the hint,
            // or tear down the session that already owns the manager.
            log.notice("realtime startup skipped because another session already owns the manager")
            return
        } catch is CancellationError {
            return
        } catch is RealtimeStartTimeout {
            await awaitRealtimeStartupDispositionForTesting(recordingID)
            log.error("realtime transcription start timed out — continuing recording without live transcript")
            guard await cleanUpRealtimeAttemptIfStillRelevant(
                attemptID,
                recordingID: recordingID,
                request: RealtimeStopRequest(abandonStartup: true)
            ) else { return }
            realtimeHint = String(localized: "Live transcription unavailable: connection timed out. Recording continues normally.")
        } catch {
            await awaitRealtimeStartupDispositionForTesting(recordingID)
            log.error("realtime transcription failed: \(error.localizedDescription, privacy: .private) — continuing recording without live transcript")
            guard await cleanUpRealtimeAttemptIfStillRelevant(
                attemptID,
                recordingID: recordingID,
                request: RealtimeStopRequest(abandonStartup: true)
            ) else { return }
            realtimeHint = String(
                localized: "Live transcription unavailable. Check the selected provider settings or network connection. Recording continues normally."
            )
        }
    }

    func resolveConfiguredRealtimeConfiguration(
        recordingID: UUID,
        recordingStartTime: Date,
        language: String
    ) async throws -> RealtimeTranscriptionConfiguration {
        let selection = try await providerResolver.resolve(
            storedProviderRawValue: dependencies.defaults.string(forKey: "realtimeTranscriptionProvider"),
            defaultProvider: .openai,
            mode: .realtime,
            language: language
        )
        return RealtimeTranscriptionConfiguration(
            selection: selection,
            language: language,
            recordingID: recordingID,
            recordingStartTime: recordingStartTime
        )
    }

    private func realtimeUnavailableHint(_ reason: String) -> String {
        String(
            format: String(localized: "Live transcription unavailable: %@ Recording continues normally."),
            reason
        )
    }

    /// Marker error for realtime-session startup timeout.
    private struct RealtimeStartTimeout: Error {}

    /// Run `operation` with a hard deadline. Both initial startup and every
    /// reconnect use this exact wrapper so a non-cooperative provider handshake
    /// cannot leave the recording state machine permanently reconnecting.
    private static func withRealtimeStartTimeout(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        do {
            try await HardAsyncDeadline.run(for: timeout, operation: operation)
        } catch is HardAsyncDeadlineExceeded {
            throw RealtimeStartTimeout()
        }
    }

    /// Integer-seconds convenience retained for focused timeout contract tests.
    private static func withRealtimeStartTimeout(
        seconds: Int,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await withRealtimeStartTimeout(
            timeout: .seconds(seconds),
            operation: operation
        )
    }

    // MARK: - Private Audio Stop

}

// MARK: - Timers

private extension RecordingEngine {

    func startDurationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            // Already on main queue — use assumeIsolated to avoid async Task dispatch,
            // which can batch/delay under load and cause the timer to appear frozen.
            MainActor.assumeIsolated {
                guard let self, let segStart = self.currentSegmentStart else { return }
                self.recordingDuration = self.pauseAccumulatedDuration + Date().timeIntervalSince(segStart)
                self.silenceWatchdogTick()
            }
        }
        timer.resume()
        durationTimer = timer
    }

    func stopDurationTimer() {
        durationTimer?.cancel()
        durationTimer = nil
    }

    func startAudioLevelPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recordingState == .recording else { return }
                let level = self.audioMixer.currentAudioLevel
                if abs(level - self.audioLevel) > 0.02 {
                    self.audioLevel = level
                }
                self.retryRealtimeOnSpeechIfNeeded(
                    sustainedSilence: self.audioMixer.systemAudioSustainedSilenceDuration
                )
            }
        }
        timer.resume()
        audioLevelTimer = timer
    }

    func stopAudioLevelPolling() {
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        audioLevel = 0
    }

    private func beginRecordingActivityIfNeeded() {
        guard recordingActivity == nil else { return }
        recordingActivity = beginProcessActivity()
        NSLog("[RecordingEngine] recording process activity started")
    }

    private func endRecordingActivityIfNeeded() {
        guard let activity = recordingActivity else { return }
        recordingActivity = nil
        endProcessActivity(activity)
        NSLog("[RecordingEngine] recording process activity ended")
    }

    func startAutoStopCountdown(
        source: AutoStopSource = .meetingDetection,
        countdownStart: Date = Date(),
        requiresMeetingEndConfirmation: Bool = false
    ) {
        guard autoStopDeadline == nil else { return }
        autoStopSource = source
        autoStopRequiresMeetingEndConfirmation = requiresMeetingEndConfirmation
        let now = Date()
        let deadline = countdownStart.addingTimeInterval(5)
        autoStopDeadline = deadline
        autoStopCountdown = countdownStart > now
            ? 0
            : max(0, Int(ceil(deadline.timeIntervalSince(now))))
        writeAutoStopDiagnostic("startAutoStopCountdown state=\(recordingState) countdownStart=\(ISO8601DateFormatter().string(from: countdownStart)) meetingActive=\(isMeetingCurrentlyActive ? 1 : 0) detectedBundle=\(detectedMeetingBundleID ?? "nil") triggeringBundle=\(triggeringMeetingBundleID ?? "nil") deadline=\(ISO8601DateFormatter().string(from: deadline))")

#if DEBUG
        if autoStopTimerDisabledForTesting {
            return
        }
#endif

        autoStopTask = Task { @MainActor [weak self] in
            var unavailableConfirmationAttempts = 0
            while !Task.isCancelled {
                guard let self else { return }
                guard self.autoStopDeadline == deadline else { return }
                let currentTime = Date()
                let deadlineElapsed = currentTime >= deadline
                let remaining: Int
                if currentTime < countdownStart {
                    remaining = 0
                } else {
                    remaining = max(0, Int(ceil(deadline.timeIntervalSince(currentTime))))
                }

                if self.autoStopCountdown != remaining {
                    self.autoStopCountdown = remaining
                    self.writeAutoStopDiagnostic("countdownTick remaining=\(remaining) state=\(self.recordingState)")
                }

                if deadlineElapsed {
                    if self.autoStopRequiresMeetingEndConfirmation {
                        let confirmation = self.confirmMeetingEndedBeforeAuthoritativeStop?() ?? .unavailable

                        // Process reconciliation can synchronously terminate the
                        // app and cancel this generation. Never act on its stale
                        // confirmation afterward.
                        guard self.autoStopDeadline == deadline else { return }

                        switch confirmation {
                        case .ended:
                            break
                        case .ongoing:
                            NSLog("[RecordingEngine] authoritative auto-stop cancelled: Teams call is active")
                            self.writeAutoStopDiagnostic("authoritativeDeadlineCancelled result=ongoing state=\(self.recordingState)")
                            self.cancelAutoStop()
                            return
                        case .unavailable:
                            unavailableConfirmationAttempts += 1
                            if unavailableConfirmationAttempts
                                >= Self.maxAuthoritativeConfirmationUnavailableAttempts {
                                // The release was already observed authoritatively.
                                // A bounded query outage must not discard it and
                                // leave the recording running forever.
                                NSLog("[RecordingEngine] authoritative confirmation unavailable after retries; honoring observed Teams release")
                                self.writeAutoStopDiagnostic("authoritativeDeadlineUnavailableFallback attempts=\(unavailableConfirmationAttempts) state=\(self.recordingState)")
                                break
                            }
                            self.writeAutoStopDiagnostic("authoritativeDeadlineRetryUnavailable attempt=\(unavailableConfirmationAttempts) state=\(self.recordingState)")
                            do {
                                try await Task.sleep(for: Self.authoritativeConfirmationRetryInterval)
                            } catch {
                                return
                            }
                            continue
                        }
                    }
                    self.cancelAutoStop()
                    self.stopRecording()
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func silenceWatchdogTick() {
        guard recordingState == .recording else { return }
        let thresholdMinutes = silenceWatchdogMinutes
        guard thresholdMinutes > 0 else { return }
        let silence = audioMixer.sustainedSilenceDuration
        let threshold = TimeInterval(thresholdMinutes * 60)

        // A watchdog countdown must self-cancel when audio resumes: in the
        // silent-tail scenario the detector stays .active the whole time, so
        // handleMeetingRecovered (the normal cancel path) never fires.
        if autoStopDeadline != nil {
            if autoStopSource == .silenceWatchdog && silence < threshold {
                NSLog("[RecordingEngine] silenceWatchdog: audio resumed during countdown, cancelling")
                writeAutoStopDiagnostic("silenceWatchdogCancelled audioResumed silence=\(Int(silence))")
                cancelAutoStop()
            }
            return
        }

        let policy = SilenceWatchdogPolicy(
            thresholdMinutes: thresholdMinutes,
            autoStopEnabled: autoStopEnabled,
            isAutoStartedRecording: currentRecordingIsAutoStarted,
            perProcessMicEverActive: isPerProcessMicSessionEverActive?() ?? false,
            suppressedByUser: autoStopSuppressedForCurrentRecording
        )
        if policy.shouldTrigger(silenceDuration: silence) {
            log.notice("silence watchdog: \(Int(silence), privacy: .public)s sustained silence, starting auto-stop countdown")
            writeAutoStopDiagnostic("silenceWatchdogTrigger silence=\(Int(silence)) thresholdMin=\(thresholdMinutes)")
            startAutoStopCountdown(source: .silenceWatchdog)
        }
    }
}

// MARK: - Meeting Detection (called directly from AppState — no XPC)

extension RecordingEngine {

    /// Called when MeetingDetector transitions to .active.
    func handleMeetingActivity(
        bundleID: String,
        appName: String,
        reason: MeetingActivityReason = .signals
    ) {
        let previousDetectedBundleID = detectedMeetingBundleID
        let previousTriggeringBundleID = triggeringMeetingBundleID
        isMeetingCurrentlyActive = true
        detectedMeetingBundleID = bundleID
        detectedMeetingAppName = appName

        // A fresh active transition can represent a rapid reconnect/redial
        // after the detector already confirmed the previous call ended. Do not
        // let that call inherit the previous session's pending auto-stop.
        if (recordingState == .recording || recordingState == .paused),
           autoStopDeadline != nil {
            let isSameAuthoritativeTeamsSession = autoStopRequiresMeetingEndConfirmation
                && (bundleID == previousTriggeringBundleID || bundleID == previousDetectedBundleID)
            let shouldPreserveAuthoritativeDeadline = isSameAuthoritativeTeamsSession
                && reason != .teamsCallAssertionActive

            if shouldPreserveAuthoritativeDeadline {
                // Retained calendar/system-mic evidence can manufacture an
                // idle → active callback after Teams' assertion already
                // released. Keep the deadline and let its fresh app-owned
                // confirmation distinguish that false recovery from a redial.
                NSLog("[RecordingEngine] handleMeetingActivity: preserving authoritative Teams deadline")
                writeAutoStopDiagnostic("handleMeetingActivity preserveAuthoritativeDeadline reason=\(reason.rawValue) state=\(recordingState) bundle=\(bundleID)")
            } else {
                if currentRecordingIsAutoStarted {
                    triggeringMeetingBundleID = bundleID
                }
                NSLog("[RecordingEngine] handleMeetingActivity: cancelling stale auto-stop for active meeting")
                writeAutoStopDiagnostic("handleMeetingActivity cancelPendingAutoStop reason=\(reason.rawValue) state=\(recordingState) previousTrigger=\(previousTriggeringBundleID ?? "nil") newTrigger=\(triggeringMeetingBundleID ?? "nil")")
                cancelAutoStop()
            }
        }

        if isStopping {
            NSLog("[RecordingEngine] handleMeetingActivity: still finalizing previous recording, will retry when ready")
            setPendingMeetingAutoStart(bundleID: bundleID, appName: appName)
            return
        }

        if let cooldown = detectionCooldownUntil, Date() < cooldown {
            NSLog("[RecordingEngine] handleMeetingActivity: in cooldown, will retry when ready")
            setPendingMeetingAutoStart(bundleID: bundleID, appName: appName)
            schedulePendingMeetingAutoStartRetry(after: cooldown)
            return
        }

        if pendingMeetingAutoStart != nil {
            clearPendingMeetingAutoStart()
        }

        guard recordingState == .idle, !isStarting else { return }

        if autoRecordEnabled {
            triggeringMeetingBundleID = bundleID
            log.notice("auto-starting recording for \(appName, privacy: .public)")
            // Reserve synchronously before scheduling the async start. A
            // deferred processing drain may already be queued on this same
            // all-idle edge, but it cannot overtake the recording intent.
            setPendingMeetingAutoStart(bundleID: bundleID, appName: appName)
            schedulePendingMeetingAutoStart(for: bundleID)
        } else {
            log.notice("showing mic prompt for \(appName, privacy: .public)")
            showMicPrompt = true
        }
    }

    /// Called when a meeting app terminates.
    /// App termination is a definitive signal — stop immediately, no countdown.
    func handleMeetingTerminated(bundleID: String) {
        let terminatedTriggeringRecording = bundleID == triggeringMeetingBundleID
        let terminatedDetectedMeeting = bundleID == detectedMeetingBundleID
        let terminatedPendingMeeting = bundleID == pendingMeetingAutoStart?.bundleID
        guard terminatedTriggeringRecording
            || terminatedDetectedMeeting
            || terminatedPendingMeeting else { return }

        // The recording being finalized and the detector's latest meeting can
        // belong to different apps. Scope every cleanup to the terminated app
        // so a late termination for meeting A cannot erase live meeting B.
        if terminatedDetectedMeeting {
            isMeetingCurrentlyActive = false
            detectedMeetingBundleID = nil
            detectedMeetingAppName = nil
        }
        if terminatedPendingMeeting {
            clearPendingMeetingAutoStart()
        }

        let shouldStopCurrentRecording = (terminatedTriggeringRecording || terminatedDetectedMeeting)
            && (recordingState == .recording || recordingState == .paused)
            && autoStopEnabled
        if terminatedTriggeringRecording {
            triggeringMeetingBundleID = nil
        }
        if shouldStopCurrentRecording {
            autoStopSuppressedForCurrentRecording = false
        }
        NSLog(
            "[RecordingEngine] handleMeetingTerminated: bundleID=%@ stopCurrent=%d",
            bundleID,
            shouldStopCurrentRecording ? 1 : 0
        )
        writeAutoStopDiagnostic("handleMeetingTerminated bundleID=\(bundleID) state=\(recordingState) autoStop=\(autoStopEnabled ? 1 : 0)")

        if shouldStopCurrentRecording {
            cancelAutoStop()
            stopRecording()
        }
    }

    /// Called when MeetingDetector enters ending state. Heuristic drops wait for
    /// the detector's grace confirmation. Teams' own released call assertion is
    /// app-owned end evidence, so it may safely register a wall-clock deadline
    /// immediately without risking a false stop during ordinary signal jitter.
    func handleMeetingEnding(_ event: MeetingEndingEvent) {
        guard recordingState == .recording || recordingState == .paused, autoStopEnabled else { return }
        guard !autoStopSuppressedForCurrentRecording else { return }
        guard event.reason.allowsAuthoritativeAutoStopDeadline else {
            NSLog("[RecordingEngine] handleMeetingEnding: waiting for detector grace reason=%@", event.reason.rawValue)
            writeAutoStopDiagnostic("handleMeetingEnding waitForGrace reason=\(event.reason.rawValue) state=\(recordingState)")
            return
        }

        let countdownStart = event.detectedAt.addingTimeInterval(MeetingSessionState.graceInterval)
        if autoStopDeadline != nil {
            // A real reconnect can release again before the old generation's
            // deadline executes. Rebase every new authoritative release so the
            // current call always receives its full grace + countdown window.
            NSLog("[RecordingEngine] handleMeetingEnding: replacing prior auto-stop generation")
            writeAutoStopDiagnostic("handleMeetingEnding replacePriorDeadline reason=\(event.reason.rawValue) state=\(recordingState)")
            cancelAutoStop()
        }
        NSLog("[RecordingEngine] handleMeetingEnding: arming Teams release deadline")
        writeAutoStopDiagnostic("handleMeetingEnding armDefinitiveDeadline reason=\(event.reason.rawValue) state=\(recordingState)")
        startAutoStopCountdown(
            countdownStart: countdownStart,
            requiresMeetingEndConfirmation: true
        )
    }

    /// Called when MeetingDetector recovers from ending → active (signals returned).
    func handleMeetingRecovered(_ reason: MeetingActivityReason = .signals) {
        if autoStopRequiresMeetingEndConfirmation,
           autoStopDeadline != nil,
           reason != .teamsCallAssertionActive {
            // After an explicit Teams assertion release, retained calendar/mic
            // heuristics or a transient IOKit outage can manufacture a grace-
            // period recovery. Preserve the deadline; its fresh three-state
            // check is the only path allowed to distinguish those signals from
            // a real reconnect/redial.
            NSLog("[RecordingEngine] handleMeetingRecovered: preserving authoritative Teams deadline")
            writeAutoStopDiagnostic("handleMeetingRecovered preserveAuthoritativeDeadline reason=\(reason.rawValue) state=\(recordingState) countdown=\(autoStopCountdown)")
            return
        }
        NSLog("[RecordingEngine] handleMeetingRecovered: cancelling auto-stop reason=%@", reason.rawValue)
        writeAutoStopDiagnostic("handleMeetingRecovered cancel reason=\(reason.rawValue) state=\(recordingState) countdown=\(autoStopCountdown)")
        cancelAutoStop()
    }

    /// Called when MeetingDetector transitions ending → idle (grace period expired).
    func handleMicDeactivated() {
        // This callback is also the authoritative re-check for a meeting that
        // is pending behind stop finalization. Clear that pending retry even
        // when no recording has started yet.
        isMeetingCurrentlyActive = false
        guard recordingState == .recording || recordingState == .paused else {
            clearPendingMeetingAutoStart()
            return
        }
        guard autoStopEnabled else { return }
        guard !autoStopSuppressedForCurrentRecording else {
            isMeetingCurrentlyActive = true
            NSLog("[RecordingEngine] handleMicDeactivated: ignored because user chose to keep recording")
            writeAutoStopDiagnostic("handleMicDeactivated suppressedByUser state=\(recordingState)")
            return
        }
        if autoStopDeadline != nil {
            // The deadline task is the sole completion path. It performs a
            // fresh detector reevaluation before stopping, including when the
            // MainActor resumes after the deadline has already elapsed.
            NSLog("[RecordingEngine] handleMicDeactivated: countdown already running")
            writeAutoStopDiagnostic("handleMicDeactivated countdownAlreadyRunning countdown=\(autoStopCountdown)")
            return
        }

        NSLog("[RecordingEngine] handleMicDeactivated: detector grace elapsed, starting auto-stop countdown")
        writeAutoStopDiagnostic("handleMicDeactivated startCountdown state=\(recordingState)")
        startAutoStopCountdown()
    }

    func resetMeetingDetectionState() {
        cancelAutoStop()
        showMicPrompt = false
        isMeetingCurrentlyActive = false
        detectedMeetingBundleID = nil
        detectedMeetingAppName = nil
        triggeringMeetingBundleID = nil
        clearPendingMeetingAutoStart()
        detectionCooldownUntil = nil
        autoStopSuppressedForCurrentRecording = false
    }

    /// Retry auto-recording for a meeting that was detected while the previous
    /// recording was finalizing. The pending meeting is intentionally retained
    /// until the recording lease releases; post-processing still running never
    /// delays the retry.
    private func retryPendingMeetingAutoStartIfNeeded() {
        guard let pending = pendingMeetingAutoStart else { return }

        guard !isStopping,
              !isStarting,
              recordingState == .idle,
              !recordingProcessingGateForNewRecording.hasRecordingLease else {
            return
        }

        // Reconfirm the same meeting is still the detector's active session.
        guard isMeetingCurrentlyActive,
              detectedMeetingBundleID == pending.bundleID else {
            clearPendingMeetingAutoStart()
            NSLog("[RecordingEngine] pendingMeetingAutoStart: meeting no longer active, discarding")
            return
        }

        guard autoRecordEnabled else {
            clearPendingMeetingAutoStart()
            showMicPrompt = true
            NSLog("[RecordingEngine] pendingMeetingAutoStart: auto-record disabled, releasing intent")
            return
        }

        if let cooldown = detectionCooldownUntil, Date() < cooldown {
            schedulePendingMeetingAutoStartRetry(after: cooldown)
            return
        }

        NSLog("[RecordingEngine] pendingMeetingAutoStart: retrying auto-start for %@", pending.appName)
        schedulePendingMeetingAutoStart(for: pending.bundleID)
    }

    private func schedulePendingMeetingAutoStart(for bundleID: String) {
        guard let generation = pendingMeetingAutoStartGeneration,
              pendingMeetingAutoStart?.bundleID == bundleID,
              scheduledPendingMeetingAutoStartGeneration != generation else { return }
        scheduledPendingMeetingAutoStartGeneration = generation
        let scheduledIntent = pendingMeetingRecordingIntent
        Task { @MainActor [weak self, scheduledIntent] in
            guard let self else {
                scheduledIntent?.cancel()
                return
            }
            defer {
                if self.scheduledPendingMeetingAutoStartGeneration == generation {
                    self.scheduledPendingMeetingAutoStartGeneration = nil
                }
            }
            guard self.pendingMeetingAutoStartGeneration == generation else {
                scheduledIntent?.cancel()
                return
            }
            guard self.autoRecordEnabled else {
                self.clearPendingMeetingAutoStart()
                self.showMicPrompt = self.isMeetingCurrentlyActive
                return
            }
            guard self.isMeetingCurrentlyActive,
                  self.detectedMeetingBundleID == bundleID,
                  let pending = self.takePendingMeetingAutoStart(
                      matching: bundleID,
                      generation: generation
                  ) else {
                if self.pendingMeetingAutoStartGeneration == generation {
                    self.clearPendingMeetingAutoStart()
                }
                return
            }
            do {
                // Auto-recordings always capture mic — meeting without your voice is useless.
                try await self.startRecording(
                    meetingName: pending.meeting.appName,
                    captureMicrophone: true,
                    skipPermissionPrompt: true,
                    isAutoStarted: true,
                    reservedRecordingIntent: pending.intent
                )
            } catch RecordingStartError.finalizationInProgress {
                // A lifecycle guard may still reject the attempt. Preserve a
                // live meeting with a fresh intent for the next idle edge.
                if self.isMeetingCurrentlyActive,
                   self.detectedMeetingBundleID == bundleID {
                    self.setPendingMeetingAutoStart(
                        bundleID: bundleID,
                        appName: pending.meeting.appName
                    )
                }
                self.log.notice("auto-record deferred until the recording lifecycle is idle")
            } catch {
                self.log.error("auto-record failed: \(error.localizedDescription, privacy: .public)")
                self.presentStartError(error)
            }
        }
    }

    private func schedulePendingMeetingAutoStartRetry(after cooldown: Date) {
        pendingMeetingAutoStartRetryTask?.cancel()
        let delay = max(cooldown.timeIntervalSinceNow + 0.1, 0.1)
        pendingMeetingAutoStartRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.pendingMeetingAutoStartRetryTask = nil
            self.retryPendingMeetingAutoStartIfNeeded()
        }
    }

    private func cancelPendingMeetingAutoStartRetry() {
        pendingMeetingAutoStartRetryTask?.cancel()
        pendingMeetingAutoStartRetryTask = nil
    }

    private func writeAutoStopDiagnostic(_ message: @autoclosure () -> String) {
        guard Self.meetingDiagnosticsEnabled else { return }
        MeetingDiagnosticsLog.shared.write(source: "[RecordingEngine]", message: message())
    }

    private static var meetingDiagnosticsEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if let value = parseBoolString(environment["AIRECORDER_MEETING_DIAGNOSTICS"]) {
            return value
        }

        let defaultsKey = "meetingDetectionDiagnosticsEnabled"
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }

        return false
    }

    private static func parseBoolString(_ value: String?) -> Bool? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

// MARK: - Test Helpers

#if DEBUG
extension RecordingEngine {
    var _test_pendingMeetingAutoStart: (bundleID: String, appName: String)? { pendingMeetingAutoStart }
    var _test_detectionCooldownUntil: Date? { detectionCooldownUntil }
    var _test_autoStopSuppressedForCurrentRecording: Bool { autoStopSuppressedForCurrentRecording }
    var _test_isReconnectingRealtime: Bool { isReconnectingRealtime }
    var _test_autoStopDeadline: Date? { autoStopDeadline }
    var _test_hasPendingAutoStop: Bool { autoStopDeadline != nil }
    var _test_hasAutoStopTask: Bool { autoStopTask != nil }
    var _test_hasRecordingActivity: Bool { recordingActivity != nil }
    var _test_hasRecordingProcessingClaim: Bool { recordingProcessingClaim != nil }
    func _test_setStopping(_ value: Bool) { isStopping = value }
    func _test_setStarting(_ value: Bool) { isStarting = value }
    func _test_setPreparingSystemAudioCapture(_ value: Bool) { isPreparingSystemAudioCapture = value }
    func _test_setSystemAudioPreparationDefaults(_ defaults: UserDefaults) {
        systemAudioPreparationDefaults = defaults
        hasPreparedSystemAudioCapture = SystemAudioCapturePreparation.isPrepared(defaults: defaults)
    }
    func _test_setCooldown(_ date: Date?) { detectionCooldownUntil = date }
    func _test_setRecordingState(_ state: RecordingState) { recordingState = state }
    func _test_setTriggeringMeetingBundleID(_ bundleID: String?) { triggeringMeetingBundleID = bundleID }
    func _test_setCurrentRecordingIsAutoStarted(_ value: Bool) { currentRecordingIsAutoStarted = value }
    func _test_completeStopLifecycle() { completeStopLifecycle() }
    func _test_disableAutoStopTimer() { autoStopTimerDisabledForTesting = true }
    func _test_beginRecordingActivityIfNeeded() { beginRecordingActivityIfNeeded() }
    func _test_endRecordingActivityIfNeeded() { endRecordingActivityIfNeeded() }
    func _test_setRealtimeHint(_ hint: String?) { realtimeHint = hint }
    func _test_triggerRealtimeFailure(_ error: Error, provider: AIProvider) {
        let attemptID = transcriptionManager.currentRealtimeAttemptID
            ?? currentRealtimeAttemptID
            ?? RealtimeAttemptID()
        transcriptionManager.onRealtimeFailure?(error, provider, attemptID)
    }
    var _test_realtimeReconnectCount: Int { realtimeReconnectCount }
    var _test_hasQueuedRealtimeSpeechRetry: Bool { queuedRealtimeSpeechRetry != nil }
    func _test_triggerRealtimeStreamHealthy() {
        transcriptionManager.onRealtimeStreamHealthy?()
    }
    func _test_simulateSpeechResumed(sustainedSilence: TimeInterval = 0) {
        retryRealtimeOnSpeechIfNeeded(sustainedSilence: sustainedSilence)
    }

    /// Exposes the start-recording timeout wrapper so the timeout semantics can
    /// be unit-tested without a live network connection.
    static func _test_withRealtimeStartTimeout(
        seconds: Int,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await withRealtimeStartTimeout(seconds: seconds, operation: operation)
    }

    static func _test_isTimeoutError(_ error: Error) -> Bool {
        error is RealtimeStartTimeout
    }
}
#endif
