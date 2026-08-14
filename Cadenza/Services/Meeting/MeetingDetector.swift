import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import CoreMediaIO
import os

/// Detects running meeting applications and determines meeting state using
/// a multi-signal confidence scoring system.
///
/// Signals (in priority order):
/// 1. **App-owned lifecycle**: Teams' public call assertion and per-process mic release
/// 2. **Per-process audio** (+3): the meeting app itself is using mic input
///    (via Process Audio Object API — not system-wide)
/// 3. **Calendar match** (+2): a calendar event matching the running app is happening now
/// 4. **Window heuristic** (+1): the meeting app has windows consistent with an active call
///
/// A meeting is considered active when the combined confidence score ≥ 3.
@Observable @MainActor
final class MeetingDetector {
    /// Lifecycle / transition logging. macOS 26 drops default-level NSLog from
    /// the unified log, so transition/STARTED/ENDING/ENDED/auto lines that need
    /// to be queryable after the fact (`log show`) go through os.Logger. The
    /// `writeMeetingDiagnostic` file log (/tmp) is unaffected and remains the
    /// primary forensic record.
    @ObservationIgnored private let log = Logger(subsystem: "com.shuiandy.Cadenza", category: "MeetingDetector")

    // Observable state actually consumed by SwiftUI views.
    private(set) var runningMeetingApps: [DetectedMeetingApp] = []
    private(set) var activeMeetingApp: MeetingApp?

    // Internal-only state. Marked @ObservationIgnored so reassigning these
    // (e.g. `cachedScWindows` every poll) does NOT invalidate every view that
    // observes AppState through this detector. Without this, the AI chat pill
    // and other UI elements re-render at the poll cadence even though nothing
    // user-visible changed.
    @ObservationIgnored private var appPollTimer: DispatchSourceTimer?
    @ObservationIgnored private let audioListener: any AudioStateListening
    @ObservationIgnored private let screenCaptureAccessProvider: @MainActor () -> Bool
    @ObservationIgnored private var cachedAppWindows: [CGWindowEnumerator.EnumeratedWindow] = []
    @ObservationIgnored private var cachedScreenCaptureAccess: Bool?
    @ObservationIgnored private var cachedScreenCaptureAccessAt: Date?
    @ObservationIgnored private var eventEvalWorkItem: DispatchWorkItem?
    @ObservationIgnored private var detectedConfirmationWorkItem: DispatchWorkItem?
    @ObservationIgnored private var teamsAdHocStartConfirmationWorkItem: DispatchWorkItem?
    @ObservationIgnored private var workspaceObservers: [Any] = []
    @ObservationIgnored private var isMonitoring = false
    @ObservationIgnored private var graceTimer: DispatchSourceTimer?
    @ObservationIgnored private var currentPollInterval: TimeInterval = 5
    @ObservationIgnored private let scoreThreshold: Int
    @ObservationIgnored private let windowDumpEnabled: Bool
    @ObservationIgnored private let windowDumpInterval: TimeInterval
    @ObservationIgnored private var lastWindowDumpAt: Date?

    /// Tracks whether per-process mic input was ever detected during the current session.
    /// When true and per-process drops, the call has definitively ended (e.g. Zoom released mic).
    /// Prevents composite fallback from masking this definitive signal.
    @ObservationIgnored private var perProcessMicEverDetected = false

    /// Once Teams has exposed its public "Call in progress" power assertion in
    /// a session, releasing that assertion is a definitive hang-up signal. The
    /// latch preserves heuristic fallback for older Teams builds and query
    /// failures without treating an unavailable API as a call ending.
    @ObservationIgnored private var teamsCallAssertionEverDetected = false

    /// Read-only view of the per-session per-process-mic latch, consumed by
    /// RecordingEngine's silence watchdog guard (via AppState closure).
    var perProcessMicEverDetectedInSession: Bool { perProcessMicEverDetected }

    /// First time an active Teams session entered a windowless/calendarless
    /// blackout while still carrying audio evidence. This covers long screen
    /// sharing stretches where Teams hides call windows and sometimes drops the
    /// helper-process audio bit briefly. Bounded so stale Teams helpers do not
    /// keep recording forever after a call actually ends.
    @ObservationIgnored private var teamsUncorroboratedKeepAliveSince: Date?

    /// Maximum time Teams may stay active with only blackout audio evidence
    /// (sticky `modulehost` input, no window / no calendar). This is a blunt
    /// time bound on the worst case where a quick call has truly ended but the
    /// helper keeps reporting `isRunningInput=true`: it caps the dead-air tail
    /// at ~10 min instead of recording until Teams quits. It remains a fallback
    /// for Teams versions or environments where the public call assertion is
    /// unavailable. Kept long enough that a legitimate long screen-share with
    /// hidden windows is not cut short by heuristic-only evidence.
    private static let teamsUncorroboratedKeepAliveCap: TimeInterval = 10 * 60

    /// First time an active/ending Teams session was sustained purely by the
    /// helper OUTPUT probe (`isTeamsHelperOutputActive`). Unlike the input-only
    /// blackout, output is useful corroboration that remote audio is flowing,
    /// but it is not treated as authoritative lifecycle evidence. It is
    /// therefore bounded by a separate hard cap, while Teams' public call
    /// assertion supplies the definitive end signal when available.
    @ObservationIgnored private var teamsHelperOutputKeepAliveSince: Date?

    /// Hard upper bound on sustaining a Teams session by helper OUTPUT alone.
    /// Output is trustworthy corroboration, so this is generous; it exists only
    /// as a safety net against a pathologically stuck `isRunningOutput` bit, not
    /// as the normal call-end mechanism (output dropping ends the call first).
    private static let teamsHelperOutputKeepAliveCap: TimeInterval = 4 * 60 * 60

    /// First time the active session was sustained by system-wide mic occupancy
    /// closing a one-point score gap (see `shouldUseSystemMicKeepAlive`). Covers
    /// the silent-opening case: the user joins a scheduled call and waits muted,
    /// the call window collapses to a non-call shape (win drops to 0), no
    /// app-owned audio evidence ever appears because nobody has spoken, and the
    /// raw score lands exactly one point below the threshold (calendar alone).
    @ObservationIgnored private var systemMicKeepAliveSince: Date?

    /// Hard cap on the system-mic keep-alive. The system-wide mic signal cannot
    /// be attributed to the meeting app — Cadenza's own capture keeps it true
    /// for the entire recording — so on its own it could pin a session forever.
    /// The calendar match required by the one-point gap bounds it naturally
    /// (the event ends), but a long event whose call actually ended silently
    /// must not record until the calendar runs out; this caps that tail.
    private static let systemMicKeepAliveCap: TimeInterval = 10 * 60

    /// Wall-clock instant the session most recently entered `.active`. Drives the
    /// minimum-active hold below. nil whenever the session is not active.
    @ObservationIgnored private var activeSince: Date?

    /// Minimum time a freshly-active session is held before a signal collapse can
    /// move it to `.ending`. An instantaneous start signal (e.g. the +1
    /// `teamsAdhocStart` audio-startup confirmation that vanishes after ~1 s)
    /// could otherwise flip the session active, immediately drop, and kill the
    /// recording ~9 s later — short enough to then be silently discarded by the
    /// "shorter than 30 s" rule, so the user never sees it. Within this window we
    /// floor the score to the threshold. Meeting-app TERMINATION still ends the
    /// session immediately (handled via the running-apps guard, not flooring).
    private static let minimumActiveHold: TimeInterval = 90

    /// Screen Recording permission changes rarely, and the preflight itself
    /// shows up in the TCC/systemstatusd path. Cache it to avoid touching TCC
    /// on every meeting poll while still rechecking periodically.
    private static let screenCaptureAccessCacheInterval: TimeInterval = 60
    private static let idlePollInterval: TimeInterval = 10
    private static let activePollInterval: TimeInterval = 5
    private static let recentMeetingAppActivationInterval: TimeInterval = 120
    private static let teamsAdHocStartConfirmationInterval: TimeInterval = 2

#if DEBUG
    @ObservationIgnored private var systemMicActivityOverride: Bool?
    @ObservationIgnored private var windowSnapshotOverride: [CGWindowEnumerator.EnumeratedWindow]?
    @ObservationIgnored private var workspaceMeetingAppsOverride: [DetectedMeetingApp]?
#endif

    // Callbacks set once during setup; never need to drive view invalidations.
    /// Fires when the state machine transitions to `.active` (meeting started).
    @ObservationIgnored var onMeetingActivityDetected: (@MainActor (MeetingActivityReason) -> Void)?

    /// Fires when the state machine transitions from `.ending` to `.idle` (meeting ended).
    /// Repurposed from the old "mic deactivated" signal — CoreEngine uses this for auto-stop.
    @ObservationIgnored var onMicrophoneDeactivated: (@MainActor () -> Void)?

    /// Fires when the state machine transitions from `.active` to `.ending`.
    /// The event distinguishes definitive app-owned release signals from
    /// heuristic drops that still need the detector's recovery grace.
    @ObservationIgnored var onMeetingEnding: (@MainActor (MeetingEndingEvent) -> Void)?

    /// Fires when the state machine recovers from `.ending` to `.active` (signals returned during grace).
    /// Used to cancel the auto-stop countdown.
    @ObservationIgnored var onMeetingRecovered: (@MainActor (MeetingActivityReason) -> Void)?

    /// Fires when a detected meeting app terminates (bundle ID passed).
    @ObservationIgnored var onMeetingAppTerminated: (@MainActor (String) -> Void)?

    // MARK: - Detection State

