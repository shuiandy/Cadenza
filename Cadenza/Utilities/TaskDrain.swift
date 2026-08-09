import Foundation
import os

/// Bounded wait for a set of tasks: resolves true when every task
/// finished, false at the timeout — a genuine one-shot race that returns
/// even while handlers stay suspended (the leaked waiter finishes when
/// they eventually observe cancellation).
enum TaskDrain {
    static func awaitAll(
        _ tasks: [Task<Void, Never>], timeout: Duration
    ) async -> Bool {
        guard !tasks.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: Bool) {
                let shouldResume = resumed.withLock { state -> Bool in
                    if state { return false }
                    state = true
                    return true
                }
                if shouldResume { continuation.resume(returning: value) }
            }
            Task.detached {
                for task in tasks { await task.value }
                resumeOnce(true)
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                resumeOnce(false)
            }
        }
    }
}
