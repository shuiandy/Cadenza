import Foundation
import Testing
@testable import Cadenza

@MainActor
private final class AutoExportFeedbackSpy {
    var enabledDestinations: Set<AutoExportDestination> = []
    var availableDestinations: Set<AutoExportDestination> = Set(AutoExportDestination.allCases)
    var failingDestinations: Set<AutoExportDestination> = []
    var rawFailureCanary = "provider-secret-body"
    private(set) var exportCalls: [AutoExportDestination] = []
    private(set) var feedback: [AutoExportFeedback] = []

    func dependencies() -> AutoExportDependencies {
        AutoExportDependencies(
            enabledDestinations: { [weak self] in
                self?.enabledDestinations ?? []
            },
            isAvailable: { [weak self] destination in
                self?.availableDestinations.contains(destination) ?? false
            },
            export: { [weak self] destination, _ in
                guard let self else { return }
                self.exportCalls.append(destination)
                if self.failingDestinations.contains(destination) {
                    throw NSError(
                        domain: self.rawFailureCanary,
                        code: 503,
                        userInfo: [NSLocalizedDescriptionKey: self.rawFailureCanary]
                    )
                }
            }
        )
    }

    func capture(_ feedback: AutoExportFeedback) {
        self.feedback.append(feedback)
    }
}

private actor AutoExportSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Automatic export feedback")
@MainActor
struct AutoExportFeedbackTests {
    private func makeService(
        spy: AutoExportFeedbackSpy
    ) -> ExportService {
        let service = ExportService(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            autoExportDependencies: spy.dependencies()
        )
        service.onAutoExportFeedback = { [weak spy] feedback in
            spy?.capture(feedback)
        }
        return service
    }

    @Test
    func eachSingleDestinationFailurePublishesOneSafeRecoveryMessage() async {
        for failedDestination in AutoExportDestination.allCases {
            let spy = AutoExportFeedbackSpy()
            spy.enabledDestinations = Set(AutoExportDestination.allCases)
            spy.failingDestinations = [failedDestination]
            let service = makeService(spy: spy)

            let outcome = await service.autoExportIfNeeded(
                TestDTOFactory.makeRecordingDetailDTO()
            )

            #expect(outcome.failedDestinations == [failedDestination])
            #expect(
                outcome.succeededDestinations
                    == Set(AutoExportDestination.allCases).subtracting([failedDestination])
            )
            #expect(spy.feedback.count == 1)
            #expect(spy.feedback.first?.failedDestinations == [failedDestination])
            #expect(
                spy.feedback.first?.message
                    == ExportError.unexpected("ignored").localizedMessage()
            )
            #expect(spy.feedback.first?.message.contains(spy.rawFailureCanary) == false)
            #expect(service.lastExportError?.contains(spy.rawFailureCanary) == false)
        }
    }

    @Test
    func dualFailureIsAggregatedIntoExactlyOneFeedbackEvent() async {
        let spy = AutoExportFeedbackSpy()
        spy.enabledDestinations = Set(AutoExportDestination.allCases)
        spy.failingDestinations = Set(AutoExportDestination.allCases)
        let service = makeService(spy: spy)

        let outcome = await service.autoExportIfNeeded(
            TestDTOFactory.makeRecordingDetailDTO()
        )

        #expect(outcome.failedDestinations == Set(AutoExportDestination.allCases))
        #expect(outcome.succeededDestinations.isEmpty)
        #expect(spy.exportCalls == AutoExportDestination.allCases)
        #expect(spy.feedback.count == 1)
        #expect(spy.feedback.first?.failedDestinations == Set(AutoExportDestination.allCases))
        #expect(spy.feedback.first?.message.contains(spy.rawFailureCanary) == false)
    }

    @Test
    func disabledDestinationsDoNotExportOrPublishFeedback() async {
        let spy = AutoExportFeedbackSpy()
        spy.failingDestinations = Set(AutoExportDestination.allCases)
        let service = makeService(spy: spy)

        let outcome = await service.autoExportIfNeeded(
            TestDTOFactory.makeRecordingDetailDTO()
        )

        #expect(outcome.enabledDestinations.isEmpty)
        #expect(outcome.succeededDestinations.isEmpty)
        #expect(outcome.failedDestinations.isEmpty)
        #expect(spy.exportCalls.isEmpty)
        #expect(spy.feedback.isEmpty)
        #expect(service.lastExportError == nil)
    }

    @Test
    func coordinatorPublishesSafeAutoExportFailureAsRecoverableStatus() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let coordinator = PostProcessingCoordinator(
            store: RecordingsStore(modelContainer: container)
        )
        let spy = AutoExportFeedbackSpy()
        spy.enabledDestinations = [.notion]
        spy.failingDestinations = [.notion]
        let service = ExportService(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            autoExportDependencies: spy.dependencies()
        )
        coordinator.exportService = service

        await service.autoExportIfNeeded(TestDTOFactory.makeRecordingDetailDTO())

        let message = try #require(coordinator.postProcessingError)
        #expect(message == ExportError.unexpected("ignored").localizedMessage())
        #expect(!message.contains(spy.rawFailureCanary))
    }

    @Test
    func visibleCompletionWaitsForExportWithoutExtendingProcessingExclusion() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Auto-export follow-up",
            startDate: Date(),
            segmentsDirURL: nil
        ))
        let gate = RecordingProcessingGate()
        let coordinator = PostProcessingCoordinator(
            store: store,
            recordingProcessingGate: gate
        )
        let suspension = AutoExportSuspension()
        let service = ExportService(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            autoExportDependencies: AutoExportDependencies(
                enabledDestinations: { [.notion] },
                isAvailable: { _ in true },
                export: { _, _ in await suspension.wait() }
            )
        )
        coordinator.exportService = service
        let processingLease = try #require(gate.claimProcessing())

        coordinator.scheduleCompletionAndAutoExportFollowUpForTesting(
            recordingID: recordingID
        )
        let clock = ContinuousClock()
        let exportStartDeadline = clock.now.advanced(by: .seconds(2))
        while !(await suspension.entered), clock.now < exportStartDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await suspension.entered)
        #expect(coordinator.postProcessingCompletedToken == 0)

        // Simulate the processing job returning and releasing its own lease.
        // The still-blocked network export must not own another lease.
        gate.releaseProcessing(processingLease)
        let recordingLease = try #require(gate.claimRecording())
        gate.releaseRecording(recordingLease)

        await suspension.release()
        let completionDeadline = clock.now.advanced(by: .seconds(2))
        while coordinator.postProcessingCompletedToken == 0,
              clock.now < completionDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.postProcessingCompletedToken == 1)
        #expect(coordinator.postProcessingError == nil)
    }
}
