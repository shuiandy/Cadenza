import Foundation
import SpeakerKit
import WhisperKit

/// A cancellation-safe FIFO permit used to keep SpeakerKit inference single-flight.
///
/// `@MainActor` alone does not prevent reentrancy across `await` points. This gate
/// deliberately keeps the permit for the complete asynchronous operation.
@MainActor
final class SpeakerDiarizationGate {
    private enum RequestState {
        case waiting
        case active
        case cancelledBeforeEnqueue
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeRequestID: UUID?
    private var requestStates: [UUID: RequestState] = [:]
    private var waiters: [Waiter] = []

    var queuedRequestCount: Int { waiters.count }
    var hasActivePermit: Bool { activeRequestID != nil }

    func withPermit<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        let requestID = UUID()
        try await acquire(requestID)
        defer { release(requestID) }

        // Cancellation may race with a permit handoff. Check only after the
        // release defer is installed so a granted permit can never be leaked.
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ requestID: UUID) async throws {
        try Task.checkCancellation()

        guard activeRequestID != nil else {
            activeRequestID = requestID
            requestStates[requestID] = .active
            return
        }

        requestStates[requestID] = .waiting
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if requestStates[requestID] == .cancelledBeforeEnqueue {
                    requestStates.removeValue(forKey: requestID)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: requestID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaitingRequest(requestID)
            }
        }
    }

    private func cancelWaitingRequest(_ requestID: UUID) {
        guard requestStates[requestID] == .waiting else {
            // The request either owns the permit already or has completed. In
            // both cases its normal defer is responsible for releasing it.
            return
        }

        guard let index = waiters.firstIndex(where: { $0.id == requestID }) else {
            // Cancellation can be delivered just before the continuation is
            // enqueued. Preserve it so registration cannot lose the signal.
            requestStates[requestID] = .cancelledBeforeEnqueue
            return
        }

        let waiter = waiters.remove(at: index)
        requestStates.removeValue(forKey: requestID)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ requestID: UUID) {
        guard activeRequestID == requestID else {
            assertionFailure("Attempted to release a SpeakerKit permit not owned by this request")
            return
        }

        requestStates.removeValue(forKey: requestID)

        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            guard requestStates[next.id] == .waiting else { continue }

            activeRequestID = next.id
            requestStates[next.id] = .active
            next.continuation.resume()
            return
        }

        activeRequestID = nil
    }
}

struct SpeakerAssignmentSpan: Sendable {
    let speakerID: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct PreparedSpeakerModels {
    let manager: SpeakerKitModelManager
    let speakerKit: SpeakerKit
}

/// Injectable boundary around every SpeakerKit operation that can consult its
/// model repository. `SpeakerDiarizer` applies the runtime policy before this
/// provider is ever invoked.
@MainActor
protocol SpeakerModelProviding: AnyObject {
    func probeAvailability() async throws -> Bool
    func prepareModels(
        progressCallback: @escaping @Sendable (Progress) -> Void
    ) async throws -> PreparedSpeakerModels
}

@MainActor
final class LiveSpeakerModelProvider: SpeakerModelProviding {
    func probeAvailability() async throws -> Bool {
        let config = PyannoteConfig(download: false)
        let manager = SpeakerKitModelManager(config: config)
        try await manager.downloadModels()
        return manager.isAvailable
    }

    func prepareModels(
        progressCallback: @escaping @Sendable (Progress) -> Void
    ) async throws -> PreparedSpeakerModels {
        let config = PyannoteConfig(download: true)
        let manager = SpeakerKitModelManager(config: config)
        try await manager.downloadModels(progressCallback: progressCallback)
        try await manager.loadModels()
        guard let models = manager.models as? PyannoteModels else {
            throw SpeakerKitError.modelUnavailable("Failed to cast models to PyannoteModels")
        }
        return PreparedSpeakerModels(
            manager: manager,
            speakerKit: try SpeakerKit(models: models)
        )
    }
}

/// Wraps SpeakerKit for on-device speaker diarization.
/// Uses SpeakerKitModelManager for download/load, SpeakerKit(models:) for inference.
@Observable @MainActor
final class SpeakerDiarizer {
    static let shared = SpeakerDiarizer(
        modelProvider: LiveSpeakerModelProvider(),
        externalModelAccessAllowed: {
            !DebugDataRoot.blocksLiveAccess && !AppState.isRunningTests
        }
    )

