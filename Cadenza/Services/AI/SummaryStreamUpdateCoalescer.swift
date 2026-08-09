import Foundation

typealias SummaryStreamSleep = @Sendable (Duration) async throws -> Void

enum SummaryStreamTextUpdate: Equatable, Sendable {
    case append(String)
    case replace(String)
}

typealias SummaryStreamUpdateHandler = @MainActor @Sendable (SummaryStreamTextUpdate) -> Void

/// Coalesces provider text deltas into bounded-cadence UI updates.
///
/// Producers await `append`, so token delivery does not create one unstructured
/// task per token. At most one delayed flush task exists for this coalescer.
/// `finish` and `cancel` wait for that task before returning, preventing a stale
/// update from escaping after the owning summary operation has completed.
actor SummaryStreamUpdateCoalescer {
    static let defaultInterval: Duration = .milliseconds(120)

    private let interval: Duration
    private let sleep: SummaryStreamSleep
    private let onUpdate: SummaryStreamUpdateHandler

    private var publishedText = ""
    private var pendingText = ""
    private var scheduledFlush: Task<Void, Never>?
    private var scheduledFlushID: Int?
    private var nextFlushID = 0
    private var nextPublishedUpdateReplaces = false
    private var isClosed = false

    init(
        interval: Duration = SummaryStreamUpdateCoalescer.defaultInterval,
        sleep: @escaping SummaryStreamSleep = { duration in
            try await Task.sleep(for: duration)
        },
        onUpdate: @escaping SummaryStreamUpdateHandler
    ) {
        self.interval = interval
        self.sleep = sleep
        self.onUpdate = onUpdate
    }

    func append(_ delta: String) {
        guard !isClosed, !delta.isEmpty else { return }

        pendingText.append(delta)
        guard scheduledFlush == nil else { return }
        scheduleFlush()
    }

    /// Starts a new stream phase whose first visible batch replaces the prior
    /// phase. Any buffered text from the prior phase is published first so the
    /// UI never flashes empty while waiting for the new phase's first token.
    func beginReplacementPhase() async {
        guard !isClosed else { return }

        let flush = scheduledFlush
        scheduledFlush = nil
        scheduledFlushID = nil

        let priorPhasePending = pendingText
        pendingText.removeAll(keepingCapacity: true)
        if !priorPhasePending.isEmpty {
            publishedText.append(priorPhasePending)
        }
        nextPublishedUpdateReplaces = true

        flush?.cancel()
        if !priorPhasePending.isEmpty {
            await onUpdate(.append(priorPhasePending))
        }
        if let flush {
            await flush.value
        }
    }

    /// Closes the coalescer and publishes the caller's authoritative result.
    /// This is used for successful and failed streams so a usable partial result
    /// remains visible without allowing a delayed snapshot to overwrite it.
    func finish(finalText: String) async {
        guard !isClosed else { return }
        isClosed = true

        let flush = scheduledFlush
        flush?.cancel()
        if let flush {
            await flush.value
        }

        scheduledFlush = nil
        scheduledFlushID = nil
        let pendingUpdate = consumePendingUpdate(keepingCapacity: false)
        nextPublishedUpdateReplaces = false

        if finalText == publishedText {
            if let pendingUpdate {
                await onUpdate(pendingUpdate)
            }
            return
        }
        publishedText = finalText
        await onUpdate(.replace(finalText))
    }

    /// Closes the coalescer without publishing buffered content.
    func cancel() async {
        guard !isClosed else { return }
        isClosed = true

        let flush = scheduledFlush
        flush?.cancel()
        if let flush {
            await flush.value
        }

        scheduledFlush = nil
        scheduledFlushID = nil
        pendingText.removeAll(keepingCapacity: false)
        nextPublishedUpdateReplaces = false
    }

    private func scheduleFlush() {
        nextFlushID &+= 1
        let flushID = nextFlushID
        let interval = interval
        let sleep = sleep
        scheduledFlushID = flushID
        scheduledFlush = Task.detached { [weak self] in
            do {
                try await sleep(interval)
            } catch {
                await self?.scheduledSleepEnded(flushID: flushID)
                return
            }

            guard !Task.isCancelled else {
                await self?.scheduledSleepEnded(flushID: flushID)
                return
            }
            await self?.publishScheduledFlush(flushID: flushID)
        }
    }

    private func scheduledSleepEnded(flushID: Int) {
        guard scheduledFlushID == flushID else { return }
        scheduledFlush = nil
        scheduledFlushID = nil
    }

    private func publishScheduledFlush(flushID: Int) async {
        guard scheduledFlushID == flushID else { return }
        guard !isClosed else {
            scheduledFlush = nil
            scheduledFlushID = nil
            return
        }

        if let update = consumePendingUpdate(keepingCapacity: true) {
            await onUpdate(update)
        }

        guard scheduledFlushID == flushID else { return }
        scheduledFlush = nil
        scheduledFlushID = nil
        if !isClosed, !pendingText.isEmpty {
            scheduleFlush()
        }
    }

    private func consumePendingUpdate(keepingCapacity: Bool) -> SummaryStreamTextUpdate? {
        guard !pendingText.isEmpty else { return nil }

        let delta = pendingText
        pendingText.removeAll(keepingCapacity: keepingCapacity)
        if nextPublishedUpdateReplaces {
            nextPublishedUpdateReplaces = false
            publishedText = delta
            return .replace(delta)
        }

        publishedText.append(delta)
        return .append(delta)
    }
}
