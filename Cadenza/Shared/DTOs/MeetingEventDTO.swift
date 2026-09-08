import Foundation

/// Calendar event for UI display (mirrors MeetingEvent without EventKit dependency).
struct MeetingEventDTO: Codable, Sendable, Identifiable, Equatable {
    let id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var meetingURL: String?
    var meetingApp: String?
    var calendarName: String
    var notes: String?
    var source: String  // CalendarSource rawValue
    var calendarID: String
    var defaultColorHex: String
    var organizer: String?
    var attendees: [EventAttendeeDTO]
    var isRecurring: Bool
    var location: String?
    var providerEventID: String = ""
    var occurrenceAnchor: Date?
    var availability: String = EventAvailability.busy.rawValue  // EventAvailability rawValue

    /// 当前用户对该会的回应(派生自 attendees)。镜像 `MeetingEvent.myResponseStatus`。
    var myResponseStatus: String? {
        attendees.first(where: \.isCurrentUser)?.status
    }

    /// occurrence key 用的 provider id:显式非空则用之,否则从 id 剥 source 前缀。镜像 `MeetingEvent.resolvedProviderEventID`。
    var resolvedProviderEventID: String {
        providerEventID.isEmpty ? MeetingEvent.stripSourcePrefix(id) : providerEventID
    }

    /// 接 Phase 1 的稳定 occurrence key。镜像 `MeetingEvent.artifactTargetKey`。
    var artifactTargetKey: String {
        ArtifactTargetKey.make(
            source: source, calendarID: calendarID,
            providerEventID: resolvedProviderEventID, occurrenceAnchor: occurrenceAnchor)
    }

    var isAllDay: Bool {
        let calendar = Calendar.current
        let duration = endDate.timeIntervalSince(startDate)
        let comps = calendar.dateComponents([.hour, .minute], from: startDate)
        return comps.hour == 0 && comps.minute == 0 && duration >= 23 * 3600
    }

    var isHappening: Bool {
        let now = Date()
        return now >= startDate && now <= endDate
    }

    func isWithinDetectionContext(at date: Date = Date()) -> Bool {
        MeetingDetectionCalendarContext.contains(
            date,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay
        )
    }

    var isUpcoming: Bool {
        Date() < startDate
    }

    var minutesUntilStart: Int {
        Int(startDate.timeIntervalSinceNow / 60)
    }
}

extension MeetingEventDTO {
    init(from event: MeetingEvent) {
        self.id = event.id
        self.title = event.title
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.meetingURL = event.meetingURL?.absoluteString
        self.meetingApp = event.meetingApp?.rawValue
        self.calendarName = event.calendarName
        self.notes = event.notes
        self.source = event.source.rawValue
        self.calendarID = event.calendarID
        self.defaultColorHex = event.defaultColorHex
        self.organizer = event.organizer
        self.attendees = event.attendees.map {
            EventAttendeeDTO(name: $0.name, email: $0.email, isOrganizer: $0.isOrganizer, status: $0.status.rawValue, isCurrentUser: $0.isCurrentUser)
        }
        self.isRecurring = event.isRecurring
        self.location = event.location
        self.providerEventID = event.providerEventID
        self.occurrenceAnchor = event.occurrenceAnchor
        self.availability = event.availability.rawValue
    }
}

struct EventAttendeeDTO: Codable, Sendable, Identifiable, Equatable {
    var id: String { email }
    let name: String
    let email: String
    let isOrganizer: Bool
    let status: String  // AttendeeStatus rawValue
    var isCurrentUser: Bool = false
}
