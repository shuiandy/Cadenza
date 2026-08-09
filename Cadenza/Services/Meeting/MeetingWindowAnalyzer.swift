import CoreGraphics
import Foundation

/// Analyzes window snapshots to detect active meeting windows.
///
/// Each meeting app has distinct window patterns during calls vs idle:
/// - Zoom: Large meeting window appears (≥700×450), home screen is small (~400×300)
/// - Teams: Floating call controls bar (small separate window) appears during calls
/// - FaceTime: Large video window appears during calls
/// - Webex: Similar to Zoom (large meeting window)
/// - Slack: Huddle overlay window appears
/// - Google Meet: Browser-based — cannot be detected via native windows
///
/// Window detection is a Tier 2 (supporting) signal worth +1 confidence point.
/// It is NOT relied upon as the sole trigger — per-process audio and calendar are primary.
enum MeetingWindowAnalyzer {

    struct WindowSnapshot: Sendable {
        let title: String?
        let width: CGFloat
        let height: CGFloat
        let isOnScreen: Bool
    }

    /// Whether the given meeting app has windows consistent with an active call.
    static func hasMeetingWindow(app: MeetingApp, snapshots: [WindowSnapshot], calendarTitle: String? = nil) -> Bool {
        let onScreen = snapshots.filter { $0.isOnScreen }
        guard !onScreen.isEmpty else { return false }

        switch app {
        case .zoom:      return zoomInMeeting(onScreen)
        case .teams:     return teamsInMeeting(onScreen, calendarTitle: calendarTitle)
        case .facetime:  return facetimeInMeeting(onScreen)
        case .webex:     return webexInMeeting(onScreen)
        case .slack:     return slackInMeeting(onScreen)
        case .googleMeet: return false // Browser-based, not detectable
        }
    }

    static func debugSummary(app: MeetingApp, snapshots: [WindowSnapshot], calendarTitle: String? = nil) -> String {
        let onScreen = snapshots.filter { $0.isOnScreen }
        let significant = onScreen.filter(isSignificantWindow(_:))
        let detected = hasMeetingWindow(app: app, snapshots: snapshots, calendarTitle: calendarTitle)
        let details = onScreen
            .sorted { area($0) > area($1) }
            .prefix(6)
            .map { describeWindow($0) }
            .joined(separator: " | ")

        return "app=\(app.rawValue) detected=\(detected ? 1 : 0) onScreen=\(onScreen.count) significant=\(significant.count) windows=\(details.isEmpty ? "none" : details)"
    }

    // MARK: - Per-App Rules

    /// Zoom: meeting window is large (≥700×450) and NOT the home screen ("Zoom Workplace"/"Zoom").
    private static func zoomInMeeting(_ windows: [WindowSnapshot]) -> Bool {
        windows.contains { w in
            w.width >= 700 && w.height >= 450
            && !isZoomHomeWindow(title: w.title)
        }
    }

    private static func isZoomHomeWindow(title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return title == "Zoom Workplace" || title == "Zoom" || title == "zoom.us"
    }

    /// Teams: during a call, Teams creates a large meeting window plus a compact
    /// call controls overlay. Idle Teams can leave multiple normal windows around
    /// after leaving a meeting, so a large main window alone is not enough.
    private static func teamsInMeeting(_ windows: [WindowSnapshot], calendarTitle: String?) -> Bool {
        let significantWindows = windows.filter(isSignificantWindow(_:))
        guard !significantWindows.isEmpty else { return false }

        if significantWindows.contains(where: { hasTeamsCallKeyword(title: $0.title) }) {
            return true
        }

        if teamsWindowMatchesCalendarTitle(significantWindows, calendarTitle: calendarTitle) {
            return true
        }

        // Structural recognition (no calendar dependency). New-Teams calls no
        // longer spawn a floating control bar, and the real meeting window's
        // title is the meeting name (e.g. "Andy / JY - skip level 121 |
        // Microsoft Teams"), which often does NOT match the in-context calendar
        // event. Recognise a large window whose title ends in
        // " | microsoft teams" but whose first " | " segment is NOT a known
        // main-app tab name and which is not the generic pre-join lobby screen.
        if teamsHasStructuralMeetingWindow(significantWindows) {
            return true
        }

        let largeWindowCount = significantWindows.filter { window in
            window.width >= TeamsTuning.largeWindowMinWidth
            && window.height >= TeamsTuning.largeWindowMinHeight
        }.count

        let controlBarCount = significantWindows.filter(isTeamsControlBarWindow(_:)).count
        return largeWindowCount >= 1 && controlBarCount >= 1
    }

    /// FaceTime: large video window (≥500×400) appears during a call.
    /// Idle FaceTime only shows a small contact list.
    private static func facetimeInMeeting(_ windows: [WindowSnapshot]) -> Bool {
        windows.contains { w in
            w.width >= 500 && w.height >= 400
        }
    }

    /// Webex: similar to Zoom — large meeting window during calls.
    private static func webexInMeeting(_ windows: [WindowSnapshot]) -> Bool {
        windows.contains { w in
            w.width >= 700 && w.height >= 450
        }
    }

    /// Slack: huddle creates an additional overlay window alongside the main window.
    private static func slackInMeeting(_ windows: [WindowSnapshot]) -> Bool {
        let significantWindows = windows.filter { w in
            w.width >= 100 && w.height >= 80
        }
        return significantWindows.count >= 2
    }

    // MARK: - Helpers

