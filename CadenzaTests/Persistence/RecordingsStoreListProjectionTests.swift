import Foundation
import Testing
@testable import Cadenza

@Suite("List projection columns", .serialized)
struct RecordingsStoreListProjectionTests {

    private func makeStore() async throws -> RecordingsStore {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        return store
    }

    private func summary(overview: String) -> SummaryResult {
        SummaryResult(title: "T", overview: overview, keyPoints: [], actionItems: [],
                      decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
    }

    @Test func transcriptAndSummaryWritesMaintainThePreviews() async throws {
        let store = try await makeStore()
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Projection", startDate: Date(), segmentsDirURL: nil))

        let empty = try #require(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).first)
        #expect(empty.hasTranscript == false)
        #expect(empty.hasSummary == false)
        #expect(empty.transcriptPreview == nil)
        #expect(empty.summaryPreview == nil)

        let text = String(repeating: "transcript words ", count: 30)  // well past 200 characters
        #expect(await store.saveTranscript(
            recordingID: id, fullText: text,
            segments: [TranscriptEntry(startTime: 0, endTime: 1, text: text)],
            language: "en", tags: []
        ))
        #expect(await store.saveSummary(recordingID: id, summary: summary(overview: "First overview"), chaptersJSON: nil) == .saved)

        let filled = try #require(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).first)
        #expect(filled.hasTranscript)
        #expect(filled.hasSummary)
        #expect(filled.transcriptPreview == String(text.prefix(200)))
        #expect(filled.transcriptPreview?.count == 200)
        #expect(filled.summaryPreview == "First overview")

        // Re-summarizing replaces the preview, it never goes stale.
        #expect(await store.saveSummary(recordingID: id, summary: summary(overview: "Second overview"), chaptersJSON: nil) == .saved)
        let resummarized = try #require(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).first)
        #expect(resummarized.summaryPreview == "Second overview")
    }

    @Test func backfillFillsRowsThatPredateTheColumns() async throws {
        let store = try await makeStore()
        let withBoth = UUID(), transcriptOnly = UUID(), bare = UUID()
        for id in [withBoth, transcriptOnly, bare] {
            #expect(await store.createRecording(id: id, title: "R", startDate: Date(), segmentsDirURL: nil))
        }
        #expect(await store.saveTranscript(recordingID: withBoth, fullText: "alpha", segments: [], language: nil, tags: []))
        #expect(await store.saveSummary(recordingID: withBoth, summary: summary(overview: "beta"), chaptersJSON: nil) == .saved)
        #expect(await store.saveTranscript(recordingID: transcriptOnly, fullText: "gamma", segments: [], language: nil, tags: []))

        await store.clearListPreviewsForTesting()
        let cleared = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        #expect(cleared.allSatisfy { $0.transcriptPreview == nil && $0.summaryPreview == nil })

        // Every unprojected row is visited once (the bare one gets the empty
        // stamp and leaves the candidate set). One row per batch, so the
        // caller's loop shape is exercised too.
        var filled = 0
        var batches = 0
        while true {
            let step = await store.backfillListPreviews(batchSize: 1)
            filled += step.updated
            batches += 1
            guard step.remaining, step.updated > 0 else { break }
        }
        #expect(filled == 3)
        #expect(batches >= 3)
        #expect(await store.backfillListPreviews() == RecordingsStore.ListPreviewBackfillStep(updated: 0, remaining: false))

        let restored = await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil)
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        #expect(byID[withBoth]?.transcriptPreview == "alpha")
        #expect(byID[withBoth]?.summaryPreview == "beta")
        #expect(byID[transcriptOnly]?.transcriptPreview == "gamma")
        #expect(byID[transcriptOnly]?.summaryPreview == nil)
        #expect(byID[bare]?.transcriptPreview == nil)
    }

    @Test func speakerNamesStillResolveThroughTheSharedProfileMap() async throws {
        let store = try await makeStore()
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Speakers", startDate: Date(), segmentsDirURL: nil))
        #expect(await store.saveTranscript(
            recordingID: id, fullText: "hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 1, text: "hello", speaker: "Speaker 1")],
            language: nil, tags: []
        ))
        _ = await store.setSpeakerName(recordingID: id, rawLabel: "Speaker 1", profileNamed: "Ada Lovelace")
        let dto = try #require(await store.fetchRecordingDTOs(sortKey: "dateNewest", folderID: nil, tagFilter: nil).first)
        #expect(dto.speakerNames == ["Ada Lovelace"])
    }
}
