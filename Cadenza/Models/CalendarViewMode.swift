import Foundation

enum CalendarViewMode: String, CaseIterable {
    case day
    case week
    case month

    var title: String {
        switch self {
        case .day: String(localized: "Day")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        }
    }
}
