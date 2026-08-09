import Testing
import Foundation
@testable import Cadenza

@Suite("ArtifactTargetKey")
struct ArtifactTargetKeyTests {

    @Test func nonRecurringHasEmptyAnchor() {
        let key = ArtifactTargetKey.make(
            source: "apple", calendarID: "cal1",
            providerEventID: "evtA", occurrenceAnchor: nil)
        #expect(key == "apple|cal1|evtA|")
    }

    @Test func recurringInstancesDoNotCollide() {
        let occ1 = Date(timeIntervalSince1970: 1_000_000)
        let occ2 = Date(timeIntervalSince1970: 1_086_400) // +1 day
        let k1 = ArtifactTargetKey.make(source: "apple", calendarID: "cal1",
            providerEventID: "series1", occurrenceAnchor: occ1)
        let k2 = ArtifactTargetKey.make(source: "apple", calendarID: "cal1",
            providerEventID: "series1", occurrenceAnchor: occ2)
        #expect(k1 != k2)
        #expect(k1 == "apple|cal1|series1|1000000")
    }

    @Test func slotKeyComposesKindAndTarget() {
        let target = ArtifactTargetKey.make(source: "apple", calendarID: "c",
            providerEventID: "e", occurrenceAnchor: nil)
        let slot = ArtifactTargetKey.slotKey(
            kind: "meetingPrep", targetType: "calendarEvent", targetKey: target)
        #expect(slot == "meetingPrep|calendarEvent|apple|c|e|")
    }
}
