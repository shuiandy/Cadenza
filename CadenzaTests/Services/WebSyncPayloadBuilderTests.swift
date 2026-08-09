import Foundation
import Testing
@testable import Cadenza

@Suite("Web sync payload builder")
struct WebSyncPayloadBuilderTests {
    @Test
    func canonicalPayloadIsStableAndExcludesLocalMetadata() throws {
        let segment = TranscriptEntryDTO(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            startTime: 1.2496,
            endTime: 2.5,
            text: "hello",
            speaker: "Andy"
        )
        let transcript = TranscriptDTO(
            id: UUID(),
            fullText: "hello",
            segments: [segment],
            detectedLanguage: "en",
            createdAt: .distantPast
        )
        let detail = TestDTOFactory.makeRecordingDetailDTO(
            title: "Weekly sync",
            duration: 90.0004,
            tags: [" team ", "alpha", "team"],
            transcript: transcript
        )
        let snapshot = WebSyncSnapshot(detail: detail, folderPath: "Work/Team", trashedDate: nil)

        let first = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)
        let second = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)

        #expect(first.contentHash == second.contentHash)
        #expect(first.contentHash.count == 64)
        #expect(first.payload.transcript?.segments.first?.startMs == 1_250)
        #expect(first.payload.durationMs == 90_000)
        #expect(first.payload.tags == ["alpha", "team"])
        #expect(first.encodedData == second.encodedData)
        let json = String(decoding: first.encodedData, as: UTF8.self)
        #expect(!json.contains("meetingURL"))
        #expect(!json.contains("linkedCalendarEventID"))
    }

    @Test
    func missingArtifactsEncodeAsNull() throws {
        let snapshot = WebSyncSnapshot(
            detail: TestDTOFactory.makeRecordingDetailDTO(),
            folderPath: "",
            trashedDate: nil
        )
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .localOnly)
        let json = String(decoding: built.encodedData, as: UTF8.self)
        #expect(json.contains("\"transcript\":null"))
        #expect(json.contains("\"summary\":null"))
    }

    @Test
    func legacyInvalidSegmentTimesAreNormalizedForServerValidation() throws {
        let transcript = TranscriptDTO(
            id: UUID(),
            fullText: "legacy",
            segments: [
                TranscriptEntryDTO(
                    id: UUID(),
                    startTime: 12,
                    endTime: 9,
                    text: "reversed",
                    speaker: nil
                ),
                TranscriptEntryDTO(
                    id: UUID(),
                    startTime: -2,
                    endTime: -1,
                    text: "negative",
                    speaker: nil
                ),
            ],
            detectedLanguage: "en",
            createdAt: Date()
        )
        let snapshot = WebSyncSnapshot(
            detail: TestDTOFactory.makeRecordingDetailDTO(transcript: transcript),
            folderPath: "",
            trashedDate: nil
        )

        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .unavailable)
        let segments = try #require(built.payload.transcript?.segments)

        #expect(segments[0].startMs == 12_000)
        #expect(segments[0].endMs == 12_000)
        #expect(segments[1].startMs == 0)
        #expect(segments[1].endMs == 0)
    }

    @Test
    func summaryPreservesTasksChaptersAndProvenance() throws {
        let actionItemID = UUID()
        let summary = SummaryDTO(
            id: UUID(),
            overview: "Overview",
            keyPoints: [],
            actionItems: [ActionItemDTO(
                id: actionItemID,
                assignee: "Alex",
                task: "Ship it",
                deadline: "Friday",
                isCompleted: false,
                priority: "high"
            )],
            decisions: [],
            followUps: [],
            yourTasks: ["Review the launch"],
            provider: "openai",
            model: "gpt-5",
            language: "en",
            createdAt: Date(),
            chapters: [ChapterDTO(title: "Launch", startSeconds: 65, summary: "Release plan")]
        )
        let snapshot = WebSyncSnapshot(
            detail: TestDTOFactory.makeRecordingDetailDTO(summary: summary),
            folderPath: "",
            trashedDate: nil
        )

        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .unavailable)
        let markdown = built.payload.summary?.markdown ?? ""
        let structured = try #require(built.payload.summary?.structured)
        let actionItem = try #require(structured.actionItems.first)
        let chapter = try #require(structured.chapters.first)

        #expect(markdown.contains("due Friday"))
        #expect(markdown.contains("priority high"))
        #expect(markdown.contains("## Your Tasks"))
        #expect(markdown.contains("## Chapters"))
        #expect(markdown.contains("Launch (1:05)"))
        #expect(markdown.contains("Provider: openai"))
        #expect(markdown.contains("Model: gpt-5"))
        #expect(markdown.contains("Language: en"))
        #expect(structured.yourTasks == ["Review the launch"])
        #expect(actionItem.id == actionItemID.uuidString.lowercased())
        #expect(actionItem.task == "Ship it")
        #expect(actionItem.assignee == "Alex")
        #expect(actionItem.deadline == "Friday")
        #expect(!actionItem.completed)
        #expect(actionItem.priority == "high")
        #expect(chapter.title == "Launch")
        #expect(chapter.startSeconds == 65)
        #expect(chapter.summary == "Release plan")

        let root = try #require(
            JSONSerialization.jsonObject(with: built.encodedData) as? [String: Any]
        )
        let summaryJSON = try #require(root["summary"] as? [String: Any])
        let structuredJSON = try #require(summaryJSON["structured"] as? [String: Any])
        let actionItemsJSON = try #require(
            structuredJSON["action_items"] as? [[String: Any]]
        )
        let chaptersJSON = try #require(structuredJSON["chapters"] as? [[String: Any]])
        #expect(actionItemsJSON.first?["id"] as? String == actionItemID.uuidString.lowercased())
        #expect(actionItemsJSON.first?["completed"] as? Bool == false)
        #expect(chaptersJSON.first?["start_seconds"] as? Double == 65)
        #expect(structuredJSON["your_tasks"] as? [String] == ["Review the launch"])
    }

    @Test
    func calendarEventUsesTheServerWireKeysAndRoundTrips() throws {
        let calendarEvent = WebSyncCalendarEvent(
            title: "Weekly sales sync",
            startAt: 1_780_000_000,
            endAt: 1_780_001_800
        )
        let snapshot = WebSyncSnapshot(
            detail: TestDTOFactory.makeRecordingDetailDTO(),
            folderPath: "",
            trashedDate: nil,
            calendarEvent: calendarEvent
        )

        let built = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .unavailable
        )
        #expect(built.payload.calendarEvent?.title == calendarEvent.title)
        #expect(built.payload.calendarEvent?.startAt == calendarEvent.startAt)
        #expect(built.payload.calendarEvent?.endAt == calendarEvent.endAt)

        let root = try #require(
            JSONSerialization.jsonObject(with: built.encodedData) as? [String: Any]
        )
        let eventJSON = try #require(root["calendar_event"] as? [String: Any])
        #expect(eventJSON["title"] as? String == calendarEvent.title)
        #expect((eventJSON["start_at"] as? NSNumber)?.int64Value == calendarEvent.startAt)
        #expect((eventJSON["end_at"] as? NSNumber)?.int64Value == calendarEvent.endAt)
    }
}
