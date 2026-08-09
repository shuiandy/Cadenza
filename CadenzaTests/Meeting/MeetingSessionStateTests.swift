import Testing
@testable import Cadenza

@Suite("MeetingSessionState")
struct MeetingSessionStateTests {

    // MARK: - Helpers

    /// Fixed reference time for deterministic tests.
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Offset from t0 by the given number of seconds.
    private func t(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    // MARK: - Idle State

    @Test func idle_belowThreshold_staysIdle() {
        let state = MeetingSessionState.idle
        let next = state.next(score: 2, app: .teams, now: t0)
        #expect(next.isIdle)
    }

    @Test func idle_noApp_staysIdle() {
        let state = MeetingSessionState.idle
        let next = state.next(score: 5, app: nil, now: t0)
        #expect(next.isIdle)
    }

    @Test func idle_atThreshold_transitionsToDetected() {
        let state = MeetingSessionState.idle
        let next = state.next(score: 3, app: .zoom, now: t0)
        #expect(next.isDetected)
        #expect(next.currentApp == .zoom)
    }

    @Test func idle_aboveThreshold_transitionsToDetected() {
        let state = MeetingSessionState.idle
        let next = state.next(score: 6, app: .teams, now: t0)
        #expect(next.isDetected)
        #expect(next.currentApp == .teams)
    }

    // MARK: - Detected State

    @Test func detected_scoreDrop_returnsToIdle() {
        let state = MeetingSessionState.detected(since: t0, app: .teams)
        let next = state.next(score: 1, app: .teams, now: t(0.5))
        #expect(next.isIdle)
    }

    @Test func detected_beforeDebounce_staysDetected() {
        let state = MeetingSessionState.detected(since: t0, app: .zoom)
        // 0.5s is within debounce (1s)
        let next = state.next(score: 4, app: .zoom, now: t(0.5))
        #expect(next.isDetected)
        #expect(next.currentApp == .zoom)
    }

    @Test func detected_atDebounce_transitionsToActive() {
        let state = MeetingSessionState.detected(since: t0, app: .zoom)
        // Exactly at debounce boundary (1s)
        let next = state.next(score: 4, app: .zoom, now: t(1))
        #expect(next.isActive)
        #expect(next.currentApp == .zoom)
    }

    @Test func detected_afterDebounce_transitionsToActive() {
        let state = MeetingSessionState.detected(since: t0, app: .teams)
        // 3s > 1s debounce
        let next = state.next(score: 3, app: .teams, now: t(3))
        #expect(next.isActive)
        #expect(next.currentApp == .teams)
    }

    @Test func detected_appChange_preservesSessionOwner() {
        let state = MeetingSessionState.detected(since: t0, app: .teams)
        // Foreground changes must not transfer a pending session.
        let next = state.next(score: 4, app: .zoom, now: t(0.5))
        #expect(next.isDetected)
        #expect(next.currentApp == .teams)
    }

    @Test func detected_nilApp_preservesOriginalApp() {
        let state = MeetingSessionState.detected(since: t0, app: .webex)
        let next = state.next(score: 3, app: nil, now: t(0.5))
        #expect(next.isDetected)
        #expect(next.currentApp == .webex)
    }

    // MARK: - Active State

    @Test func active_scoreAboveThreshold_staysActive() {
        let state = MeetingSessionState.active(app: .teams)
        let next = state.next(score: 5, app: .teams, now: t0)
        #expect(next.isActive)
        #expect(next.currentApp == .teams)
    }

    @Test func active_scoreDrop_transitionsToEnding() {
        let state = MeetingSessionState.active(app: .zoom)
        let next = state.next(score: 2, app: .zoom, now: t0)
        #expect(next.isEnding)
        #expect(next.currentApp == .zoom)
    }

    @Test func active_scoreZero_transitionsToEnding() {
        let state = MeetingSessionState.active(app: .teams)
        let next = state.next(score: 0, app: nil, now: t0)
        #expect(next.isEnding)
        #expect(next.currentApp == .teams)
    }

    @Test func active_appChange_preservesSessionOwner() {
        let state = MeetingSessionState.active(app: .teams)
        let next = state.next(score: 4, app: .zoom, now: t0)
        #expect(next.isActive)
        #expect(next.currentApp == .teams)
    }

    @Test func active_nilApp_preservesApp() {
        let state = MeetingSessionState.active(app: .facetime)
        let next = state.next(score: 3, app: nil, now: t0)
        #expect(next.isActive)
        #expect(next.currentApp == .facetime)
    }

    // MARK: - Ending State

    @Test func ending_scoreRecovery_returnsToActive() {
        let state = MeetingSessionState.ending(since: t0, app: .teams)
        let next = state.next(score: 3, app: .teams, now: t(2))
        #expect(next.isActive)
        #expect(next.currentApp == .teams)
    }

    @Test func ending_beforeGrace_staysEnding() {
        let state = MeetingSessionState.ending(since: t0, app: .zoom)
        // 1.5s < 3s grace
        let next = state.next(score: 1, app: .zoom, now: t(1.5))
        #expect(next.isEnding)
        #expect(next.currentApp == .zoom)
    }

    @Test func ending_atGrace_transitionsToIdle() {
        let state = MeetingSessionState.ending(since: t0, app: .teams)
        // Exactly at grace boundary (3s)
        let next = state.next(score: 0, app: nil, now: t(3))
        #expect(next.isIdle)
    }

    @Test func ending_afterGrace_transitionsToIdle() {
        let state = MeetingSessionState.ending(since: t0, app: .webex)
        // 5s > 3s grace
        let next = state.next(score: 1, app: .webex, now: t(5))
        #expect(next.isIdle)
    }

    @Test func ending_scoreRecoveryWithAppChange_preservesSessionOwner() {
        let state = MeetingSessionState.ending(since: t0, app: .teams)
        let next = state.next(score: 4, app: .zoom, now: t(1.5))
        #expect(next.isActive)
        #expect(next.currentApp == .teams)
    }

    @Test func ending_scoreRecoveryNilApp_preservesApp() {
        let state = MeetingSessionState.ending(since: t0, app: .slack)
        let next = state.next(score: 3, app: nil, now: t(1.5))
        #expect(next.isActive)
        #expect(next.currentApp == .slack)
    }

    // MARK: - Full Lifecycle

    @Test func fullLifecycle_idle_detected_active_ending_idle() {
        // 1. Start idle
        var state = MeetingSessionState.idle
        #expect(state.isIdle)

        // 2. Meeting signals detected -> detected
        state = state.next(score: 4, app: .teams, now: t(0))
        #expect(state.isDetected)

        // 3. Still detected at 0.5s (before 1s debounce)
        state = state.next(score: 4, app: .teams, now: t(0.5))
        #expect(state.isDetected)

        // 4. Debounce elapsed -> active
        state = state.next(score: 4, app: .teams, now: t(1))
        #expect(state.isActive)

        // 5. Signals drop -> ending
        state = state.next(score: 1, app: .teams, now: t(60))
        #expect(state.isEnding)

        // 6. Brief recovery during grace -> back to active
        state = state.next(score: 3, app: .teams, now: t(62))
        #expect(state.isActive)

        // 7. Signals drop again -> ending
        state = state.next(score: 0, app: nil, now: t(120))
        #expect(state.isEnding)

        // 8. Grace period elapsed -> idle (3s grace: t120 + 3 = t123)
        state = state.next(score: 0, app: nil, now: t(123))
        #expect(state.isIdle)
    }

    @Test func detectionFlicker_doesNotReachActive() {
        // Signal appears briefly then disappears before debounce
        var state = MeetingSessionState.idle

        // Signal appears
        state = state.next(score: 3, app: .zoom, now: t(0))
        #expect(state.isDetected)

        // Signal flickers at 0.5s — still above threshold
        state = state.next(score: 3, app: .zoom, now: t(0.5))
        #expect(state.isDetected)

        // Signal drops at 0.8s — before 1s debounce
        state = state.next(score: 1, app: .zoom, now: t(0.8))
        #expect(state.isIdle)
    }

    // MARK: - Convenience Properties

    @Test func convenienceProperties_idle() {
        let state = MeetingSessionState.idle
        #expect(state.isIdle)
        #expect(!state.isDetected)
        #expect(!state.isActive)
        #expect(!state.isEnding)
        #expect(state.currentApp == nil)
    }

    @Test func convenienceProperties_detected() {
        let state = MeetingSessionState.detected(since: t0, app: .teams)
        #expect(!state.isIdle)
        #expect(state.isDetected)
        #expect(!state.isActive)
        #expect(!state.isEnding)
        #expect(state.currentApp == .teams)
    }

    @Test func convenienceProperties_active() {
        let state = MeetingSessionState.active(app: .zoom)
        #expect(!state.isIdle)
        #expect(!state.isDetected)
        #expect(state.isActive)
        #expect(!state.isEnding)
        #expect(state.currentApp == .zoom)
    }

    @Test func convenienceProperties_ending() {
        let state = MeetingSessionState.ending(since: t0, app: .webex)
        #expect(!state.isIdle)
        #expect(!state.isDetected)
        #expect(!state.isActive)
        #expect(state.isEnding)
        #expect(state.currentApp == .webex)
    }

    // MARK: - Constants

    @Test func debounceInterval_is1Second() {
        #expect(MeetingSessionState.debounceInterval == 1)
    }

    @Test func graceInterval_is3Seconds() {
        #expect(MeetingSessionState.graceInterval == 3)
    }

    @Test func customThreshold_higherThresholdPreventsDetection() {
        let state = MeetingSessionState.idle
        let next = state.next(score: 3, app: .teams, now: t0, threshold: 4)
        #expect(next.isIdle)
    }

    @Test func customThreshold_lowerThresholdAllowsDetection() {
        let state = MeetingSessionState.idle
        let next = state.next(score: 2, app: .teams, now: t0, threshold: 2)
        #expect(next.isDetected)
        #expect(next.currentApp == .teams)
    }
}
