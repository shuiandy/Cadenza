import Foundation

/// Each invocation must return a fresh service instance dedicated to one
/// realtime attempt. Exact late cleanup intentionally targets that instance.
typealias RealtimeTranscriptionServiceFactory = @MainActor @Sendable (
    _ provider: AIProvider,
    _ apiKey: String,
    _ model: String?,
    _ language: String?
) throws -> any TranscriptionService

enum RealtimeSessionPhase: String, Sendable {
    case pending
    case active
    case closing
}

struct RealtimeSessionBusyError: Error, LocalizedError, Sendable {
    let phase: RealtimeSessionPhase

    var errorDescription: String? {
        String(localized: "Live transcription is already active.")
    }
}

/// Exact ownership detached from `TranscriptionManager` at the stop call site.
/// Async teardown must operate only on these captured services/tasks so a late
/// completion can never discover or clear a replacement session.
struct RealtimeStopHandle: Sendable {
    fileprivate enum Mode: Sendable, Equatable {
        case detached
        case awaitingFinalDeltas
    }

    fileprivate let pendingServices: [any TranscriptionService]
    fileprivate let generation: UInt64?
    fileprivate let service: (any TranscriptionService)?
    fileprivate let streamTask: Task<Void, Never>?
    fileprivate let mode: Mode
}

/// Manages transcription sessions — both real-time and post-recording.
@Observable @MainActor
final class TranscriptionManager {
    private static let realtimeTimeoutMessage = "Live transcript timed out (no realtime text received)."

    private struct PendingRealtimeSession {
        let service: any TranscriptionService
        let recordingStartTime: Date?
        let attemptID: RealtimeAttemptID
    }

    private let defaults = UserDefaults.standard
    @ObservationIgnored private let realtimeServiceFactory: RealtimeTranscriptionServiceFactory?
    @ObservationIgnored private let realtimeWatchdogDelay: Duration
    @ObservationIgnored private let realtimeFinalDrainTimeout: Duration
    private var realtimeGeneration: UInt64 = 0
    private var pendingRealtimeSessions: [UInt64: PendingRealtimeSession] = [:]
    private var activeRealtimeGeneration: UInt64?
    private var realtimeService: (any TranscriptionService)?
    private var realtimeTask: Task<Void, Never>?
    private(set) var realtimeProvider: AIProvider?
    private(set) var currentRealtimeAttemptID: RealtimeAttemptID?
    private var audioSendQueue: [Data] = []
    private var audioSendHead = 0
    private var audioQueueGeneration: UInt64?
    private var audioDrainGeneration: UInt64?
    private var noDeltaWatchdogTask: Task<Void, Never>?
    private var noDeltaWatchdogGeneration: UInt64?
    private var realtimeDeltaCount = 0
    private var realtimeContentDeltaCount = 0

    private(set) var isTranscribing = false
    private(set) var segments: [TranscriptSegment] = []
    private(set) var fullText = ""
    private(set) var detectedLanguage: String?
    /// Type-erased WhisperKit [TranscriptionResult] from last file transcription.
    private(set) var lastWhisperResults: (any Sendable)?
    private(set) var realtimeError: String?
    var onRealtimeFailure: ((Error, AIProvider, RealtimeAttemptID) -> Void)?
    /// Fired once per realtime session, on the first content-bearing delta.
    /// Deltas can only come from the current generation, so a stale stream can
    /// never report a replacement session as healthy.
    var onRealtimeStreamHealthy: (() -> Void)?
    /// Consulted when the no-delta watchdog fires. true means the audio sent so
    /// far was genuine silence, so the missing text is expected and the session
    /// stays up. false means speech went untranscribed — a half-open connection
    /// that will never error on its own — so the watchdog reports a failure.
    /// nil (no capture-side signal available) is treated as silence.
    var realtimeAudioIsSilent: (() -> Bool)?
    var onSegmentsChanged: (([TranscriptSegment]) -> Void)?

    /// Progress callback reporting (chunksDone, chunksTotal) during chunked file transcription.
    var onProgress: (@Sendable (Int, Int) -> Void)?

    init(
        realtimeServiceFactory: RealtimeTranscriptionServiceFactory? = nil,
        realtimeWatchdogDelay: Duration = .seconds(8),
        realtimeFinalDrainTimeout: Duration = .seconds(3)
    ) {
        self.realtimeServiceFactory = realtimeServiceFactory
        self.realtimeWatchdogDelay = realtimeWatchdogDelay
        self.realtimeFinalDrainTimeout = realtimeFinalDrainTimeout
    }

    // MARK: - Real-time Transcription

