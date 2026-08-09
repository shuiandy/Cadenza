import Foundation
import Testing
@testable import Cadenza

@Suite("Meeting Detection Calendar Context")
struct MeetingDetectionCalendarContextTests {

    @Test func containsStrictMeetingWindow() {
        let now = Date()
        let event = makeEvent(startOffset: -300, endOffset: 300, relativeTo: now)

        #expect(event.isWithinDetectionContext(at: now))
    }

    @Test func containsRecentlyEndedMeetingWindow() {
        let now = Date()
        let event = makeEvent(startOffset: -3600, endOffset: -60, relativeTo: now)

        #expect(event.isWithinDetectionContext(at: now))
    }

    @Test func rejectsOldEndedMeetingWindow() {
        let now = Date()
        let event = makeEvent(startOffset: -7200, endOffset: -3600, relativeTo: now)

        #expect(!event.isWithinDetectionContext(at: now))
    }

    @Test func rejectsAllDayEvents() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = start.addingTimeInterval(24 * 3600)
        let event = MeetingEvent(
            id: "all-day",
            title: "Out of Office",
            startDate: start,
            endDate: end,
            meetingURL: nil,
            meetingApp: nil,
            calendarName: "Work",
            notes: nil
        )

        #expect(!event.isWithinDetectionContext(at: start.addingTimeInterval(3600)))
    }

    private func makeEvent(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        relativeTo now: Date
    ) -> MeetingEvent {
        MeetingEvent(
            id: "event",
            title: "Design Review",
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            meetingURL: nil,
            meetingApp: .teams,
            calendarName: "Work",
            notes: nil
        )
    }
}
