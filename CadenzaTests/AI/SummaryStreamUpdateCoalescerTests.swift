import Foundation
import os
import Testing

@testable import Cadenza

@Suite("Summary stream update coalescing")
struct SummaryStreamUpdateCoalescerTests {
    @Test func burstDeltasCoalesceIntoOneAppendPerWindow() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("alpha")
        #expect(await waitUntil { sleeper.isWaiting })
        await coalescer.append(" beta")
        await coalescer.append(" gamma")

        sleeper.release()

        #expect(await waitUntil { probe.updateCount == 1 })
        await coalescer.finish(finalText: "alpha beta gamma")
        #expect(probe.events == [.append("alpha beta gamma")])
        #expect(probe.visibleText == "alpha beta gamma")
    }

    @Test func finishPublishesAuthoritativeFinalTextWithoutDroppingPendingDeltas() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("quick summary")
        #expect(await waitUntil { sleeper.isWaiting })
        await coalescer.finish(finalText: "quick summary\n\nenriched result")

        #expect(probe.events == [.replace("quick summary\n\nenriched result")])
        #expect(probe.visibleText == "quick summary\n\nenriched result")
    }

    @Test func cancellationDropsPendingAndFutureUpdates() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("partial")
        #expect(await waitUntil { sleeper.isWaiting })
        await coalescer.cancel()
        await coalescer.append(" late")
        sleeper.release()
        await Task.yield()

        #expect(probe.events.isEmpty)
        #expect(probe.visibleText.isEmpty)
    }

    @Test func errorCompletionPublishesPartialOnceAndCannotLeakLateUpdates() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("usable partial")
        #expect(await waitUntil { sleeper.isWaiting })
        await coalescer.finish(finalText: "usable partial")
        await coalescer.append(" stale callback")
        sleeper.release()
        await Task.yield()

        #expect(probe.events == [.append("usable partial")])
        #expect(probe.visibleText == "usable partial")
    }

    @Test func enrichPhaseKeepsQuickVisibleUntilFirstBatchThenReplacesOnce() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("quick")
        #expect(await waitUntil { sleeper.isWaiting })
        sleeper.release()
        #expect(await waitUntil { probe.updateCount == 1 })

        await coalescer.beginReplacementPhase()
        #expect(probe.events == [.append("quick")])
        #expect(probe.visibleText == "quick")

        await coalescer.append("enrich-1")
        #expect(await waitUntil { sleeper.isWaiting })
        await coalescer.append("-2")
        sleeper.release()
        #expect(await waitUntil { probe.updateCount == 2 })
        #expect(probe.events == [.append("quick"), .replace("enrich-1-2")])
        #expect(probe.visibleText == "enrich-1-2")

        await coalescer.append("-3")
        #expect(await waitUntil { sleeper.isWaiting })
        sleeper.release()
        #expect(await waitUntil { probe.updateCount == 3 })
        #expect(probe.events.last == .append("-3"))
        #expect(probe.visibleText == "enrich-1-2-3")

        await coalescer.finish(finalText: "quick\n\nenrich-1-2-3")
        #expect(probe.events.last == .replace("quick\n\nenrich-1-2-3"))
        #expect(probe.visibleText == "quick\n\nenrich-1-2-3")
    }

    @Test func enrichErrorBeforeFirstTokenLeavesQuickVisible() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("quick")
        #expect(await waitUntil { sleeper.isWaiting })
        await coalescer.beginReplacementPhase()
        await coalescer.finish(finalText: "quick")

        #expect(probe.events == [.append("quick")])
        #expect(probe.visibleText == "quick")
    }

    @Test func enrichErrorAfterVisiblePartialRestoresQuickFinalText() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )

        await coalescer.append("quick")
        #expect(await waitUntil { sleeper.isWaiting })
        sleeper.release()
        #expect(await waitUntil { probe.updateCount == 1 })
        await coalescer.beginReplacementPhase()

        await coalescer.append("partial enrich")
        #expect(await waitUntil { sleeper.isWaiting })
        sleeper.release()
        #expect(await waitUntil { probe.updateCount == 2 })
        await coalescer.finish(finalText: "quick")

        #expect(probe.events == [
            .append("quick"),
            .replace("partial enrich"),
            .replace("quick"),
        ])
        #expect(probe.visibleText == "quick")
    }

    @Test func tenThousandTokenBurstKeepsCallbackWorkLinearAndBounded() async {
        let sleeper = ControlledSummaryStreamSleeper()
        let probe = SummaryStreamUpdateProbe()
        let coalescer = SummaryStreamUpdateCoalescer(
            interval: .seconds(60),
            sleep: sleeper.sleep,
            onUpdate: probe.record
        )
        let tokenCount = 10_000
        let expected = String(repeating: "x", count: tokenCount)

        await coalescer.append("x")
        #expect(await waitUntil { sleeper.isWaiting })
        for _ in 1..<tokenCount {
            await coalescer.append("x")
        }
        await coalescer.finish(finalText: expected)

        #expect(probe.events == [.append(expected)])
        #expect(probe.visibleText == expected)
        #expect(probe.updateCount == 1)
        #expect(probe.totalPayloadUTF8Bytes == expected.utf8.count)
        #expect(probe.maximumPayloadUTF8Bytes == expected.utf8.count)
    }
}

private final class ControlledSummaryStreamSleeper: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isWaiting: Bool {
        state.withLock { $0.continuation != nil }
    }

    func sleep(for _: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { $0.isCancelled = false }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeCancelled = state.withLock { state in
                    if state.isCancelled {
                        return true
                    }
                    state.continuation = continuation
                    return false
                }
                if resumeCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.isCancelled = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func release() {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class SummaryStreamUpdateProbe: Sendable {
    private struct State {
        var events: [SummaryStreamTextUpdate] = []
        var visibleText = ""
        var totalPayloadUTF8Bytes = 0
        var maximumPayloadUTF8Bytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var events: [SummaryStreamTextUpdate] {
        state.withLock { $0.events }
    }

    var visibleText: String {
        state.withLock { $0.visibleText }
    }

    var updateCount: Int {
        state.withLock { $0.events.count }
    }

    var totalPayloadUTF8Bytes: Int {
        state.withLock { $0.totalPayloadUTF8Bytes }
    }

    var maximumPayloadUTF8Bytes: Int {
        state.withLock { $0.maximumPayloadUTF8Bytes }
    }

    func record(_ update: SummaryStreamTextUpdate) {
        state.withLock { state in
            let payload: String
            switch update {
            case .append(let delta):
                state.visibleText.append(delta)
                payload = delta
            case .replace(let text):
                state.visibleText = text
                payload = text
            }
            let byteCount = payload.utf8.count
            state.events.append(update)
            state.totalPayloadUTF8Bytes += byteCount
            state.maximumPayloadUTF8Bytes = max(state.maximumPayloadUTF8Bytes, byteCount)
        }
    }
}

private func waitUntil(
    attempts: Int = 200,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