    /// The confidence-based state machine replacing the old boolean `hasNotifiedCurrentSession`.
    private(set) var sessionState: MeetingSessionState = .idle

    /// The most recently activated (frontmost) meeting app. Updated via
    /// `NSWorkspace.frontmostApplication` during polling.
    @ObservationIgnored private var lastActivatedMeetingApp: MeetingApp?
    @ObservationIgnored private var lastActivatedMeetingAppAt: Date?
    @ObservationIgnored private var teamsAdHocStartCandidateSince: Date?

    /// Set when a recording stops (`resetNotificationState`). While true, the
    /// Teams ad-hoc start fallback is suppressed so the post-stop sticky state
    /// (our own recording keeping systemMic up + the always-true `modulehost`
    /// helper input + Teams still frontmost) cannot immediately re-arm a new
    /// auto-record. Cleared the first time those ingredients actually drop —
    /// proving a genuinely new call rather than leftover state — after which the
    /// normal start path (incl. the polling activation timestamp) works again.
    @ObservationIgnored private var teamsAdHocStartSuppressedUntilSignalsClear = false

    // MARK: - Signal Sources

    /// Per-process audio query (injected for testability).
    @ObservationIgnored private let audioQuery: any AudioProcessQuerying
    /// Public Teams call-lifecycle assertion query (injected for testability).
    @ObservationIgnored private let teamsCallAssertionQuery: any TeamsCallAssertionQuerying

    /// Calendar event currently happening, pushed from AppState via snapshot.
    /// Used as a high-confidence signal for meeting detection. Marked
    /// @ObservationIgnored because views read calendar state through AppState
    /// directly, not through the detector — pushing it here is purely to feed
    /// the confidence scorer.
    @ObservationIgnored var currentCalendarMeeting: MeetingEventDTO?
    @ObservationIgnored private var activeSessionCalendarMeeting: MeetingEventDTO?

    // MARK: - Types

    struct DetectedMeetingApp: Identifiable, Sendable {
        let id: String // bundleIdentifier
        let app: MeetingApp
        let name: String
        let pid: pid_t
    }

    // MARK: - Init

    init(
        audioQuery: any AudioProcessQuerying = SystemAudioProcessQuery(),
        audioListener: any AudioStateListening = SystemAudioStateListener(),
        teamsCallAssertionQuery: any TeamsCallAssertionQuerying = SystemTeamsCallAssertionQuery(),
        screenCaptureAccessProvider: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.audioQuery = audioQuery
        self.audioListener = audioListener
        self.teamsCallAssertionQuery = teamsCallAssertionQuery
        self.screenCaptureAccessProvider = screenCaptureAccessProvider
        self.scoreThreshold = Self.resolveScoreThreshold()
        self.windowDumpEnabled = Self.resolveWindowDumpEnabled()
        self.windowDumpInterval = Self.resolveWindowDumpInterval()
        if !AppState.isRunningTests {
            DiagnosticArtifactStore.shared.resetSessionArtifacts()
            DiagnosticArtifactStore.removeLegacyArtifacts()
        }
    }

    // MARK: - Computed

    /// Whether a meeting is likely in progress (state machine is active).
    var isMeetingLikelyActive: Bool {
        sessionState.isActive
    }

    /// Get the bundle ID of the active meeting app (for audio targeting).
    var activeBundleID: String? {
        if let active = sessionState.currentApp ?? activeMeetingApp {
            return runningMeetingApps.first(where: { $0.app == active })?.id
        }
        return runningMeetingApps.first?.id
    }

