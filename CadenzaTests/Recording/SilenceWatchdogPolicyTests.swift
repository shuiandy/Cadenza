import Testing
@testable import Cadenza

@Suite("SilenceWatchdogPolicy")
struct SilenceWatchdogPolicyTests {

    /// All gates open, 15-minute threshold.
    private func openPolicy() -> SilenceWatchdogPolicy {
        SilenceWatchdogPolicy(
            thresholdMinutes: 15,
            autoStopEnabled: true,
            isAutoStartedRecording: true,
            perProcessMicEverActive: false,
            suppressedByUser: false)
    }

    @Test func triggersAtThreshold() {
        #expect(openPolicy().shouldTrigger(silenceDuration: 15 * 60) == true)
        #expect(openPolicy().shouldTrigger(silenceDuration: 15 * 60 + 1) == true)
    }

    @Test func doesNotTriggerBelowThreshold() {
        #expect(openPolicy().shouldTrigger(silenceDuration: 15 * 60 - 1) == false)
    }

    @Test func zeroOrNegativeMinutesDisables() {
        var p = openPolicy()
        p.thresholdMinutes = 0
        #expect(p.shouldTrigger(silenceDuration: 99999) == false)
        p.thresholdMinutes = -5
        #expect(p.shouldTrigger(silenceDuration: 99999) == false)
    }

    @Test func autoStopSettingGates() {
        // Watchdog is a flavor of auto-stop: the user-visible
        // "Auto-stop when mic closes" toggle must gate it too.
        var p = openPolicy()
        p.autoStopEnabled = false
        #expect(p.shouldTrigger(silenceDuration: 99999) == false)
    }

    @Test func manualRecordingsNeverTriggered() {
        var p = openPolicy()
        p.isAutoStartedRecording = false
        #expect(p.shouldTrigger(silenceDuration: 99999) == false)
    }

    @Test func perProcessMicSessionsProtected() {
        // Zoom/FaceTime sessions have a real per-process mic signal —
        // the watchdog stays out of their way.
        var p = openPolicy()
        p.perProcessMicEverActive = true
        #expect(p.shouldTrigger(silenceDuration: 99999) == false)
    }

    @Test func userSuppressionBlocksRetrigger() {
        // "Keep recording" must silence the watchdog for the rest of
        // this recording — otherwise it re-fires every tick.
        var p = openPolicy()
        p.suppressedByUser = true
        #expect(p.shouldTrigger(silenceDuration: 99999) == false)
    }

    @Test func customThresholdRespected() {
        var p = openPolicy()
        p.thresholdMinutes = 1
        #expect(p.shouldTrigger(silenceDuration: 59) == false)
        #expect(p.shouldTrigger(silenceDuration: 60) == true)
    }
}
