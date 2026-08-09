import Foundation
import Testing
@testable import Cadenza

@MainActor
@Suite("CraftExportService — exported ledger")
struct CraftExportLedgerTests {

    private func makeService() -> CraftExportService {
        let defaults = UserDefaults(suiteName: "test.craft." + UUID().uuidString)!
        let service = CraftExportService(defaults: defaults)
        service.checkAppAvailableHandler = { true }
        service.openURLHandler = { _ in true }
        return service
    }

    private func makeDetail(id: UUID = UUID()) -> RecordingDetailDTO {
        RecordingDetailDTO(
            id: id, title: "Meeting", startDate: Date(timeIntervalSince1970: 0),
            endDate: nil, duration: 60, meetingApp: nil, meetingURL: nil,
            language: "en", tags: [], meetingType: nil, lastAccessedDate: nil,
            folderID: nil, audioFile: nil, linkedCalendarEventID: nil,
            transcript: nil, summary: nil, speakerMappings: [], speakerSuggestions: [])
    }

    @Test func markExportedPersistsAndDedupes() {
        let service = makeService()
        let id = UUID()
        #expect(service.exportedRecordingIDs.isEmpty)

        service.markExported(id)
        service.markExported(id) // 重复标记不产生重复条目
        #expect(service.exportedRecordingIDs == [id])
    }

    @Test func exportRecordingMarksLedger() async throws {
        let service = makeService()
        let id = UUID()
        try await service.exportRecording(makeDetail(id: id))
        #expect(service.exportedRecordingIDs.contains(id))
    }

    @Test func failedExportDoesNotMarkLedger() async {
        let service = makeService()
        service.checkAppAvailableHandler = { false } // 触发 notAvailable
        let id = UUID()
        do {
            try await service.exportRecording(makeDetail(id: id))
            Issue.record("expected throw")
        } catch {}
        #expect(service.exportedRecordingIDs.isEmpty)
    }

    @Test func rejectedURLLaunchThrowsAndDoesNotMarkLedger() async {
        let service = makeService()
        service.openURLHandler = { _ in false }
        let id = UUID()

        do {
            try await service.exportRecording(makeDetail(id: id))
            Issue.record("expected throw")
        } catch {}

        #expect(service.exportedRecordingIDs.isEmpty)
    }
}
