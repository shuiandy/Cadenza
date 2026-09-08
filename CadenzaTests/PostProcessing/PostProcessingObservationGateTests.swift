import Foundation
import Testing
@testable import Cadenza

/// Source gate for ARCHITECTURE §12.1: the raw job table is rewritten on every
/// chunk progress callback and must stay out of SwiftUI observation.
@Suite("Post-processing observation gate")
struct PostProcessingObservationGateTests {
    @Test func rawJobTableIsObservationIgnoredAndViewsReadTheProjection() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Cadenza/Services/PostProcessing/PostProcessingCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("@ObservationIgnored private var jobs: [UUID: ActiveJob]"))
        #expect(source.contains("private(set) var jobPhases: [UUID: JobPhase]"))
        // The per-recording chip and the busy checks must read the projection.
        #expect(source.contains("func jobPhase(for recordingID: UUID) -> JobPhase? {\n        jobPhases[recordingID]"))
        #expect(source.contains("func isProcessing(recordingID: UUID) -> Bool {\n        jobPhases[recordingID] != nil"))
        #expect(source.contains("var isPostProcessing: Bool { !jobPhases.isEmpty }"))
    }
}
