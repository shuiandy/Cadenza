import Foundation
import AVFoundation
import os

/// Diarization is non-fatal here by design, and a refused retry returns without
/// touching the UI. Both outcomes are invisible to the user, so the log is the
/// only account of them — and `NSLog` was not one: unpersisted at its default
/// level on macOS 26, and redacted to `<private>` in a live stream. Only the
/// shape of a failure is `.public`; messages can embed paths under the
/// user's home. See the note on `diarizerLog` in `SpeakerDiarizer`.
private let postProcessLog = Logger(
    subsystem: "com.shuiandy.Cadenza",
    category: "PostProcessingCoordinator"
)

// MARK: - Job Phase

enum JobPhase: Equatable {
    case pendingTranscription
    case transcribing
    case pendingSummary
    case summarizing
}

enum PostProcessingJobOrigin: Equatable, Sendable {
    case liveRecording
    case importedAudio
    case crashRecovery
    case historicalBackfill
}

enum PostProcessingSubmissionOutcome: Equatable, Sendable {
    case submitted
    case deferredForActiveRecording
    case duplicate
    case refusedStorageMigration
    case invalidInheritedLease
    case backfillStateUpdateFailed
    case cancelled
}

/// Controls what happens to an explicitly queued historical backfill when its
/// active post-processing task is cancelled.
enum PostProcessingCancellationDisposition: Equatable, Sendable {
    /// Preserve the user's request by returning an interrupted historical
    /// backfill to the durable queue after its real runner exits.
    case preserveForRetry
    /// Do not restore the durable queue entry because the recording is being
    /// trashed or permanently deleted.
    case discard
}

struct PostProcessingDeletionPreparation: Sendable {
    fileprivate let recordingIDs: Set<UUID>
}

#if DEBUG
enum PostProcessingLeaseOperation: Sendable, Equatable {
    case manualSummary
    case manualTranscriptionRetry
}
#endif

enum SummaryLanguageResolver {
    static func resolve(requestedSummaryLanguage: String?, detectedTranscriptLanguage: String?, transcriptionLanguage: String?) -> String {
        if let requested = canonicalCode(requestedSummaryLanguage), requested != TranscriptionLanguage.auto.rawValue {
            return requested
        }
        if let detected = canonicalCode(detectedTranscriptLanguage), detected != TranscriptionLanguage.auto.rawValue {
            return detected
        }
        if let transcription = canonicalCode(transcriptionLanguage), transcription != TranscriptionLanguage.auto.rawValue {
            return transcription
        }
        return TranscriptionLanguage.auto.rawValue
    }

    private static let supportedCodes = Set(TranscriptionLanguage.allCases.map(\.rawValue))

    private static func canonicalCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !code.isEmpty else { return nil }
        if code == "cmn" || code.hasPrefix("cmn-") {
            return TranscriptionLanguage.chinese.rawValue
        }
        if supportedCodes.contains(code) {
            return code
        }
        if let primary = code.split(separator: "-").first.map(String.init),
           supportedCodes.contains(primary) {
            return primary
        }
        return nil
    }
}

// MARK: - Transcription Dependencies

struct TranscriptionExecutionRequest: Sendable, Equatable {
    let audioURL: URL
    let provider: AIProvider
    let apiKey: String
    let model: String?
    let language: String?
}

struct ConfiguredPostProcessingTranscription: Sendable {
    let selection: TranscriptionProviderSelection
    let language: String?
}

typealias PostProcessingTranscriptionRunner = @MainActor @Sendable (
    _ manager: TranscriptionManager,
    _ request: TranscriptionExecutionRequest
) async throws -> Void

typealias PostProcessingTranscriptionTaskFactory = @MainActor @Sendable (
    _ manager: TranscriptionManager,
    _ request: TranscriptionExecutionRequest
) -> Task<TranscriptResult, Error>

struct PostProcessingSummaryExecutionRequest: Sendable {
    let transcript: String
    let provider: AIProvider
    let language: String
    let meetingTitle: String?
    let knownTags: [String]
}

typealias PostProcessingSummaryTaskFactory = @MainActor @Sendable (
    _ generator: SummaryGenerator,
    _ request: PostProcessingSummaryExecutionRequest
) -> Task<Void, Never>

struct PostProcessingTranscriptionDependencies {
    let defaults: UserDefaults
    let apiKey: @MainActor @Sendable (AIProvider) -> String?
    let supportsAppleLanguage: @MainActor @Sendable (String) async -> Bool
    let localWhisperState: @MainActor @Sendable () -> LocalWhisperState

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> Self {
        Self(
            defaults: defaults,
            apiKey: { provider in
                KeychainManager.shared.readOnlyAPIKey(for: provider)
            },
            supportsAppleLanguage: { language in
                await AppleSpeechFactory.supportsLanguage(language)
            },
            localWhisperState: {
                let manager = WhisperModelManager.shared
                let model = manager.selectedModel
                return LocalWhisperState(model: model, isAvailable: manager.isAvailable(model))
            }
        )
    }
}

/// Orchestrates post-processing (transcription + summary) in the main process.
/// Transcription and summary are called directly via async/await (network I/O only).
/// Export and store writes happen directly in the main process.
///
/// Concurrency model:
/// - Transcription pool: max 2 simultaneous transcriptions
/// - Summary pool: max 1 simultaneous summary
/// - Each job gets its own TranscriptionManager + SummaryGenerator instances
@Observable @MainActor
final class PostProcessingCoordinator {
    var store: RecordingsStore
    var exportService: ExportService? {
        didSet {
            oldValue?.onAutoExportFeedback = nil
            exportService?.onAutoExportFeedback = { [weak self] feedback in
                self?.postProcessingError = feedback.message
            }
        }
    }

    @ObservationIgnored
    var transcriptionDependencies: PostProcessingTranscriptionDependencies

    @ObservationIgnored
    private let audioFinalizerDependenciesOverride: RecordingAudioFinalizerDependencies?

    /// Shared with RecordingEngine after app wiring. Each coordinator owns an
    /// isolated gate by default so independent tests and profiles cannot
    /// interfere with one another.
    @ObservationIgnored
    let recordingProcessingGate: RecordingProcessingGate

    @ObservationIgnored
    /// Live storage-root provider: the default re-reads the active location
    /// on every call, so a completed directory migration is visible to the
    /// next operation. Each leased operation snapshots the root once inside
    /// its lease and uses that snapshot throughout; the URL is never cached
    /// across operations.
    private let recordingsDirectoryProvider: @Sendable () -> URL

    /// Storage-migration exclusion for crash recovery; tests inject an
    /// isolated gate.
    var migrationGate: StorageMigrationGate = .shared

    @ObservationIgnored
    var transcriptionRunnerOverride: PostProcessingTranscriptionRunner?

    @ObservationIgnored
    var transcriptionTaskFactoryOverride: PostProcessingTranscriptionTaskFactory?

    @ObservationIgnored
    var summaryTaskFactoryOverride: PostProcessingSummaryTaskFactory?

#if DEBUG
    /// Deterministic suspension immediately after a manual processing lease is
    /// claimed and before the operation's first production await.
    @ObservationIgnored
    var afterManualProcessingClaimForTesting: (@MainActor @Sendable (PostProcessingLeaseOperation) async -> Void)?
#endif

    /// Dedicated instances for manual (single-shot) operations.
    private let manualTranscriptionManager = TranscriptionManager()
    private let manualSummaryGenerator = SummaryGenerator()

    var postProcessingError: String?
    var backfillFailureCooldown: TimeInterval = 24 * 3600
    var maxAutomaticBackfillFailures = 2
    private(set) var postProcessingCompletedToken: Int = 0

    // Manual retry flags (private — exposed per-recordingID via methods)
    private var isGeneratingSummary = false
    private var manualGeneratingRecordingID: UUID?
    private var isRetryingTranscription = false
    private var manualRetryingRecordingID: UUID?
    private(set) var manualRetryChunksDone: Int = 0
    private(set) var manualRetryChunksTotal: Int = 0

    /// Called when recordings data changes (for UI refresh).
    var onRecordingsChanged: (() -> Void)?
    /// Called when a recording is auto-discarded (for UI feedback).
    var onRecordingDiscarded: ((_ recordingID: UUID, _ reason: String) -> Void)?

    /// Notify that a recording was auto-discarded (e.g. too short).
    /// Use this from external callers instead of accessing callbacks directly.
    func notifyRecordingDiscarded(id: UUID, reason: String) {
        onRecordingsChanged?()
        onRecordingDiscarded?(id, reason)
    }
    /// Called when post-processing succeeds (for auto-linking calendar events, etc.).
    var onPostProcessingCompleted: ((UUID) -> Void)?

    @ObservationIgnored
    var speakerMemoryRunner: ((_ recordingID: UUID, _ audioURL: URL, _ entries: [TranscriptEntry]) -> Void)?

    @ObservationIgnored
    var historicalBackfillStartHook: ((RecordingsStore.BackfillRecording) -> Bool)?

    /// Tracks in-flight on-demand chapter generation to prevent duplicate LLM requests.
    private var chaptersInFlight: Set<UUID> = []

    // MARK: - Concurrent Pool Infrastructure

    private struct ActiveJob {
        let recordingID: UUID
        let generation: UUID
        let audioURL: URL
        let meetingTitle: String?
        let origin: PostProcessingJobOrigin
        var phase: JobPhase
        var task: Task<Void, Never>?
        var chunksDone: Int = 0
        var chunksTotal: Int = 0
        var error: String?
        var summaryGenerator: SummaryGenerator?
        /// Handle to the currently-running detached task (transcription or summary)
        /// so cancelCurrentJob() can propagate cancellation to actual network I/O.
        var activeDetachedTask: (any Sendable)?
    }

    private struct DeferredSubmission {
        let recordingID: UUID
        let audioURL: URL
        let meetingTitle: String?
        let origin: PostProcessingJobOrigin
        let historicalBackfillRecord: RecordingsStore.BackfillRecording?
    }

    /// A pool permit belongs to the running operation, not to the observable job.
    /// Cancelling/removing a job must not make capacity available while a
    /// cancellation-uncooperative runner is still executing.
    private struct SlotLease: Sendable {
        let id: UUID
    }

    private struct SlotWaiter {
        let recordingID: UUID
        let generation: UUID
        let continuation: CheckedContinuation<SlotLease?, Never>
    }

    /// Persists the real task lifetime after observable job state is removed.
    /// Soft delete intentionally removes `jobs[recordingID]` immediately, but
    /// a cancellation-uncooperative runner can keep using the audio and store
    /// until this task releases its processing and migration leases.
    private struct JobTaskLifetime {
        let generation: UUID
        let task: Task<Void, Never>
    }

