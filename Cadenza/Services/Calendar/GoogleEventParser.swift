import Foundation

/// 纯函数:Google Calendar events API 的 JSON → [MeetingEvent]。无网络/无实例状态,便于单测。
enum GoogleEventParser {
    static func parse(_ data: Data) -> [MeetingEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return items.compactMap { item in parseEvent(item, iso: iso) }
    }

    private static func parseEvent(_ item: [String: Any], iso: ISO8601DateFormatter) -> MeetingEvent? {
        guard let id = item["id"] as? String,
              let summary = item["summary"] as? String else { return nil }
        if (item["status"] as? String) == "cancelled" { return nil }

        let start = item["start"] as? [String: Any]
        let end = item["end"] as? [String: Any]
        guard let startStr = start?["dateTime"] as? String ?? start?["date"] as? String,
              let endStr = end?["dateTime"] as? String ?? end?["date"] as? String,
              let startDate = iso.date(from: startStr) ?? parseDate(startStr),
              let endDate = iso.date(from: endStr) ?? parseDate(endStr) else { return nil }

        // meeting URL
        let description = item["description"] as? String
        let location = item["location"] as? String
        let hangoutLink = item["hangoutLink"] as? String
        var meetingURL: URL?
        var meetingApp: MeetingApp?
        if let link = hangoutLink, let url = URL(string: link) {
            meetingURL = url; meetingApp = .googleMeet
        } else {
            let searchText = [description, location].compactMap { $0 }.joined(separator: " ")
            if let url = MeetingURLParser.findMeetingURL(in: searchText) {
                meetingURL = url; meetingApp = MeetingURLParser.detectApp(from: url)
            }
        }

        // recurrence
        let recurringEventId = item["recurringEventId"] as? String
        let originalStart = (item["originalStartTime"] as? [String: Any])
            .flatMap { $0["dateTime"] as? String ?? $0["date"] as? String }
            .flatMap { iso.date(from: $0) ?? parseDate($0) }

        // availability
        let availability: EventAvailability = {
            if (item["eventType"] as? String) == "outOfOffice" { return .outOfOffice }
            switch item["transparency"] as? String {
            case "transparent": return .free
            default: return .busy   // opaque / 缺省
            }
        }()

        // attendees + organizer
        let organizerDict = item["organizer"] as? [String: Any]
        let organizer = organizerDict?["displayName"] as? String ?? organizerDict?["email"] as? String
        let attendees: [EventAttendee] = (item["attendees"] as? [[String: Any]] ?? []).map { a in
            let status: AttendeeStatus = switch a["responseStatus"] as? String {
                case "accepted": .accepted
                case "declined": .declined
                case "tentative": .tentative
                case "needsAction": .pending
                default: .unknown
            }
            let email = a["email"] as? String ?? ""
            return EventAttendee(
                name: a["displayName"] as? String ?? email,
                email: email,
                isOrganizer: (a["organizer"] as? Bool) ?? false,
                status: status,
                isCurrentUser: (a["self"] as? Bool) ?? false)
        }

        return MeetingEvent(
            id: "google_\(id)", title: summary, startDate: startDate, endDate: endDate,
            meetingURL: meetingURL, meetingApp: meetingApp, calendarName: "Google Calendar",
            notes: description, source: .google, calendarID: "primary",
            organizer: organizer, attendees: attendees,
            isRecurring: recurringEventId != nil, location: location,
            providerEventID: recurringEventId ?? "", occurrenceAnchor: originalStart,
            availability: availability)
    }

    private static func parseDate(_ string: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}
