import Foundation
import Testing
@testable import Cadenza

@MainActor
@Suite("BulkExportCoordinator")
struct BulkExportCoordinatorTests {

    // MARK: - Fixtures

    private func makeDTO(id: UUID = UUID(),
                         hasTranscript: Bool = true,
                         hasSummary: Bool = false) -> RecordingDTO {
        RecordingDTO(id: id, title: "Meeting", startDate: Date(timeIntervalSince1970: 0),
                     endDate: nil, duration: 60, meetingApp: nil, meetingURL: nil,
                     language: "en", tags: [], meetingType: nil, lastAccessedDate: nil,
                     trashedDate: nil, folderID: nil, linkedCalendarEventID: nil,
                     hasTranscript: hasTranscript, hasSummary: hasSummary,
                     transcriptPreview: nil, summaryPreview: nil, audioFile: nil)
    }

    private func makeDetail(id: UUID) -> RecordingDetailDTO {
        RecordingDetailDTO(
            id: id, title: "Meeting", startDate: Date(timeIntervalSince1970: 0),
            endDate: nil, duration: 60, meetingApp: nil, meetingURL: nil,
            language: "en", tags: [], meetingType: nil, lastAccessedDate: nil,
            folderID: nil, audioFile: nil, linkedCalendarEventID: nil,
            transcript: nil, summary: nil, speakerMappings: [], speakerSuggestions: [])
    }

    /// 全部依赖给出无害默认值；测试只覆写关心的闭包。
    private func makeCoordinator(
        recordings: [RecordingDTO] = [],
        notionExported: @escaping @Sendable () async throws -> Set<UUID> = { [] },
        craftExported: @escaping @Sendable () -> Set<UUID> = { [] },
        exportToNotion: @escaping @Sendable (RecordingDetailDTO) async throws -> Void = { _ in },
        exportToCraft: @escaping @Sendable (RecordingDetailDTO) async throws -> Void = { _ in }
    ) -> BulkExportCoordinator {
        let coordinator = BulkExportCoordinator()
        coordinator.dependencies = .init(
            listRecordings: { recordings },
            fetchDetail: { [self] id in makeDetail(id: id) },
            notionExportedIDs: notionExported,
            exportToNotion: exportToNotion,
            craftExportedIDs: craftExported,
            exportToCraft: exportToCraft,
            interItemDelay: { _ in .zero })
        return coordinator
    }

    // MARK: - prepare

    @Test func prepareNotionDiffsAgainstBackendLedger() async {
        let exported = UUID(), missing1 = UUID(), missing2 = UUID()
        let coordinator = makeCoordinator(
            recordings: [makeDTO(id: exported), makeDTO(id: missing1), makeDTO(id: missing2)],
            notionExported: { [exported] })

        await coordinator.prepare(.notion)
        #expect(coordinator.phase == .confirming(.notion, pending: 2))
    }

    @Test func prepareSkipsRecordingsWithNoContent() async {
        let empty = makeDTO(hasTranscript: false, hasSummary: false)
        let summaryOnly = makeDTO(hasTranscript: false, hasSummary: true)
        let coordinator = makeCoordinator(recordings: [empty, summaryOnly])

        await coordinator.prepare(.notion)
        #expect(coordinator.phase == .confirming(.notion, pending: 1))
    }

    @Test func prepareWhenNothingMissingIsUpToDate() async {
        let id = UUID()
        let coordinator = makeCoordinator(recordings: [makeDTO(id: id)],
                                          notionExported: { [id] })
        await coordinator.prepare(.notion)
        #expect(coordinator.phase == .upToDate(.notion))
    }

    @Test func prepareLedgerFailureSurfacesError() async {
        struct Boom: Error {}
        let coordinator = makeCoordinator(recordings: [makeDTO()],
                                          notionExported: { throw Boom() })
        await coordinator.prepare(.notion)
        guard case .failed(.notion, _) = coordinator.phase else {
            Issue.record("expected .failed, got \(coordinator.phase)")
            return
        }
    }

    @Test func prepareCraftUsesLocalLedgerNotBackend() async {
        let exported = UUID(), missing = UUID()
        // Use a class box to allow mutation from a @Sendable closure while
        // keeping everything on @MainActor (both the test and the coordinator).
        final class Box: @unchecked Sendable { var value = false }
        let backendAsked = Box()
        let coordinator = makeCoordinator(
            recordings: [makeDTO(id: exported), makeDTO(id: missing)],
            notionExported: { backendAsked.value = true; return [] },
            craftExported: { [exported] })

        await coordinator.prepare(.craft)
        #expect(coordinator.phase == .confirming(.craft, pending: 1))
        #expect(backendAsked.value == false)
    }

    @Test func prepareIsMutuallyExclusiveWhileBusy() async {
        let coordinator = makeCoordinator(recordings: [makeDTO()])
        await coordinator.prepare(.notion)
        #expect(coordinator.phase == .confirming(.notion, pending: 1))

        // confirming 期间再 prepare 另一目标 → no-op
        await coordinator.prepare(.craft)
        #expect(coordinator.phase == .confirming(.notion, pending: 1))
    }

