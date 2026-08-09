import Foundation
import os

struct AsyncCallbackTimeoutError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        String(localized: "The callback operation timed out.")
    }
}

/// Bridges callback-driven system APIs into async code without allowing a
/// missing callback to strand a task-group child forever. Completion,
/// cancellation, and timeout race through one resume-once state machine.
enum CancellableCallbackOperation {
    typealias Completion = @Sendable (Result<Void, Error>) -> Bool
    typealias IsActive = @Sendable () -> Bool

    struct TestHooks: Sendable {
        var beforeBeginStart: @Sendable () -> Void = {}
        var afterBeginStart: @Sendable () -> Void = {}

        static let none = TestHooks()
    }

    /// Runs a callback operation until completion or caller cancellation.
    ///
    /// Use this form for media operations whose valid duration is determined
    /// by user input and therefore has no safe fixed deadline.
    static func run(
        start: @escaping (
            _ complete: @escaping Completion,
            _ isActive: @escaping IsActive
        ) -> Void,
        cancel: @escaping () -> Void
    ) async throws {
        try await run(
            timeout: nil,
            testHooks: .none,
            start: start,
            cancel: cancel
        )
    }

    static func run(
        for timeout: Duration,
        testHooks: TestHooks = .none,
        start: @escaping (
            _ complete: @escaping Completion,
            _ isActive: @escaping IsActive
        ) -> Void,
        cancel: @escaping () -> Void
    ) async throws {
        try await run(
            timeout: timeout,
            testHooks: testHooks,
            start: start,
            cancel: cancel
        )
    }

    private static func run(
        timeout: Duration?,
        testHooks: TestHooks,
        start: @escaping (
            _ complete: @escaping Completion,
            _ isActive: @escaping IsActive
        ) -> Void,
        cancel: @escaping () -> Void
    ) async throws {
        let state = CallbackOperationState()

        let timeoutTask: Task<Void, Never>? = timeout.map { timeout in
            Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(for: timeout)
                    state.resolve(.failure(AsyncCallbackTimeoutError()))
                } catch {
                    // Normal completion or caller cancellation stopped the timer.
                }
            }
        }
        defer { timeoutTask?.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    state.install(continuation)

                    if Task.isCancelled {
                        state.resolve(.failure(CancellationError()))
                    }

                    testHooks.beforeBeginStart()
                    guard state.beginStart() else { return }
                    testHooks.afterBeginStart()
                    start(
                        { result in state.resolve(result) },
                        { state.isActive }
                    )
                    state.finishStart()
                }
            } onCancel: {
                state.resolve(.failure(CancellationError()))
            }

            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
    }
}

private final class CallbackOperationState: Sendable {
    private enum Phase {
        case idle
        case installed
        case starting
        case started
        case resolved
    }

    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var terminalResult: Result<Void, Error>?
        var phase = Phase.idle
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isActive: Bool {
        lock.withLock { $0.terminalResult == nil }
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let immediateResult = lock.withLock { state -> Result<Void, Error>? in
            guard let terminalResult = state.terminalResult else {
                state.continuation = continuation
                state.phase = .installed
                return nil
            }
            state.phase = .resolved
            return terminalResult
        }

        if let immediateResult {
            continuation.resume(with: immediateResult)
        }
    }

    /// Atomically reserves the synchronous callback-registration window. A
    /// timeout or cancellation that wins during this window is recorded but is
    /// not resumed until `finishStart()` proves registration has returned.
    func beginStart() -> Bool {
        lock.withLock { state in
            guard state.terminalResult == nil, state.phase == .installed else {
                return false
            }
            state.phase = .starting
            return true
        }
    }

    func finishStart() {
        let terminal = lock.withLock {
            state -> (CheckedContinuation<Void, Error>, Result<Void, Error>)? in
            guard state.phase == .starting else { return nil }
            guard let result = state.terminalResult,
                  let continuation = state.continuation else {
                state.phase = .started
                return nil
            }
            state.phase = .resolved
            state.continuation = nil
            return (continuation, result)
        }
        if let terminal {
            terminal.0.resume(with: terminal.1)
        }
    }

    @discardableResult
    func resolve(_ result: Result<Void, Error>) -> Bool {
        let resolution = lock.withLock {
            state -> (won: Bool, continuation: CheckedContinuation<Void, Error>?) in
            guard state.terminalResult == nil else { return (false, nil) }
            state.terminalResult = result
            if state.phase == .starting {
                return (true, nil)
            }
            state.phase = .resolved
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        guard resolution.won else { return false }
        resolution.continuation?.resume(with: result)
        return true
    }
}
