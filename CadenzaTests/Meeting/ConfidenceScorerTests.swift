import Testing
@testable import Cadenza

@Suite("ConfidenceScorer")
struct ConfidenceScorerTests {

    // MARK: - Threshold Constant

    @Test func threshold_is_3() {
        #expect(ConfidenceScorer.threshold == 3)
    }

    // MARK: - No Meeting App Running → Always 0

    @Test func noMeetingApp_alwaysZero() {
        let signals = MeetingSignals(
            meetingAppRunning: false,
            meetingApp: nil,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: true,
            hasMeetingWindow: true
        )
        #expect(ConfidenceScorer.score(signals) == 0)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    // MARK: - Individual Signal Scores

    @Test func micInputOnly_scores3_triggers() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 3)
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func calendarOnly_scores2_doesNotTrigger() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: false,
            calendarMatch: true,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 2)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func windowOnly_scores1_doesNotTrigger() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: false,
            systemMicActive: false,
            calendarMatch: false,
            hasMeetingWindow: true
        )
        #expect(ConfidenceScorer.score(signals) == 1)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    // MARK: - Key Scenarios (from design doc)

    @Test func teamsIdlePlusSiri_doesNotTrigger() {
        // Teams hanging in background, user uses Siri (system mic active but no call window)
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: true,  // Siri using mic
            calendarMatch: false,
            hasMeetingWindow: false  // No call window → composite doesn't fire
        )
        #expect(ConfidenceScorer.score(signals) == 0)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func teamsInMeetingWithCalendar_triggers() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: true,
            hasMeetingWindow: true
        )
        let score = ConfidenceScorer.score(signals)
        #expect(score == 6) // 3 + 2 + 1
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func listenOnlyMeeting_calendarPlusWindow_triggers() {
        // User joined meeting but didn't turn on mic
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: false,
            systemMicActive: false,
            calendarMatch: true,
            hasMeetingWindow: true
        )
        let score = ConfidenceScorer.score(signals)
        #expect(score == 3) // 2 + 1
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func adHocCallNoCalendar_micOnly_triggers() {
        // Spontaneous call via Zoom (per-process audio works), no calendar event
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 3)
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func bluetoothSCO_teamsIdle_doesNotTrigger() {
        // AirPods connected (SCO profile), Teams idle in background
        // System mic might show as running but Teams has no call window
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: true,  // BT SCO keeps mic "running"
            calendarMatch: false,
            hasMeetingWindow: false  // No call window → composite doesn't fire
        )
        #expect(ConfidenceScorer.score(signals) == 0)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func calendarEventButNotJoined_doesNotAutoTrigger() {
        // Calendar says meeting now, Teams is running but user hasn't joined
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: false,
            calendarMatch: true,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 2)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    // MARK: - Composite Signal: System Mic + Call Window (Teams fallback)

    @Test func teamsAdHocCall_systemMicPlusWindow_triggers() {
        // Teams ad-hoc call: per-process audio fails (modulehost always-on),
        // but system mic active + call window visible → composite fires
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,  // Teams per-process always fails
            systemMicActive: true,        // System-wide mic active (Teams using it via modulehost)
            calendarMatch: false,         // No calendar event
            hasMeetingWindow: true        // Call window visible
        )
        let score = ConfidenceScorer.score(signals)
        #expect(score == 3) // composite(2) + window(1)
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func teamsAdHocCall_systemMicPlusWindowPlusCalendar_scores5() {
        // Teams call with calendar event: composite + calendar + window
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: true,
            calendarMatch: true,
            hasMeetingWindow: true
        )
        let score = ConfidenceScorer.score(signals)
        #expect(score == 5) // composite(2) + calendar(2) + window(1)
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func systemMicOnly_noWindow_doesNotTrigger() {
        // System mic active but no call window → composite doesn't fire
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 0)
        #expect(!ConfidenceScorer.shouldTrigger(signals))
    }

    @Test func compositeIgnored_whenPerProcessWorks() {
        // Per-process audio works (Zoom) — composite is irrelevant,
        // per-process mic score (+3) is used instead of composite (+2)
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: true
        )
        let score = ConfidenceScorer.score(signals)
        #expect(score == 4) // micInput(3) + window(1), NOT composite(2) + window(1)
    }

    @Test func compositeFiresOnly_whenPerProcessFails() {
        // Per-process audio fails, system mic active + window → composite fires
        let withPerProcess = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: true
        )
        let withoutPerProcess = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .teams,
            processUsingMicInput: false,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: true
        )
        #expect(ConfidenceScorer.score(withPerProcess) == 4)    // micInput(3) + window(1)
        #expect(ConfidenceScorer.score(withoutPerProcess) == 3) // composite(2) + window(1)
    }

    // MARK: - Signal Combinations

    @Test func micPlusCalendar_scores5() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: true,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 5)
    }

    @Test func micPlusWindow_scores4() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: false,
            hasMeetingWindow: true
        )
        #expect(ConfidenceScorer.score(signals) == 4)
    }

    @Test func allSignals_scores6() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .zoom,
            processUsingMicInput: true,
            systemMicActive: true,
            calendarMatch: true,
            hasMeetingWindow: true
        )
        #expect(ConfidenceScorer.score(signals) == 6)
    }

    @Test func noSignals_appRunning_scores0() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .slack,
            processUsingMicInput: false,
            systemMicActive: false,
            calendarMatch: false,
            hasMeetingWindow: false
        )
        #expect(ConfidenceScorer.score(signals) == 0)
    }

    @Test func calendarPlusWindow_meetsThreshold() {
        let signals = MeetingSignals(
            meetingAppRunning: true,
            meetingApp: .webex,
            processUsingMicInput: false,
            systemMicActive: false,
            calendarMatch: true,
            hasMeetingWindow: true
        )
        #expect(ConfidenceScorer.score(signals) == 3)
        #expect(ConfidenceScorer.shouldTrigger(signals))
    }
}
