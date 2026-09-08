import Foundation
import Testing
@testable import Cadenza

@Suite("Today meeting strip")
struct TodayMeetingStripTests {

    private func event(_ id: String, start: Date, minutes: Double) -> MeetingEventDTO {
        MeetingEventDTO(
            id: id, title: id, startDate: start, endDate: start.addingTimeInterval(minutes * 60),
            meetingURL: nil, meetingApp: nil, calendarName: "Work", notes: nil,
            source: "test", calendarID: "cal", defaultColorHex: "", organizer: nil,
            attendees: [], isRecurring: false, location: nil
        )
    }

    @Test func inProgressWinsThenNextUpcomingAndTheClockDecides() throws {
        let calendar = Calendar(identifier: .gregorian)
        var noon = calendar.dateComponents([.year, .month, .day], from: Date())
        noon.hour = 12
        let now = try #require(calendar.date(from: noon))
        let earlier = event("earlier", start: now.addingTimeInterval(-90 * 60), minutes: 30)
        let running = event("running", start: now.addingTimeInterval(-10 * 60), minutes: 30)
        let soon = event("soon", start: now.addingTimeInterval(20 * 60), minutes: 30)
        let later = event("later", start: now.addingTimeInterval(120 * 60), minutes: 30)
        let allDay = event("allday", start: calendar.startOfDay(for: now), minutes: 24 * 60)
        let meetings = [later, soon, running, earlier, allDay]

        #expect(TodayMeetingStrip.upcomingMeeting(in: meetings, now: now, calendar: calendar)?.id == "running")
        // Same array, later clock: the running meeting ended, "soon" is next.
        let afterRunning = now.addingTimeInterval(25 * 60)
        #expect(TodayMeetingStrip.upcomingMeeting(in: meetings, now: afterRunning, calendar: calendar)?.id == "soon")
        // And once "soon" starts it flips to in progress without any array change.
        let duringSoon = now.addingTimeInterval(21 * 60)
        #expect(TodayMeetingStrip.upcomingMeeting(in: meetings, now: duringSoon, calendar: calendar)?.id == "soon")
        // Past the last meeting: nothing to show.
        #expect(TodayMeetingStrip.upcomingMeeting(in: meetings, now: now.addingTimeInterval(200 * 60), calendar: calendar) == nil)
    }

    @Test func scheduleWakesOnMinuteBoundariesAndMeetingEdges() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_000_000_035)  // :35 past a minute
        let minute = calendar.nextDate(
            after: start, matching: DateComponents(second: 0), matchingPolicy: .nextTime
        )!
        let edgeInsideFirstMinute = start.addingTimeInterval(15)
        let edgeOnMinute = minute.addingTimeInterval(60)
        let past = start.addingTimeInterval(-5)
        let entries = Array(MeetingBoundarySchedule.entries(
            boundaries: [edgeOnMinute, past, edgeInsideFirstMinute], from: start, calendar: calendar
        ).prefix(5))

        #expect(entries == [
            edgeInsideFirstMinute,
            minute,
            edgeOnMinute,                       // coincides with a minute tick: emitted once
            minute.addingTimeInterval(120),
            minute.addingTimeInterval(180),
        ])
        #expect(entries.allSatisfy { $0 > start })
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func dtoEqualityIgnoresNothingAndTracksContent() {
        let now = Date()
        let a = event("a", start: now, minutes: 30)
        var b = a
        #expect(a == b)
        b.title = "renamed"
        #expect(a != b)
    }
}
