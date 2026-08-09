import Testing
@testable import Cadenza

@Suite("MeetingDetector", .serialized)
@MainActor
struct MeetingDetectorTests {

    // MARK: - Helpers

    private func makeDetector(
        teamsCallAssertionQuery: any TeamsCallAssertionQuerying = MockTeamsCallAssertionQuery(),
        screenCaptureAccess: @escaping @MainActor () -> Bool = { true }
    ) -> (MeetingDetector, MockAudioProcessQuery, MockAudioStateListener) {
        let query = MockAudioProcessQuery()
        let listener = MockAudioStateListener()
        let detector = MeetingDetector(
            audioQuery: query,
            audioListener: listener,
            teamsCallAssertionQuery: teamsCallAssertionQuery,
            screenCaptureAccessProvider: screenCaptureAccess
        )
        return (detector, query, listener)
    }

    // MARK: - resetNotificationState

    @Test func appPollRefreshesPIDForAnExistingBundleID() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(111))
        ])
        var terminatedCallCount = 0
        detector.onMeetingAppTerminated = { _ in terminatedCallCount += 1 }

        detector._test_reconcileRunningMeetingApps(with: [
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(222))
        ])

        #expect(detector.runningMeetingApps.count == 1)
        #expect(detector.runningMeetingApps.first?.pid == pid_t(222))
        #expect(terminatedCallCount == 0)
    }

    @Test func resetNotificationState_fromIdle_isNoop() {
        let (detector, _, _) = makeDetector()
        #expect(detector.sessionState.isIdle)

        detector.resetNotificationState()
        #expect(detector.sessionState.isIdle)
    }

    @Test func resetNotificationState_fromActive_resetsToIdle() {
        let (detector, _, _) = makeDetector()
        detector._test_setSessionState(.active(app: .zoom))
        #expect(detector.sessionState.isActive)

        detector.resetNotificationState()
        #expect(detector.sessionState.isIdle)
    }

    @Test func resetNotificationState_fromEnding_resetsToIdle() {
        let (detector, _, _) = makeDetector()
        detector._test_setSessionState(.ending(since: Date(), app: .teams))
        #expect(detector.sessionState.isEnding)

        detector.resetNotificationState()
        #expect(detector.sessionState.isIdle)
    }

    @Test func resetNotificationState_fromActive_doesNotFireMicDeactivated() {
        let (detector, _, _) = makeDetector()
        detector._test_setSessionState(.active(app: .zoom))

        var micDeactivatedCalled = false
        detector.onMicrophoneDeactivated = { micDeactivatedCalled = true }

        detector.resetNotificationState()

        // resetNotificationState is an external reset, NOT a state machine transition.
        // It should NOT fire onMicrophoneDeactivated (that's for normal ending→idle).
        #expect(!micDeactivatedCalled)
    }

    @Test func resetNotificationState_fromEnding_doesNotFireMicDeactivated() {
        let (detector, _, _) = makeDetector()
        detector._test_setSessionState(.ending(since: Date(), app: .teams))

        var micDeactivatedCalled = false
        detector.onMicrophoneDeactivated = { micDeactivatedCalled = true }

        detector.resetNotificationState()
        #expect(!micDeactivatedCalled)
    }

    // MARK: - resetDetectionState

    @Test func resetDetectionState_resetsToIdle() {
        let (detector, _, _) = makeDetector()
        detector._test_setSessionState(.active(app: .zoom))

        detector.resetDetectionState()
        #expect(detector.sessionState.isIdle)
    }

    // MARK: - Teams Screen Sharing

    @Test func teamsActive_assertionRelease_forcesEndingDespiteStickySignalsAndMinHold() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, audioQuery, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        audioQuery.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        audioQuery.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector._test_setActiveSince(Date().addingTimeInterval(-5))

        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Call with Teammate | Microsoft Teams",
                    width: 1689,
                    height: 1056,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)
        #expect(detector.sessionState.isActive)
        #expect(assertionQuery.requestedProcessIDs == [pid_t(4242)])

        var endingEvents: [MeetingEndingEvent] = []
        detector.onMeetingEnding = { endingEvents.append($0) }
        var endedCallCount = 0
        detector.onMicrophoneDeactivated = { endedCallCount += 1 }
        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isEnding)
        #expect(endingEvents.count == 1)
        #expect(endingEvents.first?.reason == .teamsCallAssertionReleased)

        detector._test_setSessionState(.ending(
            since: Date().addingTimeInterval(-MeetingSessionState.graceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isIdle)
        #expect(endedCallCount == 1)
    }

    /// Full regression for the 2026-07-16 incident. Cadenza's own microphone
    /// capture and an in-progress calendar event must not let an idle Teams
    /// Calendar tab mask Teams' authoritative call-assertion release.
    @Test func teamsActive_assertionReleaseWithCalendarTabStopsAtAuthoritativeDeadline() async throws {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, audioQuery, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        audioQuery.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        audioQuery.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector._test_setActiveSince(Date().addingTimeInterval(-5))
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "shift-left-standup",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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
        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Calendar | Shift Left Standup (Europe/North America) | NIQ | person@example.com | Microsoft Teams",
                    width: 1707,
                    height: 1005,
                    isOnScreen: true
                )
            )
        ]

        let teamsApp = MeetingDetector.DetectedMeetingApp(
            id: "com.microsoft.teams2",
            app: .teams,
            name: "Microsoft Teams",
            pid: pid_t(4242)
        )
        detector._test_setWorkspaceMeetingApps([teamsApp])
        detector._test_setWindowSnapshot(windows)

        let engine = RecordingEngine()
        UserDefaults.standard.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            UserDefaults.standard.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("com.microsoft.teams2")
        engine._test_setCurrentRecordingIsAutoStarted(true)
        engine.confirmMeetingEndedBeforeAuthoritativeStop = {
            detector.confirmAuthoritativeTeamsCallEnded()
        }

        var endingEvents: [MeetingEndingEvent] = []
        detector.onMeetingEnding = { event in
            endingEvents.append(event)
            // Backdate only the engine deadline so the test exercises the
            // deadline race synchronously instead of sleeping eight seconds.
            engine.handleMeetingEnding(.init(
                detectedAt: Date().addingTimeInterval(-9),
                reason: event.reason
            ))
        }
        var recoveredCallCount = 0
        detector.onMeetingRecovered = { reason in
            recoveredCallCount += 1
            engine.handleMeetingRecovered(reason)
        }
        var endedCallCount = 0
        detector.onMicrophoneDeactivated = {
            endedCallCount += 1
            engine.handleMicDeactivated()
        }
        var activityCallCount = 0
        detector.onMeetingActivityDetected = { reason in
            activityCallCount += 1
            engine.handleMeetingActivity(
                bundleID: detector.activeBundleID ?? "",
                appName: "Microsoft Teams",
                reason: reason
            )
        }
        detector._test_evaluateConfidence(windows: windows)
        #expect(detector.sessionState.isActive)

        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isEnding)
        #expect(endingEvents.map(\.reason) == [.teamsCallAssertionReleased])

        detector._test_setSessionState(.ending(
            since: Date().addingTimeInterval(-MeetingSessionState.graceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isIdle)
        #expect(recoveredCallCount == 0)
        #expect(endedCallCount == 1)

        // A queued post-grace evaluation can manufacture idle → detected →
        // active from the retained calendar event plus Cadenza's own mic. That
        // same-bundle callback must not cancel the authoritative deadline.
        detector._test_evaluateConfidence(windows: windows)
        #expect(detector.sessionState.isDetected)
        detector._test_setSessionState(.detected(
            since: Date().addingTimeInterval(-MeetingSessionState.debounceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isActive)
        #expect(activityCallCount == 1)
        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)

        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordingState == .idle)
        #expect(detector.sessionState.isIdle)
        #expect(endedCallCount == 2)
    }

    @Test func teamsReleaseUnavailableGraceRecoveryRetriesThenStops() async throws {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        let teamsApp = MeetingDetector.DetectedMeetingApp(
            id: "com.microsoft.teams2",
            app: .teams,
            name: "Microsoft Teams",
            pid: pid_t(4242)
        )
        detector._test_setRunningMeetingApps([teamsApp])
        detector._test_setWorkspaceMeetingApps([teamsApp])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "calendar-recovery",
            title: "Shift Left Standup",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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

        let engine = RecordingEngine()
        UserDefaults.standard.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            UserDefaults.standard.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("com.microsoft.teams2")
        engine._test_setCurrentRecordingIsAutoStarted(true)
        engine.confirmMeetingEndedBeforeAuthoritativeStop = {
            detector.confirmAuthoritativeTeamsCallEnded()
        }
        detector.onMeetingEnding = { event in
            engine.handleMeetingEnding(.init(
                detectedAt: Date().addingTimeInterval(-9),
                reason: event.reason
            ))
        }
        detector.onMeetingRecovered = { engine.handleMeetingRecovered($0) }
        detector.onMicrophoneDeactivated = { engine.handleMicDeactivated() }

        detector._test_evaluateConfidence(windows: [])
        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isEnding)
        #expect(engine._test_hasPendingAutoStop)

        // A transient query outage removes the assertion override for this
        // evaluator tick, so calendar + Cadenza's own mic appears to recover.
        assertionQuery.defaultState = .unavailable
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isActive)
        #expect(engine._test_hasPendingAutoStop)

        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.recordingState == .recording)
        #expect(engine._test_hasPendingAutoStop)

        assertionQuery.defaultState = .inactive
        try await Task.sleep(for: .milliseconds(1_100))

        #expect(engine.recordingState == .idle)
        #expect(detector.sessionState.isIdle)
        #expect(!engine._test_hasPendingAutoStop)
    }

    @Test func teamsRapidRedialAtDeadlineRearmsThenSecondReleaseStops() async throws {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.statesByProcessID = [pid_t(111): .active]
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        let originalTeamsApp = MeetingDetector.DetectedMeetingApp(
            id: "com.microsoft.teams2",
            app: .teams,
            name: "Microsoft Teams",
            pid: pid_t(111)
        )
        detector._test_setRunningMeetingApps([originalTeamsApp])
        detector._test_setWorkspaceMeetingApps([originalTeamsApp])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))

        let engine = RecordingEngine()
        UserDefaults.standard.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            UserDefaults.standard.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)
        engine._test_setTriggeringMeetingBundleID("com.microsoft.teams2")
        engine._test_setCurrentRecordingIsAutoStarted(true)
        engine.confirmMeetingEndedBeforeAuthoritativeStop = {
            detector.confirmAuthoritativeTeamsCallEnded()
        }
        detector.onMeetingEnding = { event in
            engine.handleMeetingEnding(.init(
                detectedAt: Date().addingTimeInterval(-9),
                reason: event.reason
            ))
        }
        detector.onMeetingRecovered = { engine.handleMeetingRecovered($0) }
        detector.onMicrophoneDeactivated = { engine.handleMicDeactivated() }
        detector.onMeetingActivityDetected = { reason in
            engine.handleMeetingActivity(
                bundleID: detector.activeBundleID ?? "",
                appName: "Microsoft Teams",
                reason: reason
            )
        }

        detector._test_evaluateConfidence(windows: [])
        assertionQuery.statesByProcessID = [pid_t(111): .inactive]
        detector._test_evaluateConfidence(windows: [])
        detector._test_setSessionState(.ending(
            since: Date().addingTimeInterval(-MeetingSessionState.graceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isIdle)
        #expect(engine._test_hasPendingAutoStop)

        let replacementTeamsApp = MeetingDetector.DetectedMeetingApp(
            id: "com.microsoft.teams2",
            app: .teams,
            name: "Microsoft Teams",
            pid: pid_t(222)
        )
        detector._test_setWorkspaceMeetingApps([replacementTeamsApp])
        assertionQuery.statesByProcessID = [pid_t(222): .active]
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordingState == .recording)
        #expect(detector.sessionState.isActive)
        #expect(!engine._test_hasPendingAutoStop)
        #expect(assertionQuery.requestedProcessIDs.last == pid_t(222))

        assertionQuery.statesByProcessID = [pid_t(222): .inactive]
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isEnding)
        #expect(engine._test_hasPendingAutoStop)

        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.recordingState == .idle)
        #expect(detector.sessionState.isIdle)
    }

    @Test func teamsAssertion_doesNotStartSessionFromIdle() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(false)

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isIdle)
        #expect(assertionQuery.requestedProcessIDs == [pid_t(4242)])
    }

    @Test func teamsAssertionReleaseDuringDebounce_rejectsStaleCandidate() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)
        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Call with Teammate | Microsoft Teams",
                    width: 1600,
                    height: 900,
                    isOnScreen: true
                )
            )
        ]

        var activityCallCount = 0
        detector.onMeetingActivityDetected = { _ in activityCallCount += 1 }
        detector._test_evaluateConfidence(windows: windows)
        #expect(detector.sessionState.isDetected)

        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isIdle)
        #expect(activityCallCount == 0)
    }

    @Test func authoritativeEndConfirmationRearmsReplacementTeamsCallAfterGrace() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.statesByProcessID = [pid_t(111): .active]
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(111))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_evaluateConfidence(windows: [])

        assertionQuery.statesByProcessID = [pid_t(111): .inactive]
        detector._test_setSessionState(.ending(
            since: Date().addingTimeInterval(-MeetingSessionState.graceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isIdle)

        assertionQuery.statesByProcessID = [pid_t(222): .active]
        detector._test_setWorkspaceMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(222))
        ])

        let confirmation = detector.confirmAuthoritativeTeamsCallEnded()

        #expect(detector.runningMeetingApps.first?.pid == pid_t(222))
        #expect(confirmation == .ongoing)
        #expect(detector.sessionState.isActive)
        #expect(assertionQuery.requestedProcessIDs.last == pid_t(222))

        var endingEvents: [MeetingEndingEvent] = []
        detector.onMeetingEnding = { endingEvents.append($0) }
        assertionQuery.statesByProcessID = [pid_t(222): .inactive]
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingEvents.map(\.reason) == [.teamsCallAssertionReleased])
    }

    @Test func authoritativeEndConfirmationInactive_returnsTrue() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .inactive
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        let teamsApp = MeetingDetector.DetectedMeetingApp(
            id: "com.microsoft.teams2",
            app: .teams,
            name: "Microsoft Teams",
            pid: pid_t(4242)
        )
        detector._test_setRunningMeetingApps([teamsApp])
        detector._test_setWorkspaceMeetingApps([teamsApp])

        #expect(detector.confirmAuthoritativeTeamsCallEnded() == .ended)
    }

    @Test func authoritativeEndConfirmationUnavailable_failsOpen() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .unavailable
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        let teamsApp = MeetingDetector.DetectedMeetingApp(
            id: "com.microsoft.teams2",
            app: .teams,
            name: "Microsoft Teams",
            pid: pid_t(4242)
        )
        detector._test_setRunningMeetingApps([teamsApp])
        detector._test_setWorkspaceMeetingApps([teamsApp])

        #expect(detector.confirmAuthoritativeTeamsCallEnded() == .unavailable)
    }

    @Test func authoritativeEndConfirmationTeamsExited_returnsTrue() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .unavailable
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setWorkspaceMeetingApps([])

        #expect(detector.confirmAuthoritativeTeamsCallEnded() == .ended)
    }

    @Test func teamsAssertion_doesNotTakeOverActiveZoomSession() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, audioQuery, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        audioQuery.activeInputBundleIDs = ["us.zoom.xos"]
        detector._test_setRunningMeetingApps([
            .init(id: "us.zoom.xos", app: .zoom, name: "Zoom", pid: pid_t(1001)),
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        // Teams became frontmost after the Zoom session had already started.
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .zoom))
        detector._test_setSystemMicActivity(true)

        var endingCallCount = 0
        detector.onMeetingEnding = { _ in endingCallCount += 1 }
        detector._test_evaluateConfidence(windows: [])
        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.currentApp == .zoom)
        #expect(detector.activeMeetingApp == .teams)
        #expect(detector.activeBundleID == "us.zoom.xos")
        #expect(endingCallCount == 0)
    }

    @Test func teamsAssertion_aggregatesAllKnownTeamsProcessIDs() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.statesByProcessID = [
            pid_t(111): .inactive,
            pid_t(222): .active
        ]
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams", app: .teams, name: "Microsoft Teams Classic", pid: pid_t(111)),
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(222))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(assertionQuery.requestedProcessIDs == [pid_t(111), pid_t(222)])
    }

    @Test func teamsAssertion_recoveryCanArmASecondRelease() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))

        detector._test_evaluateConfidence(windows: [])
        var endingCallCount = 0
        var recoveredCallCount = 0
        detector.onMeetingEnding = { _ in endingCallCount += 1 }
        detector.onMeetingRecovered = { _ in recoveredCallCount += 1 }

        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: [])
        assertionQuery.defaultState = .active
        detector._test_evaluateConfidence(windows: [])
        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingCallCount == 2)
        #expect(recoveredCallCount == 1)
    }

    @Test func teamsAssertion_releaseRecoveryReleaseRearmsFreshAuthoritativeDeadline() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, _, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        let engine = RecordingEngine()
        UserDefaults.standard.set(true, forKey: "autoStopOnMicClose")
        defer {
            engine.cancelAutoStop()
            UserDefaults.standard.removeObject(forKey: "autoStopOnMicClose")
        }
        engine._test_setRecordingState(.recording)
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        var endingEvents: [MeetingEndingEvent] = []
        detector.onMeetingEnding = { event in
            endingEvents.append(event)
            engine.handleMeetingEnding(event)
        }
        detector.onMeetingRecovered = { engine.handleMeetingRecovered($0) }

        detector._test_evaluateConfidence(windows: [])
        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: [])
        #expect(engine._test_hasPendingAutoStop)
        let firstDeadline = engine._test_autoStopDeadline

        assertionQuery.defaultState = .active
        detector._test_evaluateConfidence(windows: [])
        #expect(!engine._test_hasPendingAutoStop)

        assertionQuery.defaultState = .inactive
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(engine._test_hasPendingAutoStop)
        #expect(engine._test_hasAutoStopTask)
        #expect(endingEvents.count == 2)
        #expect(engine._test_autoStopDeadline == endingEvents[1].detectedAt.addingTimeInterval(8))
        #expect(engine._test_autoStopDeadline.map { deadline in
            firstDeadline.map { deadline > $0 } ?? false
        } == true)
    }

    @Test func teamsActive_assertionUnavailable_fallsBackToExistingHeuristics() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .active
        let (detector, audioQuery, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        audioQuery.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        detector._test_setActiveSince(Date().addingTimeInterval(-600))

        detector._test_evaluateConfidence(windows: [])
        assertionQuery.defaultState = .unavailable

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsScreenShareWindows_keepActiveWithoutPerProcessMic() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector._test_setTeamsUncorroboratedKeepAliveSince(Date().addingTimeInterval(-301))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Call with Meet Now | Personal | Microsoft Teams",
                    width: 1689,
                    height: 1056,
                    isOnScreen: true
                )
            ),
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Chat | Meet Now | Personal | Microsoft Teams",
                    width: 1728,
                    height: 1000,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsAdHocHelperAudioWithoutWindow_doesNotTrigger() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isIdle)
    }

    /// Continuity audio (Teams modulehost) keeps an already-active meeting
    /// alive when raw signals temporarily drop — e.g. screen sharing hides the
    /// call window. Without this gate, brief window flickers would force ending
    /// and trigger the auto-stop countdown.
    @Test func teamsActive_continuityHelperAudio_keepsActiveWithoutWindows() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsActive_blackoutSystemMicBridge_keepsActiveAfterHelperAudioDrops() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector._test_setTeamsUncorroboratedKeepAliveSince(Date().addingTimeInterval(-301))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    /// During the ending grace period, continuity audio returning forces a
    /// recovery back to active before the grace timer expires.
    @Test func teamsEnding_continuityHelperAudio_recoversToActive() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.ending(since: Date(), app: .teams))
        detector._test_setSystemMicActivity(true)

        var recoveredCalled = false
        detector.onMeetingRecovered = { _ in recoveredCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(recoveredCalled)
    }

    /// Sticky `com.microsoft.teams2.modulehost` audio after a Teams call
    /// ends would otherwise pin the meeting `.active` indefinitely (no
    /// per-process mic signal exists for Teams main process to drop).
    /// The uncorroborated Teams cap bounds this: once Teams has had no window
    /// or calendar evidence for the full blackout cap, the score override is
    /// dropped and the state machine progresses to `.ending`.
    @Test func teamsActive_uncorroboratedKeepAliveExpires_progressesToEnding() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        // No system mic, no calendar match, no windows — only the sticky
        // helper audio is still reporting input.
        detector._test_setSystemMicActivity(false)
        // Pretend Teams has been in blackout for longer than the 600s cap
        // (just past it, so this test fails if the cap regresses back to 30 min).
        detector._test_setTeamsUncorroboratedKeepAliveSince(Date().addingTimeInterval(-601))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingCalled)
    }

    /// Regression: a sticky Teams `modulehost` helper must NOT pin the meeting
    /// `.active` without a cap when the uncorroborated keepalive candidate is
    /// false for a reason OTHER than expiry — here the calendar explicitly names
    /// a different app, so the keepalive timer never even starts. The old
    /// standalone `continuityAudioActive && !expired` score branch floored the
    /// score uncapped in this case, defeating `teamsUncorroboratedKeepAliveCap`.
    /// Flooring now flows only through the single capped keepalive path, so the
    /// state machine progresses to `.ending`.
    @Test func teamsActive_continuityWithoutKeepAliveCandidate_progressesToEnding() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        // Calendar explicitly names a Zoom meeting happening now (Zoom is NOT
        // running), so currentCalendarMeetingDoesNotExplicitlyMatchOtherApp is
        // false → the uncorroborated keepalive candidate is false and its timer
        // never starts (since stays nil, expired stays false).
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "zoom-meeting",
            title: "Some Zoom Sync",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "zoom",
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

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingCalled)
    }

    @Test func teamsActive_calendarRolloverKeepsPinnedSessionMeeting() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)

        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "current-teams-meeting",
            title: "Current Teams Meeting",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(-60),
            meetingURL: nil,
            meetingApp: "teams",
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
        detector._test_setSessionState(.detected(
            since: Date().addingTimeInterval(-MeetingSessionState.debounceInterval - 0.1),
            app: .teams
        ))

        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isActive)

        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "next-zoom-meeting",
            title: "Next Zoom Meeting",
            startDate: Date().addingTimeInterval(-60),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "zoom",
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

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsActive_continuityWithCalendar_doesNotExpireToEnding() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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
        detector._test_setTeamsUncorroboratedKeepAliveSince(Date().addingTimeInterval(-1801))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsIdleChatWithContinuityAudio_doesNotTrigger() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.idle)
        detector._test_setSystemMicActivity(true)

        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Chat | Meet Now | Personal | Microsoft Teams",
                    width: 1728,
                    height: 1000,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isIdle)
    }

    @Test func teamsCalendarTitleWindowWithSystemMic_reachesActive() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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

        var activityCalled = false
        detector.onMeetingActivityDetected = { _ in activityCalled = true }

        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Shift Left Standup (Europe/North America) | Acme | person@example.com | Microsoft Teams",
                    width: 1689,
                    height: 1056,
                    isOnScreen: true
                )
            ),
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Chat | ProdSec Shift Left | Acme | person@example.com | Microsoft Teams",
                    width: 1708,
                    height: 1008,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)
        #expect(detector.sessionState.isDetected)
        #expect(!activityCalled)

        detector._test_setSessionState(.detected(
            since: Date().addingTimeInterval(-MeetingSessionState.debounceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isActive)
        #expect(activityCalled)
    }

    @Test func teamsOverrunPastCalendarEnd_keepsActiveWithCalendarTitleWindow() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(-600),
            meetingURL: nil,
            meetingApp: "teams",
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

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Shift Left Standup (Europe/North America) | Acme | person@example.com | Microsoft Teams",
                    width: 1689,
                    height: 1056,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsCalendarSystemMic_reachesActiveWithoutWindow() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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

        var activityCalled = false
        detector.onMeetingActivityDetected = { _ in activityCalled = true }

        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isDetected)
        #expect(!activityCalled)

        detector._test_setSessionState(.detected(
            since: Date().addingTimeInterval(-MeetingSessionState.debounceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(activityCalled)
    }

    @Test func teamsCalendarSystemMicWithoutScreenCapture_reachesActiveWithoutWindow() {
        let (detector, _, _) = makeDetector(screenCaptureAccess: { false })
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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

        var activityCalled = false
        detector.onMeetingActivityDetected = { _ in activityCalled = true }

        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isDetected)
        #expect(!activityCalled)

        detector._test_setSessionState(.detected(
            since: Date().addingTimeInterval(-MeetingSessionState.debounceInterval - 0.1),
            app: .teams
        ))
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(activityCalled)
    }

    @Test func teamsAdHocRecentActivationAndHelperAudio_reachesActiveWithoutWindow() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setLastActivatedMeetingApp(.teams, at: Date())
        detector._test_setSystemMicActivity(true)
        detector._test_setTeamsAdHocStartCandidateSince(Date().addingTimeInterval(-3))

        var activityCalled = false
        detector.onMeetingActivityDetected = { _ in activityCalled = true }

        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isDetected)
        #expect(!activityCalled)

        detector._test_setSessionState(.detected(
            since: Date().addingTimeInterval(-MeetingSessionState.debounceInterval - 0.1),
            app: .teams
        ))
        detector._test_setTeamsAdHocStartCandidateSince(Date().addingTimeInterval(-3))
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(activityCalled)
    }

    @Test func teamsAdHocHelperAudioWithoutRecentActivation_doesNotTrigger() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setLastActivatedMeetingApp(.teams, at: Date().addingTimeInterval(-180))
        detector._test_setSystemMicActivity(true)
        detector._test_setTeamsAdHocStartCandidateSince(Date().addingTimeInterval(-3))

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isIdle)
    }

    /// After a recording stops, the sticky post-stop state (our own recording's
    /// systemMic + the always-true modulehost helper input + Teams still
    /// frontmost) must NOT immediately re-arm the Teams ad-hoc start fallback.
    /// Suppression clears the first time those ingredients drop, after which a
    /// genuinely new call re-arms normally.
    @Test func teamsAdHocStartSuppressedAfterStop_untilSignalsClear() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.idle)

        // Recording stop arms the suppression bit.
        detector.resetNotificationState()

        detector._test_setSystemMicActivity(true)
        detector._test_setLastActivatedMeetingApp(.teams, at: Date())
        detector._test_setTeamsAdHocStartCandidateSince(Date().addingTimeInterval(-3))

        var activityCalled = false
        detector.onMeetingActivityDetected = { _ in activityCalled = true }

        // Sticky ingredients present, but suppressed → no re-arm.
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isIdle)
        #expect(!activityCalled)

        // Ingredients drop once → suppression clears (still idle this tick).
        detector._test_setSystemMicActivity(false)
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isIdle)

        // A genuinely new call (signals return) re-arms ad-hoc start.
        detector._test_setSystemMicActivity(true)
        detector._test_setLastActivatedMeetingApp(.teams, at: Date())
        detector._test_setTeamsAdHocStartCandidateSince(Date().addingTimeInterval(-3))
        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isDetected)
    }

    @Test func screenCaptureAccessCheck_isCachedAcrossEvaluations() {
        var calls = 0
        let (detector, _, _) = makeDetector(screenCaptureAccess: {
            calls += 1
            return false
        })
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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

        detector._test_evaluateConfidence(windows: [])
        detector._test_evaluateConfidence(windows: [])

        #expect(calls == 1)
    }

    @Test func teamsActive_assertionUnavailable_calendarFallbackKeepsActive() {
        let assertionQuery = MockTeamsCallAssertionQuery()
        assertionQuery.defaultState = .unavailable
        let (detector, query, _) = makeDetector(teamsCallAssertionQuery: assertionQuery)
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector.currentCalendarMeeting = MeetingEventDTO(
            id: "meeting-1",
            title: "Shift Left Standup (Europe/North America)",
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: nil,
            meetingApp: "teams",
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

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }
        query.activeInputBundleIDs = []

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    @Test func teamsMeetingChatAfterLeave_entersEndingEvenWhileCadenzaMicRuns() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Chat | Meet Now | Personal | Microsoft Teams",
                    width: 1728,
                    height: 1000,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isEnding)
        #expect(endingCalled)
    }

    // MARK: - Teams helper OUTPUT sustain (tHelperOut)

    /// During an active Teams call all corroborating signals can momentarily
    /// drop (windows hidden during screen share, our own recording masking
    /// systemMic, no calendar). The helper OUTPUT probe stays true for the whole
    /// call and drops the instant the call ends, so while it is true it floors
    /// the score to the threshold and keeps the session active — not subject to
    /// the 10-min uncorroborated cap because output is real corroboration.
    @Test func teamsActive_helperOutput_keepsActiveWhenAllOtherSignalsDrop() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        // No system mic, no calendar, no windows. Min-active hold elapsed so the
        // hold is not what keeps it alive — only the output probe.
        detector._test_setSystemMicActivity(false)
        detector._test_setActiveSince(Date().addingTimeInterval(-600))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    /// The same sticky-helper blackout that the 10-min input cap bounds must NOT
    /// be capped while OUTPUT is active: output is corroboration that the call is
    /// genuinely ongoing. Even past the old input cap, output keeps it active.
    @Test func teamsActive_helperOutput_ignoresUncorroboratedInputCap() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        query.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        detector._test_setActiveSince(Date().addingTimeInterval(-3600))
        // Way past the 10-min input-only cap.
        detector._test_setTeamsUncorroboratedKeepAliveSince(Date().addingTimeInterval(-1200))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    /// When the call ends the OUTPUT probe drops to false in the same tick. With
    /// no other signal and the min-active hold elapsed, the session must enter
    /// ending normally.
    @Test func teamsActive_helperOutputDrops_entersEnding() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = []
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        // Min-active hold elapsed so it does not mask the ending transition.
        detector._test_setActiveSince(Date().addingTimeInterval(-600))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingCalled)
    }

    /// Sustain-only: helper OUTPUT being active while idle must NEVER start a new
    /// session. Only input/window/calendar/fallback paths can move idle→detected.
    @Test func teamsIdle_helperOutput_doesNotTrigger() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.idle)
        detector._test_setSystemMicActivity(false)

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isIdle)
    }

    /// Fix for the cap-burn bug: while a Teams meeting holds its own score ≥
    /// threshold (here via a structural meeting window), the output keep-alive
    /// candidate must be false so the 4-hour output cap clock never starts. A
    /// pre-armed (even already-expired) since-stamp must be cleared and the
    /// session stay active on raw score alone.
    @Test func teamsActive_helperOutputWithHealthyScore_doesNotArmOutputCap() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = ["com.microsoft.teams2.modulehost"]
        query.activeOutputBundleIDs = ["com.microsoft.teams2.modulehost"]
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)
        detector._test_setActiveSince(Date().addingTimeInterval(-3600))
        // Pretend the output cap was armed long ago and already expired. With a
        // healthy raw score this must be cleared (candidate false) rather than
        // forcing ending.
        detector._test_setTeamsHelperOutputKeepAliveSince(Date().addingTimeInterval(-5 * 60 * 60))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        // A structural meeting window keeps raw score at threshold on its own
        // (systemMic + window fallback = +2, window = +1 → 3).
        let windows = [
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Global Security Town Hall - Quarterly (2026) | Microsoft Teams",
                    width: 1689,
                    height: 1056,
                    isOnScreen: true
                )
            )
        ]

        detector._test_evaluateConfidence(windows: windows)

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    /// Fix for the active-app-termination edge case: if the *active* session's
    /// app terminates within the min-hold window while a DIFFERENT meeting app is
    /// still running, the hold must NOT keep the stale session pinned.
    @Test func active_activeAppTerminatedWithinMinHold_otherAppRunning_doesNotKeepStale() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = []
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        detector._test_setActiveSince(Date().addingTimeInterval(-5))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        // Teams (the active session app) terminates, but Zoom is now running.
        detector._test_setRunningMeetingApps([
            .init(id: "us.zoom.xos", app: .zoom, name: "Zoom", pid: pid_t(5555))
        ])
        detector._test_setActiveMeetingApp(.zoom)
        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingCalled)
    }

    // MARK: - Minimum active hold

    /// After reaching active, a transient signal collapse within the 90s
    /// minimum-active window must NOT push the session to ending. This guards
    /// the 2026-06-09 crash where an instantaneous start signal (teamsAdhocStart,
    /// +1 for one second) flipped the session active, then vanished, killing the
    /// recording ~9 s later.
    @Test func active_signalDropWithinMinHold_doesNotEnd() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = []
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        // Just entered active a few seconds ago.
        detector._test_setActiveSince(Date().addingTimeInterval(-5))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isActive)
        #expect(!endingCalled)
    }

    /// Once the 90s minimum-active window elapses, a signal collapse ends the
    /// session normally.
    @Test func active_signalDropAfterMinHold_entersEnding() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = []
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        detector._test_setActiveSince(Date().addingTimeInterval(-91))

        var endingCalled = false
        detector.onMeetingEnding = { _ in endingCalled = true }

        detector._test_evaluateConfidence(windows: [])

        #expect(detector.sessionState.isEnding)
        #expect(endingCalled)
    }

    /// The minimum-active hold must NOT override meeting-app termination — if the
    /// app quit, the meeting is over regardless of how recently it went active.
    @Test func active_appTerminatedWithinMinHold_doesNotKeepStale() {
        let (detector, query, _) = makeDetector()
        query.activeInputBundleIDs = []
        query.activeOutputBundleIDs = []
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(false)
        detector._test_setActiveSince(Date().addingTimeInterval(-5))

        var terminatedBundleID: String?
        detector.onMeetingAppTerminated = { terminatedBundleID = $0 }

        // App terminates → running apps empties → score 0 path. The min-hold
        // must not pin a stale meeting alive once the app is gone.
        detector._test_setRunningMeetingApps([])
        detector._test_setActiveMeetingApp(nil)
        detector._test_evaluateConfidence(windows: [])

        #expect(!detector.sessionState.isActive)
        _ = terminatedBundleID
    }

    @Test func graceRefreshUsesCurrentWindowsBeforeDeclaringMeetingEnded() {
        let (detector, _, _) = makeDetector()
        detector._test_setRunningMeetingApps([
            .init(id: "com.microsoft.teams2", app: .teams, name: "Microsoft Teams", pid: pid_t(4242))
        ])
        detector._test_setActiveMeetingApp(.teams)
        detector._test_setSessionState(.active(app: .teams))
        detector._test_setSystemMicActivity(true)

        var recoveredCalled = false
        var activityCalled = false
        var micDeactivatedCalled = false
        detector.onMeetingActivityDetected = { _ in activityCalled = true }
        detector.onMeetingRecovered = { _ in recoveredCalled = true }
        detector.onMicrophoneDeactivated = { micDeactivatedCalled = true }

        detector._test_evaluateConfidence(windows: [])
        #expect(detector.sessionState.isEnding)

        detector._test_setWindowSnapshot([
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Call with Meet Now | Personal | Microsoft Teams",
                    width: 1689,
                    height: 1056,
                    isOnScreen: true
                )
            ),
            CGWindowEnumerator.EnumeratedWindow(
                pid: pid_t(4242),
                snapshot: .init(
                    title: "Chat | Meet Now | Personal | Microsoft Teams",
                    width: 1728,
                    height: 1000,
                    isOnScreen: true
                )
            )
        ])

        detector._test_evaluateWithFreshWindowSnapshot()

        #expect(detector.sessionState.isActive)
        #expect(recoveredCalled)
        #expect(!activityCalled)
        #expect(!micDeactivatedCalled)
    }
}
