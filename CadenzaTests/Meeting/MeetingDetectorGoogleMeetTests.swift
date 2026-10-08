import Foundation
import Testing
@testable import Cadenza

@Suite("MeetingDetector Google Meet", .serialized)
@MainActor
struct MeetingDetectorGoogleMeetTests {

    private let chrome = BrowserMeetingFamily.family(forBundleID: "com.google.Chrome")!
    private let safari = BrowserMeetingFamily.family(forBundleID: "com.apple.Safari")!
    private let chromePID = pid_t(5001)
    private let safariPID = pid_t(5002)
    private let chromeHelper = "com.google.Chrome.helper"

    // MARK: - Helpers

    private func makeDetector(
        browsers: [MeetingDetector.RunningBrowser]? = nil
    ) -> (MeetingDetector, MockAudioProcessQuery) {
        let query = MockAudioProcessQuery()
        let detector = MeetingDetector(
            audioQuery: query,
            audioListener: MockAudioStateListener(),
            teamsCallAssertionQuery: MockTeamsCallAssertionQuery(),
            screenCaptureAccessProvider: { true }
        )
        detector._test_setWorkspaceMeetingApps([])
        detector._test_setWorkspaceBrowsers(browsers ?? [.init(family: chrome, pid: chromePID)])
        return (detector, query)
    }

    private func window(pid: pid_t, title: String, width: CGFloat = 1706, height: CGFloat = 1321)
        -> CGWindowEnumerator.EnumeratedWindow {
        CGWindowEnumerator.EnumeratedWindow(
            pid: pid,
            snapshot: .init(title: title, width: width, height: height, isOnScreen: true)
        )
    }

    private func meetEvent(meetingApp: String? = "googleMeet") -> MeetingEventDTO {
        MeetingEventDTO(
            id: "design-review",
            title: "Design review",
            startDate: Date().addingTimeInterval(-120),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: "https://meet.google.com/abc-defg-hij",
            meetingApp: meetingApp,
            calendarName: "Work",
            notes: nil,
            source: "apple",
            calendarID: "work",
            defaultColorHex: "",
            organizer: nil,
            attendees: [],
            isRecurring: false,
            location: nil
        )
    }