    @Test func dismissConfirmationReturnsToIdle() async {
        let coordinator = makeCoordinator(recordings: [makeDTO()])
        await coordinator.prepare(.notion)
        coordinator.dismissConfirmation()
        #expect(coordinator.phase == .idle)
    }

    @Test func prepareWithoutDependenciesIsNoOp() async {
        let coordinator = BulkExportCoordinator()
        await coordinator.prepare(.notion)
        #expect(coordinator.phase == .idle)
    }

    @Test func dismissResultClearsResultStates() async {
        let id = UUID()
        let coordinator = makeCoordinator(recordings: [makeDTO(id: id)],
                                          notionExported: { [id] })
        await coordinator.prepare(.notion)
        #expect(coordinator.phase == .upToDate(.notion))
        coordinator.dismissResult()
        #expect(coordinator.phase == .idle)
    }
}

// MARK: - Run loop tests

@MainActor
@Suite("BulkExportCoordinator — run loop")
struct BulkExportRunLoopTests {

    private func makeDTO(id: UUID = UUID()) -> RecordingDTO {
        RecordingDTO(id: id, title: "Meeting", startDate: Date(timeIntervalSince1970: 0),
                     endDate: nil, duration: 60, meetingApp: nil, meetingURL: nil,
                     language: "en", tags: [], meetingType: nil, lastAccessedDate: nil,
                     trashedDate: nil, folderID: nil, linkedCalendarEventID: nil,
                     hasTranscript: true, hasSummary: false,
                     transcriptPreview: nil, summaryPreview: nil, audioFile: nil)
    }

    private func makeDetail(id: UUID) -> RecordingDetailDTO {
        RecordingDetailDTO(
            id: id, title: "Meeting", startDate: Date(timeIntervalSince1970: 0),
            endDate: nil, duration: 60, meetingApp: nil, meetingURL: nil,
            language: "en", tags: [], meetingType: nil, lastAccessedDate: nil,
            folderID: nil, audioFile: nil, linkedCalendarEventID: nil,
            transcript: nil, summary: nil, speakerMappings: [], speakerSuggestions: [])
    }

    private func makeCoordinator(
        recordings: [RecordingDTO],
        exportToNotion: @escaping @Sendable (RecordingDetailDTO) async throws -> Void = { _ in },
        exportToCraft: @escaping @Sendable (RecordingDetailDTO) async throws -> Void = { _ in }
    ) -> BulkExportCoordinator {
        let coordinator = BulkExportCoordinator()
        coordinator.dependencies = .init(
            listRecordings: { recordings },
            fetchDetail: { [self] id in makeDetail(id: id) },
            notionExportedIDs: { [] },
            exportToNotion: exportToNotion,
            craftExportedIDs: { [] },
            exportToCraft: exportToCraft,
            interItemDelay: { _ in .zero })
        return coordinator
    }

    @Test func exportsAllPendingInListOrder() async {
        let ids = [UUID(), UUID(), UUID()]
        final class Box: @unchecked Sendable { var order: [UUID] = [] }
        let box = Box()
        let coordinator = makeCoordinator(
            recordings: ids.map { makeDTO(id: $0) },
            exportToNotion: { box.order.append($0.id) })

        await coordinator.prepare(.notion)
        await coordinator.confirmAndStart()

        #expect(coordinator.phase == .finished(.notion, succeeded: 3, failed: 0))
        #expect(box.order == ids)
    }

    @Test func craftRunUsesCraftClosure() async {
        final class Box: @unchecked Sendable { var craft = 0; var notion = 0 }
        let box = Box()
        let coordinator = makeCoordinator(
            recordings: [makeDTO()],
            exportToNotion: { _ in box.notion += 1 },
            exportToCraft: { _ in box.craft += 1 })

        await coordinator.prepare(.craft)
        await coordinator.confirmAndStart()

        #expect(coordinator.phase == .finished(.craft, succeeded: 1, failed: 0))
        #expect(box.craft == 1)
        #expect(box.notion == 0)
    }

    @Test func singleFailureContinuesAndAggregates() async {
        struct Flaky: Error {}
        let ids = [UUID(), UUID(), UUID()]
        final class Box: @unchecked Sendable { var attempt = 0 }
        let box = Box()
        let coordinator = makeCoordinator(
            recordings: ids.map { makeDTO(id: $0) },
            exportToNotion: { _ in
                box.attempt += 1
                if box.attempt == 2 { throw Flaky() }
            })

        await coordinator.prepare(.notion)
        await coordinator.confirmAndStart()

        #expect(coordinator.phase == .finished(.notion, succeeded: 2, failed: 1))
    }

