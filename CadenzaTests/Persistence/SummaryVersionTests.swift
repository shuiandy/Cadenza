import Foundation
import Testing
@testable import Cadenza

@Suite("Summary source versions", .serialized)
struct SummaryVersionTests {
    private func setup() async throws -> (RecordingsStore, UUID, SummarySourceVersion) {
        let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
        let id = UUID()
        #expect(await store.createRecording(id: id, title: "Fictional review", startDate: Date(), segmentsDirURL: nil))
        #expect(await store.saveTranscript(recordingID: id, fullText: "Nora will check.", segments: [TranscriptEntry(startTime: 0, endTime: 2, text: "Nora will check.", speaker: "Speaker 1")], language: "en", tags: []))
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        return (store, id, SummarySourceVersion.capture(try #require(detail.transcript), mappings: detail.speakerMappings))
    }
    private var result: SummaryResult {
        var r = SummaryResult(title: "Fictional review", overview: "Nora will check.", keyPoints: ["Check remains open"], actionItems: [ActionItemResult(assignee: "Nora", task: "Check mapping", deadline: nil)], decisions: [], followUps: [], yourTasks: [], tags: [], chapters: [], rawText: "")
        r.generationMetadata = .init(detailLevel: "fullBreakdown", stage: .reviewed)
        return r
    }
    @Test func summaryOnlyReadsReusePersistedAndMappedProvenance() async throws {
        let (store, id, source) = try await setup()
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
        for _ in 0..<4 {
            let detail = try #require(await store.fetchSummaryContextDetail(recordingID: id))
            #expect(detail.transcript == nil)
            #expect(detail.summary?.generationMetadata?.sourceChanged == false)
        }
        #expect(await store.summarySourceCaptureCount == 0)
        _ = await store.setSpeakerName(recordingID: id, rawLabel: "Speaker 1", profileNamed: "Mina")
        for _ in 0..<4 { _ = await store.fetchSummaryContextDetail(recordingID: id) }
        #expect(await store.summarySourceCaptureCount == 1)
        let before = await store.summaryContextRevision(recordingID: id)
        #expect(await store.createRecording(id: UUID(), title: "Unrelated fictional meeting", startDate: Date(), segmentsDirURL: nil))
        #expect(await store.summaryContextRevision(recordingID: id) == before)
    }

    @Test func replacementInvalidatesSourceEvenWithoutSpeakerReset() async throws {
        let (store, id, source) = try await setup()
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: "[]", expectedSource: source) == .saved)
        let summaryID = try #require(await store.currentSummaryID(for: id))
        #expect(await store.saveTranscript(recordingID: id, fullText: "Nora will check.", segments: [TranscriptEntry(startTime: 1, endTime: 3, text: "Nora will check.", speaker: "Speaker 1")], language: "en", tags: []))
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .sourceSuperseded)
        #expect(await store.updateChapters(recordingID: id, chaptersJSON: "[]", expectedSummaryID: summaryID, expectedSource: source) == false)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.summary?.generationMetadata?.sourceChanged == true)
        #expect(detail.summary?.id == summaryID)
    }
    @Test func failedReplacementKeepsVersionAndSummary() async throws {
        let (store, id, source) = try await setup()
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
        await store.failNextSaveForTesting()
        #expect(await store.saveTranscript(recordingID: id, fullText: "different", segments: [], language: "en", tags: []) == false)
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
    }
    @Test func speakerIdentityChangeKeepsPendingResultWithSeparateWarning() async throws {
        let (store, id, source) = try await setup()
        let profile = try #require(await store.createSpeakerProfile(displayName: "Mina"))
        #expect(await store.applySpeakerMappingIfCurrent(recordingID: id, rawLabel: "Speaker 1",
            profileID: profile.id, expectedSpeakerIdentityRevision: 0) == .applied)
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.summary?.overview == result.overview)
        #expect(detail.summary?.generationMetadata?.sourceChanged == false)
        #expect(detail.summary?.generationMetadata?.speakerMappingsChanged == true)
        #expect(detail.summary?.generationMetadata?.source == source)
        #expect(SummaryContextSnapshot.build(detail: detail, input: .init(), userName: "",
            jobTitle: "", defaultFocus: "", event: nil, history: []) != nil)
    }
    @Test func completedAndEditedTasksSurviveRegeneration() async throws {
        let (store, id, source) = try await setup()
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        let task = try #require(detail.summary?.actionItems.first)
        #expect(await store.toggleActionItem(recordingID: id, actionItemID: task.id))
        #expect(await store.addActionItem(recordingID: id, task: "User added note"))
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
        let updated = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(updated.summary?.actionItems.count == 2)
        #expect(updated.summary?.actionItems.first?.id == task.id)
        #expect(updated.summary?.actionItems.first?.isCompleted == true)
    }
    @Test func deadlinePurposeRejectsTargetDate() {
        let summary = SummaryPrompt.parseResponse(#"{"action_items":[{"task":"Send schedule","deadline":"November","deadline_kind":"target"}]}"#)
        #expect(summary.actionItems.first?.deadline == nil)
    }

    @Test func renamedSpeakerKeepsExistingAndPendingChapters() async throws {
        let (store, id, source) = try await setup()
        let chapters = #"[{"title":"Review","startSeconds":0,"summary":"Review the mapping"}]"#
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: chapters, expectedSource: source) == .saved)
        let summaryID = try #require(await store.currentSummaryID(for: id))
        _ = await store.setSpeakerName(recordingID: id, rawLabel: "Speaker 1", profileNamed: "Mina")
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.summary?.chapters.count == 1)
        #expect(detail.summary?.generationMetadata?.sourceChanged == false)
        #expect(detail.summary?.generationMetadata?.speakerMappingsChanged == true)
        #expect(await store.updateChapters(recordingID: id, chaptersJSON: chapters,
            expectedSummaryID: summaryID, expectedSource: source))
    }

    @Test func legacyCombinedDigestDoesNotInvalidateSummaryAfterNaming() async throws {
        let (store, id, source) = try await setup()
        let legacy = SummarySourceVersion(transcriptID: source.transcriptID, digest: source.digest)
        let encoded = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SummarySourceVersion.self, from: encoded)
        #expect(decoded.transcriptDigest == nil)
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: decoded) == .saved)
        let unchanged = try #require(await store.fetchRecordingDetail(recordingID: id)?.summary)
        #expect(unchanged.generationMetadata?.speakerMappingsChanged == nil)
        // The old DTO had no mapping advisory key. An upgrade alone must not
        // change its digest and invalidate already saved personal notes.
        var oldDTO = unchanged
        oldDTO.generationMetadata?.speakerMappingsChanged = nil
        #expect(SummaryContextSnapshot.digest(unchanged) == SummaryContextSnapshot.digest(oldDTO))
        _ = await store.setSpeakerName(recordingID: id, rawLabel: "Speaker 1", profileNamed: "Mina")
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        #expect(detail.summary?.generationMetadata?.sourceChanged == false)
        #expect(detail.summary?.generationMetadata?.speakerMappingsChanged == true)
        #expect(await store.saveTranscript(recordingID: id, fullText: "Nora will check.", segments: [], language: "en", tags: []))
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: decoded) == .sourceSuperseded)
    }

    @Test func exactTranscriptEditsStillInvalidateSameID() async throws {
        let (store, id, source) = try await setup()
        let detail = try #require(await store.fetchRecordingDetail(recordingID: id))
        let original = try #require(detail.transcript)
        var textEdit = original
        textEdit.fullText += " Corrected."
        var timeEdit = original
        timeEdit.segments[0].startTime += 0.001
        var speakerEdit = original
        speakerEdit.segments[0].speaker = "Speaker 2"
        for changed in [textEdit, timeEdit, speakerEdit] {
            #expect(!source.matchesTranscript(.capture(changed, mappings: [])))
        }
    }

    @Test func saveFailureKeepsExistingSummaryAndIsDistinctFromSupersession() async throws {
        let (store, id, source) = try await setup()
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .saved)
        let oldID = await store.currentSummaryID(for: id)
        await store.failNextSaveForTesting()
        #expect(await store.saveSummary(recordingID: id, summary: result, chaptersJSON: nil, expectedSource: source) == .failed)
        #expect(await store.currentSummaryID(for: id) == oldID)
        var draft = result
        draft.generationMetadata?.stage = .draft
        #expect(await store.saveSummary(recordingID: id, summary: draft, chaptersJSON: nil, expectedSource: source) == .keptReviewedSummary)
    }

    @Test func cancelledSaveDoesNotPersist() async throws {
        let (store, id, source) = try await setup()
        let output = result
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.saveSummary(recordingID: id, summary: output, chaptersJSON: nil, expectedSource: source)
        }
        #expect(await task.value == .cancelled)
        #expect(await store.currentSummaryID(for: id) == nil)
    }
}