    // MARK: - Start Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Initial scan via CGWindowList (sync, doesn't go through replayd).
        scanRunningApps()

        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            let processID = app.processIdentifier
            let localizedName = app.localizedName
            Task { @MainActor [weak self] in
                self?.handleWorkspaceAppLaunch(bundleID: bundleID, processID: processID, localizedName: localizedName)
            }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.handleWorkspaceAppTerminate(bundleID: bundleID)
            }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.handleWorkspaceAppActivation(bundleID: bundleID)
            }
        })

        audioListener.onAudioStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleEventEvaluation()
            }
        }
        audioListener.startListening()

        rescheduleAppPollTimer(fastPoll: false)

        NSLog("[MeetingDetector] startMonitoring: event-driven activePoll=%.0fs idlePoll=%.0fs threshold=%d windowDump=%d interval=%.1fs",
              Self.activePollInterval,
              Self.idlePollInterval,
              scoreThreshold,
              windowDumpEnabled ? 1 : 0,
              windowDumpInterval)
    }

    func stopMonitoring() {
        isMonitoring = false
        appPollTimer?.cancel()
        appPollTimer = nil
        eventEvalWorkItem?.cancel()
        eventEvalWorkItem = nil
        detectedConfirmationWorkItem?.cancel()
        detectedConfirmationWorkItem = nil
        teamsAdHocStartConfirmationWorkItem?.cancel()
        teamsAdHocStartConfirmationWorkItem = nil
        graceTimer?.cancel()
        graceTimer = nil
        audioListener.stopListening()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        runningMeetingApps = []
        activeMeetingApp = nil
        lastActivatedMeetingApp = nil
        lastActivatedMeetingAppAt = nil
        sessionState = .idle
        cachedAppWindows = []
        cachedScreenCaptureAccess = nil
        cachedScreenCaptureAccessAt = nil
        currentPollInterval = Self.idlePollInterval
        perProcessMicEverDetected = false
        teamsCallAssertionEverDetected = false
        teamsUncorroboratedKeepAliveSince = nil
        teamsHelperOutputKeepAliveSince = nil
        systemMicKeepAliveSince = nil
        activeSince = nil
        teamsAdHocStartCandidateSince = nil
        teamsAdHocStartSuppressedUntilSignalsClear = false
        activeSessionCalendarMeeting = nil
        lastWindowDumpAt = nil
    }

    // MARK: - Poll & Evaluate

    /// Poll-based app detection + confidence evaluation.
    private func pollRunningApps() async {
        let currentMeetingApps = currentWorkspaceMeetingApps()
        reconcileRunningMeetingApps(with: currentMeetingApps)

        // Track frontmost meeting app. Guard the observable `activeMeetingApp` write
        // so an unchanged value doesn't trigger SwiftUI invalidations every poll —
        // same pattern as the `sessionState` phase gate elsewhere in this class.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier,
           let detected = runningMeetingApps.first(where: { $0.id == bundleID }) {
            lastActivatedMeetingApp = detected.app
            lastActivatedMeetingAppAt = Date()
            if activeMeetingApp != detected.app {
                activeMeetingApp = detected.app
            }
        } else if activeMeetingApp == nil || !runningMeetingApps.contains(where: { $0.app == activeMeetingApp }) {
            let next = runningMeetingApps.first?.app
            if activeMeetingApp != next {
                activeMeetingApp = next
            }
        }

        let windows = enumerateAppWindows()
        cachedAppWindows = windows
        maybeLogWindowDump(windows: windows, reason: "poll")
        evaluateConfidence(windows: windows)
    }

    private func reconcileRunningMeetingApps(with currentMeetingApps: [DetectedMeetingApp]) {
        let currentIDs = Set(currentMeetingApps.map(\.id))

        // Detect newly launched meeting apps and refresh PIDs when an app
        // restarts under the same bundle ID. The Teams assertion is process
        // scoped, so retaining the old PID would silently lose call-end state.
        for app in currentMeetingApps {
            if let index = runningMeetingApps.firstIndex(where: { $0.id == app.id }) {
                if runningMeetingApps[index].pid != app.pid {
                    NSLog(
                        "[MeetingDetector] poll: meeting app PID changed %@ (%@) %d -> %d",
                        app.name,
                        app.id,
                        runningMeetingApps[index].pid,
                        app.pid
                    )
                    runningMeetingApps[index] = app
                }
            } else {
                NSLog("[MeetingDetector] poll: detected new meeting app %@ (%@)", app.name, app.id)
                runningMeetingApps.append(app)
            }
        }

        // Detect terminated meeting apps
        for app in runningMeetingApps where !currentIDs.contains(app.id) {
            NSLog("[MeetingDetector] poll: meeting app terminated %@ (%@)", app.name, app.id)
            let bundleID = app.id
            runningMeetingApps.removeAll { $0.id == bundleID }
            onMeetingAppTerminated?(bundleID)
        }
    }

    private func handleWorkspaceAppLaunch(bundleID: String, processID: pid_t, localizedName: String?) {
        guard let meetingApp = MeetingApp.allCases.first(where: { $0.bundleIdentifiers.contains(bundleID) }) else { return }
        guard !runningMeetingApps.contains(where: { $0.id == bundleID }) else { return }

        let detected = DetectedMeetingApp(
            id: bundleID,
            app: meetingApp,
            name: localizedName ?? meetingApp.displayName,
            pid: processID
        )

        NSLog("[MeetingDetector] event: meeting app launched %@ (%@)", detected.name, detected.id)
        runningMeetingApps.append(detected)
        scheduleEventEvaluation()
    }

    private func handleWorkspaceAppTerminate(bundleID: String) {
        if let idx = runningMeetingApps.firstIndex(where: { $0.id == bundleID }) {
            let terminated = runningMeetingApps.remove(at: idx)
            NSLog("[MeetingDetector] event: meeting app terminated %@ (%@)", terminated.name, terminated.id)
            onMeetingAppTerminated?(bundleID)
            scheduleEventEvaluation()
        }
    }

    private func handleWorkspaceAppActivation(bundleID: String) {
        guard let detected = runningMeetingApps.first(where: { $0.id == bundleID }) else { return }
        lastActivatedMeetingApp = detected.app
        lastActivatedMeetingAppAt = Date()
        if activeMeetingApp != detected.app {
            activeMeetingApp = detected.app
        }
    }

    private func scheduleEventEvaluation() {
        eventEvalWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateWithFreshWindowSnapshot(reason: "event")
        }
        eventEvalWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    func reevaluateNow(reason: String, refreshRunningApps: Bool = false) {
        if refreshRunningApps {
            reconcileRunningMeetingApps(with: currentWorkspaceMeetingApps())
        }
        evaluateWithFreshWindowSnapshot(reason: reason)
    }

    /// Fresh, app-owned confirmation used only after this detector already
    /// observed Teams' assertion release and armed an authoritative stop.
    ///
    /// Do not run the general confidence scorer here: while Cadenza is still
    /// recording, its own mic plus the retained calendar event can recreate an
    /// idle Teams candidate and cancel the stop. Refreshing the process list is
    /// still required so a rapid Teams restart/redial is queried using its new
    /// PID. Active restores Teams lifecycle tracking for a rapid reconnect or
    /// redial; unavailable stays distinct so RecordingEngine can retry without
    /// losing an already-observed release. Only explicit inactive (or Teams no
    /// longer running) confirms the old call ended.
    func confirmAuthoritativeTeamsCallEnded() -> AuthoritativeMeetingEndConfirmation {
        reconcileRunningMeetingApps(with: currentWorkspaceMeetingApps())

        let teamsStillRunning = runningMeetingApps.contains { $0.app == .teams }
        let assertionState = currentTeamsCallAssertionState()
        let confirmation: AuthoritativeMeetingEndConfirmation
        if !teamsStillRunning || assertionState == .inactive {
            concludeAuthoritativeTeamsSessionIfNeeded()
            confirmation = .ended
        } else if assertionState == .active {
            restoreTeamsLifecycleTrackingAfterAuthoritativeReconnect()
            confirmation = .ongoing
        } else {
            confirmation = .unavailable
        }
        writeMeetingDiagnostic(
            "authoritativeConfirm teamsRunning=\(teamsStillRunning ? 1 : 0) teamsAssert=\(assertionState.rawValue) result=\(String(describing: confirmation))"
        )
        return confirmation
    }

    private func concludeAuthoritativeTeamsSessionIfNeeded() {
        guard sessionState.currentApp == .teams else { return }

        let previousState = sessionState
        let endedState = MeetingSessionState.idle
        sessionState = endedState
        handleStateTransition(
            from: previousState,
            to: endedState,
            endingEvent: MeetingEndingEvent(detectedAt: Date(), reason: .teamsCallAssertionReleased)
        )
        writeMeetingDiagnostic(
            "authoritativeConfirm restored=\(stateLabel(previousState))->idle"
        )
    }

    /// An active assertion at the old call's authoritative deadline means a
    /// reconnect or redial won the race after grace had already moved the
    /// detector to idle. Restore the app-owned latch and fast lifecycle polling
    /// without allowing assertions to start unrelated recordings from idle.
    private func restoreTeamsLifecycleTrackingAfterAuthoritativeReconnect() {
        guard sessionState.currentApp == nil || sessionState.currentApp == .teams else {
            return
        }
        teamsCallAssertionEverDetected = true
        guard !sessionState.isActive else { return }

        let previousState = sessionState
        let restoredState = MeetingSessionState.active(app: .teams)
        sessionState = restoredState
        handleStateTransition(
            from: previousState,
            to: restoredState,
            endingEvent: MeetingEndingEvent(detectedAt: Date(), reason: .signalDrop),
            activityReason: .teamsCallAssertionActive
        )
        writeMeetingDiagnostic(
            "authoritativeReconnect restored=\(stateLabel(previousState))->active:teams"
        )
    }

    // MARK: - Confidence Evaluation

    private func evaluateWithFreshWindowSnapshot(reason: String, forceWindowDump: Bool = false) {
        let windows = enumerateAppWindows()
        cachedAppWindows = windows
        maybeLogWindowDump(windows: windows, reason: reason, force: forceWindowDump)
        writeMeetingDiagnostic("fresh reason=\(reason) windows=\(diagnosticWindowSummary(windows))")
        evaluateConfidence(windows: windows)
    }

    /// Gather all signals, score, transition state machine, fire callbacks.
    private func evaluateConfidence(windows: [CGWindowEnumerator.EnumeratedWindow]) {
        let teamsCallAssertionState = currentTeamsCallAssertionState()
        let teamsAssertionOwnsCurrentSession = sessionState.currentApp == .teams
        if teamsAssertionOwnsCurrentSession && teamsCallAssertionState == .active {
            teamsCallAssertionEverDetected = true
        }

        // Use audioBundleIdentifiers (not bundleIdentifiers) because some apps
        // delegate audio to helper subprocesses with different bundle IDs.
        let allAudioBundleIDs = runningMeetingApps.flatMap { detected in
            detected.app.audioBundleIdentifiers
        }
        // Teams delegates audio to the `modulehost` helper; probe those bundle
        // IDs for the continuity / startup / output signals.
        let teamsHelperBundleIDs = runningMeetingApps
            .filter { $0.app == .teams }
            .flatMap { $0.app.continuityAudioBundleIdentifiers }
        // Single HAL process-list walk per evaluation: one snapshot answers the
        // per-process mic check plus the Teams continuity / startup / output
        // probes, instead of re-walking the process list once per query.
        let audioUsage = audioQuery.audioUsage(
            bundleIDs: Array(Set(allAudioBundleIDs).union(teamsHelperBundleIDs))
        )

        let systemMicActive: Bool
#if DEBUG
        if let systemMicActivityOverride {
            systemMicActive = systemMicActivityOverride
        } else {
            systemMicActive = checkMicrophoneActivity()
        }
#else
        systemMicActive = checkMicrophoneActivity()
#endif

        let signals = MeetingSignals(
            meetingAppRunning: !runningMeetingApps.isEmpty,
            meetingApp: activeMeetingApp,
            processUsingMicInput: allAudioBundleIDs.contains { audioUsage[$0]?.isRunningInput == true },
            systemMicActive: systemMicActive,
            calendarMatch: hasCalendarMatch(),
            hasMeetingWindow: hasAnyMeetingWindow(windows: windows)
        )
        let now = Date()
        let continuityAudioActive = isContinuityAudioActive(usage: audioUsage)
        let teamsStartupAudioActive = isTeamsStartupAudioActive(usage: audioUsage)
        // Diagnostic-only: logged alongside the input signals to validate the
        // call-end discriminator. Does NOT participate in scoring yet.
        let teamsHelperOutputActive = isTeamsHelperOutputActive(usage: audioUsage)
        let screenCaptureAvailable = screenCaptureAccessAvailable()
        let screenPermissionFallbackActive = shouldUseScreenPermissionFallback(
            signals: signals,
            screenCaptureAvailable: screenCaptureAvailable
        )
        let teamsCalendarStartFallbackActive = shouldUseTeamsCalendarStartFallback(signals: signals)
        let teamsAdHocStartFallbackActive = shouldUseTeamsAdHocStartFallback(
            signals: signals,
            teamsStartupAudioActive: teamsStartupAudioActive,
            now: now
        )

        // Track per-process mic detection across the session.
        if signals.processUsingMicInput {
            perProcessMicEverDetected = true
        }

        let rawScore = ConfidenceScorer.score(signals)
        let teamsCalendarKeepAliveActive = shouldUseTeamsCalendarKeepAlive(signals: signals)
        let teamsUncorroboratedKeepAliveCandidate = shouldUseTeamsUncorroboratedKeepAlive(
            signals: signals,
            rawScore: rawScore,
            continuityAudioActive: continuityAudioActive,
            teamsStartupAudioActive: teamsStartupAudioActive,
            hadExistingKeepAlive: teamsUncorroboratedKeepAliveSince != nil
        )
        if teamsUncorroboratedKeepAliveCandidate {
            if teamsUncorroboratedKeepAliveSince == nil {
                teamsUncorroboratedKeepAliveSince = now
            }
        } else {
            teamsUncorroboratedKeepAliveSince = nil
        }
        let teamsUncorroboratedKeepAliveExpired: Bool
        if let since = teamsUncorroboratedKeepAliveSince {
            teamsUncorroboratedKeepAliveExpired = now.timeIntervalSince(since) > Self.teamsUncorroboratedKeepAliveCap
        } else {
            teamsUncorroboratedKeepAliveExpired = false
        }
        let teamsUncorroboratedKeepAliveActive = teamsUncorroboratedKeepAliveCandidate
            && !teamsUncorroboratedKeepAliveExpired

        // Minimum-active hold (change 3): keep a freshly-active session alive
        // through a transient signal collapse so an instantaneous start signal
        // cannot kill the recording seconds later. Requires the session's own
        // meeting app to still be running — termination must end immediately.
        let minimumActiveHoldActive = isWithinMinimumActiveHold(now: now)

        // End/sustain-only: Teams' assertion may stabilize an already-active
        // session, but it must never start one from idle, carry a weak detected
        // candidate through debounce, or take ownership of another app.
        let teamsCallAssertionActive = (sessionState.isActive || sessionState.isEnding)
            && teamsAssertionOwnsCurrentSession
            && teamsCallAssertionState == .active
        let startupFallbackActive = teamsCallAssertionActive
            || screenPermissionFallbackActive
            || teamsCalendarStartFallbackActive
            || teamsAdHocStartFallbackActive

        // Whether some OTHER path is already flooring the score this tick. The
        // output cap should only ARM while output is the path actually keeping
        // the session alive — otherwise a long calendar/min-hold-backed meeting
        // would burn the 4h output budget during hours it never needed output,
        // leaving the cap already expired when a genuine late output-only
        // blackout arrives. (Codex review, round 2.)
        let otherFlooringActive = startupFallbackActive
            || teamsCalendarKeepAliveActive
            || teamsUncorroboratedKeepAliveActive
            || minimumActiveHoldActive

        // Helper OUTPUT sustain (change 2): corroborates an ongoing call without
        // the 10-min input cap. Sustain-only — gated on active/ending so it can
        // never start a session from idle, and only arms when no other path is
        // already flooring the score.
        let teamsHelperOutputKeepAliveCandidate = !otherFlooringActive
            && shouldUseTeamsHelperOutputKeepAlive(
                signals: signals,
                rawScore: rawScore,
                teamsHelperOutputActive: teamsHelperOutputActive
            )
        if teamsHelperOutputKeepAliveCandidate {
            if teamsHelperOutputKeepAliveSince == nil {
                teamsHelperOutputKeepAliveSince = now
            }
        } else {
            teamsHelperOutputKeepAliveSince = nil
        }
        let teamsHelperOutputKeepAliveExpired: Bool
        if let since = teamsHelperOutputKeepAliveSince {
            teamsHelperOutputKeepAliveExpired = now.timeIntervalSince(since) > Self.teamsHelperOutputKeepAliveCap
        } else {
            teamsHelperOutputKeepAliveExpired = false
        }
        let teamsHelperOutputKeepAliveActive = teamsHelperOutputKeepAliveCandidate
            && !teamsHelperOutputKeepAliveExpired

        // System-mic keep-alive (change 4, silent-opening fix): weakest and
        // last-resort flooring path, so it only arms when nothing stronger is
        // already keeping the session alive — including helper output, which is
        // genuine corroboration and should burn its own (much longer) cap first.
        let systemMicKeepAliveCandidate = !otherFlooringActive
            && !teamsHelperOutputKeepAliveActive
            && shouldUseSystemMicKeepAlive(signals: signals, rawScore: rawScore)
        if systemMicKeepAliveCandidate {
            if systemMicKeepAliveSince == nil {
                systemMicKeepAliveSince = now
            }
        } else {
            systemMicKeepAliveSince = nil
        }
        let systemMicKeepAliveExpired: Bool
        if let since = systemMicKeepAliveSince {
            systemMicKeepAliveExpired = now.timeIntervalSince(since) > Self.systemMicKeepAliveCap
        } else {
            systemMicKeepAliveExpired = false
        }
        let systemMicKeepAliveActive = systemMicKeepAliveCandidate
            && !systemMicKeepAliveExpired

        let scoreOverrideActive = otherFlooringActive
            || teamsHelperOutputKeepAliveActive
            || systemMicKeepAliveActive
        let effectiveRawScore = scoreOverrideActive ? max(rawScore, scoreThreshold) : rawScore

        // Once observed, release of Teams' own call assertion is definitive and
        // takes precedence over retained windows, helper audio, calendar state,
        // and the minimum-active hold. Query failures remain fail-open because
        // only an explicit `.inactive` result can take this branch.
        let sessionMeetingApp = sessionState.currentApp ?? activeMeetingApp
        let teamsCallAssertionReleased = teamsAssertionOwnsCurrentSession
            && teamsCallAssertionEverDetected
            && teamsCallAssertionState == .inactive
            && (sessionState.isDetected || sessionState.isActive || sessionState.isEnding)
            && sessionMeetingApp == .teams

        let processMicReleased = perProcessMicEverDetected && !signals.processUsingMicInput

        // When per-process mic was previously detected and drops, the call has
        // definitively ended (e.g. Zoom released mic). Force score to 0 to prevent
        // composite fallback (systemMicActive from our recording + stale windows)
        // from masking this definitive signal.
        //
        // This per-process-drop branch INTENTIONALLY takes precedence over the
        // minimum-active hold: for a per-process app (Zoom/Webex/etc.) the mic
        // release is an unambiguous, immediate end, and going active for those
        // apps already required a stable +3 per-process signal — never the
        // instantaneous start signal the min-hold guards against (that scenario
        // is Teams-only, and Teams never sets `perProcessMicEverDetected`). So
        // the min-hold cannot mask a real per-process call end.
        //
        // All keepalive flooring otherwise flows through capped paths
        // (`teamsUncorroboratedKeepAliveActive` 10-min input cap;
        // `teamsHelperOutputKeepAliveActive` 4-hour output cap;
        // `systemMicKeepAliveActive` 10-min one-point-gap cap) plus the bounded
        // `minimumActiveHoldActive` (90s) window. There is intentionally no
        // second, *uncapped* `continuityAudioActive` flooring branch: that path
        // let a sticky Teams `modulehost` helper pin the meeting active forever
        // whenever the keepalive candidate was false for a non-expiry reason
        // (e.g. the calendar explicitly named a different app), defeating the cap.
        let score: Int
        if teamsCallAssertionReleased {
            score = 0
        } else if processMicReleased {
            score = 0
        } else if teamsUncorroboratedKeepAliveActive
                    || teamsHelperOutputKeepAliveActive
                    || systemMicKeepAliveActive
                    || minimumActiveHoldActive {
            score = max(effectiveRawScore, scoreThreshold)
        } else {
            score = effectiveRawScore
        }

        writeMeetingDiagnostic(
            "eval state=\(stateLabel(sessionState)) activeApp=\(activeMeetingApp?.rawValue ?? "nil") running=\(runningMeetingApps.map(\.id).joined(separator: ",")) score=\(score) raw=\(rawScore) thr=\(scoreThreshold) pmic=\(signals.processUsingMicInput ? 1 : 0) ever=\(perProcessMicEverDetected ? 1 : 0) teamsAssert=\(teamsCallAssertionState.rawValue) teamsAssertEver=\(teamsCallAssertionEverDetected ? 1 : 0) teamsAssertReleased=\(teamsCallAssertionReleased ? 1 : 0) cont=\(continuityAudioActive ? 1 : 0) startAudio=\(teamsStartupAudioActive ? 1 : 0) tHelperOut=\(teamsHelperOutputActive ? 1 : 0) toutKeep=\(teamsHelperOutputKeepAliveActive ? 1 : 0) toutExp=\(teamsHelperOutputKeepAliveExpired ? 1 : 0) minHold=\(minimumActiveHoldActive ? 1 : 0) tcalKeep=\(teamsCalendarKeepAliveActive ? 1 : 0) tblackout=\(teamsUncorroboratedKeepAliveActive ? 1 : 0) texp=\(teamsUncorroboratedKeepAliveExpired ? 1 : 0) smic=\(signals.systemMicActive ? 1 : 0) smicKeep=\(systemMicKeepAliveActive ? 1 : 0) smicExp=\(systemMicKeepAliveExpired ? 1 : 0) cal=\(signals.calendarMatch ? 1 : 0) win=\(signals.hasMeetingWindow ? 1 : 0) screen=\(screenCaptureAvailable ? 1 : 0) sfallback=\(screenPermissionFallbackActive ? 1 : 0) teamsCalStart=\(teamsCalendarStartFallbackActive ? 1 : 0) teamsAdhocStart=\(teamsAdHocStartFallbackActive ? 1 : 0) windows=\(diagnosticWindowSummary(windows))"
        )

        let previousState = sessionState
        // Once a session is active, its owning app must remain stable. Merely
        // bringing another meeting app to the foreground cannot transfer the
        // recording (or its app-specific end signals) to that app.
        let transitionApp = sessionState.currentApp ?? activeMeetingApp
        let newState = sessionState.next(score: score, app: transitionApp, now: now, threshold: scoreThreshold)

        // Preserve an assertion observed on the exact idle → detected tick.
        // If Teams hangs up during the debounce window, the following explicit
        // inactive state can reject the stale candidate before recording starts.
        if previousState.isIdle,
           newState.isDetected,
           newState.currentApp == .teams,
           teamsCallAssertionState == .active {
            teamsCallAssertionEverDetected = true
        }

        // Log every evaluation during active/ending for diagnostics.
        if sessionState.isActive || sessionState.isEnding {
            log.notice("tick: score=\(score, privacy: .public) thr=\(self.scoreThreshold, privacy: .public) pmic=\(signals.processUsingMicInput ? 1 : 0, privacy: .public)(ever=\(self.perProcessMicEverDetected ? 1 : 0, privacy: .public)) teamsAssert=\(teamsCallAssertionState.rawValue, privacy: .public)(ever=\(self.teamsCallAssertionEverDetected ? 1 : 0, privacy: .public)) cont=\(continuityAudioActive ? 1 : 0, privacy: .public) tout=\(teamsHelperOutputActive ? 1 : 0, privacy: .public) toutKeep=\(teamsHelperOutputKeepAliveActive ? 1 : 0, privacy: .public) minHold=\(minimumActiveHoldActive ? 1 : 0, privacy: .public) tcalKeep=\(teamsCalendarKeepAliveActive ? 1 : 0, privacy: .public) tblackout=\(teamsUncorroboratedKeepAliveActive ? 1 : 0, privacy: .public) texp=\(teamsUncorroboratedKeepAliveExpired ? 1 : 0, privacy: .public) smic=\(signals.systemMicActive ? 1 : 0, privacy: .public) smicKeep=\(systemMicKeepAliveActive ? 1 : 0, privacy: .public) smicExp=\(systemMicKeepAliveExpired ? 1 : 0, privacy: .public) cal=\(signals.calendarMatch ? 1 : 0, privacy: .public) win=\(signals.hasMeetingWindow ? 1 : 0, privacy: .public) state=\(self.stateLabel(self.sessionState), privacy: .public)")
        }

        // Only write sessionState when the phase actually changes.
        // Avoids triggering @Observable notifications on every poll tick,
        // which would cause unnecessary SwiftUI re-renders and overlay stutter.
        if !previousState.isSamePhase(as: newState) {
            sessionState = newState

            log.notice("evaluate: score=\(score, privacy: .public) pmic=\(signals.processUsingMicInput ? 1 : 0, privacy: .public) cont=\(continuityAudioActive ? 1 : 0, privacy: .public) tout=\(teamsHelperOutputActive ? 1 : 0, privacy: .public) toutKeep=\(teamsHelperOutputKeepAliveActive ? 1 : 0, privacy: .public) minHold=\(minimumActiveHoldActive ? 1 : 0, privacy: .public) smic=\(signals.systemMicActive ? 1 : 0, privacy: .public) cal=\(signals.calendarMatch ? 1 : 0, privacy: .public) win=\(signals.hasMeetingWindow ? 1 : 0, privacy: .public) state=\(self.stateLabel(previousState), privacy: .public)->\(self.stateLabel(newState), privacy: .public)")
            writeMeetingDiagnostic(
                "transition \(stateLabel(previousState))->\(stateLabel(newState)) score=\(score) raw=\(rawScore) pmic=\(signals.processUsingMicInput ? 1 : 0) teamsAssert=\(teamsCallAssertionState.rawValue) teamsAssertEver=\(teamsCallAssertionEverDetected ? 1 : 0) teamsAssertReleased=\(teamsCallAssertionReleased ? 1 : 0) cont=\(continuityAudioActive ? 1 : 0) startAudio=\(teamsStartupAudioActive ? 1 : 0) tHelperOut=\(teamsHelperOutputActive ? 1 : 0) toutKeep=\(teamsHelperOutputKeepAliveActive ? 1 : 0) minHold=\(minimumActiveHoldActive ? 1 : 0) tcalKeep=\(teamsCalendarKeepAliveActive ? 1 : 0) tblackout=\(teamsUncorroboratedKeepAliveActive ? 1 : 0) texp=\(teamsUncorroboratedKeepAliveExpired ? 1 : 0) smic=\(signals.systemMicActive ? 1 : 0) smicKeep=\(systemMicKeepAliveActive ? 1 : 0) smicExp=\(systemMicKeepAliveExpired ? 1 : 0) cal=\(signals.calendarMatch ? 1 : 0) win=\(signals.hasMeetingWindow ? 1 : 0) sfallback=\(screenPermissionFallbackActive ? 1 : 0) teamsCalStart=\(teamsCalendarStartFallbackActive ? 1 : 0) teamsAdhocStart=\(teamsAdHocStartFallbackActive ? 1 : 0)"
            )

            maybeLogWindowDump(
                windows: windows,
                reason: "transition:\(stateLabel(previousState))->\(stateLabel(newState))",
                force: true
            )

            let endingReason: MeetingEndingReason
            if teamsCallAssertionReleased {
                endingReason = .teamsCallAssertionReleased
            } else if processMicReleased {
                endingReason = .processMicReleased
            } else {
                endingReason = .signalDrop
            }
            let activityReason: MeetingActivityReason = teamsAssertionOwnsCurrentSession
                && teamsCallAssertionState == .active
                ? .teamsCallAssertionActive
                : .signals
            handleStateTransition(
                from: previousState,
                to: newState,
                endingEvent: MeetingEndingEvent(detectedAt: now, reason: endingReason),
                activityReason: activityReason
            )
        }
    }

    /// Check if a calendar event matching any running meeting app is happening now.
    private func hasCalendarMatch() -> Bool {
        guard let meeting = calendarMeetingForDetection(), !meeting.isAllDay else { return false }

        // Keep this aligned with AppState's detection-context snapshot. A
        // meeting that runs over its scheduled end can still provide title/app
        // context for window matching and screen-permission fallback.
        guard meeting.isWithinDetectionContext() else { return false }

        // If we know which app the meeting uses, check if it's running
        if let meetingAppRaw = meeting.meetingApp,
           let meetingApp = MeetingApp(rawValue: meetingAppRaw) {
            return runningMeetingApps.contains { $0.app == meetingApp }
        }

        // No specific app in calendar event — accept any running meeting app
        return !runningMeetingApps.isEmpty
    }

    private func currentTeamsCallAssertionState() -> TeamsCallAssertionState {
        let teamsProcessIDs = runningMeetingApps
            .filter { $0.app == .teams }
            .map(\.pid)
        guard !teamsProcessIDs.isEmpty else {
            return .inactive
        }
        return teamsCallAssertionQuery.state(for: teamsProcessIDs)
    }

    private func shouldUseScreenPermissionFallback(
        signals: MeetingSignals,
        screenCaptureAvailable: Bool
    ) -> Bool {
        guard !screenCaptureAvailable else { return false }
        guard signals.meetingApp == .teams else { return false }
        guard signals.systemMicActive, signals.calendarMatch else { return false }
        guard !signals.hasMeetingWindow else { return false }
        return true
    }

    private func shouldUseTeamsCalendarStartFallback(signals: MeetingSignals) -> Bool {
        guard sessionState.isIdle || sessionState.isDetected else { return false }
        guard signals.meetingApp == .teams else { return false }
        guard signals.systemMicActive else { return false }
        guard !signals.hasMeetingWindow else { return false }
        return hasCalendarMatch(for: .teams)
    }

    private func shouldUseTeamsCalendarKeepAlive(signals: MeetingSignals) -> Bool {
        guard sessionState.isActive || sessionState.isEnding else { return false }
        guard (sessionState.currentApp ?? activeMeetingApp) == .teams else { return false }
        guard signals.systemMicActive else { return false }
        guard !signals.hasMeetingWindow else { return false }
        return hasCalendarMatch(for: .teams)
    }

    private func shouldUseTeamsUncorroboratedKeepAlive(
        signals: MeetingSignals,
        rawScore: Int,
        continuityAudioActive: Bool,
        teamsStartupAudioActive: Bool,
        hadExistingKeepAlive: Bool
    ) -> Bool {
        guard sessionState.isActive || sessionState.isEnding else { return false }
        guard (sessionState.currentApp ?? activeMeetingApp) == .teams else { return false }
        guard rawScore < scoreThreshold else { return false }
        guard !signals.calendarMatch, !signals.hasMeetingWindow else { return false }
        guard currentCalendarMeetingDoesNotExplicitlyMatchOtherApp(than: .teams) else { return false }

        if continuityAudioActive || teamsStartupAudioActive {
            return true
        }

        // System mic alone is too weak to start a Teams keepalive because our
        // own recording can keep the input device running. It can bridge a
        // blackout only after Teams audio already established that blackout.
        return signals.systemMicActive && hadExistingKeepAlive
    }

    /// Helper OUTPUT sustain (change 2). Sustain-only: gated on active/ending so
    /// it can never start a session from idle. While the Teams helper is playing
    /// remote-participant audio it provides corroboration that is NOT subject
    /// to the 10-min uncorroborated input cap. Output may be absent during
    /// silence and is never treated as authoritative call-end evidence.
    ///
    /// Gated on `rawScore < scoreThreshold` so the 4-hour hard cap clock only
    /// starts when output is actually flooring an otherwise-failing score. A
    /// normal long meeting that keeps its own ≥3 score (windows / calendar) does
    /// NOT start (and continuously resets) the timer, so the cap remains
    /// available for a genuine late-meeting blackout instead of being burned
    /// down by the meeting's own healthy hours.
    private func shouldUseTeamsHelperOutputKeepAlive(
        signals: MeetingSignals,
        rawScore: Int,
        teamsHelperOutputActive: Bool
    ) -> Bool {
        guard sessionState.isActive || sessionState.isEnding else { return false }
        guard (sessionState.currentApp ?? activeMeetingApp) == .teams else { return false }
        // Teams must still be running for the helper signal to mean anything.
        guard runningMeetingApps.contains(where: { $0.app == .teams }) else { return false }
        guard rawScore < scoreThreshold else { return false }
        return teamsHelperOutputActive
    }

    /// System-mic keep-alive (change 4). Sustain-only and deliberately the
    /// weakest flooring path: the system-wide mic signal cannot be attributed
    /// to the meeting app (Cadenza's own capture keeps it true throughout a
    /// recording), so it may only close a ONE-point score gap — standing in for
    /// the lost `win` (+1) while stronger evidence (calendar) still carries the
    /// rest. This keeps the silent-opening case alive (user joined a scheduled
    /// call, waits muted, call window collapsed, no app-owned audio evidence
    /// yet) without letting smic alone sustain a session whose score genuinely
    /// collapsed — leaving a meeting for the chat tab drops the raw score to 0
    /// and must still end (see `teamsMeetingChatAfterLeave` regression test).
    /// Never participates in idle→detected: triggering stays smic-free.
    private func shouldUseSystemMicKeepAlive(signals: MeetingSignals, rawScore: Int) -> Bool {
        guard sessionState.isActive || sessionState.isEnding else { return false }
        guard let sessionApp = sessionState.currentApp ?? activeMeetingApp,
              runningMeetingApps.contains(where: { $0.app == sessionApp }) else {
            return false
        }
        guard rawScore < scoreThreshold else { return false }
        guard rawScore >= scoreThreshold - 1 else { return false }
        return signals.systemMicActive
    }

    /// Minimum-active hold (change 3). True while the session has been active for
    /// less than `minimumActiveHold` AND the session's own meeting app is still
    /// running. Termination of the active app must end the session immediately,
    /// so the guard checks `sessionState.currentApp` specifically — not just
    /// "any meeting app is running" (otherwise a different running meeting app
    /// would keep the terminated session pinned, and `next(...)` could even
    /// hand the active slot to it).
    private func isWithinMinimumActiveHold(now: Date) -> Bool {
        guard sessionState.isActive else { return false }
        guard let activeSince else { return false }
        let sessionApp = sessionState.currentApp ?? activeMeetingApp
        guard let sessionApp, runningMeetingApps.contains(where: { $0.app == sessionApp }) else {
            return false
        }
        return now.timeIntervalSince(activeSince) < Self.minimumActiveHold
    }

    private func shouldUseTeamsAdHocStartFallback(
        signals: MeetingSignals,
        teamsStartupAudioActive: Bool,
        now: Date
    ) -> Bool {
        guard sessionState.isIdle || sessionState.isDetected else {
            resetTeamsAdHocStartCandidate()
            return false
        }
        // Post-stop suppression: don't re-arm until the sticky ingredients that
        // were present when we stopped actually drop at least once, proving a
        // genuinely new call rather than leftover state (our recording's mic,
        // the always-true modulehost helper, Teams still frontmost).
        if teamsAdHocStartSuppressedUntilSignalsClear {
            if !signals.systemMicActive || !teamsStartupAudioActive || activeMeetingApp != .teams {
                teamsAdHocStartSuppressedUntilSignalsClear = false
            } else {
                resetTeamsAdHocStartCandidate()
                return false
            }
        }
        guard signals.meetingApp == .teams else {
            resetTeamsAdHocStartCandidate()
            return false
        }
        guard signals.systemMicActive, teamsStartupAudioActive else {
            resetTeamsAdHocStartCandidate()
            return false
        }
        guard currentCalendarMeetingDoesNotExplicitlyMatchOtherApp(than: .teams) else {
            resetTeamsAdHocStartCandidate()
            return false
        }
        guard wasMeetingAppRecentlyActivated(.teams, now: now) else {
            resetTeamsAdHocStartCandidate()
            return false
        }

        if teamsAdHocStartCandidateSince == nil {
            teamsAdHocStartCandidateSince = now
            scheduleTeamsAdHocStartConfirmation()
            return false
        }

        guard let since = teamsAdHocStartCandidateSince else { return false }
        let confirmed = now.timeIntervalSince(since) >= Self.teamsAdHocStartConfirmationInterval
        if !confirmed {
            scheduleTeamsAdHocStartConfirmation()
        }
        return confirmed
    }

    private func hasCalendarMatch(for app: MeetingApp) -> Bool {
        guard let meeting = calendarMeetingForDetection(), !meeting.isAllDay else { return false }
        guard meeting.isWithinDetectionContext() else { return false }

        return calendarMeeting(meeting, matches: app)
    }

    private func calendarMeetingForDetection() -> MeetingEventDTO? {
        if (sessionState.isActive || sessionState.isEnding || sessionState.isDetected),
           let activeSessionCalendarMeeting {
            return activeSessionCalendarMeeting
        }
        return currentCalendarMeeting
    }

    private func captureCalendarMeetingForActiveSession(app: MeetingApp?) {
        guard let app else { return }
        if let currentCalendarMeeting,
           !currentCalendarMeeting.isAllDay,
           currentCalendarMeeting.isWithinDetectionContext(),
           calendarMeeting(currentCalendarMeeting, matches: app) {
            activeSessionCalendarMeeting = currentCalendarMeeting
        }
    }

    private func calendarMeeting(_ meeting: MeetingEventDTO, matches app: MeetingApp) -> Bool {
        if let meetingAppRaw = meeting.meetingApp,
           let meetingApp = MeetingApp(rawValue: meetingAppRaw) {
            return meetingApp == app
        }

        if app == .teams,
           let meetingURL = meeting.meetingURL?.lowercased(),
           meetingURL.contains("teams.microsoft.com") {
            return true
        }

        return false
    }

    private func currentCalendarMeetingDoesNotExplicitlyMatchOtherApp(than app: MeetingApp) -> Bool {
        guard let meeting = calendarMeetingForDetection(), !meeting.isAllDay else { return true }
        guard meeting.isWithinDetectionContext() else { return true }
        guard let meetingAppRaw = meeting.meetingApp,
              let meetingApp = MeetingApp(rawValue: meetingAppRaw) else {
            return true
        }
        return meetingApp == app
    }

    private func wasMeetingAppRecentlyActivated(_ app: MeetingApp, now: Date) -> Bool {
        guard lastActivatedMeetingApp == app, let lastActivatedMeetingAppAt else { return false }
        return now.timeIntervalSince(lastActivatedMeetingAppAt) <= Self.recentMeetingAppActivationInterval
    }

    /// Check if any running meeting app has windows consistent with an active call.
    private func hasAnyMeetingWindow(windows: [CGWindowEnumerator.EnumeratedWindow]) -> Bool {
        for detectedApp in runningMeetingApps {
            let snapshots = windows
                .filter { $0.pid == detectedApp.pid }
                .map(\.snapshot)
            if MeetingWindowAnalyzer.hasMeetingWindow(
                app: detectedApp.app,
                snapshots: snapshots,
                calendarTitle: calendarMeetingForDetection()?.title
            ) {
                return true
            }
        }
        return false
    }

    /// Teams can hide or retitle its call windows while screen sharing. Once a
    /// Teams meeting is already active, use Teams' audio helper (`modulehost`)
    /// as a continuity signal so transient window loss does not start the
    /// auto-stop path. Lifecycle-gated: only contributes during active/ending,
    /// never during idle→detected, because the helper process can remain sticky
    /// outside a real call.
    private func isContinuityAudioActive(usage: [String: AudioProcessUsage]) -> Bool {
        guard sessionState.isActive || sessionState.isEnding else { return false }
        guard let meetingApp = sessionState.currentApp ?? activeMeetingApp,
              meetingApp == .teams else { return false }

        return isTeamsAudioHelperInputActive(meetingApp: meetingApp, usage: usage)
    }

    private func isTeamsStartupAudioActive(usage: [String: AudioProcessUsage]) -> Bool {
        guard activeMeetingApp == .teams || lastActivatedMeetingApp == .teams else { return false }
        return isTeamsAudioHelperInputActive(meetingApp: .teams, usage: usage)
    }

    private func isTeamsAudioHelperInputActive(meetingApp: MeetingApp, usage: [String: AudioProcessUsage]) -> Bool {
        let bundleIDs = runningMeetingApps
            .filter { $0.app == meetingApp }
            .flatMap { $0.app.continuityAudioBundleIdentifiers }
        guard !bundleIDs.isEmpty else { return false }

        return bundleIDs.contains { usage[$0]?.isRunningInput == true }
    }

    /// Whether the Teams audio helper is currently using OUTPUT
    /// (remote-participant audio playback). The `modulehost` helper keeps
    /// `isRunningInput=true` even when idle, so input alone cannot distinguish an
    /// ongoing call from a stale helper after the call ended. Output, by
    /// contrast, was validated 6/8–6/10 against real calls to stay true for the
    /// whole call and drop the instant it ends. It is now a SUSTAIN-only scoring
    /// signal (see `shouldUseTeamsHelperOutputKeepAlive`): it can keep an
    /// already-active session alive without the 10-min uncorroborated input cap,
    /// but never starts a session from idle. Still logged side-by-side
    /// (`tHelperOut`/`toutKeep`) for ongoing validation, including the not-yet-
    /// validated screen-share + fully-muted-remote case where output may be
    /// false. Reads the shared per-eval `audioUsage` snapshot — no extra HAL walk.
    private func isTeamsHelperOutputActive(usage: [String: AudioProcessUsage]) -> Bool {
        let bundleIDs = runningMeetingApps
            .filter { $0.app == .teams }
            .flatMap { $0.app.continuityAudioBundleIdentifiers }
        guard !bundleIDs.isEmpty else { return false }
        return bundleIDs.contains { usage[$0]?.isRunningOutput == true }
    }

    // MARK: - State Transitions → Callbacks

    private func handleStateTransition(
        from previous: MeetingSessionState,
        to current: MeetingSessionState,
        endingEvent: MeetingEndingEvent,
        activityReason: MeetingActivityReason = .signals
    ) {
        // Manage grace timer based on ending state
        if current.isEnding && !previous.isEnding {
            startGraceTimer()
        } else if !current.isEnding {
            cancelGraceTimer()
        }

        if current.isDetected && !previous.isDetected {
            scheduleDetectedConfirmation()
        } else if !current.isDetected {
            cancelDetectedConfirmation()
        }

        if current.isActive || current.isEnding || current.isIdle {
            resetTeamsAdHocStartCandidate()
        }

        // A detected session can fall back to idle without passing through the
        // active/ending callback block below. Never leak the assertion latch
        // into a later call attempt.
        if current.isIdle && !previous.isIdle {
            teamsCallAssertionEverDetected = false
        }

        // Adaptive poll: faster during active/ending for quicker stop detection
        let needsFastPoll = current.isActive || current.isEnding
        let previousNeedsFast = previous.isActive || previous.isEnding
        if needsFastPoll != previousNeedsFast {
            rescheduleAppPollTimer(fastPoll: needsFastPoll)
        }

        // idle/detected → active: meeting started
        if (previous.isIdle || previous.isDetected) && current.isActive {
            // Stamp the minimum-active hold from the fresh session start. (An
            // ending→active recovery below intentionally preserves the original
            // stamp so a flapping signal cannot keep re-arming the hold.)
            activeSince = Date()
            captureCalendarMeetingForActiveSession(app: current.currentApp)
            updateActiveMeetingApp()
            log.notice("meeting STARTED (app=\(self.activeMeetingApp?.displayName ?? "unknown", privacy: .public))")
            onMeetingActivityDetected?(activityReason)
        } else if previous.isEnding && current.isActive {
            // ending → active: signals recovered during grace period. Keep the
            // existing activeSince (same session). Guard against a nil stamp from
            // an externally-injected state.
            if activeSince == nil { activeSince = Date() }
            captureCalendarMeetingForActiveSession(app: current.currentApp)
            log.notice("meeting RECOVERED reason=\(activityReason.rawValue, privacy: .public)")
            onMeetingRecovered?(activityReason)
        }

        // active → ending: meeting signals dropped, start countdown immediately
        if previous.isActive && current.isEnding {
            log.notice("meeting ENDING reason=\(endingEvent.reason.rawValue, privacy: .public) (grace period started)")
            onMeetingEnding?(endingEvent)
        }

        // active/ending → idle: meeting ended
        if (previous.isActive || previous.isEnding) && current.isIdle {
            perProcessMicEverDetected = false
            teamsCallAssertionEverDetected = false
            teamsUncorroboratedKeepAliveSince = nil
            teamsHelperOutputKeepAliveSince = nil
            systemMicKeepAliveSince = nil
            activeSince = nil
            activeSessionCalendarMeeting = nil
            log.notice("meeting ENDED")
            onMicrophoneDeactivated?()
        }
    }

    private func scheduleDetectedConfirmation() {
        cancelDetectedConfirmation()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.sessionState.isDetected else { return }
            self.evaluateWithFreshWindowSnapshot(reason: "detectedConfirm")
        }
        detectedConfirmationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + MeetingSessionState.debounceInterval + 0.05, execute: item)
    }

    private func cancelDetectedConfirmation() {
        detectedConfirmationWorkItem?.cancel()
        detectedConfirmationWorkItem = nil
    }

    private func scheduleTeamsAdHocStartConfirmation() {
        guard teamsAdHocStartConfirmationWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.teamsAdHocStartConfirmationWorkItem = nil
            self.evaluateWithFreshWindowSnapshot(reason: "teamsAdHocStartConfirm")
        }
        teamsAdHocStartConfirmationWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.teamsAdHocStartConfirmationInterval + 0.05,
            execute: item
        )
    }

    private func resetTeamsAdHocStartCandidate() {
        teamsAdHocStartCandidateSince = nil
        teamsAdHocStartConfirmationWorkItem?.cancel()
        teamsAdHocStartConfirmationWorkItem = nil
    }

    /// Set `activeMeetingApp` based on the most recently activated meeting app.
    /// Guarded to avoid triggering SwiftUI invalidations when the value is unchanged.
    private func updateActiveMeetingApp() {
        let next: MeetingApp?
        if let last = lastActivatedMeetingApp,
           runningMeetingApps.contains(where: { $0.app == last }) {
            next = last
        } else {
            next = runningMeetingApps.first?.app
        }
        if activeMeetingApp != next {
            activeMeetingApp = next
        }
    }

    // MARK: - Reset

    /// Reset detection state so the next meeting activity can trigger a new notification.
    func resetDetectionState() {
        cancelDetectedConfirmation()
        resetTeamsAdHocStartCandidate()
        sessionState = .idle
        perProcessMicEverDetected = false
        teamsCallAssertionEverDetected = false
        teamsUncorroboratedKeepAliveSince = nil
        teamsHelperOutputKeepAliveSince = nil
        systemMicKeepAliveSince = nil
        activeSince = nil
        activeSessionCalendarMeeting = nil
        // Forget the last activation timestamp so the Teams ad-hoc start fallback
        // (gated on wasMeetingAppRecentlyActivated) cannot re-arm from a stale
        // activation after a reset/auto-stop without a fresh activation.
        lastActivatedMeetingAppAt = nil
        // Full reset returns to a clean slate: also lift the post-stop ad-hoc
        // suppression. Without this, a reset right after a recording stop could
        // leave ad-hoc start permanently suppressed when the sticky signals
        // (modulehost input / frontmost Teams / own-recording systemMic) never
        // drop — the next quick call would silently never auto-record.
        // (resetNotificationState intentionally SETS this flag; the two resets
        // have different post-conditions by design.)
        teamsAdHocStartSuppressedUntilSignalsClear = false
    }

    /// Reset so detection can re-trigger. Used after stopping recording to allow
    /// the next meeting to be detected even if signals haven't fully cleared.
    func resetNotificationState() {
        // Always forget the stale activation timestamp — even when the detector
        // already reached idle. The auto-stop path transitions ending→idle
        // BEFORE AppState calls this on recording-stop, so guarding this behind
        // `!isIdle` would skip it exactly when it matters and let the Teams
        // ad-hoc start fallback re-arm from a stale activation. (Poll re-stamps
        // it while Teams stays frontmost — intentional, needed for start
        // detection — so the suppression bit below, not this clear, is the real
        // guard against immediate re-arm.)
        lastActivatedMeetingAppAt = nil
        teamsAdHocStartSuppressedUntilSignalsClear = true
        if !sessionState.isIdle {
            let wasFastPoll = sessionState.isActive || sessionState.isEnding
            cancelGraceTimer()
            cancelDetectedConfirmation()
            resetTeamsAdHocStartCandidate()
            sessionState = .idle
            perProcessMicEverDetected = false
            teamsCallAssertionEverDetected = false
            teamsUncorroboratedKeepAliveSince = nil
            teamsHelperOutputKeepAliveSince = nil
            systemMicKeepAliveSince = nil
            activeSince = nil
            activeSessionCalendarMeeting = nil
            if wasFastPoll {
                rescheduleAppPollTimer(fastPoll: false)
            }
        }
    }

    // MARK: - System-Wide Mic Check (backward compat for CoreEngine mic probe)

    /// Check if any audio input device is currently running (system-wide).
    /// Used by CoreEngine's mic probe — NOT used for meeting detection.
    func checkMicrophoneActivity() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return false }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return false }

        for deviceID in deviceIDs {
            var inputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(deviceID, &inputStreamAddress, 0, nil, &streamSize)
            guard streamStatus == noErr, streamSize > 0 else { continue }

            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            let runStatus = AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &runningSize, &isRunning)
            if runStatus == noErr && isRunning != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - App Detection

    private func scanRunningApps() {
        let detected = currentWorkspaceMeetingApps()
        // Guard observable writes for consistency with the rest of the class —
        // `scanRunningApps` only runs at startup, but keeping all observable
        // assignments behind equality checks preserves the invariant
        // "MeetingDetector never invalidates SwiftUI without a real change".
        if runningMeetingApps.map(\.id) != detected.map(\.id) {
            runningMeetingApps = detected
        }
        let next = detected.first?.app
        if activeMeetingApp != next {
            activeMeetingApp = next
        }
        NSLog("[MeetingDetector] scanRunningApps: found %d meeting apps", detected.count)
        let windows = enumerateAppWindows()
        cachedAppWindows = windows
        evaluateConfidence(windows: windows)
    }

    private func currentWorkspaceMeetingApps() -> [DetectedMeetingApp] {
#if DEBUG
        if let workspaceMeetingAppsOverride {
            return workspaceMeetingAppsOverride
        }
#endif
        var seenBundleIDs: Set<String> = []
        var detected: [DetectedMeetingApp] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let mapped = mapToMeetingApp(app) else { continue }
            guard !seenBundleIDs.contains(mapped.id) else { continue }
            seenBundleIDs.insert(mapped.id)
            detected.append(mapped)
        }

        return detected
    }

    /// Enumerate on-screen meeting-app windows via CGWindowList — does NOT go
    /// through replayd. Replaces the prior `SCShareableContent` call which
    /// triggered macOS 26.4's systemstatusd attribution-cache pathology and
    /// broke other SCK clients (Microsoft Teams screen sharing) just by Cadenza
    /// being open. Skip work entirely when no meeting app is running.
    private func enumerateAppWindows() -> [CGWindowEnumerator.EnumeratedWindow] {
        guard !runningMeetingApps.isEmpty else { return [] }
#if DEBUG
        if let windowSnapshotOverride {
            return windowSnapshotOverride
        }
#endif
        return CGWindowEnumerator.snapshotOnScreenWindows(
            screenCaptureAccessAvailable: screenCaptureAccessAvailable()
        )
    }

    private func mapToMeetingApp(_ app: NSRunningApplication) -> DetectedMeetingApp? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        for meetingApp in MeetingApp.allCases {
            if meetingApp.bundleIdentifiers.contains(bundleID) {
                return DetectedMeetingApp(
                    id: bundleID,
                    app: meetingApp,
                    name: app.localizedName ?? meetingApp.displayName,
                    pid: app.processIdentifier
                )
            }
        }
        return nil
    }

    // MARK: - Window Monitoring

    /// Count on-screen windows for a meeting app (filtered by min size to
    /// exclude tooltips, menus, and other small transient UI elements).
    func countMeetingWindows(bundleID: String) -> Int {
        guard screenCaptureAccessAvailable() else { return 0 }
        guard let detectedApp = runningMeetingApps.first(where: { $0.id == bundleID }) else { return 0 }
        let targetPID = detectedApp.pid

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        var count = 0
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == targetPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            if bounds.width >= 300 && bounds.height >= 200 {
                count += 1
            }
        }
        return count
    }

    // MARK: - Grace Timer

    /// Schedules a one-shot timer to fire at exactly graceInterval after entering `.ending`.
    /// Eliminates the need to wait for the next 5s poll to check if grace period expired.
    private func startGraceTimer() {
        cancelGraceTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + MeetingSessionState.graceInterval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionState.isEnding else { return }
                self.log.notice("graceTimer fired, refreshing windows and re-evaluating")
                self.writeMeetingDiagnostic("graceTimer fired state=\(self.stateLabel(self.sessionState))")
                self.evaluateWithFreshWindowSnapshot(reason: "graceTimer", forceWindowDump: true)
            }
        }
        timer.resume()
        graceTimer = timer
        writeMeetingDiagnostic("graceTimer scheduled interval=\(MeetingSessionState.graceInterval)")
    }

    private func cancelGraceTimer() {
        if graceTimer != nil {
            writeMeetingDiagnostic("graceTimer cancelled state=\(stateLabel(sessionState))")
        }
        graceTimer?.cancel()
        graceTimer = nil
    }

    // MARK: - Adaptive Poll Interval

    /// Restarts the poll timer with interval suited to current state.
    /// Event-driven audio/workspace callbacks do the low-latency work; the
    /// timer is only a safety net. Keep it slow enough that idle Teams does not
    /// keep TCC/windowserver hot for hours.
    private func rescheduleAppPollTimer(fastPoll: Bool) {
        appPollTimer?.cancel()
        let interval = fastPoll ? Self.activePollInterval : Self.idlePollInterval
        currentPollInterval = interval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.pollRunningApps()
            }
        }
        timer.resume()
        appPollTimer = timer
        NSLog("[MeetingDetector] poll interval changed to %.0fs", interval)
    }

    // MARK: - Helpers

    private func screenCaptureAccessAvailable(now: Date = Date()) -> Bool {
        if let cachedScreenCaptureAccess,
           let cachedScreenCaptureAccessAt,
           now.timeIntervalSince(cachedScreenCaptureAccessAt) < Self.screenCaptureAccessCacheInterval {
            return cachedScreenCaptureAccess
        }

        let allowed = screenCaptureAccessProvider()
        cachedScreenCaptureAccess = allowed
        cachedScreenCaptureAccessAt = now
        return allowed
    }

    private func maybeLogWindowDump(windows: [CGWindowEnumerator.EnumeratedWindow], reason: String, force: Bool = false) {
        guard windowDumpEnabled else { return }

        let now = Date()
        if !force,
           let lastWindowDumpAt,
           now.timeIntervalSince(lastWindowDumpAt) < windowDumpInterval {
            return
        }
        lastWindowDumpAt = now

        guard !runningMeetingApps.isEmpty else {
            MeetingDiagnosticsLog.shared.write(
                source: "[MeetingDetector]",
                message: "windowDump[\(reason)]: no running meeting apps"
            )
            return
        }

        for detectedApp in runningMeetingApps {
            let snapshots = windows
                .filter { $0.pid == detectedApp.pid }
                .map(\.snapshot)

            let summary = MeetingWindowAnalyzer.debugSummary(
                app: detectedApp.app,
                snapshots: snapshots,
                calendarTitle: calendarMeetingForDetection()?.title
            )
            MeetingDiagnosticsLog.shared.write(
                source: "[MeetingDetector]",
                message: "windowDump[\(reason)]: \(detectedApp.name) "
                    + "(\(detectedApp.id)) pid=\(detectedApp.pid) \(summary)"
            )
        }
    }

    private static func resolveScoreThreshold() -> Int {
        let environment = ProcessInfo.processInfo.environment

        if let raw = environment["AIRECORDER_MEETING_SCORE_THRESHOLD"],
           let parsed = Int(raw) {
            return clampedScoreThreshold(parsed)
        }

        let defaults = UserDefaults.standard
        let defaultsKey = "meetingDetectionScoreThreshold"
        if defaults.object(forKey: defaultsKey) != nil {
            return clampedScoreThreshold(defaults.integer(forKey: defaultsKey))
        }

        return ConfidenceScorer.threshold
    }

    private static func resolveWindowDumpEnabled() -> Bool {
        let environment = ProcessInfo.processInfo.environment

        if let value = parseBoolString(environment["AIRECORDER_MEETING_DUMP_WINDOWS"]) {
            return value
        }

        let defaults = UserDefaults.standard
        let defaultsKey = "meetingDetectionDumpWindows"
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }

        return false
    }

    private static func resolveWindowDumpInterval() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment

        if let raw = environment["AIRECORDER_MEETING_DUMP_INTERVAL"],
           let parsed = TimeInterval(raw),
           parsed > 0 {
            return clampedDumpInterval(parsed)
        }

        let defaults = UserDefaults.standard
        let defaultsKey = "meetingDetectionDumpIntervalSeconds"
        if defaults.object(forKey: defaultsKey) != nil {
            let value = defaults.double(forKey: defaultsKey)
            if value > 0 {
                return clampedDumpInterval(value)
            }
        }

        return 5
    }

    private static func parseBoolString(_ value: String?) -> Bool? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func clampedScoreThreshold(_ value: Int) -> Int {
        min(max(value, 1), 6)
    }

    private static func clampedDumpInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, 1), 60)
    }

    private func stateLabel(_ state: MeetingSessionState) -> String {
        switch state {
        case .idle: "idle"
        case .detected: "detected"
        case .active: "active"
        case .ending: "ending"
        }
    }

    private func diagnosticWindowSummary(_ windows: [CGWindowEnumerator.EnumeratedWindow]) -> String {
        guard !windows.isEmpty else { return "none" }
        return windows
            .filter { window in
                runningMeetingApps.contains { $0.pid == window.pid }
            }
            .prefix(8)
            .map { window in
                let title = (window.snapshot.title ?? "<empty>")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                return "\(window.pid):\(Int(window.snapshot.width))x\(Int(window.snapshot.height)):\(String(title.prefix(80)))"
            }
            .joined(separator: " | ")
    }

    private func writeMeetingDiagnostic(_ message: @autoclosure () -> String) {
        guard Self.meetingDiagnosticsEnabled else { return }
        // Message interpolation reads MainActor state (gated), but the file I/O
        // is offloaded to MeetingDiagnosticsLog's serial queue.
        MeetingDiagnosticsLog.shared.write(source: "[MeetingDetector]", message: message())
    }

    private static var meetingDiagnosticsEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if let value = parseBoolString(environment["AIRECORDER_MEETING_DIAGNOSTICS"]) {
            return value
        }

        let defaultsKey = "meetingDetectionDiagnosticsEnabled"
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }

        return false
    }
}

