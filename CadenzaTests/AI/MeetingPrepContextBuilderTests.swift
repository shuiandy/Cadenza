import Testing
import Foundation
@testable import Cadenza

@Suite("MeetingPrepContextBuilder")
struct MeetingPrepContextBuilderTests {

    private func event() -> MeetingEvent {
        MeetingEvent(
            id: "e1", title: "Roadmap Sync",
            startDate: Date(timeIntervalSince1970: 1_000_000),
            endDate: Date(timeIntervalSince1970: 1_003_600),
            meetingURL: URL(string: "https://zoom.us/j/1"), meetingApp: .zoom,
            calendarName: "Work", notes: nil, source: .apple, calendarID: "c",
            attendees: [
                EventAttendee(name: "Me", email: "me@x.com", isOrganizer: false, status: .accepted, isCurrentUser: true),
                EventAttendee(name: "Dana", email: "dana@x.com", isOrganizer: true, status: .accepted)])
    }

    private func aiContext() -> AIContextData {
        AIContextData(
            summaries: [.init(recordingID: UUID(), title: "Last Roadmap Sync",
                startDate: Date(timeIntervalSince1970: 900_000), duration: 1800,
                summary: "Agreed to cut scope X.", meetingType: nil)],
            actionItems: [
                .init(recordingID: UUID(), recordingTitle: "Last Roadmap Sync", text: "Draft the spec",
                      isCompleted: false, assignee: "Dana", deadline: nil, priority: nil),
                .init(recordingID: UUID(), recordingTitle: "Last Roadmap Sync", text: "Done thing",
                      isCompleted: true, assignee: nil, deadline: nil, priority: nil)],
            decisions: [], followUps: [], transcriptExcerpts: [], transcriptCoverage: .excerpts, speakers: [])
    }

    @Test func includesEventAttendeesHistoryAndOpenItems() {
        let text = MeetingPrepContextBuilder.build(event: event(), aiContext: aiContext(), folderContext: nil)
        #expect(text.contains("Roadmap Sync"))
        #expect(text.contains("Dana"))
        #expect(text.contains("(you)"))                 // current user marked
        #expect(text.contains("Agreed to cut scope X.")) // last-touch summary
        #expect(text.contains("Draft the spec"))         // open action item
        #expect(!text.contains("Done thing"))            // completed item excluded
    }

    @Test func includesProjectContextWhenPresent() {
        let folder = FolderContextDTO(
            folderName: "Apollo", folderStatus: "active", totalRecordingCount: 3,
            recentMeetings: [], openActionItems: [], recentDecisions: [],
            followUps: [.init(text: "Follow up on vendor", sourceRecordingTitle: "Kickoff", sourceRecordingID: UUID())],
            knownSpeakers: [])
        let text = MeetingPrepContextBuilder.build(event: event(), aiContext: nil, folderContext: folder)
        #expect(text.contains("Apollo"))
        #expect(text.contains("Follow up on vendor"))
    }

    @Test func handlesEmptyContextGracefully() {
        let text = MeetingPrepContextBuilder.build(event: event(), aiContext: nil, folderContext: nil)
        #expect(text.contains("Roadmap Sync"))          // still has the event header
    }

    // MARK: - scoped() 隐私收窄

    @Test func scopedExcludesUnrelatedRecordings() {
        let related = UUID(), unrelated = UUID()
        let ctx = AIContextData(
            summaries: [
                .init(recordingID: related, title: "Roadmap Sync", startDate: Date(timeIntervalSince1970: 1),
                      duration: 60, summary: "roadmap stuff", meetingType: nil),
                .init(recordingID: unrelated, title: "Security Incident Review", startDate: Date(timeIntervalSince1970: 2),
                      duration: 60, summary: "sensitive stuff", meetingType: nil)],
            actionItems: [
                .init(recordingID: related, recordingTitle: "Roadmap Sync", text: "ship roadmap",
                      isCompleted: false, assignee: nil, deadline: nil, priority: nil),
                .init(recordingID: unrelated, recordingTitle: "Security Incident Review", text: "rotate keys",
                      isCompleted: false, assignee: nil, deadline: nil, priority: nil)],
            decisions: [], followUps: [], transcriptExcerpts: [], transcriptCoverage: .excerpts, speakers: [])
        let scoped = MeetingPrepContextBuilder.scoped(ctx, eventTitle: "Roadmap Sync")
        #expect(scoped.summaries.map(\.recordingID) == [related])
        #expect(scoped.actionItems.map(\.recordingID) == [related])
        // 无关会议内容绝不进入 prompt
        let text = MeetingPrepContextBuilder.build(event: event(), aiContext: scoped, folderContext: nil)
        #expect(!text.contains("rotate keys"))
        #expect(!text.contains("sensitive stuff"))
    }

    @Test func scopedIncludesExcerptHitRecordings() {
        // 标题完全不同,但参会人在该录音中说话(excerpt 命中)→ 相关
        let hit = UUID()
        let ctx = AIContextData(
            summaries: [.init(recordingID: hit, title: "Totally Different Title",
                startDate: Date(timeIntervalSince1970: 1), duration: 60, summary: "dana context", meetingType: nil)],
            actionItems: [],
            decisions: [], followUps: [],
            transcriptExcerpts: [.init(recordingID: hit, recordingTitle: "Totally Different Title",
                startTime: 0, rawSpeaker: "Speaker 1", resolvedSpeakerName: "Dana", text: "hello")],
            transcriptCoverage: .excerpts, speakers: [])
        let scoped = MeetingPrepContextBuilder.scoped(ctx, eventTitle: "1:1 Dana")
        #expect(scoped.summaries.count == 1)
    }

    @Test func scopedEmptyWhenNothingRelevant() {
        let ctx = AIContextData(
            summaries: [.init(recordingID: UUID(), title: "Other Meeting",
                startDate: Date(timeIntervalSince1970: 1), duration: 60, summary: "x", meetingType: nil)],
            actionItems: [], decisions: [], followUps: [], transcriptExcerpts: [], transcriptCoverage: .excerpts, speakers: [])
        #expect(MeetingPrepContextBuilder.scoped(ctx, eventTitle: "Quarterly Kickoff").summaries.isEmpty)
    }

    @Test func titleMatchingAvoidsSubstringAndGenericWordFalsePositives() {
        // 子串误伤回归:"ai" 是 "d[ai]ly" 的子串;"Sync" 是 "Security Sync" 的子串——都不得匹配
        #expect(!MeetingPrepContextBuilder.titleSimilar("Daily Standup", "AI"))
        #expect(!MeetingPrepContextBuilder.titleSimilar("Security Sync", "Sync"))
        #expect(!MeetingPrepContextBuilder.titleSimilar("Q3 Budget Review", "Q3"))
        // token 重叠占比够高才匹配
        #expect(MeetingPrepContextBuilder.titleSimilar("Last Roadmap Sync", "Roadmap Sync"))   // 2/3
        #expect(MeetingPrepContextBuilder.titleSimilar("Security Sync", "Security Sync Weekly")) // 2/3
        // 完全相等(含 CJK 整题)始终匹配
        #expect(MeetingPrepContextBuilder.titleSimilar("周会", "周会"))
        #expect(!MeetingPrepContextBuilder.titleSimilar("产品周会", "周会"))  // CJK 无分词 → 不同即不匹配(漏配优于误伤)
    }
}