    /// Raw job table. Rewritten on every chunk progress callback, so it must
    /// never be a view input: with `@Observable` tracking, each rewrite would
    /// invalidate every card that asked for its phase (ARCHITECTURE §12.1).
    /// Views read the projections below, which change only on real transitions.
    @ObservationIgnored private var jobs: [UUID: ActiveJob] = [:] {
        didSet { syncJobProjection() }
    }
    /// Per-recording phase, written only when a phase actually changes.
    private(set) var jobPhases: [UUID: JobPhase] = [:]
    /// Chunk progress of the single transcribing job, for the toolbar pill.
    private(set) var activeTranscriptionChunksDone = 0
    private(set) var activeTranscriptionChunksTotal = 0

    private func syncJobProjection() {
        let phases = jobs.mapValues(\.phase)
        if phases != jobPhases { jobPhases = phases }
        let transcribing = jobs.values.filter { $0.phase == .transcribing }
        let done = transcribing.count == 1 ? transcribing[0].chunksDone : 0
        let total = transcribing.count == 1 ? transcribing[0].chunksTotal : 0
        if done != activeTranscriptionChunksDone { activeTranscriptionChunksDone = done }
        if total != activeTranscriptionChunksTotal { activeTranscriptionChunksTotal = total }
    }
    private var transcriptionSlotsAvailable = maxTranscriptionSlots
    private var summarySlotsAvailable = maxSummarySlots
    private var transcriptionWaiters: [SlotWaiter] = []
    private var summaryWaiters: [SlotWaiter] = []
    private var activeTranscriptionLeases: Set<UUID> = []
    private var activeSummaryLeases: Set<UUID> = []

    @ObservationIgnored
    private var deferredSubmissions: [UUID: DeferredSubmission] = [:]
    @ObservationIgnored
    private var deferredSubmissionOrder: [UUID] = []
    @ObservationIgnored
    private var submissionReservations: Set<UUID> = []
    @ObservationIgnored
    private var cancelledSubmissionReservations: [UUID: PostProcessingCancellationDisposition] = [:]
    @ObservationIgnored
    private var historicalCancellationFinalizations: [UUID: HistoricalCancellationFinalization] = [:]
    @ObservationIgnored
    private var jobTaskLifetimes: [UUID: [UUID: JobTaskLifetime]] = [:]
    /// Reference-counted barriers owned by hard-delete callers. A barrier is
    /// installed before cancellation and remains until the corresponding
    /// model/file transaction finishes, so a suspended submitter cannot
    /// restart the same recording in the cancellation-to-delete window.
    @ObservationIgnored
    private var deletionBarrierCounts: [UUID: Int] = [:]
    @ObservationIgnored
    private var deferredDrainScheduled = false
    @ObservationIgnored
    private var deferredAllIdleObserverID: UUID?

    private struct HistoricalCancellationFinalization {
        let generation: UUID
        var disposition: PostProcessingCancellationDisposition
    }

    private func isDeletionBlocked(_ recordingID: UUID) -> Bool {
        (deletionBarrierCounts[recordingID] ?? 0) > 0
    }

    // MARK: - Backward-Compatible Computed Properties

    var isPostProcessing: Bool { !jobPhases.isEmpty }

    var postProcessingPhase: String? {
        if isRetryingTranscription { return "transcribing" }
        if isGeneratingSummary { return "summarizing" }
        if jobPhases.values.contains(.transcribing) { return "transcribing" }
        if jobPhases.values.contains(.summarizing) { return "summarizing" }
        if jobPhases.values.contains(where: { $0 == .pendingTranscription || $0 == .pendingSummary }) { return "transcribing" }
        return nil
    }

    var transcriptionChunksDone: Int {
        if isRetryingTranscription && manualRetryChunksTotal > 0 {
            return manualRetryChunksDone
        }
        return activeTranscriptionChunksDone
    }

    var transcriptionChunksTotal: Int {
        if isRetryingTranscription && manualRetryChunksTotal > 0 {
            return manualRetryChunksTotal
        }
        return activeTranscriptionChunksTotal
    }

    var transcriptionProgress: Double {
        let total = transcriptionChunksTotal
        return total > 0 ? Double(transcriptionChunksDone) / Double(total) : 0
    }

    var summaryStreamedText: String {
        get {
            if isGeneratingSummary {
                return manualSummaryGenerator.streamedText
            }
            return jobs.values.first(where: { $0.phase == .summarizing })?.summaryGenerator?.streamedText ?? ""
        }
        set { /* streaming text owned by per-job generator or manualSummaryGenerator */ }
    }

    /// True when the enrich phase is running for a specific recording.
    func isEnrichingSummary(for recordingID: UUID) -> Bool {
        if isGeneratingSummary, manualGeneratingRecordingID == recordingID {
            return manualSummaryGenerator.isEnriching
        }
        return jobs[recordingID]?.summaryGenerator?.isEnriching ?? false
    }

    /// Quick summary result for a specific recording (available during enrich phase, not yet persisted).
    func quickSummaryResult(for recordingID: UUID) -> SummaryResult? {
        if isGeneratingSummary, manualGeneratingRecordingID == recordingID {
            return manualSummaryGenerator.quickResult
        }
        return jobs[recordingID]?.summaryGenerator?.quickResult
    }

    /// True when a manual summary generation is running for a specific recording.
    func isGeneratingSummary(for recordingID: UUID) -> Bool {
        isGeneratingSummary && manualGeneratingRecordingID == recordingID
    }

    /// True when a manual transcription retry is running for a specific recording.
    func isRetryingTranscription(for recordingID: UUID) -> Bool {
        isRetryingTranscription && manualRetryingRecordingID == recordingID
    }

    func isProcessing(recordingID: UUID) -> Bool {
        jobPhases[recordingID] != nil
    }

    /// Per-recording job phase for collection status chips (nil when idle).
    func jobPhase(for recordingID: UUID) -> JobPhase? {
        jobPhases[recordingID]
    }

    /// Exclusivity signal for operations that require a stable storage root
    /// (e.g. changing the recordings directory): true while any job, manual
    /// retry, or summary generation is running.
    var hasActiveWork: Bool {
        recordingProcessingGate.hasProcessingLeases
            || !jobPhases.isEmpty
            || !jobTaskLifetimes.isEmpty
            || !deferredSubmissions.isEmpty
            || !submissionReservations.isEmpty
            || isRetryingTranscription
            || isGeneratingSummary
    }

    init(
        store: RecordingsStore,
        transcriptionDependencies: PostProcessingTranscriptionDependencies? = nil,
        audioFinalizerDependencies: RecordingAudioFinalizerDependencies? = nil,
        recordingProcessingGate: RecordingProcessingGate = RecordingProcessingGate(),
        recordingsDirectory: @autoclosure @escaping @Sendable () -> URL
            = StorageLocationManager.recordingsDirectory
    ) {
        self.store = store
        self.transcriptionDependencies = transcriptionDependencies ?? .live()
        self.audioFinalizerDependenciesOverride = audioFinalizerDependencies
        self.recordingProcessingGate = recordingProcessingGate
        self.recordingsDirectoryProvider = recordingsDirectory
    }

    // MARK: - Slot Acquire / Release

    private func isCurrentJob(recordingID: UUID, generation: UUID) -> Bool {
        jobs[recordingID]?.generation == generation
    }

    @discardableResult
    private func updateCurrentJob(
        recordingID: UUID,
        generation: UUID,
        _ update: (inout ActiveJob) -> Void
    ) -> Bool {
        guard var job = jobs[recordingID], job.generation == generation else { return false }
        update(&job)
        jobs[recordingID] = job
        return true
    }

    private func acquireTranscriptionSlot(recordingID: UUID, generation: UUID) async -> SlotLease? {
        guard isCurrentJob(recordingID: recordingID, generation: generation) else { return nil }
        if transcriptionSlotsAvailable > 0 {
            transcriptionSlotsAvailable -= 1
            let lease = SlotLease(id: UUID())
            activeTranscriptionLeases.insert(lease.id)
            return lease
        }
        return await withCheckedContinuation { continuation in
            guard isCurrentJob(recordingID: recordingID, generation: generation) else {
                continuation.resume(returning: nil)
                return
            }
            transcriptionWaiters.append(SlotWaiter(
                recordingID: recordingID,
                generation: generation,
                continuation: continuation
            ))
        }
    }

    private static let maxTranscriptionSlots = 2
    private static let maxSummarySlots = 1

    private func releaseTranscriptionSlot(_ lease: SlotLease) {
        guard activeTranscriptionLeases.remove(lease.id) != nil else { return }
        makeTranscriptionSlotAvailable()
    }

    private func makeTranscriptionSlotAvailable() {
        while !transcriptionWaiters.isEmpty {
            let waiter = transcriptionWaiters.removeFirst()
            guard isCurrentJob(recordingID: waiter.recordingID, generation: waiter.generation) else {
                waiter.continuation.resume(returning: nil)
                continue
            }
            let lease = SlotLease(id: UUID())
            activeTranscriptionLeases.insert(lease.id)
            waiter.continuation.resume(returning: lease)
            return
        }
        transcriptionSlotsAvailable = min(transcriptionSlotsAvailable + 1, Self.maxTranscriptionSlots)
    }

    private func acquireSummarySlot(recordingID: UUID, generation: UUID) async -> SlotLease? {
        guard isCurrentJob(recordingID: recordingID, generation: generation) else { return nil }
        if summarySlotsAvailable > 0 {
            summarySlotsAvailable -= 1
            let lease = SlotLease(id: UUID())
            activeSummaryLeases.insert(lease.id)
            return lease
        }
        return await withCheckedContinuation { continuation in
            guard isCurrentJob(recordingID: recordingID, generation: generation) else {
                continuation.resume(returning: nil)
                return
            }
            summaryWaiters.append(SlotWaiter(
                recordingID: recordingID,
                generation: generation,
                continuation: continuation
            ))
        }
    }

    private func releaseSummarySlot(_ lease: SlotLease) {
        guard activeSummaryLeases.remove(lease.id) != nil else { return }
        makeSummarySlotAvailable()
    }

    private func makeSummarySlotAvailable() {
        while !summaryWaiters.isEmpty {
            let waiter = summaryWaiters.removeFirst()
            guard isCurrentJob(recordingID: waiter.recordingID, generation: waiter.generation) else {
                waiter.continuation.resume(returning: nil)
                continue
            }
            let lease = SlotLease(id: UUID())
            activeSummaryLeases.insert(lease.id)
            waiter.continuation.resume(returning: lease)
            return
        }
        summarySlotsAvailable = min(summarySlotsAvailable + 1, Self.maxSummarySlots)
    }

    private func cancelWaiters(recordingID: UUID, generation: UUID) {
        let cancelledTranscription = transcriptionWaiters.filter {
            $0.recordingID == recordingID && $0.generation == generation
        }
        transcriptionWaiters.removeAll {
            $0.recordingID == recordingID && $0.generation == generation
        }
        for waiter in cancelledTranscription {
            waiter.continuation.resume(returning: nil)
        }

        let cancelledSummary = summaryWaiters.filter {
            $0.recordingID == recordingID && $0.generation == generation
        }
        summaryWaiters.removeAll {
            $0.recordingID == recordingID && $0.generation == generation
        }
        for waiter in cancelledSummary {
            waiter.continuation.resume(returning: nil)
        }
    }