// MARK: - Diagnostics Log

/// Private bounded diagnostic log shared by `MeetingDetector` and
/// `RecordingEngine`. Caller-side message interpolation remains gated, while
/// secure no-follow file I/O runs on a serial utility queue.
final class MeetingDiagnosticsLog: Sendable {
    static let shared = MeetingDiagnosticsLog()

    private let queue = DispatchQueue(label: "com.shuiandy.Cadenza.meetingDiagnostics", qos: .utility)
    private let artifactStore = DiagnosticArtifactStore.shared
    private let pid = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func write(source: String, message: String, at date: Date = Date()) {
        queue.async { [artifactStore, pid] in
            let line = "\(date.ISO8601Format()) pid=\(pid) \(source) \(message)\n"
            let data = Data(line.utf8)
            do {
                try artifactStore.appendLog(
                    named: "meeting-detection.log",
                    data: data,
                    maximumBytes: 2 * 1_024 * 1_024
                )
            } catch {
                NSLog(
                    "[MeetingDiagnosticsLog] secure append failed: %@",
                    error.localizedDescription
                )
            }
        }
    }
}

// MARK: - Test Helpers

#if DEBUG
extension MeetingDetector {
    func _test_setSessionState(_ state: MeetingSessionState) { sessionState = state }
    func _test_setRunningMeetingApps(_ apps: [DetectedMeetingApp]) { runningMeetingApps = apps }
    func _test_reconcileRunningMeetingApps(with apps: [DetectedMeetingApp]) {
        reconcileRunningMeetingApps(with: apps)
    }
    func _test_setActiveMeetingApp(_ app: MeetingApp?) { activeMeetingApp = app }
    func _test_setLastActivatedMeetingApp(_ app: MeetingApp?, at date: Date?) {
        lastActivatedMeetingApp = app
        lastActivatedMeetingAppAt = date
    }
    func _test_setSystemMicActivity(_ value: Bool?) { systemMicActivityOverride = value }
    func _test_setWindowSnapshot(_ value: [CGWindowEnumerator.EnumeratedWindow]?) { windowSnapshotOverride = value }
    func _test_setWorkspaceMeetingApps(_ value: [DetectedMeetingApp]?) { workspaceMeetingAppsOverride = value }
    func _test_evaluateConfidence(windows: [CGWindowEnumerator.EnumeratedWindow]) { evaluateConfidence(windows: windows) }
    func _test_evaluateWithFreshWindowSnapshot() { evaluateWithFreshWindowSnapshot(reason: "test") }
    func _test_setTeamsUncorroboratedKeepAliveSince(_ date: Date?) {
        teamsUncorroboratedKeepAliveSince = date
    }
    func _test_setTeamsHelperOutputKeepAliveSince(_ date: Date?) {
        teamsHelperOutputKeepAliveSince = date
    }
    func _test_setSystemMicKeepAliveSince(_ date: Date?) {
        systemMicKeepAliveSince = date
    }
    func _test_setActiveSince(_ date: Date?) { activeSince = date }
    func _test_setTeamsAdHocStartCandidateSince(_ date: Date?) { teamsAdHocStartCandidateSince = date }
}
#endif
