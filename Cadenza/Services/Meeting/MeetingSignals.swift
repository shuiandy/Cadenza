import Foundation

// MARK: - Meeting Signals

/// Raw signals collected from various sources for meeting detection.
/// Pure value type — no dependencies on system APIs.
struct MeetingSignals: Sendable {
    /// Whether at least one known meeting app process is running.
    let meetingAppRunning: Bool
    /// The frontmost/active meeting app (if any).
    let meetingApp: MeetingApp?
    /// Per-process audio: the meeting app itself is using microphone input.
    let processUsingMicInput: Bool
    /// System-wide: ANY audio input device is currently running.
    /// Weaker than per-process — cannot attribute to a specific app.
    let systemMicActive: Bool
    /// Calendar: a matching meeting event is happening now.
    let calendarMatch: Bool
    /// Window heuristic: meeting app has windows consistent with an active call.
    let hasMeetingWindow: Bool
}

// MARK: - Meeting Ending Evidence

enum MeetingEndingReason: String, Equatable, Sendable {
    case signalDrop
    case processMicReleased
    case teamsCallAssertionReleased

    var allowsAuthoritativeAutoStopDeadline: Bool {
        self == .teamsCallAssertionReleased
    }
}

struct MeetingEndingEvent: Equatable, Sendable {
    let detectedAt: Date
    let reason: MeetingEndingReason
}

enum MeetingActivityReason: String, Equatable, Sendable {
    case signals
    case teamsCallAssertionActive
}

/// Result of re-checking app-owned lifecycle evidence at an authoritative
/// auto-stop deadline. `unavailable` is distinct from `ongoing` so a transient
/// IOKit query failure cannot permanently discard an already-observed hang-up.
enum AuthoritativeMeetingEndConfirmation: Equatable, Sendable {
    case ended
    case ongoing
    case unavailable
}

// MARK: - Confidence Scorer

/// Evaluates meeting confidence from collected signals.
/// Pure function — no side effects, fully deterministic, trivially testable.
enum ConfidenceScorer {
    /// Minimum score to consider a meeting active.
    static let threshold = 3

    /// Per-process mic input is the strongest signal — the meeting app itself
    /// has an active audio input session, not just "some app is using the mic."
    static let micInputScore = 3

    /// Fallback when per-process audio is unreliable (e.g. Teams delegates audio
    /// to a helper subprocess whose `isRunningInput` is always true).
    /// System-wide mic active + call-like windows = strong circumstantial evidence.
    static let systemMicWithWindowScore = 2

    /// Calendar match is strong but not definitive alone — user might have a
    /// scheduled meeting but hasn't joined yet.
    static let calendarScore = 2

    /// Window heuristic is a supporting signal — meeting apps show specific
    /// window patterns during calls, but patterns vary across apps and versions.
    static let windowScore = 1

    static func score(_ signals: MeetingSignals) -> Int {
        guard signals.meetingAppRunning else { return 0 }
        var s = 0
        if signals.processUsingMicInput {
            // Definitive: per-process API confirms this app is using mic
            s += micInputScore
        } else if signals.systemMicActive && signals.hasMeetingWindow {
            // Fallback: system mic active + call windows visible.
            // Handles apps (Teams) where audio runs in a helper subprocess
            // and per-process detection on the main bundle ID always fails.
            s += systemMicWithWindowScore
        }
        if signals.calendarMatch { s += calendarScore }
        if signals.hasMeetingWindow { s += windowScore }
        return s
    }

    static func shouldTrigger(_ signals: MeetingSignals, threshold: Int = threshold) -> Bool {
        score(signals) >= threshold
    }
}

// MARK: - Meeting Session State Machine

/// Tracks meeting lifecycle with debounce and grace period.
///
/// State transitions:
/// ```
/// idle → detected (score ≥ threshold)
/// detected → active (held for debounceInterval)
/// detected → idle (score dropped before debounce)
/// active → ending (score dropped below threshold)
/// ending → active (score recovered within grace period)
/// ending → idle (grace period elapsed)
/// ```
enum MeetingSessionState: Sendable {
    case idle
    case detected(since: Date, app: MeetingApp)
    case active(app: MeetingApp)
    case ending(since: Date, app: MeetingApp)

    /// How long a detection must hold before transitioning to active.
    /// Filters out transient signals (app startup flicker, brief mic probe).
    static let debounceInterval: TimeInterval = 1

    /// How long to wait after signals drop before declaring meeting ended.
    /// Handles screenshare toggles, window rearrangement, brief mic interruptions.
    static let graceInterval: TimeInterval = 3

    /// Compute the next state given current confidence score and time.
    func next(
        score: Int,
        app: MeetingApp?,
        now: Date,
        threshold: Int = ConfidenceScorer.threshold
    ) -> MeetingSessionState {
        switch self {
        case .idle:
            if score >= threshold, let app {
                return .detected(since: now, app: app)
            }
            return .idle

        case .detected(let since, let detectedApp):
            if score < threshold {
                return .idle
            }
            if now.timeIntervalSince(since) >= Self.debounceInterval {
                return .active(app: detectedApp)
            }
            return .detected(since: since, app: detectedApp)

        case .active(let activeApp):
            if score < threshold {
                return .ending(since: now, app: activeApp)
            }
            return .active(app: activeApp)

        case .ending(let since, let endingApp):
            if score >= threshold {
                return .active(app: endingApp)
            }
            if now.timeIntervalSince(since) >= Self.graceInterval {
                return .idle
            }
            return .ending(since: since, app: endingApp)
        }
    }

    // MARK: - Convenience

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isEnding: Bool {
        if case .ending = self { return true }
        return false
    }

    var isDetected: Bool {
        if case .detected = self { return true }
        return false
    }

    var currentApp: MeetingApp? {
        switch self {
        case .idle: nil
        case .detected(_, let app): app
        case .active(let app): app
        case .ending(_, let app): app
        }
    }

    /// Whether two states represent the same phase and app.
    /// Ignores associated `Date` values to avoid triggering `@Observable`
    /// notifications on every poll when the state hasn't meaningfully changed.
    func isSamePhase(as other: MeetingSessionState) -> Bool {
        switch (self, other) {
        case (.idle, .idle):
            return true
        case (.detected(_, let a), .detected(_, let b)),
             (.active(let a), .active(let b)),
             (.ending(_, let a), .ending(_, let b)):
            return a == b
        default:
            return false
        }
    }
}
