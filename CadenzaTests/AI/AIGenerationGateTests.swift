import Testing
import Foundation
@testable import Cadenza

private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var maxConcurrent = 0
    private(set) var totalRuns = 0
    func enter() { current += 1; maxConcurrent = max(maxConcurrent, current); totalRuns += 1 }
    func exit() { current -= 1 }
}

@Suite("AIGenerationGate")
struct AIGenerationGateTests {

    @Test func serializesConcurrentOpsAndRunsAll() async throws {
        let gate = AIGenerationGate()
        let tracker = ConcurrencyTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gate.run(provider: .openai) {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000) // force overlap window
                        await tracker.exit()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await tracker.maxConcurrent == 1)  // never two at once
        #expect(await tracker.totalRuns == 6)      // none dropped / no deadlock
    }

    @Test func propagatesReturnValueAndError() async throws {
        let gate = AIGenerationGate()
        let v = try await gate.run(provider: .openai) { 42 }
        #expect(v == 42)

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await gate.run(provider: .openai) { throw Boom() }
        }
    }
    @Test func differentProvidersDoNotBlockEachOther() async throws {
        let gate = AIGenerationGate()
        let entered = GateTestSignal(), release = GateTestSignal(), otherDone = GateTestSignal()
        let first = Task { try await gate.run(provider: .openai) { await entered.signal(); await release.wait() } }
        await entered.wait()
        let second = Task { try await gate.run(provider: .claude) { await otherDone.signal() } }
        for _ in 0..<10_000 {
            if await otherDone.isSet { break }
            await Task.yield()
        }
        let completedBeforeRelease = await otherDone.isSet
        await release.signal()
        try await first.value
        try await second.value
        #expect(completedBeforeRelease)
    }

    @Test func cancelledWaiterNeverRunsAndPermitSurvives() async throws {
        let gate = AIGenerationGate()
        let entered = GateTestSignal(), release = GateTestSignal(), executed = GateTestSignal()
        let holder = Task { try await gate.run(provider: .openai) { await entered.signal(); await release.wait() } }
        await entered.wait()
        let waiter = Task { try await gate.run(provider: .openai) { await executed.signal() } }
        await waitForQueue(gate, count: 1)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!(await executed.isSet))
        #expect(await gate.pendingCount(for: .openai) == 0)
        await release.signal()
        try await holder.value
        #expect(try await gate.run(provider: .openai) { 7 } == 7)
    }

    @Test func cancelledRunningOperationReleasesPermit() async throws {
        let gate = AIGenerationGate(), entered = GateTestSignal()
        let holder = Task {
            try await gate.run(provider: .openai) {
                await entered.signal()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await entered.wait()
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        #expect(try await gate.run(provider: .openai) { 9 } == 9)
    }

    @Test func foregroundPriorityDoesNotStarveBackground() async throws {
        let gate = AIGenerationGate(), entered = GateTestSignal(), release = GateTestSignal()
        let order = GateTestOrder()
        let holder = Task { try await gate.run(provider: .openai) { await entered.signal(); await release.wait() } }
        await entered.wait()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<5 {
            tasks.append(Task {
                try await gate.run(provider: .openai, priority: index == 0 ? .background : .foreground) { await order.append(index) }
            })
            await waitForQueue(gate, count: index + 1)
        }
        await release.signal()
        try await holder.value
        for task in tasks { try await task.value }
        #expect(await order.values == [1, 2, 3, 0, 4])
    }

    private func waitForQueue(_ gate: AIGenerationGate, count: Int) async {
        for _ in 0..<10_000 {
            if await gate.pendingCount(for: .openai) == count { return }
            await Task.yield()
        }
        Issue.record("gate waiter was not queued")
    }

}


private actor GateTestSignal {
    private(set) var isSet = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isSet { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func signal() {
        isSet = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}
private actor GateTestOrder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
