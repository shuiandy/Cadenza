import Foundation
import SwiftData
import Testing
@testable import Cadenza

@Suite("Markdown Mirror", .serialized)
struct MarkdownMirrorServiceTests {
    @MainActor private static var sharedContainer: ModelContainer?

    @MainActor
    private func makeStore() async throws -> RecordingsStore {
        let container: ModelContainer
        if let existing = Self.sharedContainer {
            container = existing
        } else {
            container = try RecordingsStore.makeContainer(inMemory: true)
            Self.sharedContainer = container
        }
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        return store
    }

    private func makeDefaultsSuite() -> String {
        "markdown-mirror-tests-\(UUID().uuidString)"
    }

    @Test @MainActor
    func writesStableMarkdownWithFrontMatterAndOptionalTranscript() async throws {
        let store = try await makeStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Roadmap / Review", startDate: Date(timeIntervalSince1970: 1_700_000_000), segmentsDirURL: nil)
        await store.saveTranscript(
            recordingID: id,
            fullText: "Alice: We should ship.",
            segments: [],
            language: "en",
            tags: ["planning"]
        )
        await store.saveSummary(
            recordingID: id,
            summary: SummaryResult(
                title: "Roadmap / Review",
                overview: "Ship plan",
                keyPoints: [],
                actionItems: [ActionItemResult(assignee: "Alice", task: "Publish plan", deadline: "Friday")],
                decisions: ["Ship"],
                followUps: [],
                yourTasks: [],
                tags: [],
                chapters: [],
                rawText: ""
            ),
            chaptersJSON: nil
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-mirror-\(UUID().uuidString)", isDirectory: true)
        let suite = makeDefaultsSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = MarkdownMirrorService(
            store: store,
            defaultsSuiteName: suite,
            ledgerKey: "ledger",
            directoryProvider: { directory }
        )

        let first = await service.rebuildAll(includeTranscript: true)
        #expect(first.written == 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        #expect(file.lastPathComponent.contains(id.uuidString))
        #expect(!file.lastPathComponent.contains("/"))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("id: \"\(id.uuidString)\""))
        #expect(content.contains("source: \"captured\""))
        #expect(content.contains("## Decisions"))
        #expect(content.contains("## Action Items"))
        #expect(content.contains("## Transcript"))

        #expect(await store.updateTitle(recordingID: id, title: "Renamed Roadmap"))
        let second = await service.rebuildAll(includeTranscript: true)
        #expect(second.written == 1)
        let afterFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(afterFiles.map(\.lastPathComponent) == files.map(\.lastPathComponent))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("# Renamed Roadmap"))
    }

    @Test @MainActor
    func userModifiedFileIsReportedAsConflictAndNeverOverwritten() async throws {
        let store = try await makeStore()
        let id = UUID()
        await store.createRecording(id: id, title: "Protected", startDate: Date(), segmentsDirURL: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-mirror-\(UUID().uuidString)", isDirectory: true)
        let suite = makeDefaultsSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = MarkdownMirrorService(
            store: store,
            defaultsSuiteName: suite,
            ledgerKey: "ledger",
            directoryProvider: { directory }
        )
        #expect(await service.rebuildAll(includeTranscript: false).written == 1)
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        let userContent = "# My edited note\n"
        try Data(userContent.utf8).write(to: file, options: .atomic)

        #expect(await store.updateTitle(recordingID: id, title: "Source changed"))
        let result = await service.rebuildAll(includeTranscript: false)
        #expect(result.conflicts == 1)
        #expect(result.written == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == userContent)
    }

}
