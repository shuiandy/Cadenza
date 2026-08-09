import Foundation

/// 判定一场会是否值得自动生成 prep(纯函数)。
enum MeetingPrepEligibility {
    static func isEligible(_ event: MeetingEvent) -> Bool {
        if event.isAllDay { return false }
        if event.myResponseStatus == .declined { return false }
        if event.availability == .free || event.availability == .outOfOffice { return false }
        let hasOtherAttendee = event.attendees.contains { !$0.isCurrentUser }
        let hasMeetingURL = event.meetingURL != nil
        return hasOtherAttendee || hasMeetingURL
    }
}
