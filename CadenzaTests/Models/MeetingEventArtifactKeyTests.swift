import Testing
import Foundation
@testable import Cadenza

@Suite("MeetingEventArtifactKey")
struct MeetingEventArtifactKeyTests {

    private func makeEvent(id: String, source: CalendarSource, calendarID: String,
                           providerEventID: String = "", occurrenceAnchor: Date? = nil,
                           attendees: [EventAttendee] = []) -> MeetingEvent {
        MeetingEvent(
            id: id, title: "T",
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 4600),
            meetingURL: nil, meetingApp: nil, calendarName: "cal", notes: nil,
            source: source, calendarID: calendarID, attendees: attendees,
            providerEventID: providerEventID, occurrenceAnchor: occurrenceAnchor)
    }

    @Test func appleKeyUsesEventIdentifierNoPrefix() {
        let e = makeEvent(id: "APPLE-EVT-1", source: .apple, calendarID: "calA")
        #expect(e.artifactTargetKey == "apple|calA|APPLE-EVT-1|")
    }

    @Test func googleRecurringUsesMasterAndAnchor() {
        let e = makeEvent(id: "google_inst_1", source: .google, calendarID: "primary",
            providerEventID: "masterABC", occurrenceAnchor: Date(timeIntervalSince1970: 1000))
        #expect(e.artifactTargetKey == "google|primary|masterABC|1000")
    }

    @Test func zoomStripsPrefixWhenNoExplicitProviderID() {
        let e = makeEvent(id: "zoom_98765", source: .zoom, calendarID: "")
        #expect(e.artifactTargetKey == "zoom||98765|")
    }

    @Test func myResponseFromCurrentUserAttendee() {
        let att = [
            EventAttendee(name: "Me", email: "me@x.com", isOrganizer: false, status: .accepted, isCurrentUser: true),
            EventAttendee(name: "Other", email: "o@x.com", isOrganizer: true, status: .declined)]
        let e = makeEvent(id: "x", source: .apple, calendarID: "c", attendees: att)
        #expect(e.myResponseStatus == .accepted)
    }

    @Test func myResponseNilWhenNoCurrentUser() {
        let e = makeEvent(id: "x", source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "Other", email: "o@x.com", isOrganizer: true, status: .accepted)])
        #expect(e.myResponseStatus == nil)
    }

    @Test func availabilityDefaultsBusy() {
        #expect(makeEvent(id: "x", source: .apple, calendarID: "c").availability == .busy)
    }
}
