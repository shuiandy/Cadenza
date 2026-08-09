import Foundation

enum CalendarAutoLinkResolver {
    static func bestEvent(startDate: Date, endDate: Date, events: [MeetingEvent]) -> MeetingEvent? {
        var bestEvent: MeetingEvent?
        var bestOverlap: TimeInterval = 0

        for event in events where !event.isAllDay {
            let overlapStart = max(event.startDate, startDate)
            let overlapEnd = min(event.endDate, endDate)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestEvent = event
            }
        }

        return bestEvent
    }
}
