import Testing
import Foundation
@testable import Cadenza

@Suite("MeetingPrepFingerprint")
struct MeetingPrepFingerprintTests {
    private func ev(title: String, start: TimeInterval, attendeeStatus: AttendeeStatus = .accepted, notes: String? = nil) -> MeetingEvent {
        MeetingEvent(id: "e", title: title,
            startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: start + 3600),
            meetingURL: nil, meetingApp: nil, calendarName: "c", notes: notes, source: .apple, calendarID: "c",
            attendees: [EventAttendee(name: "D", email: "d@x.com", isOrganizer: true, status: attendeeStatus)])
    }
    @Test func stableForSameEvent() {
        #expect(MeetingPrepFingerprint.compute(ev(title: "A", start: 100)) == MeetingPrepFingerprint.compute(ev(title: "A", start: 100)))
    }
    @Test func changesOnTimeMove() {
        #expect(MeetingPrepFingerprint.compute(ev(title: "A", start: 100)) != MeetingPrepFingerprint.compute(ev(title: "A", start: 200)))
    }
    @Test func changesOnAttendeeStatus() {
        #expect(MeetingPrepFingerprint.compute(ev(title: "A", start: 100)) != MeetingPrepFingerprint.compute(ev(title: "A", start: 100, attendeeStatus: .declined)))
    }
    @Test func changesOnNotes() {
        #expect(MeetingPrepFingerprint.compute(ev(title: "A", start: 100)) != MeetingPrepFingerprint.compute(ev(title: "A", start: 100, notes: "agenda")))
    }
}
