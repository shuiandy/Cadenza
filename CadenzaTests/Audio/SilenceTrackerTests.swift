import Testing
import Foundation
@testable import Cadenza

@Suite("SilenceTracker")
struct SilenceTrackerTests {

    /// Injectable fake clock.
    final class Clock: @unchecked Sendable {
        var current: TimeInterval = 1000
        func now() -> TimeInterval { current }
    }

    @Test func startsWithZeroSilence() {
        let clock = Clock()
        let tracker = SilenceTracker(now: clock.now)
        #expect(tracker.silenceDuration == 0)
    }

    @Test func silenceAccumulatesWhenLevelsBelowThreshold() {
        let clock = Clock()
        let tracker = SilenceTracker(now: clock.now)
        clock.current = 1010
        tracker.record(level: 0.0)
        clock.current = 1060
        tracker.record(level: 0.01) // below 0.03 threshold
        #expect(tracker.silenceDuration == 60)
    }

    @Test func audibleLevelResetsSilence() {
        let clock = Clock()
        let tracker = SilenceTracker(now: clock.now)
        clock.current = 1100
        tracker.record(level: 0.5)
        #expect(tracker.silenceDuration == 0)
        clock.current = 1130
        #expect(tracker.silenceDuration == 30)
    }

    @Test func nilLevelFailsOpenAsAudible() {
        // nil = unknown buffer format — must count as audible so an
        // unparseable mic format can never read as silence.
        let clock = Clock()
        let tracker = SilenceTracker(now: clock.now)
        clock.current = 1200
        tracker.record(level: nil)
        #expect(tracker.silenceDuration == 0)
    }

    @Test func resetClearsSilence() {
        let clock = Clock()
        let tracker = SilenceTracker(now: clock.now)
        clock.current = 1500
        #expect(tracker.silenceDuration == 500)
        tracker.reset()
        #expect(tracker.silenceDuration == 0)
    }

    @Test func thresholdBoundaryIsSilent() {
        // Exactly at threshold does NOT reset (strictly-greater counts audible).
        let clock = Clock()
        let tracker = SilenceTracker(now: clock.now)
        clock.current = 1050
        tracker.record(level: SilenceTracker.silenceLevelThreshold)
        #expect(tracker.silenceDuration == 50)
    }
}
