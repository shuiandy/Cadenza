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

    @Test func serializesConcurrentOpsAndRunsAll() async {
        let gate = AIGenerationGate()
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await gate.run {
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000) // force overlap window
                        await tracker.exit()
                    }
                }
            }
        }
        #expect(await tracker.maxConcurrent == 1)  // never two at once
        #expect(await tracker.totalRuns == 6)      // none dropped / no deadlock
    }

    @Test func propagatesReturnValueAndError() async throws {
        let gate = AIGenerationGate()
        let v = await gate.run { 42 }
        #expect(v == 42)

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await gate.run { throw Boom() }
        }
    }
}
