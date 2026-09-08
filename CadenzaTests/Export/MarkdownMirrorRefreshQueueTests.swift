import Foundation
import Testing
@testable import Cadenza

@Suite("Markdown mirror refresh queue")
struct MarkdownMirrorRefreshQueueTests {

    /// Refresh closure the test can hold open, to interleave saves with a
    /// drain that is already in flight.
    @MainActor
    private final class GatedRefresh {
        private(set) var batches: [Set<UUID>] = []
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func refresh(_ ids: Set<UUID>) async {
            batches.append(ids)
            started?.resume()
            started = nil
            await withCheckedContinuation { release = $0 }
        }

        func waitForStart() async {
            await withCheckedContinuation { started = $0 }
        }

        func finishCurrent() {
            release?.resume()
            release = nil
        }
    }

    @Test @MainActor func saveDuringADrainDoesNotLoseTheBatchInFlight() async {
        let gate = GatedRefresh()
        let queue = MarkdownMirrorRefreshQueue(debounce: .milliseconds(1)) { ids in
            await gate.refresh(ids)
        }
        let a = UUID(), b = UUID()

        queue.enqueue([a])
        await gate.waitForStart()                 // drain took [a] and is inside the refresh
        #expect(queue.isDraining)

        queue.enqueue([b])                        // the save that used to cancel the refresh
        #expect(queue.pendingIDs == [b])
        gate.finishCurrent()                      // a's refresh completes...
        await gate.waitForStart()                 // ...and the same drain continues with b
        #expect(gate.batches == [[a], [b]])
        #expect(queue.pendingIDs.isEmpty)
        gate.finishCurrent()

        // Drain ends once nothing is pending.
        for _ in 0..<50 where queue.isDraining { await Task.yield() }
        #expect(!queue.isDraining)
    }

    @Test @MainActor func debounceCoalescesSavesBeforeTheDrainStarts() async {
        let gate = GatedRefresh()
        let queue = MarkdownMirrorRefreshQueue(debounce: .milliseconds(20)) { ids in
            await gate.refresh(ids)
        }
        let a = UUID(), b = UUID(), c = UUID()
        queue.enqueue([a])
        queue.enqueue([b, c])
        queue.enqueue([])                         // empty sets are ignored
        await gate.waitForStart()
        #expect(gate.batches == [[a, b, c]])
        gate.finishCurrent()
    }

    @Test @MainActor func cancelIsTeardownOnly() async {
        let gate = GatedRefresh()
        let queue = MarkdownMirrorRefreshQueue(debounce: .seconds(10)) { ids in
            await gate.refresh(ids)
        }
        queue.enqueue([UUID()])
        queue.cancel()
        #expect(queue.pendingIDs.isEmpty)
        #expect(!queue.isDraining)
        #expect(gate.batches.isEmpty)
    }
}