    // MARK: - Cancel Support

    /// Establishes a per-recording deletion barrier, cancels observable jobs,
    /// and waits for their real tasks (including cancellation-uncooperative
    /// runners) plus any already-running manual operation to exit. The caller
    /// must keep the returned preparation alive through the store transaction
    /// and balance it with `finishDeletionPreparation`.
    func prepareForDeletion(
        recordingIDs: [UUID]
    ) async -> PostProcessingDeletionPreparation {
        let targets = Set(recordingIDs)
        for recordingID in targets {
            deletionBarrierCounts[recordingID, default: 0] += 1
        }

        for recordingID in targets {
            cancelJob(for: recordingID, disposition: .discard)
        }
        let activeTasks = targets.flatMap { recordingID in
            jobTaskLifetimes[recordingID]?.values.map(\.task) ?? []
        }
        for task in activeTasks {
            await task.value
        }

        // Submission reservations and manual operations do not expose an
        // outer Task handle. They all own their processing lease until their
        // async method really returns, so wait for their target-specific state
        // to clear while the deletion barrier prevents a replacement start.
        while targets.contains(where: hasDeletionTargetActivity) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return PostProcessingDeletionPreparation(recordingIDs: targets)
    }

    func finishDeletionPreparation(_ preparation: PostProcessingDeletionPreparation) {
        for recordingID in preparation.recordingIDs {
            guard let count = deletionBarrierCounts[recordingID] else { continue }
            if count <= 1 {
                deletionBarrierCounts.removeValue(forKey: recordingID)
            } else {
                deletionBarrierCounts[recordingID] = count - 1
            }
        }
    }

    private func hasDeletionTargetActivity(_ recordingID: UUID) -> Bool {
        jobs[recordingID] != nil
            || jobTaskLifetimes[recordingID]?.isEmpty == false
            || submissionReservations.contains(recordingID)
            || historicalCancellationFinalizations[recordingID] != nil
            || (isGeneratingSummary && manualGeneratingRecordingID == recordingID)
            || (isRetryingTranscription && manualRetryingRecordingID == recordingID)
    }

    /// Cancel a specific recording's post-processing job.
    func cancelJob(
        for recordingID: UUID,
        disposition: PostProcessingCancellationDisposition = .preserveForRetry
    ) {
        removeDeferredSubmission(recordingID)
        if submissionReservations.contains(recordingID) {
            recordReservationCancellation(recordingID: recordingID, disposition: disposition)
        }
        if var cancellation = historicalCancellationFinalizations[recordingID] {
            cancellation.disposition = mergedCancellationDisposition(
                cancellation.disposition,
                disposition
            )
            historicalCancellationFinalizations[recordingID] = cancellation
        }
        guard let job = jobs[recordingID] else { return }
        NSLog("[PostProcessCoord] cancelling job for %@", recordingID.uuidString)
        if job.origin == .historicalBackfill {
            historicalCancellationFinalizations[recordingID] = HistoricalCancellationFinalization(
                generation: job.generation,
                disposition: disposition
            )
        }
        job.task?.cancel()
        if let detached = job.activeDetachedTask as? Task<Void, Never> {
            detached.cancel()
        } else if let detached = job.activeDetachedTask as? Task<TranscriptResult, Error> {
            detached.cancel()
        }
        cancelWaiters(recordingID: recordingID, generation: job.generation)
        jobs.removeValue(forKey: recordingID)
    }

    /// Cancel all active post-processing jobs.
    func cancelCurrentJob(
        disposition: PostProcessingCancellationDisposition = .preserveForRetry
    ) {
        guard !jobs.isEmpty
                || !deferredSubmissions.isEmpty
                || !submissionReservations.isEmpty
                || !historicalCancellationFinalizations.isEmpty else {
            return
        }
        NSLog(
            "[PostProcessCoord] cancelling %d active and %d deferred job(s)",
            jobs.count,
            deferredSubmissions.count
        )
        deferredSubmissions.removeAll()
        deferredSubmissionOrder.removeAll()
        for recordingID in submissionReservations {
            recordReservationCancellation(recordingID: recordingID, disposition: disposition)
        }
        for (recordingID, var cancellation) in historicalCancellationFinalizations {
            cancellation.disposition = mergedCancellationDisposition(
                cancellation.disposition,
                disposition
            )
            historicalCancellationFinalizations[recordingID] = cancellation
        }
        let activeJobs = Array(jobs.values)
        for job in activeJobs {
            if job.origin == .historicalBackfill {
                historicalCancellationFinalizations[job.recordingID] = HistoricalCancellationFinalization(
                    generation: job.generation,
                    disposition: disposition
                )
            }
            job.task?.cancel()
            // Cancel the detached transcription/summary task so network I/O stops
            if let detached = job.activeDetachedTask as? Task<Void, Never> {
                detached.cancel()
            } else if let detached = job.activeDetachedTask as? Task<TranscriptResult, Error> {
                detached.cancel()
            }
        }
        for waiter in transcriptionWaiters {
            waiter.continuation.resume(returning: nil)
        }
        for waiter in summaryWaiters {
            waiter.continuation.resume(returning: nil)
        }
        jobs.removeAll()
        transcriptionWaiters.removeAll()
        summaryWaiters.removeAll()
    }

    private func recordReservationCancellation(
        recordingID: UUID,
        disposition: PostProcessingCancellationDisposition
    ) {
        if let existing = cancelledSubmissionReservations[recordingID] {
            cancelledSubmissionReservations[recordingID] = mergedCancellationDisposition(
                existing,
                disposition
            )
        } else {
            cancelledSubmissionReservations[recordingID] = disposition
        }
    }

    private func mergedCancellationDisposition(
        _ lhs: PostProcessingCancellationDisposition,
        _ rhs: PostProcessingCancellationDisposition
    ) -> PostProcessingCancellationDisposition {
        if lhs == .discard || rhs == .discard {
            return .discard
        }
        return .preserveForRetry
    }

    // MARK: - Auto Post-Processing (after recording stops)

    @discardableResult
    func startPostProcessing(
        recordingID: UUID,
        audioURL: URL,
        meetingTitle: String?,
        origin: PostProcessingJobOrigin = .liveRecording,
        inheritedProcessingLease: RecordingProcessingGate.ProcessingLease? = nil,
        historicalBackfillRecord: RecordingsStore.BackfillRecording? = nil
    ) async -> PostProcessingSubmissionOutcome {
        let submission = DeferredSubmission(
            recordingID: recordingID,
            audioURL: audioURL,
            meetingTitle: meetingTitle,
            origin: origin,
            historicalBackfillRecord: historicalBackfillRecord
        )
        return await submitPostProcessing(
            submission,
            inheritedProcessingLease: inheritedProcessingLease
        )
    }

    private func submitPostProcessing(
        _ submission: DeferredSubmission,
        inheritedProcessingLease: RecordingProcessingGate.ProcessingLease? = nil
    ) async -> PostProcessingSubmissionOutcome {
        let recordingID = submission.recordingID
        guard !isDeletionBlocked(recordingID) else {
            NSLog("[PostProcessCoord] submission blocked by deletion for %@", recordingID.uuidString)
            recordingProcessingGate.releaseProcessing(inheritedProcessingLease)
            return .cancelled
        }
        guard jobs[recordingID] == nil,
              !submissionReservations.contains(recordingID),
              historicalCancellationFinalizations[recordingID] == nil,
              deferredSubmissions[recordingID] == nil else {
            NSLog("[PostProcessCoord] job already active for %@, skipping", recordingID.uuidString)
            recordingProcessingGate.releaseProcessing(inheritedProcessingLease)
            return .duplicate
        }
        submissionReservations.insert(recordingID)

        let processingLease: RecordingProcessingGate.ProcessingLease
        if let inheritedProcessingLease {
            guard recordingProcessingGate.ownsProcessing(inheritedProcessingLease) else {
                NSLog("[PostProcessCoord] inherited processing lease is invalid for %@", recordingID.uuidString)
                submissionReservations.remove(recordingID)
                return .invalidInheritedLease
            }
            processingLease = inheritedProcessingLease
        } else {
            guard let claimedLease = recordingProcessingGate.claimProcessing() else {
                submissionReservations.remove(recordingID)
                return deferSubmissionUntilRecordingStops(submission)
            }
            processingLease = claimedLease
        }
        // The lease spans the job task's real lifetime: cancellation removes
        // the observable job immediately, but the root stays claimed until
        // the runner actually returns.
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[PostProcessCoord] startPostProcessing refused: storage migration in progress")
            recordingProcessingGate.releaseProcessing(processingLease)
            submissionReservations.remove(recordingID)
            return .refusedStorageMigration
        }

        if submission.origin == .historicalBackfill {
            let marked = await store.markBackfillProcessing(recordingID: recordingID)
            if let disposition = cancelledSubmissionReservations.removeValue(forKey: recordingID) {
                if marked, disposition == .preserveForRetry {
                    _ = await store.enqueuePostProcessingBackfill(
                        recordingID: recordingID,
                        source: "cancelled-before-submit"
                    )
                }
                submissionReservations.remove(recordingID)
                migrationGate.releaseActivity(migrationLease)
                recordingProcessingGate.releaseProcessing(processingLease)
                return .cancelled
            }
            guard marked else {
                NSLog("[PostProcessCoord] historical backfill state update failed for %@", recordingID.uuidString)
                submissionReservations.remove(recordingID)
                migrationGate.releaseActivity(migrationLease)
                recordingProcessingGate.releaseProcessing(processingLease)
                return .backfillStateUpdateFailed
            }
            if let record = submission.historicalBackfillRecord,
               let historicalBackfillStartHook,
               historicalBackfillStartHook(record) {
                submissionReservations.remove(recordingID)
                migrationGate.releaseActivity(migrationLease)
                recordingProcessingGate.releaseProcessing(processingLease)
                return .submitted
            }
        }

        guard cancelledSubmissionReservations.removeValue(forKey: recordingID) == nil else {
            submissionReservations.remove(recordingID)
            migrationGate.releaseActivity(migrationLease)
            recordingProcessingGate.releaseProcessing(processingLease)
            return .cancelled
        }

