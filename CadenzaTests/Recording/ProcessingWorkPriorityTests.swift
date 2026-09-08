import Foundation
import Testing
@testable import Cadenza

@Suite("Processing work priority follows the recording lease")
struct ProcessingWorkPriorityTests {
    @Test @MainActor func leaseTransitionsDriveThePolicy() throws {
        let policy = ProcessingWorkPriority()
        let gate = RecordingProcessingGate(workPriority: policy)
        #expect(policy.current == .userInitiated)

        let lease = try #require(gate.claimRecording())
        #expect(policy.isRecordingActive)
        #expect(policy.current == .utility)

        // Normal stop: recording becomes processing atomically; background
        // work may run at full priority again.
        let processing = try #require(gate.transitionRecordingToProcessing(lease))
        #expect(!policy.isRecordingActive)
        #expect(policy.current == .userInitiated)
        gate.releaseProcessing(processing)

        // Reserved intent path.
        let intent = try #require(gate.reserveRecordingIntent())
        #expect(policy.current == .userInitiated)
        let consumed = try #require(gate.claimRecording(consuming: intent))
        #expect(policy.current == .utility)
        gate.releaseRecording(consumed)
        #expect(policy.current == .userInitiated)
    }
}
