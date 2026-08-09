import Testing
import EventKit
import Foundation
@testable import Cadenza

@Suite("CalendarEventMapping")
struct CalendarEventMappingTests {

    @Test func availabilityMapping() {
        #expect(CalendarEventMapping.availability(from: .busy) == .busy)
        #expect(CalendarEventMapping.availability(from: .free) == .free)
        #expect(CalendarEventMapping.availability(from: .tentative) == .tentative)
        #expect(CalendarEventMapping.availability(from: .unavailable) == .unavailable)
        #expect(CalendarEventMapping.availability(from: .notSupported) == .busy) // 缺省当忙
    }

    @Test func occurrenceAnchorOnlyForRecurring() {
        let start = Date(timeIntervalSince1970: 5000)
        #expect(CalendarEventMapping.occurrenceAnchor(isRecurring: true, startDate: start) == start)
        #expect(CalendarEventMapping.occurrenceAnchor(isRecurring: false, startDate: start) == nil)
    }
}