        let generation = UUID()
        var job = ActiveJob(
            recordingID: recordingID,
            generation: generation,
            audioURL: submission.audioURL,
            meetingTitle: submission.meetingTitle,
            origin: submission.origin,
            phase: .pendingTranscription
        )
        let gate = migrationGate
        let recordingProcessingGate = recordingProcessingGate
        let jobTask = Task { @MainActor [weak self] in
            if let self {
                await self.processJob(recordingID: recordingID, generation: generation)
                await self.restoreCancelledHistoricalBackfillIfNeeded(
                    recordingID: recordingID,
                    generation: generation
                )
            }
            gate.releaseActivity(migrationLease)
            recordingProcessingGate.releaseProcessing(processingLease)
            self?.completeHistoricalCancellationFinalization(
                recordingID: recordingID,
                generation: generation
            )
            self?.completeJobTaskLifetime(
                recordingID: recordingID,
                generation: generation
            )
        }
        job.task = jobTask
        jobTaskLifetimes[recordingID, default: [:]][generation] = JobTaskLifetime(
            generation: generation,
            task: jobTask
        )
        jobs[recordingID] = job
        submissionReservations.remove(recordingID)
        NSLog(
            "[PostProcessCoord] submitted job for %@ origin=%@ active=%d",
            recordingID.uuidString,
            "\(submission.origin)",
            jobs.count
        )
        return .submitted
    }

    /// Cancellation removes observable job state immediately, but the durable
    /// backfill must stay `processing` until the cancellation-uncooperative
    /// runner really exits. Restore it while both leases are still held; the
    /// finalization tombstone prevents another submission in that small window.
    private func restoreCancelledHistoricalBackfillIfNeeded(
        recordingID: UUID,
        generation: UUID
    ) async {
        guard let cancellation = historicalCancellationFinalizations[recordingID],
              cancellation.generation == generation,
              cancellation.disposition == .preserveForRetry else {
            return
        }
        let restored = await store.enqueuePostProcessingBackfill(
            recordingID: recordingID,
            source: "cancelled-active-job"
        )
        NSLog(
            "[PostProcessCoord] cancelled historical backfill %@ restored=%d",
            recordingID.uuidString,
            restored ? 1 : 0
        )
    }

    private func completeHistoricalCancellationFinalization(
        recordingID: UUID,
        generation: UUID
    ) {
        guard historicalCancellationFinalizations[recordingID]?.generation == generation else {
            return
        }
        historicalCancellationFinalizations.removeValue(forKey: recordingID)
    }

    private func completeJobTaskLifetime(recordingID: UUID, generation: UUID) {
        guard var lifetimes = jobTaskLifetimes[recordingID],
              lifetimes[generation]?.generation == generation else {
            return
        }
        lifetimes.removeValue(forKey: generation)
        if lifetimes.isEmpty {
            jobTaskLifetimes.removeValue(forKey: recordingID)
        } else {
            jobTaskLifetimes[recordingID] = lifetimes
        }
    }

    private func deferSubmissionUntilRecordingStops(
        _ submission: DeferredSubmission
    ) -> PostProcessingSubmissionOutcome {
        guard deferredSubmissions[submission.recordingID] == nil else {
            return .duplicate
        }
        deferredSubmissions[submission.recordingID] = submission
        deferredSubmissionOrder.append(submission.recordingID)
        installDeferredAllIdleObserverIfNeeded()
        NSLog(
            "[PostProcessCoord] deferred job for %@ until recording is idle",
            submission.recordingID.uuidString
        )
        return .deferredForActiveRecording
    }

    private func installDeferredAllIdleObserverIfNeeded() {
        guard deferredAllIdleObserverID == nil else { return }
        deferredAllIdleObserverID = recordingProcessingGate.observeAllIdle { [weak self] in
            self?.scheduleDeferredSubmissionDrain()
        }
    }

    private func scheduleDeferredSubmissionDrain() {
        guard !deferredSubmissions.isEmpty, !deferredDrainScheduled else { return }
        deferredDrainScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deferredDrainScheduled = false
            await self.drainDeferredSubmissions()
        }
    }

    private func drainDeferredSubmissions() async {
        guard !recordingProcessingGate.hasRecordingLease else { return }
        let recordingIDs = deferredSubmissionOrder
        for recordingID in recordingIDs {
            guard let submission = deferredSubmissions.removeValue(forKey: recordingID) else {
                continue
            }
            deferredSubmissionOrder.removeAll { $0 == recordingID }
            _ = await submitPostProcessing(submission)
        }
    }

    @discardableResult
    private func removeDeferredSubmission(_ recordingID: UUID) -> DeferredSubmission? {
        deferredSubmissionOrder.removeAll { $0 == recordingID }
        return deferredSubmissions.removeValue(forKey: recordingID)
    }

    private func finishJob(
        recordingID: UUID,
        generation: UUID,
        didFail: Bool,
        error: String? = nil
    ) async {
        guard let job = jobs[recordingID], job.generation == generation else { return }
        let origin = job.origin
        cancelWaiters(recordingID: recordingID, generation: generation)
        jobs.removeValue(forKey: recordingID)
        if origin == .historicalBackfill {
            await finishHistoricalBackfill(recordingID: recordingID, didFail: didFail, error: error)
        }
    }

    func finishHistoricalBackfill(recordingID: UUID, didFail: Bool, error: String? = nil) async {
        if didFail {
            await store.markBackfillFailed(
                recordingID: recordingID,
                error: error ?? postProcessingError ?? "Post-processing failed",
                maxAutomaticFailures: maxAutomaticBackfillFailures,
                cooldown: backfillFailureCooldown
            )
        } else {
            let completed = await store.markBackfillCompleted(recordingID: recordingID)
            if !completed {
                await store.markBackfillFailed(
                    recordingID: recordingID,
                    error: "Post-processing did not produce both transcript and summary",
                    maxAutomaticFailures: maxAutomaticBackfillFailures,
                    cooldown: backfillFailureCooldown
                )
            }
        }
        await processQueuedHistoricalBackfill(limit: 1)
    }

    // MARK: - Job Processing Pipeline

    /// Minimum recording duration (in seconds) to attempt transcription.
    /// Shorter recordings are auto-discarded — silence/noise causes API hallucinations.
    private static let minimumTranscriptionDuration: TimeInterval = 30

    private func processJob(recordingID: UUID, generation: UUID) async {
        guard let job = jobs[recordingID], job.generation == generation else { return }
        let audioURL = job.audioURL
        let meetingTitle = job.meetingTitle

        // Verify audio file exists before processing
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            NSLog("[PostProcessCoord] audio file missing at %@, skipping job for %@", audioURL.path, recordingID.uuidString)
            await finishJob(
                recordingID: recordingID,
                generation: generation,
                didFail: true,
                error: "Audio file missing"
            )
            return
        }

        // Configuration errors are retryable and must never trigger short-recording
        // deletion or consume a transcription slot.
        let configuration: ConfiguredPostProcessingTranscription
        do {
            configuration = try await resolveConfiguredTranscriptionProvider()
        } catch {
            guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
                return
            }
            let message = error.localizedDescription
            NSLog("[PostProcessCoord] transcription configuration invalid for %@: %@", recordingID.uuidString, message)
            postProcessingError = message
            updateCurrentJob(recordingID: recordingID, generation: generation) {
                $0.error = message
            }
            await finishJob(
                recordingID: recordingID,
                generation: generation,
                didFail: true,
                error: message
            )
            return
        }
        guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
            return
        }

        // Auto-discard recordings too short for meaningful transcription
        let recordingDuration = await store.fetchRecordingDuration(recordingID: recordingID)
        guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
            return
        }
        if recordingDuration > 0 && recordingDuration < Self.minimumTranscriptionDuration {
            NSLog("[PostProcessCoord] recording %.0fs < %.0fs minimum, auto-discarding", recordingDuration, Self.minimumTranscriptionDuration)
            await store.trashRecording(recordingID: recordingID, reason: "recording_too_short")
            onRecordingsChanged?()
            onRecordingDiscarded?(
                recordingID,
                String(localized: "The recording was too short and was discarded.")
            )
            await finishJob(recordingID: recordingID, generation: generation, didFail: false)
            return
        }

        // Create per-job transcription manager (SummaryGenerator created later if needed)
        let transcriptionManager = TranscriptionManager()
        var didFail = false

        var fullText = ""
        var entries: [TranscriptEntry]?
        var detectedLang: String?
        var actualProvider: AIProvider?
        var whisperRawResults: (any Sendable)?
        let selection = configuration.selection

        // Step 1: Transcription — the lease remains held until the runner's await
        // actually returns, even if the observable job is cancelled meanwhile.
        guard let transcriptionLease = await acquireTranscriptionSlot(
            recordingID: recordingID,
            generation: generation
        ) else { return }
        do {
            defer { releaseTranscriptionSlot(transcriptionLease) }
            guard isCurrentJob(recordingID: recordingID, generation: generation),
                  !Task.isCancelled else { return }

            updateCurrentJob(recordingID: recordingID, generation: generation) {
                $0.phase = .transcribing
            }

            transcriptionManager.onProgress = { [weak self] done, total in
                Task { @MainActor in
                    self?.updateCurrentJob(recordingID: recordingID, generation: generation) {
                        $0.chunksDone = done
                        $0.chunksTotal = total
                    }
                }
            }

            do {
                var taskResult: TranscriptResult?
                let request = TranscriptionExecutionRequest(
                    audioURL: audioURL,
                    provider: selection.provider,
                    apiKey: selection.apiKey ?? "",
                    model: selection.model,
                    language: configuration.language
                )
                if let transcriptionRunnerOverride {
                    try await transcriptionRunnerOverride(transcriptionManager, request)
                } else {
                    let usesTaskFactoryOverride = transcriptionTaskFactoryOverride != nil
                    let transcriptionTask = if let transcriptionTaskFactoryOverride {
                        transcriptionTaskFactoryOverride(transcriptionManager, request)
                    } else {
                        Task.detached(priority: ProcessingWorkPriority.shared.current) { [transcriptionManager] in
                            try await transcriptionManager.transcribeFile(
                                at: request.audioURL,
                                provider: request.provider,
                                apiKey: request.apiKey,
                                language: request.language,
                                model: request.model
                            )
                        }
                    }
                    updateCurrentJob(recordingID: recordingID, generation: generation) {
                        $0.activeDetachedTask = transcriptionTask
                    }
                    let result = try await transcriptionTask.value
                    if usesTaskFactoryOverride {
                        taskResult = result
                    }
                    updateCurrentJob(recordingID: recordingID, generation: generation) {
                        $0.activeDetachedTask = nil
                    }
                }
                actualProvider = selection.provider
                if let taskResult {
                    fullText = taskResult.text
                    entries = taskResult.segments.map {
                        TranscriptEntry(
                            startTime: $0.startTime,
                            endTime: $0.endTime,
                            text: $0.text,
                            speaker: $0.speaker
                        )
                    }
                    detectedLang = taskResult.language
                    whisperRawResults = taskResult.whisperResults
                } else {
                    fullText = transcriptionManager.fullText
                    entries = Self.buildEntries(from: transcriptionManager.segments)
                    detectedLang = transcriptionManager.detectedLanguage
                    whisperRawResults = transcriptionManager.lastWhisperResults
                }
                transcriptionManager.reset()
            } catch {
                updateCurrentJob(recordingID: recordingID, generation: generation) {
                    $0.activeDetachedTask = nil
                }
                if isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled {
                    postProcessingError = String(
                        localized: "Transcription failed: \(error.localizedDescription)"
                    )
                    didFail = true
                }
                transcriptionManager.reset()
            }
        }

        // Step 1.5: Shape entries BEFORE speaker assignment. The readable-text
        // fallback and the >60s subdivision must precede diarization: the
        // IoU/dominance gate can only label fine-grained entries, and a
        // provider response that collapsed into per-chunk monoliths (or into
        // plain text) would otherwise take one winner-takes-all label per
        // multi-minute block, or none at all. The retry path already ran in
        // this order; this brings first-pass processing in line with it.
        var finalEntries = entries ?? []
        let duration = await store.fetchRecordingDuration(recordingID: recordingID)
        guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
            return
        }
        if finalEntries.isEmpty {
            let fallbackText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallbackText.isEmpty {
                finalEntries = [TranscriptEntry(startTime: 0, endTime: max(duration, 0), text: fallbackText)]
            }
        }
        if finalEntries.count <= 1 {
            let sourceText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            let segmented = buildReadableTranscriptEntries(from: sourceText, totalDuration: duration)
            if segmented.count > 1 {
                finalEntries = segmented
            }
        }
        // Subdivide any segments >60s at sentence boundaries for timeline usability
        finalEntries = Self.subdivideCoarseSegments(finalEntries)

        // Speaker diarization on the shaped entries. Per-entry skip logic
        // handles partial labels. Notice level: .info is unpersisted by
        // default, so these outcomes were invisible in `log show`.
        let diarizationEnabled = SpeakerDiarizer.shared.isEnabled
        postProcessLog.notice(
            "diarization gate: enabled=\(diarizationEnabled, privacy: .public), didFail=\(didFail, privacy: .public), entries=\(finalEntries.count, privacy: .public), provider=\(String(describing: actualProvider), privacy: .public)"
        )
        // Kept for speaker memory so it never diarizes the same audio twice.
        var reusableEmbeddings: SpeakerEmbeddingResult?
        if diarizationEnabled, !didFail, !finalEntries.isEmpty {
            do {
                let diarizer = SpeakerDiarizer.shared
                let diarizationResult = try await diarizer.diarize(audioURL: audioURL)
                reusableEmbeddings = SpeakerKitEmbeddingExtractor.makeResult(from: diarizationResult)

                if actualProvider == .whisperLocal, let rawResults = whisperRawResults {
                    diarizer.applySpeakersAligned(
                        diarization: diarizationResult,
                        whisperResults: rawResults,
                        entries: &finalEntries,
                        replaceExistingSpeakers: false
                    )
                } else {
                    finalEntries = await SpeakerDiarizer.assignSpeakersOffMain(
                        entries: finalEntries,
                        diarization: diarizationResult,
                        replaceExistingSpeakers: true
                    )
                }
                let withSpeaker = finalEntries.filter { $0.speaker != nil }.count
                postProcessLog.notice(
                    "diarization: \(diarizationResult.speakerCount, privacy: .public) speakers, \(withSpeaker, privacy: .public)/\(finalEntries.count, privacy: .public) entries labelled"
                )
            } catch {
                postProcessLog.error(
                    "diarization failed (non-fatal): \(String(describing: type(of: error)), privacy: .public) — \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        // Check cancellation
        guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
            return
        }

        // Step 2: Save transcript
        // Merge consecutive same-speaker segments (caps at 30s/500chars per merged segment)
        if finalEntries.contains(where: { $0.speaker != nil }) {
            SpeakerDiarizer.shared.mergeConsecutiveSpeakers(entries: &finalEntries)
        }
        // Strip whitespace-only entries before saving — some providers emit empty filler segments
        finalEntries.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !finalEntries.isEmpty {
            if fullText.isEmpty {
                fullText = finalEntries.map(\.text).joined(separator: " ")
            }
            let speakerIdentityRevision = await store.replaceTranscriptForSpeakerAnalysis(
                recordingID: recordingID,
                fullText: fullText,
                segments: finalEntries,
                language: detectedLang,
                tags: []
            )
            if speakerIdentityRevision == nil {
                NSLog("[PostProcessCoord] saveTranscript failed for %@", recordingID.uuidString)
                postProcessingError = String(localized: "The transcript could not be saved.")
                didFail = true
            } else if let speakerIdentityRevision {
                runSpeakerMemoryIfNeeded(
                    recordingID: recordingID,
                    audioURL: audioURL,
                    entries: finalEntries,
                    speakerIdentityRevision: speakerIdentityRevision,
                    precomputedEmbeddings: reusableEmbeddings
                )
            }
            onRecordingsChanged?()
        }

        // Check cancellation before summary
        guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
            return
        }

        // If transcript is empty (recording too short), discard
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !didFail {
            NSLog("[PostProcessCoord] empty transcript, trashing recording")
            await store.trashRecording(recordingID: recordingID, reason: "recording_too_short_to_transcribe")
            onRecordingsChanged?()
            onRecordingDiscarded?(
                recordingID,
                String(localized: "The recording was too short and was discarded.")
            )
            await finishJob(recordingID: recordingID, generation: generation, didFail: false)
            return
        }

        // Step 3: Summary — acquire slot
        if !fullText.isEmpty {
            updateCurrentJob(recordingID: recordingID, generation: generation) {
                $0.phase = .pendingSummary
            }
            guard let summaryLease = await acquireSummarySlot(
                recordingID: recordingID,
                generation: generation
            ) else { return }

            let summaryGenerator = SummaryGenerator()
            let providerRaw = UserDefaults.standard.string(forKey: "defaultAIProvider") ?? AIProvider.apple.rawValue
            let provider = AIProvider(rawValue: providerRaw) ?? .apple
            let summaryModel = provider.summaryModel
            var summarySource: SummarySourceVersion?
            let requestedSummaryLanguage = UserDefaults.standard.string(forKey: "summaryLanguage") ?? "auto"
            let summaryLanguage = SummaryLanguageResolver.resolve(
                requestedSummaryLanguage: requestedSummaryLanguage,
                detectedTranscriptLanguage: detectedLang,
                transcriptionLanguage: configuration.language ?? TranscriptionLanguage.auto.rawValue
            )

            do {
                defer { releaseSummarySlot(summaryLease) }
                guard isCurrentJob(recordingID: recordingID, generation: generation),
                      !Task.isCancelled else { return }

                updateCurrentJob(recordingID: recordingID, generation: generation) {
                    $0.phase = .summarizing
                    $0.summaryGenerator = summaryGenerator
                }

                let knownTags = await store.distinctTags(language: summaryLanguage).prefix(80).map(\.tag)
                // Speaker memory runs independently. Use any mappings that are
                // already available after waiting for the summary slot, but do
                // not block summary generation on the full-audio embedding pass.
                guard let summaryDetail = await store.fetchRecordingDetail(recordingID: recordingID),
                      let summaryInput = summaryDetail.transcript else { return }
                summarySource = SummarySourceVersion.capture(summaryInput, mappings: summaryDetail.speakerMappings)
                let summaryTranscript = await Task.detached {
                    SummaryTranscriptFormatter.format(fullText: summaryInput.fullText,
                        segments: summaryInput.segments, speakerMappings: summaryDetail.speakerMappings)
                }.value
                guard isCurrentJob(recordingID: recordingID, generation: generation),
                      !Task.isCancelled else { return }
                let request = PostProcessingSummaryExecutionRequest(
                    transcript: summaryTranscript,
                    provider: provider,
                    language: summaryLanguage,
                    meetingTitle: meetingTitle,
                    knownTags: knownTags
                )
                let summaryTask = if let summaryTaskFactoryOverride {
                    summaryTaskFactoryOverride(summaryGenerator, request)
                } else {
                    Task.detached(priority: ProcessingWorkPriority.shared.current) { [summaryGenerator] in
                        await AIGenerationGate.$priority.withValue(.foreground) {
                            await summaryGenerator.streamGenerate(
                                transcript: request.transcript,
                                provider: request.provider,
                                model: summaryModel,
                                language: request.language,
                                meetingTitle: request.meetingTitle,
                                knownTags: request.knownTags
                            )
                        }
                    }
                }
                updateCurrentJob(recordingID: recordingID, generation: generation) {
                    $0.activeDetachedTask = summaryTask
                }
                await summaryTask.value
                updateCurrentJob(recordingID: recordingID, generation: generation) {
                    $0.activeDetachedTask = nil
                }
            }

            // Check cancellation after summary completes
            guard isCurrentJob(recordingID: recordingID, generation: generation), !Task.isCancelled else {
                return
            }

            if let result = summaryGenerator.result {
                let overviewTrimmed = result.overview.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasMeaningful = !overviewTrimmed.isEmpty && !result.keyPoints.isEmpty

                if !hasMeaningful {
                    // If the generator reported an error (e.g. empty provider response),
                    // keep the recording for retry instead of auto-trashing.
                    if let summaryError = summaryGenerator.error {
                        NSLog("[PostProcessCoord] summary error with empty result, keeping recording: %@", summaryError)
                        await finishJob(
                            recordingID: recordingID,
                            generation: generation,
                            didFail: true,
                            error: summaryError
                        )
                        return
                    }
                    NSLog("[PostProcessCoord] no meaningful summary, trashing recording")
                    await store.trashRecording(recordingID: recordingID, reason: "no_meaningful_content")
                    onRecordingsChanged?()
                    onRecordingDiscarded?(
                        recordingID,
                        String(localized: "No meaningful content was detected, so the recording was discarded.")
                    )
                    await finishJob(recordingID: recordingID, generation: generation, didFail: false)
                    return
                }

                let classifiedType: String? = {
                    guard let rawType = result.meetingType, MeetingType(rawValue: rawType) != nil else { return nil }
                    return rawType
                }()

                let summarySaved = await store.saveSummary(
                    recordingID: recordingID,
                    summary: result,
                    chaptersJSON: nil,
                    provider: provider,
                    model: summaryModel,
                    language: summaryLanguage,
                    meetingType: classifiedType,
                    expectedSource: summarySource
                )
                switch summarySaved {
                case .saved, .keptReviewedSummary:
                    break
                case .cancelled, .recordingUnavailable, .sourceSuperseded:
                    // This job no longer owns the input. Do not call a normal
                    // supersession a database failure or export a stale result.
                    await finishJob(recordingID: recordingID, generation: generation, didFail: false)
                    return
                case .failed:
                    NSLog("[PostProcessCoord] saveSummary failed for %@", recordingID.uuidString)
                    postProcessingError = String(localized: "The summary could not be saved.")
                    didFail = true
                }
                onRecordingsChanged?()
            } else {
                let summaryError = summaryGenerator.error
                    ?? String(localized: "Summary generation returned no result.")
                NSLog("[PostProcessCoord] summary missing result for %@: %@", recordingID.uuidString, summaryError)
                postProcessingError = String(localized: "Summary failed: \(summaryError)")
                didFail = true
            }

            if let summaryError = summaryGenerator.error,
               isCurrentJob(recordingID: recordingID, generation: generation),
               !Task.isCancelled {
                postProcessingError = String(localized: "Summary failed: \(summaryError)")
                didFail = true
            }
        }

        // Compress audio to save storage (48kHz → 16kHz mono, ~3-4x smaller)
        if !didFail {
            await compressAudioIfNeeded(audioURL: audioURL, recordingID: recordingID)
        }

        // Done — content processing succeeded. Calendar linking can react now,
        // while the visible completion token waits for any configured
        // auto-export attempt. The export stays in an independent task, so its
        // network duration cannot extend this job's recording-processing lease.
        // A failed attempt publishes recovery guidance before completion.
        if !didFail,
           isCurrentJob(recordingID: recordingID, generation: generation),
           !Task.isCancelled {
            scheduleCompletionAndAutoExportFollowUp(recordingID: recordingID)
            onPostProcessingCompleted?(recordingID)
        }

        await finishJob(recordingID: recordingID, generation: generation, didFail: didFail)
    }

    // MARK: - Manual Generate Summary

    func generateSummary(recordingID: UUID, provider: String, language: String) async {
        guard !isDeletionBlocked(recordingID),
              !isProcessing(recordingID: recordingID),
              !isGeneratingSummary else { return }
        guard let processingLease = recordingProcessingGate.claimProcessing() else {
            NSLog("[PostProcessCoord] generateSummary refused: recording is active")
            return
        }
        defer { recordingProcessingGate.releaseProcessing(processingLease) }
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[PostProcessCoord] generateSummary refused: storage migration in progress")
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }

        // Set flags before first await to prevent re-entrancy
        isGeneratingSummary = true
        manualGeneratingRecordingID = recordingID
        postProcessingError = nil
        defer { isGeneratingSummary = false; manualGeneratingRecordingID = nil }

