import Foundation

/// Shared permits are scoped to provider quota domains; local inference has its own domain.
/// Same-provider requests remain serialized until measured quotas justify more concurrency.
/// Priority selects the next waiter; an active request is never preempted.
actor AIGenerationGate {
    static let shared = AIGenerationGate()
    enum Priority: Sendable { case foreground, background }
    @TaskLocal static var priority: Priority = .background

    private enum Domain: Hashable {
        case cloud(AIProvider)
        case local
        init(_ provider: AIProvider) {
            self = provider.requiresAPIKey ? .cloud(provider) : .local
        }
    }
    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Queue {
        var busy = false
        var foregroundStreak = 0
        var waiters: [Waiter] = []
    }
    private var queues: [Domain: Queue] = [:]

    func run<T: Sendable>(provider: AIProvider, priority: Priority? = nil, _ op: @Sendable () async throws -> T) async throws -> T {
        let domain = Domain(provider)
        let queuedAt = ContinuousClock.now
        try await acquire(domain: domain, priority: priority ?? Self.priority)
        defer { release(domain) }
        AIGenerationObservation.trace?.recordWait(queuedAt.duration(to: .now))
        try Task.checkCancellation()
        return try await op()
    }

    private func acquire(domain: Domain, priority: Priority) async throws {
        try Task.checkCancellation()
        if queues[domain]?.busy != true {
            queues[domain, default: Queue()].busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                queues[domain, default: Queue()].waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id, domain: domain) }
        }
    }

    private func cancel(_ id: UUID, domain: Domain) {
        guard let index = queues[domain]?.waiters.firstIndex(where: { $0.id == id }),
              let waiter = queues[domain]?.waiters.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ domain: Domain) {
        guard var queue = queues[domain] else { return }
        guard !queue.waiters.isEmpty else { queues.removeValue(forKey: domain); return }
        // After at most three foreground handoffs, serve a waiting background task.
        let background = queue.waiters.firstIndex { $0.priority == .background }
        let foreground = queue.waiters.firstIndex { $0.priority == .foreground }
        let index = queue.foregroundStreak >= 3 ? (background ?? foreground ?? 0) : (foreground ?? background ?? 0)
        let waiter = queue.waiters.remove(at: index)
        queue.foregroundStreak = waiter.priority == .foreground ? queue.foregroundStreak + 1 : 0
        queues[domain] = queue
        waiter.continuation.resume()
    }

    func pendingCount(for provider: AIProvider) -> Int { queues[Domain(provider)]?.waiters.count ?? 0 }
}