    private enum TeamsTuning {
        static let minSignificantWindowCount = 2
        static let significantMinWidth: CGFloat = 120
        static let significantMinHeight: CGFloat = 50
        static let largeWindowMinWidth: CGFloat = 520
        static let largeWindowMinHeight: CGFloat = 320
        static let controlBarMinWidth: CGFloat = 260
        static let controlBarMaxWidth: CGFloat = 1400
        static let controlBarMinHeight: CGFloat = 36
        static let controlBarMaxHeight: CGFloat = 140
        static let calendarTitleMinLength = 8
        static let titleKeywords = [
            "call",
            "webinar",
            "screen share",
            "sharing",
            "present"
        ]
        /// Suffix every Teams window title carries (normalized, lowercase).
        static let titleSuffix = " | microsoft teams"
        /// Generic pre-join lobby title shared by every meeting. Excluded so
        /// sitting on the join screen during a calendar event does not falsely
        /// trigger recording before the user actually joins.
        static let preJoinTitle = "microsoft teams meeting | microsoft teams"
        /// First " | " segment of a main-app window is one of these tab names.
        /// Real meeting windows lead with the meeting name instead, which is
        /// never one of these tokens. Lowercase for case-insensitive matching.
        static let mainAppTabNames: Set<String> = [
            "chat",
            "calendar",
            "activity",
            "teams",
            "calls",
            "files",
            "onedrive",
            "apps"
        ]
    }

    private static func isSignificantWindow(_ window: WindowSnapshot) -> Bool {
        window.width >= TeamsTuning.significantMinWidth
            && window.height >= TeamsTuning.significantMinHeight
    }

    private static func isTeamsControlBarWindow(_ window: WindowSnapshot) -> Bool {
        window.width >= TeamsTuning.controlBarMinWidth
            && window.width <= TeamsTuning.controlBarMaxWidth
            && window.height >= TeamsTuning.controlBarMinHeight
            && window.height <= TeamsTuning.controlBarMaxHeight
    }

    private static func hasTeamsCallKeyword(title: String?) -> Bool {
        guard let normalizedTitle = normalizeTitle(title), !normalizedTitle.isEmpty else {
            return false
        }
        guard !isTeamsMainAppTabTitle(normalizedTitle) else { return false }

        return TeamsTuning.titleKeywords.contains { keyword in
            normalizedTitle.contains(keyword)
        }
    }

    private static func teamsWindowMatchesCalendarTitle(_ windows: [WindowSnapshot], calendarTitle: String?) -> Bool {
        guard let normalizedCalendarTitle = normalizeTitle(calendarTitle),
              normalizedCalendarTitle.count >= TeamsTuning.calendarTitleMinLength else {
            return false
        }

        return windows.contains { window in
            guard window.width >= TeamsTuning.largeWindowMinWidth,
                  window.height >= TeamsTuning.largeWindowMinHeight,
                  let normalizedWindowTitle = normalizeTitle(window.title) else {
                return false
            }

            // Exclude Teams' main-app tabs before matching the event title.
            // Calendar and Chat can both retain the meeting name after the
            // user leaves; treating either as a call window keeps confidence
            // above the auto-stop threshold indefinitely.
            if isTeamsMainAppTabTitle(normalizedWindowTitle)
                || isTeamsChatWindow(title: normalizedWindowTitle) {
                return false
            }

            return normalizedWindowTitle.contains(normalizedCalendarTitle)
        }
    }

    private static func isTeamsChatWindow(title normalized: String) -> Bool {
        normalized.hasPrefix("chat |")
            || normalized.hasPrefix("chat - ")
            || normalized.hasPrefix("chat:")
    }

    /// Structural meeting-window recognition that does NOT depend on a calendar
    /// title or call keywords. A meeting window is a large window whose
    /// normalized title:
    ///   - ends in " | microsoft teams",
    ///   - is not the generic pre-join lobby ("microsoft teams meeting | …"),
    ///   - whose first " | " segment is not a known main-app tab name, and
    ///   - is not a "Chat |" thread window.
    private static func teamsHasStructuralMeetingWindow(_ windows: [WindowSnapshot]) -> Bool {
        windows.contains { window in
            guard window.width >= TeamsTuning.largeWindowMinWidth,
                  window.height >= TeamsTuning.largeWindowMinHeight,
                  let normalized = normalizeTitle(window.title),
                  isTeamsStructuralMeetingTitle(normalized) else {
                return false
            }
            return true
        }
    }

    private static func isTeamsStructuralMeetingTitle(_ normalized: String) -> Bool {
        // Must be a Teams window (suffix), but not the generic lobby screen.
        guard normalized.hasSuffix(TeamsTuning.titleSuffix),
              normalized != TeamsTuning.preJoinTitle else {
            return false
        }
        // Main-app tab windows (Chat / Calendar / Activity …) lead with a known
        // tab name as their first " | " segment. Real meeting windows lead with
        // the meeting name, which is never one of those tokens.
        guard !isTeamsMainAppTabTitle(normalized) else { return false }
        // Defense in depth against chat thread windows whose first segment is a
        // "chat" variant not caught above (e.g. "chat: …").
        guard !isTeamsChatWindow(title: normalized) else {
            return false
        }
        return true
    }

    private static func isTeamsMainAppTabTitle(_ normalized: String) -> Bool {
        guard normalized.hasSuffix(TeamsTuning.titleSuffix) else { return false }
        let firstSegment = normalized
            .components(separatedBy: " | ")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return TeamsTuning.mainAppTabNames.contains(firstSegment)
    }

    private static func normalizeTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let singleLine = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.lowercased()
    }

    private static func describeWindow(_ window: WindowSnapshot) -> String {
        let rawTitle = normalizeTitle(window.title) ?? ""
        let title = rawTitle.isEmpty ? "<empty>" : String(rawTitle.prefix(40))
        return "\(Int(window.width))x\(Int(window.height)):\(title)"
    }

    private static func area(_ window: WindowSnapshot) -> CGFloat {
        window.width * window.height
    }
}