#if DEBUG
        await afterManualProcessingClaimForTesting?(.manualSummary)
#endif

        guard let detail = await store.fetchRecordingDetail(recordingID: recordingID),
              let transcript = detail.transcript else { return }

        let aiProvider = AIProvider(rawValue: provider) ?? .apple
        let summaryModel = aiProvider.summaryModel
        let summarySource = SummarySourceVersion.capture(transcript, mappings: detail.speakerMappings)
        let summaryLanguage = SummaryLanguageResolver.resolve(
            requestedSummaryLanguage: language,
            detectedTranscriptLanguage: transcript.detectedLanguage,
            transcriptionLanguage: detail.language
        )

        // Stream summary with periodic text bridging
        let streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // summaryStreamedText computed property reads from manualSummaryGenerator when isGeneratingSummary
                // Force observation update by touching a trivial property
                _ = self.manualSummaryGenerator.streamedText
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let knownTags = await store.distinctTags(language: summaryLanguage).prefix(80).map(\.tag)
        let transcriptFullText = transcript.fullText
        let transcriptSegments = transcript.segments
        let speakerMappings = detail.speakerMappings
        let summaryTranscript = await Task.detached {
            SummaryTranscriptFormatter.format(
                fullText: transcriptFullText,
                segments: transcriptSegments,
                speakerMappings: speakerMappings
            )
        }.value
        await AIGenerationGate.$priority.withValue(.foreground) {
            await manualSummaryGenerator.streamGenerate(
                transcript: summaryTranscript,
                provider: aiProvider,
                model: summaryModel,
                language: summaryLanguage,
                meetingTitle: detail.title,
                knownTags: knownTags
            )
        }
        streamTask.cancel()
        guard !Task.isCancelled else { return }

        if let error = manualSummaryGenerator.error {
            postProcessingError = String(localized: "Summary failed: \(error)")
        }

        if let result = manualSummaryGenerator.result {
            let classifiedType: String? = {
                guard let rawType = result.meetingType, MeetingType(rawValue: rawType) != nil else { return nil }
                return rawType
            }()

            let saved = await store.saveSummary(
                recordingID: recordingID,
                summary: result,
                chaptersJSON: nil,
                provider: aiProvider,
                model: summaryModel,
                language: summaryLanguage,
                meetingType: classifiedType,
                expectedSource: summarySource
            )
            switch saved {
            case .saved, .keptReviewedSummary, .cancelled, .recordingUnavailable:
                break
            case .sourceSuperseded:
                postProcessingError = String(localized: "Transcript changed. Regenerate summary.")
            case .failed:
                NSLog("[PostProcessCoord] generateSummary: saveSummary failed for %@", recordingID.uuidString)
                postProcessingError = String(localized: "The summary could not be saved.")
            }
            onRecordingsChanged?()
        }
    }

    // MARK: - On-Demand Chapter Generation

    /// Generate chapters for a recording that has a summary but no chapters yet.
    /// Called lazily when the user opens the detail page.
    func generateChaptersIfNeeded(recordingID: UUID) {
        guard !isDeletionBlocked(recordingID),
              !chaptersInFlight.contains(recordingID) else { return }
        chaptersInFlight.insert(recordingID)

        Task { [manualSummaryGenerator, store, weak self] in
            defer { self?.chaptersInFlight.remove(recordingID) }

            guard let detail = await store.fetchRecordingDetail(recordingID: recordingID),
                  let transcript = detail.transcript,
                  let summary = detail.summary,
                  summary.chapters.isEmpty, summary.generationMetadata?.sourceChanged != true else { return }

            let provider = AIProvider(rawValue: summary.provider) ?? .apple
            if provider.requiresAPIKey, (manualSummaryGenerator.apiKeyResolver(provider) ?? "").isEmpty { return }

            let summaryID = summary.id
            let source = SummarySourceVersion.capture(transcript, mappings: detail.speakerMappings)
            let transcriptFullText = transcript.fullText
            let transcriptSegments = transcript.segments
            let speakerMappings = detail.speakerMappings
            let summaryTranscript = await Task.detached {
                SummaryTranscriptFormatter.format(
                    fullText: transcriptFullText,
                    segments: transcriptSegments,
                    speakerMappings: speakerMappings
                )
            }.value
            let chapters = await manualSummaryGenerator.generateChapters(
                transcript: summaryTranscript,
                provider: provider,
                language: summary.language,
                summaryContext: ([summary.overview] + summary.keyPoints + summary.decisions + summary.followUps).joined(separator: "\n")
            )
            guard !chapters.isEmpty else { return }

            let chaptersData = chapters.map { ch in
                ["title": ch.title, "startSeconds": ch.startSeconds, "summary": ch.summary] as [String: Any]
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: chaptersData),
                  let jsonStr = String(data: encoded, encoding: .utf8) else { return }

            let updated = await store.updateChapters(recordingID: recordingID, chaptersJSON: jsonStr, expectedSummaryID: summaryID, expectedSource: source)
            if updated { self?.onRecordingsChanged?() }
            NSLog("[PostProcessCoord] on-demand chapters generated for %@ (applied=%d)", recordingID.uuidString, updated ? 1 : 0)
        }
    }

    // MARK: - Manual Retry Transcription

    func retryTranscription(recordingID: UUID) async {
        guard !isDeletionBlocked(recordingID),
              !isProcessing(recordingID: recordingID),
              !isRetryingTranscription else {
            postProcessLog.error(
                "retryTranscription skipped: already processing or retrying"
            )
            return
        }
        guard let processingLease = recordingProcessingGate.claimProcessing() else {
            // Also refuses on a mere recording *intent* — the detector arming
            // for a meeting is enough. The button gives no feedback, so this
            // line is the only way to tell a refusal from a silent no-op.
            postProcessLog.error(
                "retryTranscription refused: a recording is active or armed"
            )
            return
        }
        defer { recordingProcessingGate.releaseProcessing(processingLease) }
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[PostProcessCoord] retryTranscription refused: storage migration in progress")
            postProcessingError = String(
                localized: "Transcription is unavailable while the storage location is being changed."
            )
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }

        isRetryingTranscription = true
        manualRetryingRecordingID = recordingID
        defer { isRetryingTranscription = false; manualRetryingRecordingID = nil }
        postProcessingError = nil
        manualRetryChunksDone = 0
        manualRetryChunksTotal = 0