    private(set) var isProcessing = false
    private(set) var downloadProgress: Double = 0
    private(set) var isReady = false
    private var modelManager: SpeakerKitModelManager?
    private var speakerKit: SpeakerKit?
    /// Single-flight guard: only one prepare() at a time.
    private var prepareTask: Task<Void, Error>?
    private let diarizationGate = SpeakerDiarizationGate()
    private let modelProvider: any SpeakerModelProviding
    private let externalModelAccessAllowed: @MainActor () -> Bool

    private static let enabledKey = "diarization.enabled"

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: "diarization.enabled") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    init(
        modelProvider: any SpeakerModelProviding,
        externalModelAccessAllowed: @escaping @MainActor () -> Bool,
        automaticallyProbe: Bool = true
    ) {
        self.modelProvider = modelProvider
        self.externalModelAccessAllowed = externalModelAccessAllowed
        if automaticallyProbe {
            Task { [weak self] in
                await self?.probeModelAvailability()
            }
        }
    }

    // MARK: - Model Probe

    func probeModelAvailability(externalAccessEnabled: Bool = true) async {
        guard externalAccessEnabled, externalModelAccessAllowed() else {
            isReady = false
            return
        }
        do {
            isReady = try await modelProvider.probeAvailability()
        } catch {
            isReady = false
        }
    }

    // MARK: - Prepare

