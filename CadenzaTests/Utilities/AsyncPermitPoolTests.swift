import Foundation
import os
import Testing
@testable import Cadenza

@Suite("Async permit pool")
struct AsyncPermitPoolTests {
    @Test func thrownOperationReturnsPermitToNextWaiter() async throws {
        let pool = AsyncPermitPool(limit: 1)

        await #expect(throws: PermitPoolTestError.self) {
            try await pool.withPermit {
                throw PermitPoolTestError.expected
            }
        }

        let value = try await HardAsyncDeadline.run(for: .milliseconds(250)) {
            try await pool.withPermit { 42 }
        }
        #expect(value == 42)
    }

    @Test func cancelledWaiterNeverRunsAndDoesNotConsumePermit() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let gate = PermitPoolGate()
        let probe = PermitPoolProbe()

        let holder = Task {
            try await pool.withPermit {
                await probe.markHolderStarted()
                await gate.wait()
            }
        }
        #expect(await waitUntil { await probe.holderStarted })

        let cancelled = Task {
            try await pool.withPermit {
                await probe.markCancelledWaiterRan()
            }
        }
        #expect(await waitUntil { await pool.waitingCountForTesting == 1 })

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await gate.open()
        try await holder.value

        try await HardAsyncDeadline.run(for: .milliseconds(250)) {
            try await pool.withPermit {
                await probe.markSuccessorRan()
            }
        }

        #expect(await probe.cancelledWaiterRan == false)
        #expect(await probe.successorRan)
    }

    @Test func concurrentOperationsNeverExceedConfiguredLimit() async throws {
        let pool = AsyncPermitPool(limit: 2)
        let gate = PermitPoolGate()
        let probe = PermitPoolProbe()

        let tasks = (0..<4).map { _ in
            Task {
                try await pool.withPermit {
                    await probe.enter()
                    await gate.wait()
                    await probe.leave()
                }
            }
        }

        #expect(await waitUntil { await probe.activeCount == 2 })
        #expect(await probe.maximumActiveCount == 2)
        // The two queued tasks reach the waiting queue asynchronously after
        // the first two hold their permits — poll instead of asserting a
        // scheduler-dependent instant.
        #expect(await waitUntil { await pool.waitingCountForTesting == 2 })

        await gate.open()
        for task in tasks {
            try await task.value
        }

        #expect(await probe.maximumActiveCount == 2)
        #expect(await probe.activeCount == 0)
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@Suite("Cancellable callback operation")
struct CancellableCallbackOperationTests {
    @Test func timeoutCancelsNeverCompletingOperationAndReturnsPermit() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let probe = CallbackOperationProbe()

        await #expect(throws: AsyncCallbackTimeoutError.self) {
            try await pool.withPermit {
                try await CancellableCallbackOperation.run(for: .milliseconds(20)) { _, _ in
                    probe.markStarted()
                } cancel: {
                    probe.markCancelled()
                }
            }
        }

        let successor = try await HardAsyncDeadline.run(for: .milliseconds(250)) {
            try await pool.withPermit { "successor" }
        }
        #expect(successor == "successor")
        #expect(probe.startedCount == 1)
        #expect(probe.cancelledCount == 1)
    }

    @Test func callerCancellationCancelsNeverCompletingOperationExactlyOnce() async throws {
        let probe = CallbackOperationProbe()
        let task = Task {
            try await CancellableCallbackOperation.run(for: .seconds(5)) { _, _ in
                probe.markStarted()
            } cancel: {
                probe.markCancelled()
            }
        }

        #expect(await waitUntil { probe.startedCount == 1 })
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.cancelledCount == 1)
    }

    @Test func callerCancellationCancelsOperationWithoutDeadlineExactlyOnce() async throws {
        let probe = CallbackOperationProbe()
        let task = Task {
            try await CancellableCallbackOperation.run { _, _ in
                probe.markStarted()
            } cancel: {
                probe.markCancelled()
            }
        }

        #expect(await waitUntil { probe.startedCount == 1 })
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.cancelledCount == 1)
    }

    @Test func lateCallbackAfterTimeoutIsIgnored() async throws {
        let probe = CallbackOperationProbe()
        let callback = CallbackCapture()

        await #expect(throws: AsyncCallbackTimeoutError.self) {
            try await CancellableCallbackOperation.run(for: .milliseconds(20)) { completion, _ in
                callback.store(completion)
                probe.markStarted()
            } cancel: {
                probe.markCancelled()
            }
        }

        #expect(callback.complete(.success(())) == false)
        #expect(probe.cancelledCount == 1)
    }

    @Test func successfulCallbackDoesNotInvokeCancellation() async throws {
        let probe = CallbackOperationProbe()

        try await CancellableCallbackOperation.run(for: .milliseconds(250)) { completion, isActive in
            #expect(isActive())
            #expect(completion(.success(())))
        } cancel: {
            probe.markCancelled()
        }

        #expect(probe.cancelledCount == 0)
    }

    @Test func throwingSiblingCancelsNeverCompletingTaskGroupChild() async throws {
        let pool = AsyncPermitPool(limit: 2)
        let probe = CallbackOperationProbe()

        await #expect(throws: PermitPoolTestError.self) {
            try await HardAsyncDeadline.run(for: .milliseconds(500)) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while probe.startedCount == 0 {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                        throw PermitPoolTestError.expected
                    }
                    group.addTask {
                        try await pool.withPermit {
                            try await CancellableCallbackOperation.run(for: .seconds(5)) { _, _ in
                                probe.markStarted()
                            } cancel: {
                                probe.markCancelled()
                            }
                        }
                    }

                    for try await _ in group {}
                }
            }
        }

        #expect(probe.cancelledCount == 1)
        try await HardAsyncDeadline.run(for: .milliseconds(250)) {
            try await pool.withPermit {}
        }
    }

    @Test func cancellationBeforeStartClaimSkipsStartThenCleansUp() async throws {
        let probe = CallbackOperationProbe()
        let task = Task {
            try await CancellableCallbackOperation.run(
                for: .seconds(5),
                testHooks: .init(beforeBeginStart: {
                    probe.markHookEntered()
                    probe.waitForHookRelease()
                })
            ) { _, _ in
                probe.markStarted()
            } cancel: {
                probe.markCancelled()
            }
        }

        #expect(await waitUntil { probe.hookEntered })
        task.cancel()
        probe.releaseHook()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.startedCount == 0)
        #expect(probe.events == ["hook", "cancel"])
    }

    @Test func cancellationDuringStartClaimDefersCleanupUntilRegistrationReturns() async throws {
        let probe = CallbackOperationProbe()
        let task = Task {
            try await CancellableCallbackOperation.run(
                for: .seconds(5),
                testHooks: .init(afterBeginStart: {
                    probe.markHookEntered()
                    probe.waitForHookRelease()
                })
            ) { _, _ in
                probe.markStarted()
            } cancel: {
                probe.markCancelled()
            }
        }

        #expect(await waitUntil { probe.hookEntered })
        task.cancel()
        probe.releaseHook()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.startedCount == 1)
        #expect(probe.events == ["hook", "start", "cancel"])
    }

    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@Suite("Gemini upload planning")