#if DEBUG
        await afterManualProcessingClaimForTesting?(.manualTranscriptionRetry)
#endif

        guard let detail = await store.fetchRecordingDetail(recordingID: recordingID) else {
            NSLog("[PostProcessCoord] retryTranscription: no detail found for %@", recordingID.uuidString)
            return
        }
        // Root snapshot inside the lease: stable for this retry, fresh for
        // the next one. Legacy references resolve verbatim; the iCloud
        // branch below covers not-yet-downloaded files, and anything else
        // missing surfaces as not-found rather than being guessed at.
        let recordingsDirectory = recordingsDirectoryProvider()
        guard let reference = detail.audioFile,
              let resolved = try? ProfileStorageResolver(root: recordingsDirectory)
                .resolveAudio(reference) else {
            NSLog("[PostProcessCoord] retryTranscription: no audio reference for %@", recordingID.uuidString)
            postProcessingError = String(localized: "The audio file for this recording could not be found.")
            return
        }

        let configuration: ConfiguredPostProcessingTranscription
        do {
            configuration = try await resolveConfiguredTranscriptionProvider()
        } catch {
            NSLog("[PostProcessCoord] retryTranscription: invalid configuration for %@: %@", recordingID.uuidString, error.localizedDescription)
            postProcessingError = error.localizedDescription
            return
        }

        let url = resolved
        if !FileManager.default.fileExists(atPath: url.path) {
            // Try triggering iCloud download for the resolved path
            NSLog("[PostProcessCoord] retryTranscription: attempting iCloud download for %@", url.path)
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                // Wait for download (up to 120s)
                for _ in 0..<240 {
                    if FileManager.default.fileExists(atPath: url.path) { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                NSLog("[PostProcessCoord] retryTranscription: iCloud download trigger failed: %@", error.localizedDescription)
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                NSLog("[PostProcessCoord] retryTranscription: audio not found at %@", url.path)
                postProcessingError = String(
                    localized: "The audio file could not be found. It may still be downloading from iCloud — please try again in a moment."
                )
                return
            }
        }

        manualTranscriptionManager.onProgress = { [weak self] done, total in
            Task { @MainActor in
                self?.manualRetryChunksDone = done
                self?.manualRetryChunksTotal = total
            }
        }

        let selection = configuration.selection
        NSLog("[PostProcessCoord] retryTranscription: starting with provider=%@", selection.provider.rawValue)
        do {
            let request = TranscriptionExecutionRequest(
                audioURL: url,
                provider: selection.provider,
                apiKey: selection.apiKey ?? "",
                model: selection.model,
                language: configuration.language
            )
            if let transcriptionRunnerOverride {
                try await transcriptionRunnerOverride(manualTranscriptionManager, request)
            } else {
                _ = try await manualTranscriptionManager.transcribeFile(
                    at: request.audioURL,
                    provider: request.provider,
                    apiKey: request.apiKey,
                    language: request.language,
                    model: request.model
                )
            }
            NSLog("[PostProcessCoord] retryTranscription: transcribeFile completed, fullText=%d chars", manualTranscriptionManager.fullText.count)
        } catch {
            NSLog("[PostProcessCoord] retryTranscription: transcribeFile threw: %@", error.localizedDescription)
            postProcessingError = String(
                localized: "Transcription failed: \(error.localizedDescription)"
            )
            manualTranscriptionManager.reset()
            manualRetryChunksDone = 0
            manualRetryChunksTotal = 0
            return
        }

        let fullText = manualTranscriptionManager.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullText.isEmpty {
            let rawSegments = manualTranscriptionManager.segments
            let speakerCount = Set(rawSegments.compactMap(\.speaker)).count
            NSLog("[PostProcessCoord] retryTranscription: %d segments, %d distinct speakers, speakers=%@",
                  rawSegments.count, speakerCount,
                  Set(rawSegments.compactMap(\.speaker)).sorted().joined(separator: ", "))
            var entries = Self.buildEntries(from: rawSegments)
            if entries.isEmpty {
                entries = [TranscriptEntry(startTime: 0, endTime: 0, text: fullText)]
            }
            if entries.count <= 1 {
                let segmented = buildReadableTranscriptEntries(from: fullText, totalDuration: max(detail.duration, 0))
                if segmented.count > 1 {
                    entries = segmented
                }
            }
            // Subdivide any segments >60s at sentence boundaries
            entries = Self.subdivideCoarseSegments(entries)

            // Speaker diarization
            let diarizationEnabled = SpeakerDiarizer.shared.isEnabled
            postProcessLog.notice(
                "retryTranscription diarization gate: enabled=\(diarizationEnabled, privacy: .public), entries=\(entries.count, privacy: .public), provider=\(String(describing: selection.provider), privacy: .public)"
            )
            var reusableEmbeddings: SpeakerEmbeddingResult?
            if diarizationEnabled, !entries.isEmpty {
                do {
                    let diarizer = SpeakerDiarizer.shared
                    let diarizationResult = try await diarizer.diarize(audioURL: url)
                    reusableEmbeddings = SpeakerKitEmbeddingExtractor.makeResult(from: diarizationResult)

                    if selection.provider == .whisperLocal, let rawResults = manualTranscriptionManager.lastWhisperResults {
                        diarizer.applySpeakersAligned(
                            diarization: diarizationResult,
                            whisperResults: rawResults,
                            entries: &entries,
                            replaceExistingSpeakers: false
                        )
                    } else {
                        entries = await SpeakerDiarizer.assignSpeakersOffMain(
                            entries: entries,
                            diarization: diarizationResult,
                            replaceExistingSpeakers: true
                        )
                    }
                    let withSpeaker = entries.filter { $0.speaker != nil }.count
                    postProcessLog.notice(
                        "retryTranscription diarization: \(diarizationResult.speakerCount, privacy: .public) speakers, \(withSpeaker, privacy: .public)/\(entries.count, privacy: .public) entries"
                    )
                } catch {
                    postProcessLog.error(
                        "retryTranscription diarization failed (non-fatal): \(String(describing: type(of: error)), privacy: .public) — \(error.localizedDescription, privacy: .private)"
                    )
                }
            }

            // Provider labels are request-local. Merge only after an optional
            // recording-wide pass has replaced them with canonical identities.
            if entries.contains(where: { $0.speaker != nil }) {
                SpeakerDiarizer.shared.mergeConsecutiveSpeakers(entries: &entries)
            }

            // Strip whitespace-only entries before saving
            entries.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let speakerIdentityRevision = await store.replaceTranscriptForSpeakerAnalysis(
                recordingID: recordingID,
                fullText: fullText,
                segments: entries,
                language: manualTranscriptionManager.detectedLanguage,
                tags: []
            )
            if speakerIdentityRevision == nil {
                NSLog("[PostProcessCoord] retryTranscription: saveTranscript failed for %@", recordingID.uuidString)
                postProcessingError = String(localized: "The transcript could not be saved.")
            } else if let speakerIdentityRevision {
                runSpeakerMemoryIfNeeded(
                    recordingID: recordingID,
                    audioURL: url,
                    entries: entries,
                    speakerIdentityRevision: speakerIdentityRevision,
                    precomputedEmbeddings: reusableEmbeddings
                )
                await store.markBackfillCompleted(recordingID: recordingID)
            }
            onRecordingsChanged?()
        }
        manualTranscriptionManager.reset()
        manualRetryChunksDone = 0
        manualRetryChunksTotal = 0
    }

    /// `precomputedEmbeddings` is the transcription pass's own diarization,
    /// mapped once; when present, speaker memory analyzes it instead of
    /// decoding and diarizing the file again.
    func runSpeakerMemoryIfNeeded(
        recordingID: UUID,
        audioURL: URL,
        entries: [TranscriptEntry],
        speakerIdentityRevision: UInt64,
        precomputedEmbeddings: SpeakerEmbeddingResult? = nil
    ) {
        guard SpeakerDiarizer.shared.isEnabled else { return }
        guard SpeakerMemoryConsent.isEnabled(in: transcriptionDependencies.defaults) else { return }
        let speakerSpans = SpeakerLabelSpan.fromTranscriptEntries(entries)
        guard !speakerSpans.isEmpty else { return }

        if let speakerMemoryRunner {
            speakerMemoryRunner(recordingID, audioURL, entries)
            onRecordingsChanged?()
            return
        }

        let memoryStore = store
        Task.detached(priority: .utility) { [weak self] in
            let hasSamples = await memoryStore.hasVoiceSamples(recordingID: recordingID)
            if hasSamples,
               let detail = await memoryStore.fetchRecordingDetail(recordingID: recordingID),
               (!detail.speakerMappings.isEmpty || !detail.speakerSuggestions.isEmpty) {
                return
            }

            do {
                let service = SpeakerMemoryService()
                let extractor: SpeakerEmbeddingExtractorProtocol = precomputedEmbeddings.map {
                    PrecomputedSpeakerEmbeddingExtractor(result: $0)
                } ?? SpeakerKitEmbeddingExtractor()
                try await service.analyze(
                    recordingID: recordingID,
                    audioURL: audioURL,
                    speakerSpans: speakerSpans,
                    speakerIdentityRevision: speakerIdentityRevision,
                    store: memoryStore,
                    extractor: extractor
                )
                await MainActor.run {
                    self?.onRecordingsChanged?()
                }
            } catch {
                NSLog("[SpeakerMemory] Analysis failed: %@", "\(error)")
            }
        }
    }

    // MARK: - Crash Recovery

    func recoverInterrupted() async {
        // Recovery reads and finalizes under the storage root; it holds an
        // activity lease so a directory migration cannot interleave. When a
        // migration is already claimed, recovery defers to the next launch.
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[PostProcessCoord] recovery deferred: storage migration in progress")
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }
        let recordingsDirectory = recordingsDirectoryProvider()

        // Phase 1: Merge interrupted recordings (still have a segments directory)
        let interrupted = await store.fetchInterruptedRecordings()
        if !interrupted.isEmpty {
            NSLog("[PostProcessCoord] found %d interrupted recording(s)", interrupted.count)
        }

        let explicitRecoveryRoot = recordingsDirectory
        let segmentStorageAuthority = SegmentStorageAuthority.authorize(
            root: explicitRecoveryRoot
        )
        let audioFinalizer = makeCrashRecoveryAudioFinalizer()
        let recoveryResolver = ProfileStorageResolver(root: recordingsDirectory)
        for rec in interrupted {
            let segDir = rec.segmentsDirURL

            // Determine output URL. Merged output must land under the active
            // root: reference writes are strictly relative, so an existing
            // destination outside the root (a legacy row from an upgraded
            // install) is replaced by a fresh in-root path.
            let outputURL: URL
            if let existingURL = rec.audioFileURL,
               (try? recoveryResolver.makeReference(for: existingURL)) != nil {
                outputURL = existingURL
            } else {
                let recordingsDir = recordingsDirectory
                try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let filename = "recording_\(formatter.string(from: rec.startDate)).m4a"
                outputURL = recordingsDir.appendingPathComponent(filename)
            }

            let outcome = await audioFinalizer.finalize(
                RecordingAudioFinalizationRequest(
                    origin: .crashRecovery,
                    recordingID: rec.id,
                    segmentsDirectory: segDir,
                    suppliedSegmentURLs: [],
                    segmentStorageAuthority: segmentStorageAuthority,
                    outputURL: outputURL,
                    fallbackDuration: rec.duration,
                    startDate: rec.startDate,
                    endDate: rec.startDate.addingTimeInterval(rec.duration),
                    meetingTitle: rec.title
                )
            )
            if outcome.didPrepareAudio {
                NSLog("[PostProcessCoord] recovered %@", rec.id.uuidString)
            } else {
                NSLog("[PostProcessCoord] recovery preparation failed for %@", rec.id.uuidString)
            }
        }

        // Phase 2: Re-queue recordings that were finalized but have incomplete post-processing
        let unprocessed = await store.fetchUnprocessedRecordings()
        if !unprocessed.isEmpty {
            NSLog("[PostProcessCoord] found %d unprocessed recording(s)", unprocessed.count)
        }
        for rec in unprocessed {
            let audioURL = rec.audioFileURL
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                NSLog("[PostProcessCoord] audio file missing for %@, skipping", rec.id.uuidString)
                continue
            }
            await store.incrementProcessingAttempts(id: rec.id)
            NSLog("[PostProcessCoord] re-queuing post-processing for %@ (hasTranscript=%d)", rec.id.uuidString, rec.hasTranscript ? 1 : 0)
            await startPostProcessing(recordingID: rec.id, audioURL: audioURL, meetingTitle: rec.title, origin: .crashRecovery)
        }

        // Phase 3: Historical backfill recovery and explicit queue.
        let interruptedBackfills = await store.markInterruptedBackfillProcessingFailed(
            error: "Interrupted before completion",
            maxAutomaticFailures: maxAutomaticBackfillFailures,
            cooldown: backfillFailureCooldown
        )
        if interruptedBackfills > 0 {
            NSLog("[PostProcessCoord] marked %d interrupted historical backfill job(s) as failed", interruptedBackfills)
        }
        await processQueuedHistoricalBackfill(limit: 2)

        // Phase 4: Clean up short recordings and enforce storage limit. Exact
        // segment cleanup is owned by RecordingAudioFinalizer after a durable
        // store commit; filename coincidence must never remove recovery data.
        // Recovery operates entirely within its injected root and defaults;
        // the store-side no-arg overload reads the live storage location.
        await store.cleanupStorage(
            root: recordingsDirectory,
            limitMegabytes: transcriptionDependencies.defaults.integer(forKey: "storageLimitMB")
        )
    }

    private func makeCrashRecoveryAudioFinalizer() -> RecordingAudioFinalizer {
        let baseDependencies = audioFinalizerDependenciesOverride
            ?? RecordingAudioFinalizerDependencies.legacy(
                storeCommit: { [store] request in
                    guard request.didPrepareAudio, let audioURL = request.audioURL else {
                        _ = await store.markRecoveryFailed(id: request.finalization.recordingID)
                        return .failed
                    }
                    let saved = await store.updateRecoveredRecording(
                        id: request.finalization.recordingID,
                        endDate: request.endDate,
                        duration: request.duration,
                        audioFileURL: audioURL
                    )
                    return saved ? .saved : .failed
                },
                postProcess: { [weak self] request, audioURL in
                    await MainActor.run {
                        self?.onRecordingsChanged?()
                    }
                    await self?.startPostProcessing(
                        recordingID: request.recordingID,
                        audioURL: audioURL,
                        meetingTitle: request.meetingTitle,
                        origin: .crashRecovery
                    )
                }
            )
        return RecordingAudioFinalizer(dependencies: baseDependencies)
    }

    /// Processes recordings explicitly queued for historical post-processing.
    /// This stays separate from the 72h crash-recovery scan to avoid startup retry loops.
    func processQueuedHistoricalBackfill(limit: Int = 2) async {
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[PostProcessCoord] backfill refused: storage migration in progress")
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }
        let backfill = await store.fetchQueuedBackfillRecordings(limit: limit)
        if !backfill.isEmpty {
            NSLog("[PostProcessCoord] found %d queued historical backfill recording(s)", backfill.count)
        }
        for rec in backfill {
            let audioURL = rec.audioFileURL
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                await store.markBackfillFailed(
                    recordingID: rec.id,
                    error: "Audio file missing",
                    maxAutomaticFailures: maxAutomaticBackfillFailures,
                    cooldown: backfillFailureCooldown
                )
                continue
            }
            NSLog("[PostProcessCoord] queueing historical backfill for %@ (hasTranscript=%d)", rec.id.uuidString, rec.hasTranscript ? 1 : 0)
            await startPostProcessing(
                recordingID: rec.id,
                audioURL: audioURL,
                meetingTitle: rec.title,
                origin: .historicalBackfill,
                historicalBackfillRecord: rec
            )
        }
    }

    // MARK: - Audio Compression

    /// Re-encode audio with Apple's M4A preset when it saves space.
    /// Ownership decides the write strategy (INV-18): `appCreated` files
    /// are replaced in place atomically; anything else is copy-on-write —
    /// the compressed data lands in a NEW file inside the storage root and
    /// the store reference switches atomically, the original bytes stay
    /// untouched. Runs only inside a post-processing job, which holds the
    /// storage-migration activity lease, so `recordingsDirectoryProvider`
    /// and the store's resolver observe the same root for the whole
    /// operation; if they ever diverge, the store rejects the reference
    /// and the new file is discarded. Internal (not private) so the
    /// ownership-branch integration tests can drive it directly.
    func compressAudioIfNeeded(audioURL: URL, recordingID: UUID) async {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }

        let asset = AVURLAsset(url: audioURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let desc = try? await track.load(.formatDescriptions).first else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        guard let sampleRate = asbd?.pointee.mSampleRate, sampleRate > 24000 else { return }

        let ownership = await store.audioOwnership(recordingID: recordingID) ?? .unknownLegacy
        // The compressed output always goes to the storage root: for the
        // CoW branch it IS the final file, and it must be referenceable
        // relative to the root (the original may live anywhere).
        let outputDirectory = ownership == .appCreated
            ? audioURL.deletingLastPathComponent()
            : recordingsDirectoryProvider()
        let tempURL = outputDirectory
            .appendingPathComponent("compressed_\(UUID().uuidString).m4a")

        do {
            try await AudioExporter.exportToM4A(asset: asset, track: track, outputURL: tempURL, settings: .compressed)

            let originalSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
            let compressedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0

            guard compressedSize > 0, compressedSize < originalSize else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            if ownership == .appCreated {
                // Atomic replace — safe even if app crashes mid-operation
                _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: tempURL)
            } else {
                let replaced = await store.replaceAudioFile(
                    recordingID: recordingID, newURL: tempURL, ownership: .appCreated
                )
                guard replaced else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
            }
            let savedMB = Double(originalSize - compressedSize) / 1_048_576
            NSLog("[PostProcessCoord] compressed audio for %@: %.1f MB → %.1f MB (saved %.1f MB)",
                  recordingID.uuidString,
                  Double(originalSize) / 1_048_576,
                  Double(compressedSize) / 1_048_576,
                  savedMB)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            NSLog("[PostProcessCoord] audio compression failed for %@: %@", recordingID.uuidString, error.localizedDescription)
        }
    }

    // MARK: - Auto Export (direct — no XPC)

    private func scheduleCompletionAndAutoExportFollowUp(recordingID: UUID) {
        guard let exportService else {
            postProcessingCompletedToken += 1
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let detail = await self.store.fetchRecordingDetail(recordingID: recordingID) else {
                self.postProcessingCompletedToken += 1
                return
            }
            await exportService.autoExportIfNeeded(detail)
            self.postProcessingCompletedToken += 1
        }
    }

