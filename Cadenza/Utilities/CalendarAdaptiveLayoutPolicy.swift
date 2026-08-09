import SwiftUI

enum CalendarAdaptiveLayoutMode: Equatable, Sendable {
    case timeline
    case agenda
}

enum CalendarAdaptiveLayoutPolicy {
    /// The compact timeline's 30-minute event slot is 30pt high. The real
    /// `CalendarEventBlock` hierarchy fits both title and time at the default
    /// scale only; `.xLarge` already measures 31pt even with compact padding.
    /// Reflow as an agenda as soon as the combined product/system scale grows.
    /// A small epsilon avoids a floating-point product near 1.0 flipping modes.
    static func mode(
        for size: DynamicTypeSize,
        effectiveScale: CGFloat
    ) -> CalendarAdaptiveLayoutMode {
        guard effectiveScale.isFinite, effectiveScale <= 1.001 else {
            return .agenda
        }
        switch size {
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            return .agenda
        default:
            return .timeline
        }
    }
}
