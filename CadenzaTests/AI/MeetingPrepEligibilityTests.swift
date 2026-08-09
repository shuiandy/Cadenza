import Testing
import Foundation
@testable import Cadenza

@Suite("MeetingPrepEligibility")
struct MeetingPrepEligibilityTests {
    private func ev(title: String = "Sync", availability: EventAvailability = .busy,
                    myStatus: AttendeeStatus? = nil, attendees: [EventAttendee] = [],
                    url: URL? = nil, allDayHours: Double = 1) -> MeetingEvent {
        var att = attendees
        if let s = myStatus { att.append(EventAttendee(name: "Me", email: "me@x.com", isOrganizer: false, status: s, isCurrentUser: true)) }

        // Create midnight start date in local calendar
        var midnightComps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        midnightComps.hour = 0
        midnightComps.minute = 0
        midnightComps.second = 0
        let startDate = Calendar.current.date(from: midnightComps) ?? Date()
        let endDate = startDate.addingTimeInterval(allDayHours * 3600)

        return MeetingEvent(id: "e", title: title,
            startDate: startDate,
            endDate: endDate,
            meetingURL: url, meetingApp: nil, calendarName: "c", notes: nil, source: .apple, calendarID: "c",
            attendees: att, availability: availability)
    }

    @Test func eligibleWithOtherAttendee() {
        let e = ev(attendees: [EventAttendee(name: "Dana", email: "d@x.com", isOrganizer: true, status: .accepted)])
        #expect(MeetingPrepEligibility.isEligible(e))
    }
    @Test func eligibleWithMeetingURLOnly() {
        #expect(MeetingPrepEligibility.isEligible(ev(url: URL(string: "https://zoom.us/j/1"))))
    }
    @Test func ineligibleAllDay() {
        #expect(!MeetingPrepEligibility.isEligible(ev(url: URL(string: "https://zoom.us/j/1"), allDayHours: 24)))
    }
    @Test func ineligibleDeclined() {
        #expect(!MeetingPrepEligibility.isEligible(ev(myStatus: .declined,
            attendees: [EventAttendee(name: "Dana", email: "d@x.com", isOrganizer: true, status: .accepted)])))
    }
    @Test func ineligibleFreeOrOoO() {
        let base = [EventAttendee(name: "Dana", email: "d@x.com", isOrganizer: true, status: .accepted)]
        #expect(!MeetingPrepEligibility.isEligible(ev(availability: .free, attendees: base)))
        #expect(!MeetingPrepEligibility.isEligible(ev(availability: .outOfOffice, attendees: base)))
    }
    @Test func ineligibleSoloBlock() {
        #expect(!MeetingPrepEligibility.isEligible(ev()))  // no other attendee, no URL
    }
}
