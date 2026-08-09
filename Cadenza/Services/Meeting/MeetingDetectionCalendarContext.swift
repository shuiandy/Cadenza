import Foundation

enum MeetingDetectionCalendarContext {
    static let startTolerance: TimeInterval = 120
    static let endTolerance: TimeInterval = 30 * 60

    static func contains(
        _ date: Date = Date(),
        startDate: Date,
        endDate: Date,
        isAllDay: Bool
    ) -> Bool {
        guard !isAllDay else { return false }

        let effectiveStart = startDate.addingTimeInterval(-startTolerance)
        let effectiveEnd = endDate.addingTimeInterval(endTolerance)
        return date >= effectiveStart && date <= effectiveEnd
    }
}