struct GeminiUploadPlanningTests {
    @Test(arguments: [
        (duration: 601.0, bytes: 1_000, expected: 601.0),
        (duration: 500.0, bytes: 15_000_001, expected: 500.0),
        (duration: 0.0, bytes: 16_000_000, expected: 1_000.0),
    ])
    func chunkingUsesEitherDurationOrFileSize(
        duration: TimeInterval,
        bytes: Int,
        expected: TimeInterval
    ) {
        #expect(
            GeminiTranscriber.chunkingDuration(
                totalDuration: duration,
                fileSize: bytes
            ) == expected
        )
    }

    @Test(arguments: [
        (duration: 600.0, bytes: 15_000_000),
        (duration: 500.0, bytes: 1_000),
        (duration: 0.0, bytes: 1_000),
    ])
    func smallFilesRemainSingleRequest(duration: TimeInterval, bytes: Int) {
        #expect(
            GeminiTranscriber.chunkingDuration(
                totalDuration: duration,
                fileSize: bytes
            ) == nil
        )
    }

    @Test func invalidDurationsNeverCreateUnboundedChunkPlans() {
        #expect(
            GeminiTranscriber.chunkingDuration(
                totalDuration: .infinity,
                fileSize: 16_000_000
            ) == 1_000
        )
        #expect(
            GeminiTranscriber.chunkingDuration(
                totalDuration: .nan,
                fileSize: 16_000_000
            ) == 1_000
        )
        #expect(
            GeminiTranscriber.chunkingDuration(
                totalDuration: -1,
                fileSize: 16_000_000
            ) == 1_000
        )
        #expect(
            GeminiTranscriber.chunkingDuration(
                totalDuration: .infinity,
                fileSize: 1_000
            ) == nil
        )
    }
}

private enum PermitPoolTestError: Error {
    case expected
}

private actor PermitPoolGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor PermitPoolProbe {
    private(set) var holderStarted = false
    private(set) var cancelledWaiterRan = false
    private(set) var successorRan = false
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    func markHolderStarted() {
        holderStarted = true
    }

    func markCancelledWaiterRan() {
        cancelledWaiterRan = true
    }

    func markSuccessorRan() {
        successorRan = true
    }

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}

private final class CallbackOperationProbe: Sendable {
    private struct State {
        var startedCount = 0
        var cancelledCount = 0
        var hookEntered = false
        var hookReleased = false
        var events: [String] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var startedCount: Int {
        lock.withLock { $0.startedCount }
    }

    var cancelledCount: Int {
        lock.withLock { $0.cancelledCount }
    }

    var hookEntered: Bool {
        lock.withLock { $0.hookEntered }
    }

    var events: [String] {
        lock.withLock { $0.events }
    }

    func markStarted() {
        lock.withLock {
            $0.startedCount += 1
            $0.events.append("start")
        }
    }

    func markCancelled() {
        lock.withLock {
            $0.cancelledCount += 1
            $0.events.append("cancel")
        }
    }

    func markHookEntered() {
        lock.withLock {
            $0.hookEntered = true
            $0.events.append("hook")
        }
    }

    func waitForHookRelease() {
        while !lock.withLock({ $0.hookReleased }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func releaseHook() {
        lock.withLock { $0.hookReleased = true }
    }
}

private final class CallbackCapture: Sendable {
    private let lock = OSAllocatedUnfairLock<CancellableCallbackOperation.Completion?>(
        initialState: nil
    )

    func store(_ callback: @escaping CancellableCallbackOperation.Completion) {
        lock.withLock { $0 = callback }
    }

    func complete(_ result: Result<Void, Error>) -> Bool? {
        let callback = lock.withLock { $0 }
        return callback?(result)
    }
}