#if DEBUG
    func scheduleCompletionAndAutoExportFollowUpForTesting(recordingID: UUID) {
        scheduleCompletionAndAutoExportFollowUp(recordingID: recordingID)
    }
#endif

    // MARK: - Provider Resolution

    func resolveConfiguredTranscriptionProvider() async throws -> ConfiguredPostProcessingTranscription {
        let language = transcriptionDependencies.defaults.string(forKey: "transcriptionLanguage") ?? "auto"
        let resolver = TranscriptionProviderResolver(
            apiKey: transcriptionDependencies.apiKey,
            supportsAppleLanguage: transcriptionDependencies.supportsAppleLanguage,
            localWhisperState: transcriptionDependencies.localWhisperState
        )
        let selection = try await resolver.resolve(
            storedProviderRawValue: transcriptionDependencies.defaults.string(forKey: "transcriptionProvider"),
            defaultProvider: .apple,
            mode: .postProcessing,
            language: language
        )
        return ConfiguredPostProcessingTranscription(
            selection: selection,
            language: language == "auto" ? nil : language
        )
    }

    // MARK: - Transcript Segmentation

    /// Split transcript entries longer than `maxDuration` seconds at sentence boundaries.
    /// Distributes time proportionally by character count within the original entry.
    /// Convert TranscriptSegments to TranscriptEntries, filling in missing endTimes.
    /// When endTime is nil, uses the next segment's startTime (or keeps startTime as last resort).
    static func buildEntries(from segments: [TranscriptSegment]) -> [TranscriptEntry] {
        let filtered = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty else { return [] }

        return filtered.enumerated().map { i, seg in
            let end: TimeInterval
            if let segEnd = seg.endTime, segEnd > seg.timestamp {
                end = segEnd
            } else if i + 1 < filtered.count {
                end = filtered[i + 1].timestamp
            } else {
                end = seg.timestamp
            }
            return TranscriptEntry(startTime: seg.timestamp, endTime: end, text: seg.text, speaker: seg.speaker)
        }
    }

    static func subdivideCoarseSegments(_ entries: [TranscriptEntry], maxDuration: TimeInterval = 60) -> [TranscriptEntry] {
        var result: [TranscriptEntry] = []
        result.reserveCapacity(entries.count)

        for entry in entries {
            let duration = entry.endTime - entry.startTime
            guard duration > maxDuration else {
                result.append(entry)
                continue
            }

            let sentences = splitIntoSentences(entry.text)
            guard sentences.count > 1 else {
                result.append(entry)
                continue
            }

            // Group sentences so each group's proportional duration ≤ maxDuration
            let totalChars = max(1, sentences.reduce(0) { $0 + $1.count })
            var groups: [[String]] = []
            var currentGroup: [String] = []
            var currentGroupChars = 0

            for sentence in sentences {
                let projectedDuration = duration * Double(currentGroupChars + sentence.count) / Double(totalChars)
                if !currentGroup.isEmpty && projectedDuration > maxDuration {
                    groups.append(currentGroup)
                    currentGroup = [sentence]
                    currentGroupChars = sentence.count
                } else {
                    currentGroup.append(sentence)
                    currentGroupChars += sentence.count
                }
            }
            if !currentGroup.isEmpty {
                groups.append(currentGroup)
            }

            // Assign timestamps proportionally
            let totalWeight = max(1, groups.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } })
            var cursor = entry.startTime

            for (i, group) in groups.enumerated() {
                let groupChars = group.reduce(0) { $0 + $1.count }
                let groupDuration = duration * Double(groupChars) / Double(totalWeight)
                let segEnd = i == groups.count - 1 ? entry.endTime : cursor + groupDuration

                let text = joinSentences(group)
                result.append(TranscriptEntry(
                    startTime: cursor,
                    endTime: segEnd,
                    text: text,
                    speaker: entry.speaker
                ))
                cursor = segEnd
            }
        }

        return result
    }

    /// Split text into sentences at `.` `!` `?` `。` `！` `？` `…` boundaries.
    private static func splitIntoSentences(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if terminators.contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty {
            if let last = sentences.last {
                sentences[sentences.count - 1] = joinSentences([last, remainder])
            } else {
                sentences.append(remainder)
            }
        }

        return sentences
    }

    /// Join sentences: use space for Latin, no space for CJK.
    private static func joinSentences(_ parts: [String]) -> String {
        guard let first = parts.first else { return "" }
        var result = first
        for part in parts.dropFirst() {
            let lastChar = result.last
            let firstChar = part.first
            let needsSpace = !(lastChar?.isCJK == true || firstChar?.isCJK == true)
            if needsSpace {
                result += " " + part
            } else {
                result += part
            }
        }
        return result
    }

    private func buildReadableTranscriptEntries(from text: String, totalDuration: TimeInterval) -> [TranscriptEntry] {
        let chunks = splitTranscriptText(text)
        guard !chunks.isEmpty else { return [] }
        if chunks.count == 1 {
            return [TranscriptEntry(startTime: 0, endTime: max(totalDuration, 0), text: chunks[0])]
        }

        let duration = max(totalDuration, 0)
        let totalWeight = max(1, chunks.reduce(0) { $0 + $1.count })
        var cursor: TimeInterval = 0
        var result: [TranscriptEntry] = []

        for (index, chunk) in chunks.enumerated() {
            let weightedDuration = duration > 0 ? (duration * Double(chunk.count) / Double(totalWeight)) : 2.0
            let segmentDuration = max(duration > 0 ? 0.6 : 2.0, weightedDuration)
            let endTime: TimeInterval
            if duration > 0 {
                endTime = index == chunks.count - 1 ? duration : min(duration, cursor + segmentDuration)
            } else {
                endTime = cursor + segmentDuration
            }
            result.append(TranscriptEntry(startTime: cursor, endTime: endTime, text: chunk))
            cursor = endTime
        }

        return result
    }

    private func splitTranscriptText(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sentences = trimmed.components(separatedBy: ". ")
        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            let piece = current.isEmpty ? sentence : ". " + sentence
            if current.count + piece.count > 200 && !current.isEmpty {
                chunks.append(current)
                current = sentence
            } else {
                current += piece
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x3000...0x303F).contains(v)
            || (0x3040...0x309F).contains(v)
            || (0x30A0...0x30FF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }
}