    func startRealtime(
        provider: AIProvider,
        apiKey: String,
        model: String? = nil,
        language: String? = nil,
        preserveSegments: Bool = false,
        recordingStartTime: Date? = nil,
        attemptID: RealtimeAttemptID = RealtimeAttemptID()
    ) async throws {
        try Task.checkCancellation()
        if let busyPhase = realtimeBusyPhase {
            throw RealtimeSessionBusyError(phase: busyPhase)
        }

        NSLog("[TranscriptionManager] startRealtime: provider=%@ preserveSegments=%d", provider.rawValue, preserveSegments ? 1 : 0)
        realtimeError = nil

        let lang = language == "auto" ? nil : language
        let service = try makeRealtimeService(
            provider: provider,
            apiKey: apiKey,
            model: model,
            language: lang
        )

        let generation = nextRealtimeGeneration()
        pendingRealtimeSessions[generation] = PendingRealtimeSession(
            service: service,
            recordingStartTime: recordingStartTime,
            attemptID: attemptID
        )
        currentRealtimeAttemptID = attemptID

        let stream: AsyncThrowingStream<TranscriptDelta, Error>
        do {
            stream = try await service.startRealtimeSession(language: lang)
        } catch {
            let stillOwned = pendingRealtimeSessions.removeValue(forKey: generation) != nil
            if currentRealtimeAttemptID == attemptID {
                currentRealtimeAttemptID = nil
            }
            if stillOwned, realtimeGeneration == generation {
                invalidateRealtimeGeneration(generation)
            }
            // A failed handshake can still leave a socket/continuation allocated.
            // Close this exact service, never whichever service is current now.
            try? await service.stopRealtimeSession()
            throw error
        }

        let pendingSession = pendingRealtimeSessions.removeValue(forKey: generation)
        let stillOwned = pendingSession != nil
        let wasCancelled = Task.isCancelled
        guard stillOwned,
              let pendingSession,
              realtimeGeneration == generation,
              !wasCancelled else {
            if stillOwned, realtimeGeneration == generation {
                invalidateRealtimeGeneration(generation)
            }
            if currentRealtimeAttemptID == attemptID {
                currentRealtimeAttemptID = nil
            }
            // stop/reset may already have asked a pending provider to close. A
            // non-cooperative handshake can become ready later, so close it again
            // now that the provider has created its live session.
            try? await service.stopRealtimeSession()
            throw CancellationError()
        }

        activeRealtimeGeneration = generation
        currentRealtimeAttemptID = attemptID
        realtimeService = service
        realtimeProvider = provider
        isTranscribing = true
        realtimeDeltaCount = 0
        realtimeContentDeltaCount = 0
        sendAudioCount = 0
        prepareAudioQueue(for: generation)
        if !preserveSegments {
            segments = []
            fullText = ""
            onSegmentsChanged?(segments)
        }

        NSLog("[TranscriptionManager] session ready, listening for deltas")

        // Process incoming deltas
        let streamTask = Task { [weak self] in
            var deltaCount = 0
            var pending: [TranscriptDelta] = []
            var lastFlushAt = Date()
            do {
                for try await delta in stream {
                    deltaCount += 1
                    pending.append(delta)

                    let now = Date()
                    let shouldFlush = delta.isFinal
                        || pending.count >= 4
                        || now.timeIntervalSince(lastFlushAt) >= 0.18

                    if shouldFlush {
                        self?.handleDeltasBatch(
                            pending,
                            generation: generation,
                            provider: provider,
                            recordingStartTime: pendingSession.recordingStartTime
                        )
                        pending.removeAll(keepingCapacity: true)
                        lastFlushAt = now
                    }
                }

                if !pending.isEmpty {
                    self?.handleDeltasBatch(
                        pending,
                        generation: generation,
                        provider: provider,
                        recordingStartTime: pendingSession.recordingStartTime
                    )
                }
                NSLog("[TranscriptionManager] stream ended normally after %d deltas", deltaCount)
                // Stream ended without error (server closed connection).
                // Notify failure handler so RecordingEngine can reconnect if still recording.
                guard let self,
                      self.isCurrentRealtimeSession(generation),
                      self.isTranscribing else { return }
                let error = TranscriptionError.apiError("Realtime stream ended unexpectedly")
                self.onRealtimeFailure?(error, provider, attemptID)
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                NSLog("[TranscriptionManager] stream error: %@", error.localizedDescription)
                guard let self,
                      self.isCurrentRealtimeSession(generation),
                      self.isTranscribing else { return }
                self.realtimeError = error.localizedDescription
                self.onRealtimeFailure?(error, provider, attemptID)
            }
            guard let self, self.isCurrentRealtimeSession(generation) else { return }
            self.isTranscribing = false
        }
        realtimeTask = streamTask

        let watchdogDelay = realtimeWatchdogDelay
        let watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: watchdogDelay)
            await MainActor.run {
                guard let self else { return }
                guard self.isCurrentRealtimeSession(generation) else { return }
                guard self.isTranscribing else { return }
                guard self.realtimeContentDeltaCount == 0, self.sendAudioCount > 0 else { return }
                if self.realtimeAudioIsSilent?() ?? true {
                    // No deltas while silent audio flows is what a healthy
                    // realtime stream looks like: providers only emit text for
                    // speech. Real faults (socket errors, server error events,
                    // unexpected stream end) surface through the stream task
                    // and still reach onRealtimeFailure. Record a diagnostic;
                    // never tear down.
                    NSLog("[TranscriptionManager] no realtime text %.0fs after connect; treating as silence, session stays up", Double(watchdogDelay.components.seconds))
                    self.realtimeError = Self.realtimeTimeoutMessage
                } else {
                    // Speech was captured and no text ever arrived: the stream
                    // is half-open in a way that never produces its own error
                    // event, so this is the only place it can be detected.
                    NSLog("[TranscriptionManager] no realtime text %.0fs after connect despite speech; reporting stream failure", Double(watchdogDelay.components.seconds))
                    self.realtimeError = Self.realtimeTimeoutMessage
                    let error = TranscriptionError.apiError(Self.realtimeTimeoutMessage)
                    self.onRealtimeFailure?(error, provider, attemptID)
                }
            }
        }
        noDeltaWatchdogTask = watchdogTask
        noDeltaWatchdogGeneration = generation
    }

    private var realtimeBusyPhase: RealtimeSessionPhase? {
        if !pendingRealtimeSessions.isEmpty {
            return .pending
        }
        if activeRealtimeGeneration != nil {
            if !isTranscribing { return .closing }
            return .active
        }
        if isTranscribing {
            return .active
        }
        return nil
    }

    private func nextRealtimeGeneration() -> UInt64 {
        realtimeGeneration &+= 1
        return realtimeGeneration
    }

    private func invalidateRealtimeGeneration(_ generation: UInt64) {
        guard realtimeGeneration == generation else { return }
        realtimeGeneration &+= 1
    }

    private func isCurrentRealtimeSession(_ generation: UInt64) -> Bool {
        realtimeGeneration == generation && activeRealtimeGeneration == generation
    }

    private func makeRealtimeService(
        provider: AIProvider,
        apiKey: String,
        model: String?,
        language: String?
    ) throws -> any TranscriptionService {
        if let realtimeServiceFactory {
            return try realtimeServiceFactory(provider, apiKey, model, language)
        }

        switch provider {
        case .openai:
            return RealtimeTranscriber(apiKey: apiKey, model: model ?? provider.realtimeModel)
        case .gemini:
            return GeminiRealtimeTranscriber(apiKey: apiKey, model: model ?? provider.realtimeModel)
        case .claude, .minimax:
            throw TranscriptionError.notSupported("\(provider.displayName) does not support real-time audio transcription")
        case .apple:
            guard let transcriber = AppleSpeechFactory.makeTranscriber(language: language) else {
                throw TranscriptionError.notSupported("\(provider.displayName) does not support real-time audio transcription")
            }
            return transcriber
        case .whisperLocal:
            throw TranscriptionError.notSupported("Local Whisper does not support real-time transcription")
        }
    }

    private(set) var sendAudioCount = 0
    private let maxChunksPerDrainPass = 2

    /// Send audio data to the real-time transcriber.
    func sendAudio(_ data: Data) {
        guard isTranscribing,
              let generation = activeRealtimeGeneration,
              isCurrentRealtimeSession(generation),
              let service = realtimeService else {
            sendAudioCount += 1
            return
        }
        sendAudioCount += 1
        if audioQueueGeneration != generation {
            prepareAudioQueue(for: generation)
        }
        audioSendQueue.append(data)

        // Prevent unbounded memory growth if producer outruns network.
        let queueLimit = currentQueueLimit
        let queuedCount = audioSendQueue.count - audioSendHead
        if queuedCount > queueLimit {
            let keepTail = currentQueueTail
            let oldHead = audioSendHead
            audioSendHead = max(audioSendHead, audioSendQueue.count - keepTail)
            let dropped = max(0, audioSendHead - oldHead)
            if audioSendHead > 256 && audioSendHead * 2 > audioSendQueue.count {
                audioSendQueue.removeFirst(audioSendHead)
                audioSendHead = 0
            }
            if dropped > 0 {
                NSLog("[Cadenza] Dropped %d queued live transcription audio chunks (low-latency)", dropped)
            }
        }

        scheduleAudioDrain(with: service, generation: generation)
    }

    /// Flush any buffered audio (e.g. Gemini requires audioStreamEnd to process cached audio).
    func flushRealtimeAudio() async {
        guard let generation = activeRealtimeGeneration,
              isCurrentRealtimeSession(generation),
              let service = realtimeService else { return }
        await flushRealtimeAudio(using: service)
    }

    /// Tear down the realtime session.
    ///
    /// - Parameter abandonStartup: When true, this is a startup-failure / timeout
    ///   teardown of a *half-open* session. We must NOT block: skip the audio flush
    ///   (Gemini's `sendAudioStreamEnd` would `rawSend` on a not-yet-ready
    ///   connection via a bare, non-cancellable continuation and could hang the
    ///   caller) and the 500ms drain wait. State is cleared synchronously and the
    ///   underlying session close is fire-and-forget so the caller returns at once.
    func stopRealtime(
        preserveFailureHandler: Bool = false,
        preserveRealtimeError: Bool = false,
        awaitFinalDeltas: Bool = false,
        abandonStartup: Bool = false
    ) async {
        let handle = beginRealtimeStop(
            preserveFailureHandler: preserveFailureHandler,
            preserveRealtimeError: preserveRealtimeError,
            awaitFinalDeltas: awaitFinalDeltas && !abandonStartup
        )
        await finishRealtimeStop(
            handle,
            abandonStartup: abandonStartup
        )
    }

    /// Synchronously revokes and detaches the current generation. This method is
    /// deliberately non-async: callers must capture ownership before scheduling
    /// any delayed cleanup work.
    func beginRealtimeStop(
        matching attemptID: RealtimeAttemptID,
        preserveFailureHandler: Bool = false,
        preserveRealtimeError: Bool = false,
        awaitFinalDeltas: Bool = false
    ) -> RealtimeStopHandle? {
        guard currentRealtimeAttemptID == attemptID else { return nil }
        return beginRealtimeStop(
            preserveFailureHandler: preserveFailureHandler,
            preserveRealtimeError: preserveRealtimeError,
            awaitFinalDeltas: awaitFinalDeltas
        )
    }

    func beginRealtimeStop(
        preserveFailureHandler: Bool = false,
        preserveRealtimeError: Bool = false,
        awaitFinalDeltas: Bool = false
    ) -> RealtimeStopHandle {
        let canAwaitFinalDeltas = awaitFinalDeltas
            && activeRealtimeGeneration != nil
            && realtimeService != nil
        let handle = RealtimeStopHandle(
            pendingServices: pendingRealtimeSessions.values.map(\.service),
            generation: activeRealtimeGeneration,
            service: realtimeService,
            streamTask: realtimeTask,
            mode: canAwaitFinalDeltas ? .awaitingFinalDeltas : .detached
        )
        pendingRealtimeSessions.removeAll(keepingCapacity: false)

        if !preserveFailureHandler {
            onRealtimeFailure = nil
            onRealtimeStreamHealthy = nil
            realtimeAudioIsSilent = nil
        }
        if !preserveRealtimeError {
            realtimeError = nil
        }

        if let generation = handle.generation {
            cancelNoDeltaWatchdog(for: generation)
            clearAudioQueue(ifOwnedBy: generation)
        } else {
            noDeltaWatchdogTask?.cancel()
            noDeltaWatchdogTask = nil
            noDeltaWatchdogGeneration = nil
            clearAudioQueue()
        }

        if canAwaitFinalDeltas {
            // Keep this exact generation attached so deltas emitted by the
            // provider's stop handshake can still commit. Marking it closing
            // blocks new audio and replacement starts until bounded teardown or
            // an explicit reset revokes it.
            isTranscribing = false
            return handle
        }

        // Revoke every pending/active owner before a replacement can start.
        realtimeGeneration &+= 1

        realtimeTask = nil
        realtimeService = nil
        activeRealtimeGeneration = nil
        realtimeProvider = nil
        currentRealtimeAttemptID = nil
        isTranscribing = false
        realtimeDeltaCount = 0
        realtimeContentDeltaCount = 0

        return handle
    }

    /// Flushes/closes only the ownership captured by `beginRealtimeStop`.
    ///
    /// Detaching first allows a replacement session to start even if a provider
    /// close hangs. Deltas arriving after detachment are intentionally discarded:
    /// the manager's transcript buffer is shared, so accepting them could corrupt
    /// the replacement generation.
    func finishRealtimeStop(
        _ handle: RealtimeStopHandle,
        abandonStartup: Bool = false
    ) async {
        closeRealtimeServicesWithoutWaiting(handle.pendingServices)

        guard let service = handle.service else {
            handle.streamTask?.cancel()
            return
        }

        var exactCloseStarted = false
        defer {
            if !exactCloseStarted {
                // Always attempt close on this captured service, including when
                // flush/caller cancellation wins. Never rediscover global state.
                closeRealtimeServicesWithoutWaiting([service])
            }
        }

        if abandonStartup {
            handle.streamTask?.cancel()
            return
        }

        await flushRealtimeAudio(using: service)

        if handle.mode == .awaitingFinalDeltas {
            // Exactly one provider stop attempt owns final drain. If its task is
            // non-cooperative, the deadline detaches manager ownership and
            // cancels that same task; never race it with a second stop call.
            exactCloseStarted = true
            do {
                let streamTask = handle.streamTask
                try await HardAsyncDeadline.run(for: realtimeFinalDrainTimeout) {
                    try await service.stopRealtimeSession()
                    try await Task.sleep(for: .milliseconds(250))
                    await streamTask?.value
                }
            } catch is HardAsyncDeadlineExceeded {
                NSLog("[TranscriptionManager] realtime final drain timed out; releasing exact owner")
                handle.streamTask?.cancel()
            } catch is CancellationError {
                handle.streamTask?.cancel()
            } catch {
                NSLog("[TranscriptionManager] realtime close error: %@", error.localizedDescription)
                handle.streamTask?.cancel()
            }
            completeAwaitingFinalDeltasStop(handle)
        } else {
            try? await Task.sleep(for: .milliseconds(500))
            handle.streamTask?.cancel()
        }
    }

    private func completeAwaitingFinalDeltasStop(_ handle: RealtimeStopHandle) {
        guard handle.mode == .awaitingFinalDeltas,
              let generation = handle.generation,
              isCurrentRealtimeSession(generation) else { return }

        realtimeGeneration &+= 1
        realtimeTask = nil
        realtimeService = nil
        activeRealtimeGeneration = nil
        realtimeProvider = nil
        currentRealtimeAttemptID = nil
        isTranscribing = false
        realtimeDeltaCount = 0
        realtimeContentDeltaCount = 0
    }

    private func flushRealtimeAudio(using service: any TranscriptionService) async {
        if let gemini = service as? GeminiRealtimeTranscriber {
            try? await gemini.sendAudioStreamEnd()
        }
    }

    private func closeRealtimeServicesWithoutWaiting(_ services: [any TranscriptionService]) {
        guard !services.isEmpty else { return }
        Task {
            for service in services {
                try? await service.stopRealtimeSession()
            }
        }
    }

    private func cancelNoDeltaWatchdog(for generation: UInt64) {
        guard noDeltaWatchdogGeneration == generation else { return }
        noDeltaWatchdogTask?.cancel()
        noDeltaWatchdogTask = nil
        noDeltaWatchdogGeneration = nil
    }

    // MARK: - Post-recording Transcription

    func transcribeFile(at url: URL, provider: AIProvider, apiKey: String, language: String? = nil, model: String? = nil) async throws -> TranscriptResult {
        isTranscribing = true
        defer { isTranscribing = false }

        let lang = language == "auto" ? nil : language

        // Resolve model on MainActor (reads @Observable state), then hand off to nonisolated.
        let resolvedModel: String
        if let model {
            resolvedModel = model
        } else if provider == .whisperLocal {
            let selected = WhisperModelManager.shared.selectedModel
            resolvedModel = WhisperModelManager.shared.isAvailable(selected) ? selected : "base"
        } else {
            // UserDefaults override (transcriptionModel.<provider>) ?? code default.
            resolvedModel = provider.transcriptionModel
        }
        let progressCb = onProgress

        // File I/O and network run off MainActor via nonisolated static method.
        let result = try await Self.runTranscription(
            at: url, provider: provider, apiKey: apiKey,
            language: lang, model: resolvedModel, onProgress: progressCb
        )

        // Update observable state on MainActor.
        applyTranscriptionResult(result)
        return result
    }

    /// Nonisolated transcription dispatch — file I/O and network run off MainActor.
    private nonisolated static func runTranscription(
        at url: URL, provider: AIProvider, apiKey: String,
        language: String?, model: String,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> TranscriptResult {
        switch provider {
        case .openai:
            let transcriber = WhisperTranscriber(
                apiKey: apiKey,
                model: model,
                onProgress: onProgress
            )
            return try await transcriber.transcribeFile(at: url, language: language)
        case .gemini:
            let transcriber = GeminiTranscriber(apiKey: apiKey, model: model)
            transcriber.onProgress = onProgress
            return try await transcriber.transcribeFile(at: url, language: language)
        case .apple:
            guard let transcriber = AppleSpeechFactory.makeTranscriber(language: language) else {
                throw TranscriptionError.notSupported("\(provider.displayName) does not support audio transcription")
            }
            return try await transcriber.transcribeFile(at: url, language: language)
        case .whisperLocal:
            let transcriber = LocalWhisperTranscriber(
                modelName: model,
                onProgress: onProgress
            )
            return try await transcriber.transcribeFile(at: url, language: language)
        case .claude, .minimax:
            throw TranscriptionError.notSupported("\(provider.displayName) does not support audio transcription")
        }
    }

    /// Update observable state from transcription result (must be called on MainActor).
    private func applyTranscriptionResult(_ result: TranscriptResult) {
        fullText = result.text
        detectedLanguage = result.language
        lastWhisperResults = result.whisperResults

        if result.segments.isEmpty {
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments = [TranscriptSegment(timestamp: 0, text: trimmed, isFinal: true)]
            } else {
                segments = []
            }
        } else {
            segments = result.segments.map { seg in
                TranscriptSegment(
                    timestamp: seg.startTime,
                    endTime: seg.endTime > seg.startTime ? seg.endTime : nil,
                    text: seg.text,
                    isFinal: true,
                    speaker: seg.speaker
                )
            }
        }
    }

    /// Clear in-memory state for the next recording session.
    func reset() {
        // Revoke synchronously; provider close stays bound to this exact handle.
        let stopHandle = beginRealtimeStop()
        stopHandle.streamTask?.cancel()
        closeRealtimeServicesWithoutWaiting(
            stopHandle.pendingServices + (stopHandle.service.map { [$0] } ?? [])
        )
        segments = []
        fullText = ""
        detectedLanguage = nil
        lastWhisperResults = nil
        realtimeError = nil
        realtimeProvider = nil
        currentRealtimeAttemptID = nil
        onRealtimeFailure = nil
        onRealtimeStreamHealthy = nil
        realtimeAudioIsSilent = nil
        onProgress = nil
        isTranscribing = false
        noDeltaWatchdogTask?.cancel()
        noDeltaWatchdogTask = nil
        noDeltaWatchdogGeneration = nil
        realtimeDeltaCount = 0
        realtimeContentDeltaCount = 0
        onSegmentsChanged?(segments)
        sendAudioCount = 0
        clearAudioQueue()
    }

    func setRealtimeHint(_ message: String?) {
        realtimeError = message
    }

    // MARK: - Delta Handling

    private func handleDeltasBatch(
        _ deltas: [TranscriptDelta],
        generation: UInt64,
        provider: AIProvider,
        recordingStartTime: Date?
    ) {
        guard !deltas.isEmpty, isCurrentRealtimeSession(generation) else { return }
        var didChange = false
        for delta in deltas {
            guard isCurrentRealtimeSession(generation) else { return }
            didChange = handleDelta(
                delta,
                generation: generation,
                provider: provider,
                recordingStartTime: recordingStartTime
            ) || didChange
        }
        if didChange, isCurrentRealtimeSession(generation) {
            onSegmentsChanged?(segments)
        }
    }

    @discardableResult
    private func handleDelta(
        _ delta: TranscriptDelta,
        generation: UInt64,
        provider: AIProvider,
        recordingStartTime: Date?
    ) -> Bool {
        guard isCurrentRealtimeSession(generation) else { return false }
        let normalizedIncoming = delta.text
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        let trimmedIncoming = normalizedIncoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else {
            detectedLanguage = delta.language ?? detectedLanguage
            return false
        }

        realtimeDeltaCount += 1
        realtimeContentDeltaCount += 1
        if realtimeContentDeltaCount == 1 {
            cancelNoDeltaWatchdog(for: generation)
            if realtimeError == Self.realtimeTimeoutMessage {
                realtimeError = nil
            }
            onRealtimeStreamHealthy?()
        }

        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        var changed = false
        // Apple's recognizer always resends the full utterance; cloud
        // providers vary by model, so the transcriber flags it per delta.
        let replaceHypothesis = provider == .apple || delta.replacesHypothesis

        if delta.isFinal {
            let incomingFinal = trimmedIncoming

            // Replace the last non-final segment or append
            if let lastIndex = segments.lastIndex(where: { !$0.isFinal }) {
                let current = segments[lastIndex]
                let finalText = replaceHypothesis
                    ? incomingFinal
                    : mergeDeltaText(existing: current.text, incoming: normalizedIncoming)
                if current.text != finalText || !current.isFinal {
                    segments[lastIndex] = current.updating(text: finalText, isFinal: true)
                    changed = true
                }
            } else if let lastFinalIndex = segments.indices.last, segments[lastFinalIndex].isFinal {
                let previous = segments[lastFinalIndex]
                let gap = max(0, elapsed - previous.timestamp)
                if shouldCoalesceWithPreviousFinal(
                    previous: previous.text,
                    incoming: incomingFinal,
                    gap: gap
                ) {
                    let merged = mergeFinalContinuation(existing: previous.text, incoming: incomingFinal)
                    if merged != previous.text {
                        segments[lastFinalIndex] = previous.updating(text: merged, isFinal: true)
                        changed = true
                    }
                } else {
                    segments.append(TranscriptSegment(timestamp: elapsed, text: incomingFinal, isFinal: true))
                    changed = true
                }
            } else {
                segments.append(TranscriptSegment(timestamp: elapsed, text: incomingFinal, isFinal: true))
                changed = true
            }
            detectedLanguage = delta.language ?? detectedLanguage
            if changed {
                compactTrailingFinalSegments()
                rebuildFullTextFromFinalSegments()
            }
        } else {
            // Append or update interim segment
            if let lastIndex = segments.lastIndex(where: { !$0.isFinal }) {
                let current = segments[lastIndex]
                let mergedText = replaceHypothesis
                    ? normalizedIncoming
                    : mergeDeltaText(existing: current.text, incoming: normalizedIncoming)
                if current.text != mergedText {
                    segments[lastIndex] = current.updating(text: mergedText, isFinal: false)
                    changed = true
                }
            } else {
                segments.append(TranscriptSegment(timestamp: elapsed, text: normalizedIncoming, isFinal: false))
                changed = true
            }
        }
        return changed
    }

    private func scheduleAudioDrain(
        with service: any TranscriptionService,
        generation: UInt64
    ) {
        guard isCurrentRealtimeSession(generation),
              audioQueueGeneration == generation,
              audioDrainGeneration == nil else { return }
        audioDrainGeneration = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainAudioQueue(with: service, generation: generation)
        }
    }

    private func drainAudioQueue(
        with service: any TranscriptionService,
        generation: UInt64
    ) async {
        var sentInThisPass = 0

        while true {
            guard isCurrentRealtimeSession(generation),
                  isTranscribing,
                  audioQueueGeneration == generation else {
                finishAudioDrain(ifOwnedBy: generation)
                return
            }

            guard audioSendHead < audioSendQueue.count else {
                finishAudioDrain(ifOwnedBy: generation)
                if audioSendHead > 256 {
                    audioSendQueue.removeFirst(audioSendHead)
                    audioSendHead = 0
                }
                return
            }

            if lowLatencyModeEnabled && (audioSendQueue.count - audioSendHead) < 3 {
                try? await Task.sleep(for: .milliseconds(40))
                guard isCurrentRealtimeSession(generation),
                      audioQueueGeneration == generation else {
                    finishAudioDrain(ifOwnedBy: generation)
                    return
                }
            }

            var chunk = Data()
            chunk.reserveCapacity(maxRealtimeBatchBytes)
            var batchedCount = 0

            while audioSendHead < audioSendQueue.count && batchedCount < maxRealtimeBatchChunks {
                let next = audioSendQueue[audioSendHead]
                if !chunk.isEmpty && (chunk.count + next.count) > maxRealtimeBatchBytes {
                    break
                }
                chunk.append(next)
                audioSendHead += 1
                batchedCount += 1

                if chunk.count >= maxRealtimeBatchBytes {
                    break
                }
            }

            do {
                guard !chunk.isEmpty else { continue }
                try await Task.detached(priority: .utility) { [service, chunk] in
                    try await service.sendAudio(chunk)
                }.value
                guard isCurrentRealtimeSession(generation),
                      audioQueueGeneration == generation else {
                    finishAudioDrain(ifOwnedBy: generation)
                    return
                }
                sentInThisPass += 1
            } catch {
                guard isCurrentRealtimeSession(generation),
                      audioQueueGeneration == generation else {
                    finishAudioDrain(ifOwnedBy: generation)
                    return
                }
                NSLog("[TranscriptionManager] audio send error: %@", error.localizedDescription)
                realtimeError = error.localizedDescription
                if let provider = realtimeProvider,
                   let attemptID = currentRealtimeAttemptID {
                    onRealtimeFailure?(error, provider, attemptID)
                }
                finishAudioDrain(ifOwnedBy: generation)
                clearAudioQueue(ifOwnedBy: generation)
                return
            }

            if sentInThisPass >= maxChunksPerDrainPass {
                break
            }
        }

        finishAudioDrain(ifOwnedBy: generation)
        if isCurrentRealtimeSession(generation),
           audioQueueGeneration == generation,
           audioSendHead < audioSendQueue.count {
            scheduleAudioDrain(with: service, generation: generation)
        }
    }

    private func prepareAudioQueue(for generation: UInt64) {
        audioSendQueue.removeAll(keepingCapacity: false)
        audioSendHead = 0
        audioQueueGeneration = generation
        audioDrainGeneration = nil
    }

    private func finishAudioDrain(ifOwnedBy generation: UInt64) {
        if audioDrainGeneration == generation {
            audioDrainGeneration = nil
        }
    }

    private func clearAudioQueue(ifOwnedBy generation: UInt64? = nil) {
        if let generation, audioQueueGeneration != generation { return }
        audioSendQueue.removeAll(keepingCapacity: false)
        audioSendHead = 0
        audioQueueGeneration = nil
        audioDrainGeneration = nil
    }

    private var lowLatencyModeEnabled: Bool {
        defaults.object(forKey: "liveTranscriptLowLatency") as? Bool ?? false
    }

    private var currentQueueLimit: Int {
        lowLatencyModeEnabled ? 220 : 960
    }

    private var currentQueueTail: Int {
        lowLatencyModeEnabled ? 56 : 320
    }

    private var maxRealtimeBatchBytes: Int {
        lowLatencyModeEnabled ? 64_000 : 128_000
    }

    private var maxRealtimeBatchChunks: Int {
        lowLatencyModeEnabled ? 16 : 32
    }

    private func rebuildFullTextFromFinalSegments() {
        fullText = segments
            .filter(\.isFinal)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func shouldCoalesceWithPreviousFinal(previous: String, incoming: String, gap: TimeInterval) -> Bool {
        guard gap <= 4.0 else { return false }

        let prevTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prevTrimmed.isEmpty else { return false }

        if !endsSentence(text: prevTrimmed) {
            return true
        }

        if incoming.count <= 96 {
            return true
        }

        if prevTrimmed.count <= 120 && gap <= 1.8 {
            return true
        }

        if let first = incoming.first, first.isLowercase {
            return true
        }

        return false
    }

    private func compactTrailingFinalSegments() {
        guard segments.count >= 2 else { return }
        var index = segments.count - 1
        while index > 0 {
            let current = segments[index]
            let previous = segments[index - 1]
            guard current.isFinal, previous.isFinal else { break }

            let gap = max(0, current.timestamp - previous.timestamp)
            let prevTrimmed = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTrimmed = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if prevTrimmed.isEmpty || currentTrimmed.isEmpty { break }

            let shouldMerge = gap <= 3.2 && (
                !endsSentence(text: prevTrimmed)
                || currentTrimmed.count <= 80
                || prevTrimmed.count <= 90
            )
            guard shouldMerge else { break }

            let merged = mergeFinalContinuation(existing: prevTrimmed, incoming: currentTrimmed)
            segments[index - 1] = previous.updating(text: merged, isFinal: true)
            segments.remove(at: index)
            index -= 1
        }
    }

    private func mergeFinalContinuation(existing: String, incoming: String) -> String {
        let merged = mergeDeltaText(existing: existing, incoming: incoming)
        if merged != existing {
            return merged
        }

        let lhs = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        let needsSpace = !(lhs.hasSuffix(" ") || rhs.hasPrefix(" "))
        return needsSpace ? "\(lhs) \(rhs)" : "\(lhs)\(rhs)"
    }

    private func endsSentence(text: String) -> Bool {
        guard let last = text.last else { return false }
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        return terminators.contains(last)
    }

    private func mergeDeltaText(existing: String, incoming: String) -> String {
        let normalizedIncoming = incoming
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")

        if normalizedIncoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        if existing.isEmpty { return normalizedIncoming }
        if normalizedIncoming == existing { return existing }

        // Some providers send the full in-progress text each delta.
        if normalizedIncoming.hasPrefix(existing) { return normalizedIncoming }
        if existing.hasPrefix(normalizedIncoming) || existing.hasSuffix(normalizedIncoming) {
            return existing
        }

        let overlap = suffixPrefixOverlap(existing, normalizedIncoming)
        if overlap > 0 {
            let appendStart = normalizedIncoming.index(normalizedIncoming.startIndex, offsetBy: overlap)
            return existing + normalizedIncoming[appendStart...]
        }

        // OpenAI-style token deltas: append incrementally.
        return existing + normalizedIncoming
    }

    private func suffixPrefixOverlap(_ lhs: String, _ rhs: String) -> Int {
        let maxProbe = min(96, min(lhs.count, rhs.count))
        guard maxProbe > 0 else { return 0 }

        for size in stride(from: maxProbe, through: 1, by: -1) {
            let lhsStart = lhs.index(lhs.endIndex, offsetBy: -size)
            let rhsEnd = rhs.index(rhs.startIndex, offsetBy: size)
            if lhs[lhsStart...] == rhs[..<rhsEnd] {
                return size
            }
        }

        return 0
    }
}
