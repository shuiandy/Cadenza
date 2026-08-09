import Testing
import Foundation
import SwiftData
@testable import Cadenza

@Suite("MeetingSummary Model")
struct MeetingSummaryModelTests {

    @Test func defaultInit() {
        let s = MeetingSummary()
        #expect(s.overview == "")
        #expect(s.keyPoints.isEmpty)
        #expect(s.actionItems.isEmpty)
        #expect(s.decisions.isEmpty)
        #expect(s.followUps.isEmpty)
        #expect(s.provider == AIProvider.openai.rawValue)
        #expect(s.model == "")
        #expect(s.language == "en")
        #expect(s.recording == nil)
    }

    @Test func customInit() {
        let item = ActionItem(assignee: "Alice", task: "Review PR", deadline: "Friday")
        let s = MeetingSummary(
            overview: "Sprint review",
            keyPoints: ["Shipped v2", "Bug count down"],
            actionItems: [item],
            decisions: ["Go with plan A"],
            followUps: ["Check metrics"],
            provider: .claude,
            model: "claude-sonnet-4-5-20250929",
            language: "ja"
        )
        #expect(s.overview == "Sprint review")
        #expect(s.keyPoints.count == 2)
        #expect(s.actionItems.count == 1)
        #expect(s.decisions == ["Go with plan A"])
        #expect(s.followUps == ["Check metrics"])
        #expect(s.provider == "claude")
        #expect(s.model == "claude-sonnet-4-5-20250929")
        #expect(s.language == "ja")
    }

    @Test func idIsUnique() {
        let s1 = MeetingSummary()
        let s2 = MeetingSummary()
        #expect(s1.id != s2.id)
    }

    @Test func createdAtIsNow() {
        let before = Date()
        let s = MeetingSummary()
        let after = Date()
        #expect(s.createdAt >= before)
        #expect(s.createdAt <= after)
    }

    // MARK: - ActionItem

    @Test func actionItemDefaultInit() {
        let item = ActionItem(task: "Do something")
        #expect(item.assignee == nil)
        #expect(item.task == "Do something")
        #expect(item.deadline == nil)
    }

    @Test func actionItemFullInit() {
        let item = ActionItem(assignee: "Bob", task: "Write tests", deadline: "2025-01-15")
        #expect(item.assignee == "Bob")
        #expect(item.task == "Write tests")
        #expect(item.deadline == "2025-01-15")
    }

    @Test func actionItemCodable() throws {
        let original = ActionItem(assignee: "Charlie", task: "Deploy", deadline: "Monday")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionItem.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.assignee == "Charlie")
        #expect(decoded.task == "Deploy")
        #expect(decoded.deadline == "Monday")
    }

    @Test func actionItemDecodesLegacyPayloadWithoutInventingTimestamps() throws {
        let id = UUID()
        let data = Data("""
        {
          "id": "\(id.uuidString)",
          "assignee": "Dana",
          "task": "Review the legacy note",
          "deadline": "Friday",
          "isCompleted": false,
          "priority": "medium"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ActionItem.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.createdAt == nil)
        #expect(decoded.updatedAt == nil)
    }

    @Test func actionItemIdIsUnique() {
        let a1 = ActionItem(task: "a")
        let a2 = ActionItem(task: "a")
        #expect(a1.id != a2.id)
    }

    @MainActor @Test func persistWithRecording() throws {
        let context = try TestPersistence.makeFreshContext()

        let r = TestRecordingFactory.makeRecording()
        let s = TestRecordingFactory.makeSummary(overview: "Test summary", keyPoints: ["K1", "K2"])
        r.summary = s
        context.insert(r)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MeetingSummary>()).first!
        #expect(fetched.overview == "Test summary")
        #expect(fetched.keyPoints.count == 2)
    }
}
