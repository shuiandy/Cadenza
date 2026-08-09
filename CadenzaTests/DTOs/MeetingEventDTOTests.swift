import Testing
import Foundation
@testable import Cadenza

@Suite("MeetingEventDTO")
struct MeetingEventDTOTests {
    @Test func roundTripPreservesOccurrenceKeyFields() {
        let event = MeetingEvent(
            id: "google_inst1", title: "Sync",
            startDate: Date(timeIntervalSince1970: 1000), endDate: Date(timeIntervalSince1970: 4600),
            meetingURL: nil, meetingApp: nil, calendarName: "G", notes: nil, source: .google, calendarID: "primary",
            attendees: [EventAttendee(name: "Me", email: "me@x.com", isOrganizer: false, status: .accepted, isCurrentUser: true)],
            isRecurring: true, providerEventID: "master", occurrenceAnchor: Date(timeIntervalSince1970: 1000),
            availability: .busy)
        let dto = MeetingEventDTO(from: event)
        #expect(dto.providerEventID == "master")
        #expect(dto.occurrenceAnchor == Date(timeIntervalSince1970: 1000))
        #expect(dto.availability == "busy")
        #expect(dto.attendees.first?.isCurrentUser == true)
        #expect(dto.myResponseStatus == "accepted")
        // artifactTargetKey matches the raw event's
        #expect(dto.artifactTargetKey == event.artifactTargetKey)
    }
}