    func prepare(externalAccessEnabled: Bool = true) async throws {
        // Deepest network boundary: no provider or task is created when the
        // fixture/test process policy or its explicit caller policy is closed.
        guard externalAccessEnabled, externalModelAccessAllowed() else {
            throw CancellationError()
        }

        // Single-flight: if already preparing, await the existing task
        if let existing = prepareTask {
            try await existing.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.prepareTask = nil }
            self.downloadProgress = 0

            let progressCallback: @Sendable (Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress.fractionCompleted
                }
            }
            let prepared = try await self.modelProvider.prepareModels(
                progressCallback: progressCallback
            )
            self.speakerKit = prepared.speakerKit
            self.modelManager = prepared.manager
            self.isReady = true
            self.downloadProgress = 1.0
            NSLog("[SpeakerDiarizer] ready")
        }
        prepareTask = task
        try await task.value
    }

    // MARK: - Diarization

    func diarize(audioURL: URL) async throws -> DiarizationResult {
        try await diarizationGate.withPermit {
            self.isProcessing = true
            defer { self.isProcessing = false }

            if self.speakerKit == nil {
                try await self.prepare()
            }
            let sk = self.speakerKit!

            let audioArray = try await Task.detached {
                try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            }.value

            NSLog("[SpeakerDiarizer] diarizing %.1fs of audio", Float(audioArray.count) / 16000.0)
            let result = try await sk.diarize(audioArray: audioArray)
            NSLog("[SpeakerDiarizer] done: %d speakers, %d segments", result.speakerCount, result.segments.count)
            return result
        }
    }

    // MARK: - Speaker Assignment (WhisperKit native, type-erased)

    func applySpeakersAligned(
        diarization: DiarizationResult,
        whisperResults: any Sendable,
        entries: inout [TranscriptEntry],
        replaceExistingSpeakers: Bool = false
    ) {
        guard let results = whisperResults as? [TranscriptionResult] else {
            applySpeakers(
                diarization: diarization,
                entries: &entries,
                replaceExistingSpeakers: replaceExistingSpeakers
            )
            return
        }
        let aligned = diarization.addSpeakerInfo(to: results, strategy: .segment)
        let speakerSegments = aligned.flatMap { $0 }
        if speakerSegments.isEmpty {
            // WhisperKit alignment produced no results — fall back to IoU
            NSLog("[SpeakerDiarizer] addSpeakerInfo returned empty, falling back to IoU")
            applySpeakers(
                diarization: diarization,
                entries: &entries,
                replaceExistingSpeakers: replaceExistingSpeakers
            )
            return
        }
        assignFromSegments(
            entries: &entries,
            speakerSegments: speakerSegments,
            replaceExistingSpeakers: replaceExistingSpeakers
        )
    }

    // MARK: - Speaker Assignment (IoU overlap)

    func applySpeakers(
        diarization: DiarizationResult,
        entries: inout [TranscriptEntry],
        replaceExistingSpeakers: Bool = false
    ) {
        assignFromSegments(
            entries: &entries,
            speakerSegments: diarization.segments,
            replaceExistingSpeakers: replaceExistingSpeakers
        )
    }

    // MARK: - Merge Consecutive Same-Speaker Segments

    /// Merge consecutive entries that share the same speaker into single entries.
    /// Merge consecutive entries with the same speaker, but cap at ~30s or ~500 chars
    /// to keep segments readable and prevent SwiftUI from rendering giant text blocks.
    func mergeConsecutiveSpeakers(entries: inout [TranscriptEntry]) {
        // Strip whitespace-only entries before merging
        entries.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard entries.count > 1 else { return }
        var merged: [TranscriptEntry] = []
        var current = entries[0]

        for i in 1..<entries.count {
            let next = entries[i]
            let sameSpeaker = current.speaker != nil && current.speaker == next.speaker
            let tooLong = (next.endTime - current.startTime) > 30 || current.text.count > 500

            if sameSpeaker && !tooLong {
                current = TranscriptEntry(
                    startTime: current.startTime,
                    endTime: next.endTime,
                    text: current.text + " " + next.text,
                    speaker: current.speaker
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        entries = merged
    }

    // MARK: - Private

    private func assignFromSegments(
        entries: inout [TranscriptEntry],
        speakerSegments: [SpeakerSegment],
        replaceExistingSpeakers: Bool
    ) {
        if let firstEntry = entries.first, let firstSeg = speakerSegments.first,
           let lastEntry = entries.last, let lastSeg = speakerSegments.last {
            NSLog("[SpeakerDiarizer] entries time: %.1f-%.1f, speakerSegs time: %.1f-%.1f, segCount=%d",
                  firstEntry.startTime, lastEntry.endTime,
                  Double(firstSeg.startTime), Double(lastSeg.endTime),
                  speakerSegments.count)
        }

        let spans = speakerSegments.compactMap { segment -> SpeakerAssignmentSpan? in
            let speakerID: Int
            switch segment.speaker {
            case .speakerId(let id):
                speakerID = id
            case .multiple(let ids) where ids.count == 1:
                speakerID = ids[0]
            case .multiple, .noMatch:
                return nil
            }
            return SpeakerAssignmentSpan(
                speakerID: speakerID,
                startTime: TimeInterval(segment.startTime),
                endTime: TimeInterval(segment.endTime)
            )
        }
        assignSpeakers(
            entries: &entries,
            spans: spans,
            replaceExistingSpeakers: replaceExistingSpeakers
        )
    }

    /// Reconciles transcript entries against one recording-wide diarization pass.
    /// Provider labels such as A/B are request-local and may swap between chunks;
    /// when replacement is requested, only these canonical labels are persisted.
    func assignSpeakers(
        entries: inout [TranscriptEntry],
        spans: [SpeakerAssignmentSpan],
        replaceExistingSpeakers: Bool
    ) {
        let validSpans = spans.filter {
            $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
        }
        let firstAppearance = Dictionary(grouping: validSpans, by: \.speakerID)
            .mapValues { speakerSpans in speakerSpans.map(\.startTime).min() ?? .greatestFiniteMagnitude }
        let orderedSpeakerIDs = firstAppearance.keys.sorted {
            let lhsStart = firstAppearance[$0] ?? .greatestFiniteMagnitude
            let rhsStart = firstAppearance[$1] ?? .greatestFiniteMagnitude
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return $0 < $1
        }
        let canonicalLabels = Dictionary(uniqueKeysWithValues: orderedSpeakerIDs.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)")
        })

        for i in entries.indices {
            let entry = entries[i]
            if entry.speaker != nil && !replaceExistingSpeakers { continue }
            var overlapBySpeaker: [Int: TimeInterval] = [:]

            for span in validSpans {
                let overlapStart = max(entry.startTime, span.startTime)
                let overlapEnd = min(entry.endTime, span.endTime)
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > 0 {
                    overlapBySpeaker[span.speakerID, default: 0] += overlap
                }
            }

            let ranked = overlapBySpeaker.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            let totalOverlap = ranked.reduce(0) { $0 + $1.value }
            let top = ranked.first
            let runnerUpOverlap = ranked.dropFirst().first?.value ?? 0
            let dominance = top.map { totalOverlap > 0 ? $0.value / totalOverlap : 0 } ?? 0
            let margin = top.map { $0.value - runnerUpOverlap } ?? 0
            let entryDuration = max(0, entry.endTime - entry.startTime)
            let coverage = entryDuration > 0 ? min(totalOverlap, entryDuration) / entryDuration : 0
            let minimumMargin = min(0.20, max(0.02, totalOverlap * 0.05))
            let isConfident = top != nil
                && coverage >= 0.20
                && dominance >= 0.55
                && margin >= minimumMargin
            let label = isConfident ? top.flatMap { canonicalLabels[$0.key] } : nil

            entries[i] = TranscriptEntry(
                startTime: entry.startTime, endTime: entry.endTime,
                text: entry.text,
                speaker: label ?? (replaceExistingSpeakers ? nil : entry.speaker)
            )
        }
    }
}
