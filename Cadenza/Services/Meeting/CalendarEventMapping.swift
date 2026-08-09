import EventKit
import Foundation

/// 纯映射 helper(可脱离真实 EKEvent 单测)。
enum CalendarEventMapping {
    static func availability(from a: EKEventAvailability) -> EventAvailability {
        switch a {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .busy
        @unknown default: .busy
        }
    }

    /// Apple best-effort:EventKit 无稳定「原始 occurrence start」公共 API,
    /// 周期实例用当前 startDate 作 anchor(移动后换 key,Phase 4 fingerprint/stale 兜)。
    static func occurrenceAnchor(isRecurring: Bool, startDate: Date) -> Date? {
        isRecurring ? startDate : nil
    }
}