    /// Puts the detector in an active Chrome Meet session whose microphone was
    /// observed open, as it would be after a real start.
    private func activateChromeMeet(
        _ detector: MeetingDetector,
        _ query: MockAudioProcessQuery,
        activeFor duration: TimeInterval
    ) {
        query.activeInputBundleIDs = [chromeHelper]
        detector._test_setBrowserMeetingSession(chrome)
        detector._test_setSessionState(.active(app: .googleMeet))
        detector._test_setActiveSince(Date().addingTimeInterval(-duration))
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isActive)
    }

    // MARK: - Start

    @Test func chromeMicrophoneAndMeetTitleStartGoogleMeet() {
        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        detector._test_setWindowSnapshot([window(pid: chromePID, title: "Meet - abc-defg-hij")])
        var activityCount = 0
        detector.onMeetingActivityDetected = { _ in activityCount += 1 }

        // The fresh-snapshot path also covers the window gate: no native
        // meeting app is running, so windows are read only for the browser.
        detector._test_evaluateWithFreshWindowSnapshot()
        #expect(detector.sessionState.isDetected)
        #expect(detector.sessionState.currentApp == .googleMeet)

        detector._test_setSessionState(.detected(since: Date().addingTimeInterval(-2), app: .googleMeet))
        detector._test_evaluateWithFreshWindowSnapshot()

        #expect(detector.sessionState.isActive)
        #expect(activityCount == 1)
        #expect(detector.activeBundleID == "com.google.Chrome")
        #expect(detector.perProcessMicEverDetectedInSession)
    }

    @Test func meetCandidateDroppedDuringDebounceDoesNotLeakMicLatch() {
        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        let meetWindow = [window(pid: chromePID, title: "Meet - abc-defg-hij")]
        detector._test_evaluateConfidence(windows: meetWindow)
        detector._test_evaluateConfidence(windows: meetWindow)
        #expect(detector.sessionState.isDetected)
        #expect(detector.perProcessMicEverDetectedInSession)

        query.activeInputBundleIDs = []
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isIdle)
        #expect(!detector.perProcessMicEverDetectedInSession)
    }

    @Test(arguments: ["Meet", "Google Meet", "Weekly notes"])
    func chromeMicrophoneWithoutMeetEvidenceStaysIdle(_ title: String) {
        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        detector._test_setWindowSnapshot([window(pid: chromePID, title: title)])

        detector._test_evaluateWithFreshWindowSnapshot()

        #expect(detector.sessionState.isIdle)
    }

    @Test func meetTitleWithoutMicrophoneStaysIdle() {
        let (detector, _) = makeDetector()
        detector.currentCalendarMeeting = meetEvent()

        detector._test_evaluateConfidence(windows: [window(pid: chromePID, title: "Meet - abc-defg-hij")])

        #expect(detector.sessionState.isIdle)
    }

    @Test(arguments: ["googleMeet", nil] as [String?])
    func meetEventStartsWithoutWindowTitle(_ meetingApp: String?) {
        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        detector.currentCalendarMeeting = meetEvent(meetingApp: meetingApp)

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.currentApp == .googleMeet)
        #expect(detector.activeBundleID == "com.google.Chrome")
    }

    @Test func safariNeedsMeetWindowEvenDuringMeetEvent() {
        let (detector, query) = makeDetector(browsers: [.init(family: safari, pid: safariPID)])
        query.activeInputBundleIDs = ["com.apple.WebKit.GPU"]
        detector.currentCalendarMeeting = meetEvent()

        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isIdle)

        detector._test_evaluateConfidence(windows: [window(pid: safariPID, title: "Meet - abc-defg-hij")])
        #expect(detector.sessionState.currentApp == .googleMeet)
        #expect(detector.activeBundleID == "com.apple.Safari")
    }

    @Test func helperInputFromBrowserThatIsNotRunningIsIgnored() {
        let (detector, query) = makeDetector(browsers: [])
        query.activeInputBundleIDs = [chromeHelper]
        detector.currentCalendarMeeting = meetEvent()

        detector._test_evaluateConfidence(windows: [window(pid: chromePID, title: "Meet - abc-defg-hij")])

        #expect(detector.sessionState.isIdle)
    }

    // MARK: - Start rechecks

    /// Measured 2026-10-02: when `/new` joined the call directly, the tab
    /// stayed titled `Meet` for about 40 s after the microphone opened.
    @Test func meetTitleArrivingAfterTenSecondsStartsMeet() {
        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        detector._test_setWindowSnapshot([window(pid: chromePID, title: "Meet")])
        detector._test_evaluateWithFreshWindowSnapshot()

        // Seven 2 s rechecks without a title; the old limit stopped after five.
        for recheck in 1...7 {
            #expect(detector._test_hasPendingBrowserStartRecheck)
            detector._test_setBrowserStartRecheckWaitingSince(Date().addingTimeInterval(-2 * Double(recheck)))
            detector._test_runPendingBrowserStartRecheck()
            #expect(detector.sessionState.isIdle)
        }
        #expect(detector._test_hasPendingBrowserStartRecheck)

        detector._test_setWindowSnapshot([window(pid: chromePID, title: "Meet - abc-defg-hij")])
        detector._test_runPendingBrowserStartRecheck()

        #expect(detector.sessionState.isDetected)
        #expect(detector.sessionState.currentApp == .googleMeet)
        #expect(!detector._test_hasPendingBrowserStartRecheck)
    }

    @Test func startRechecksSlowDownButContinueWhileMicrophoneIsHeld() {
        #expect(MeetingDetector.browserStartRecheckDelay(afterWaiting: 0) == 2)
        #expect(MeetingDetector.browserStartRecheckDelay(afterWaiting: 119) == 2)
        #expect(MeetingDetector.browserStartRecheckDelay(afterWaiting: 120) == 5)

        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        detector._test_setWindowSnapshot([window(pid: chromePID, title: "Weekly notes")])
        detector._test_evaluateWithFreshWindowSnapshot()
        detector._test_setBrowserStartRecheckWaitingSince(Date().addingTimeInterval(-3600))
        detector._test_runPendingBrowserStartRecheck()

        #expect(detector.sessionState.isIdle)
        #expect(detector._test_hasPendingBrowserStartRecheck)
    }

    @Test func microphoneReleaseStopsStartRechecks() {
        let (detector, query) = makeDetector()
        query.activeInputBundleIDs = [chromeHelper]
        detector._test_setWindowSnapshot([window(pid: chromePID, title: "Meet")])
        detector._test_evaluateWithFreshWindowSnapshot()
        #expect(detector._test_hasPendingBrowserStartRecheck)

        query.activeInputBundleIDs = []
        detector._test_evaluateWithFreshWindowSnapshot()

        #expect(!detector._test_hasPendingBrowserStartRecheck)
    }

    @Test func userStopHoldPausesStartRechecks() {
        let (detector, query) = makeDetector()
        activateChromeMeet(detector, query, activeFor: 300)
        detector.holdAutoStartAfterUserStop()
        detector.resetNotificationState()

        // The user moved to another tab, so no window shows Meet.
        detector._test_setWindowSnapshot([window(pid: chromePID, title: "Weekly notes")])
        detector._test_evaluateWithFreshWindowSnapshot()

        #expect(detector.sessionState.isIdle)
        #expect(!detector._test_hasPendingBrowserStartRecheck)
    }

    // MARK: - Native apps

    @Test func backgroundNativeAppsDoNotClaimMeetCall() {
        let (detector, query) = makeDetector()
        let zoomPID = pid_t(7001)
        let teamsPID = pid_t(7002)
        detector._test_setRunningMeetingApps([
            .init(id: "us.zoom.xos", app: .zoom, name: "Zoom", pid: zoomPID),
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: teamsPID),
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setLastActivatedMeetingApp(.teams, at: Date())
        detector._test_setSystemMicActivity(true)
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        let nativeWindows = [window(pid: zoomPID, title: "Zoom Meeting", width: 1200, height: 800)]

        // Without the browser, these heuristics alone claim a call.
        detector._test_evaluateConfidence(windows: nativeWindows)
        #expect(!detector.sessionState.isIdle)
        detector.resetDetectionState()

        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost", chromeHelper]
        detector._test_evaluateConfidence(
            windows: nativeWindows + [window(pid: chromePID, title: "Meet - abc-defg-hij")]
        )

        #expect(detector.sessionState.currentApp == .googleMeet)
        #expect(detector.activeBundleID == "com.google.Chrome")
    }

    @Test func nativeHeuristicsWaitWhileMeetTitleLagsMicrophone() {
        let (detector, query) = makeDetector()
        let zoomPID = pid_t(7001)
        detector._test_setRunningMeetingApps([.init(id: "us.zoom.xos", app: .zoom, name: "Zoom", pid: zoomPID)])
        detector._test_setActiveMeetingApp(.zoom)
        detector._test_setSystemMicActivity(true)
        query.activeInputBundleIDs = [chromeHelper]
        let zoomWindow = window(pid: zoomPID, title: "Zoom Meeting", width: 1200, height: 800)

        // Meet opens the microphone before it titles the tab.
        detector._test_evaluateConfidence(windows: [zoomWindow, window(pid: chromePID, title: "Meet")])
        #expect(detector.sessionState.isIdle)

        detector._test_evaluateConfidence(windows: [zoomWindow, window(pid: chromePID, title: "Meet - abc-defg-hij")])
        #expect(detector.sessionState.currentApp == .googleMeet)
    }

    @Test func nativeAppUsingItsOwnMicrophoneOutranksBrowser() {
        let (detector, query) = makeDetector()
        detector._test_setRunningMeetingApps([.init(id: "us.zoom.xos", app: .zoom, name: "Zoom", pid: pid_t(7001))])
        detector._test_setActiveMeetingApp(.zoom)
        query.activeInputBundleIDs = ["us.zoom.xos", chromeHelper]

        detector._test_evaluateConfidence(windows: [window(pid: chromePID, title: "Meet - abc-defg-hij")])

        #expect(detector.sessionState.currentApp == .zoom)
    }

    // MARK: - Sustain and end

    @Test func meetSurvivesTabSwitchWhileMicrophoneStaysOpen() {
        let (detector, query) = makeDetector()
        activateChromeMeet(detector, query, activeFor: 300)

        detector._test_evaluateConfidence(windows: [window(pid: chromePID, title: "Weekly notes")])

        #expect(detector.sessionState.isActive)
    }

    @Test func microphoneReleaseEndsMeetDespiteMinimumActiveHold() {
        let (detector, query) = makeDetector()
        activateChromeMeet(detector, query, activeFor: 5)
        var endingEvents: [MeetingEndingEvent] = []
        detector.onMeetingEnding = { endingEvents.append($0) }

        query.activeInputBundleIDs = []
        detector._test_evaluateConfidence(windows: [window(pid: chromePID, title: "Meet - abc-defg-hij")])

        #expect(detector.sessionState.isEnding)
        #expect(endingEvents.map(\.reason) == [.processMicReleased])
    }

    @Test func abandonedPreviewKeepsMeetEventForRealJoin() {
        let (detector, query) = makeDetector()
        detector.currentCalendarMeeting = meetEvent()
        endChromeMeet(detector, query, activeFor: 9)

        query.activeInputBundleIDs = [chromeHelper]
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.currentApp == .googleMeet)
    }

    @Test func finishedMeetCallRetiresMeetEvent() {
        let (detector, query) = makeDetector()
        detector.currentCalendarMeeting = meetEvent()
        endChromeMeet(detector, query, activeFor: 600)

        query.activeInputBundleIDs = [chromeHelper]
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isIdle)
    }

    @Test func userStopHoldsMeetUntilBrowserReleasesMicrophone() {
        let (detector, query) = makeDetector()
        activateChromeMeet(detector, query, activeFor: 300)
        let meetWindow = [window(pid: chromePID, title: "Meet - abc-defg-hij")]

        detector.holdAutoStartAfterUserStop()
        detector.resetNotificationState()
        detector._test_evaluateConfidence(windows: meetWindow)
        #expect(detector.sessionState.isIdle)

        query.activeInputBundleIDs = []
        detector._test_evaluateConfidence(windows: meetWindow)
        #expect(detector.sessionState.isIdle)

        query.activeInputBundleIDs = [chromeHelper]
        detector._test_evaluateConfidence(windows: meetWindow)
        #expect(detector.sessionState.currentApp == .googleMeet)
    }

    /// Runs an active Chrome Meet session through mic release and the grace
    /// period to idle.
    private func endChromeMeet(
        _ detector: MeetingDetector,
        _ query: MockAudioProcessQuery,
        activeFor duration: TimeInterval
    ) {
        activateChromeMeet(detector, query, activeFor: duration)
        query.activeInputBundleIDs = []
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isEnding)

        detector._test_setSessionState(.ending(
            since: Date().addingTimeInterval(-(MeetingSessionState.graceInterval + 1)),
            app: .googleMeet
        ))
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isIdle)
    }
}