    @Test func authFailureAbortsImmediately() async {
        let ids = [UUID(), UUID(), UUID()]
        final class Box: @unchecked Sendable { var attempts = 0 }
        let box = Box()
        let coordinator = makeCoordinator(
            recordings: ids.map { makeDTO(id: $0) },
            exportToNotion: { _ in
                box.attempts += 1
                throw CadenzaAPIError.unauthorized
            })

        await coordinator.prepare(.notion)
        await coordinator.confirmAndStart()

        guard case .failed(.notion, _) = coordinator.phase else {
            Issue.record("expected .failed, got \(coordinator.phase)")
            return
        }
        #expect(box.attempts == 1) // 第 2、3 条没有被尝试
    }

    @Test func cancelStopsAfterCurrentItem() async {
        let ids = [UUID(), UUID(), UUID()]
        final class Box: @unchecked Sendable { var attempts = 0 }
        let box = Box()
        let coordinator = makeCoordinator(recordings: ids.map { makeDTO(id: $0) })
        coordinator.dependencies!.exportToNotion = { [weak coordinator] _ in
            box.attempts += 1
            coordinator?.cancel() // 第 1 条导出期间用户点了 Cancel
        }

        await coordinator.prepare(.notion)
        await coordinator.confirmAndStart()

        #expect(coordinator.phase == .cancelled(.notion, exported: 1))
        #expect(box.attempts == 1)
    }

    @Test func cancelActiveRunForDestinationClearsConfirmation() async {
        let coordinator = makeCoordinator(recordings: [makeDTO()])
        await coordinator.prepare(.notion)
        coordinator.cancelActiveRun(for: .notion) // disconnect 路径
        #expect(coordinator.phase == .idle)
    }

    @Test func confirmWithoutPrepareIsNoOp() async {
        let coordinator = makeCoordinator(recordings: [makeDTO()])
        await coordinator.confirmAndStart()
        #expect(coordinator.phase == .idle)
    }

    @Test func dismissResultClearsFinishedAndCancelled() async {
        // .finished → idle
        let c1 = makeCoordinator(recordings: [makeDTO()])
        await c1.prepare(.notion)
        await c1.confirmAndStart()
        #expect(c1.phase == .finished(.notion, succeeded: 1, failed: 0))
        c1.dismissResult()
        #expect(c1.phase == .idle)

        // .cancelled → idle
        let c2 = makeCoordinator(recordings: [makeDTO(), makeDTO()])
        c2.dependencies!.exportToNotion = { [weak c2] _ in c2?.cancel() }
        await c2.prepare(.notion)
        await c2.confirmAndStart()
        #expect(c2.phase == .cancelled(.notion, exported: 1))
        c2.dismissResult()
        #expect(c2.phase == .idle)
    }

    @Test func cancelActiveRunDuringRunStopsAsCancelled() async {
        let ids = [UUID(), UUID(), UUID()]
        final class Box: @unchecked Sendable { var attempts = 0 }
        let box = Box()
        let coordinator = makeCoordinator(recordings: ids.map { makeDTO(id: $0) })
        coordinator.dependencies!.exportToNotion = { [weak coordinator] _ in
            box.attempts += 1
            coordinator?.cancelActiveRun(for: .notion) // disconnect mid-run
        }

        await coordinator.prepare(.notion)
        await coordinator.confirmAndStart()

        #expect(coordinator.phase == .cancelled(.notion, exported: 1))
        #expect(box.attempts == 1)
    }

    @Test func missingDetailCountsAsFailedAndContinues() async {
        let ids = [UUID(), UUID()]
        let coordinator = makeCoordinator(recordings: ids.map { makeDTO(id: $0) })
        coordinator.dependencies!.fetchDetail = { [self, missing = ids[0]] id in
            id == missing ? nil : makeDetail(id: id)
        }

        await coordinator.prepare(.notion)
        await coordinator.confirmAndStart()

        #expect(coordinator.phase == .finished(.notion, succeeded: 1, failed: 1))
    }

    /// Race fix: SwiftUI dismisses the alert (→ dismissConfirmation) in the
    /// same MainActor turn as the confirm button action, before any Task body
    /// runs. beginConfirmedRun must claim the phase synchronously so the
    /// trailing dismissConfirmation is a no-op instead of killing the run.
    @Test func beginConfirmedRunSurvivesAlertDismissRace() async {
        let coordinator = makeCoordinator(recordings: [makeDTO()])
        await coordinator.prepare(.notion)

        coordinator.beginConfirmedRun()      // synchronous claim → .running
        coordinator.dismissConfirmation()    // alert's set(false) fires right after — must be a no-op

        guard case .running = coordinator.phase else {
            // The run may have already finished on fast paths — both are fine,
            // the only WRONG outcome is .idle (the race losing the run).
            #expect(coordinator.phase == .finished(.notion, succeeded: 1, failed: 0))
            return
        }
        while coordinator.isBusy { await Task.yield() }   // drain the spawned Task
        #expect(coordinator.phase == .finished(.notion, succeeded: 1, failed: 0))
    }
}
