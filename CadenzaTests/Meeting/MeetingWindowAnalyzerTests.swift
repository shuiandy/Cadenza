import Testing
@testable import Cadenza

@Suite("MeetingWindowAnalyzer")
struct MeetingWindowAnalyzerTests {

    private func snapshot(
        title: String?,
        width: Double,
        height: Double,
        isOnScreen: Bool = true
    ) -> MeetingWindowAnalyzer.WindowSnapshot {
        MeetingWindowAnalyzer.WindowSnapshot(
            title: title,
            width: width,
            height: height,
            isOnScreen: isOnScreen
        )
    }

    @Test func teams_idleSingleWindow_isNotMeeting() {
        let windows = [
            snapshot(title: "Microsoft Teams", width: 1697, height: 1060)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_largeWindowPlusControlBar_isMeeting() {
        let windows = [
            snapshot(title: "Microsoft Teams", width: 1320, height: 880),
            snapshot(title: nil, width: 720, height: 80)
        ]

        #expect(MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_largeWindowPlusGenericSecondWindow_isNotMeeting() {
        let windows = [
            snapshot(title: "Microsoft Teams", width: 1320, height: 880),
            snapshot(title: "Chat", width: 420, height: 300)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_keywordWindow_isMeetingEvenSingleWindow() {
        let windows = [
            snapshot(title: "Weekly Call - Microsoft Teams", width: 980, height: 760)
        ]

        #expect(MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_calendarTitleWindow_isMeeting() {
        let windows = [
            snapshot(
                title: "Shift Left Standup (Europe/North America) | Acme | person@example.com | Microsoft Teams",
                width: 1689,
                height: 1056
            ),
            snapshot(
                title: "Chat | ProdSec Shift Left | Acme | person@example.com | Microsoft Teams",
                width: 1708,
                height: 1008
            )
        ]

        #expect(MeetingWindowAnalyzer.hasMeetingWindow(
            app: .teams,
            snapshots: windows,
            calendarTitle: "Shift Left Standup (Europe/North America)"
        ))
    }

    @Test func teams_meetingChatTitleAlone_isNotMeeting() {
        let windows = [
            snapshot(title: "Weekly Meeting - Microsoft Teams", width: 980, height: 760)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    /// Teams keeps a chat tab titled `Chat | <meeting name>` open after
    /// the user leaves a call. That title contains the calendar event's
    /// name, so a naive `windowTitle.contains(calendarTitle)` check would
    /// classify the chat as an active call window and falsely keep
    /// auto-record alive. The analyzer must reject "Chat |" prefixes
    /// from the calendar-title-match path.
    @Test func teams_meetingChatWithCalendarTitle_isNotMeeting() {
        let windows = [
            snapshot(
                title: "Chat | Shift Left Standup (Europe/North America) | Acme | person@example.com | Microsoft Teams",
                width: 1708,
                height: 1008
            )
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(
            app: .teams,
            snapshots: windows,
            calendarTitle: "Shift Left Standup (Europe/North America)"
        ))
    }

    /// Regression for the 2026-07-16 auto-stop failure: after hang-up,
    /// Teams retained a Calendar tab containing the active event title.
    /// Calendar-title matching must not turn that main-app tab back into a
    /// meeting window.
    @Test func teams_calendarMainWindowWithCalendarTitle_isNotMeeting() {
        let windows = [
            snapshot(
                title: "Calendar | Shift Left Standup (Europe/North America) | NIQ | person@example.com | Microsoft Teams",
                width: 1707,
                height: 1005
            )
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(
            app: .teams,
            snapshots: windows,
            calendarTitle: "Shift Left Standup (Europe/North America)"
        ))
    }

    @Test func teams_calendarMainWindowContainingCallKeyword_isNotMeeting() {
        let windows = [
            snapshot(
                title: "Calendar | Customer Call | Microsoft Teams",
                width: 1707,
                height: 1005
            )
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(
            app: .teams,
            snapshots: windows,
            calendarTitle: "Customer Call"
        ))
    }

    @Test func teams_smallTransientWindows_doNotTrigger() {
        let windows = [
            snapshot(title: nil, width: 110, height: 40),
            snapshot(title: nil, width: 118, height: 42)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    // MARK: - Structural meeting-window recognition (no calendar match)

    /// Regression for the 2026-06-09 "Global Security Town Hall" miss: the real
    /// meeting window's title is the event name, which did NOT match the
    /// in-context calendar event title. New-Teams calls also no longer spawn a
    /// floating control bar, so neither the keyword path, the control-bar path,
    /// nor the calendar-title path fire. Structural recognition must catch it:
    /// a large window whose title ends in " | microsoft teams" and whose first
    /// " | " segment is NOT a known Teams tab name is a meeting window.
    @Test func teams_townHallWindowWithoutCalendarMatch_isMeetingByStructure() {
        let windows = [
            snapshot(
                title: "Global Security Town Hall - Quarterly (2026) | Microsoft Teams",
                width: 1689,
                height: 1056
            )
        ]

        #expect(MeetingWindowAnalyzer.hasMeetingWindow(
            app: .teams,
            snapshots: windows,
            calendarTitle: "Some Unrelated Daily Standup"
        ))
    }

    @Test func teams_skipLevelMeetingWindow_isMeetingByStructure() {
        let windows = [
            snapshot(
                title: "Andy / JY - skip level 121 | Microsoft Teams",
                width: 1689,
                height: 1056
            )
        ]

        #expect(MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    /// The pre-join lobby window uses a generic title shared by every meeting.
    /// It must NOT count as a meeting window — otherwise being parked on the
    /// join screen during a calendar event window would trigger recording before
    /// the user actually joins.
    @Test func teams_preJoinGenericScreen_isNotMeeting() {
        let windows = [
            snapshot(
                title: "Microsoft Teams meeting | Microsoft Teams",
                width: 1689,
                height: 1056
            )
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    /// Main-app tab windows (Chat / Calendar / Activity …) are NOT meetings.
    /// Their first " | " segment is a known tab name, so structural recognition
    /// must reject them even though they end in " | microsoft teams".
    @Test func teams_chatMainWindow_isNotMeetingByStructure() {
        let windows = [
            snapshot(
                title: "Chat | ProdSec Shift Left | Microsoft Teams",
                width: 1708,
                height: 960
            )
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_calendarMainWindow_isNotMeetingByStructure() {
        let windows = [
            snapshot(title: "Calendar | ProdSec Shift Left | Microsoft Teams", width: 1708, height: 960),
            snapshot(title: "Calendar | Microsoft Teams", width: 1708, height: 960)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_activityTab_isNotMeetingByStructure() {
        let windows = [
            snapshot(title: "Activity | Microsoft Teams", width: 1708, height: 960)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func teams_callsMainWindow_isNotMeeting() {
        let windows = [
            snapshot(title: "Calls | Microsoft Teams", width: 1708, height: 960)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    /// A small (sub-threshold) window with a non-tab title must not trigger via
    /// the structural path — guards against tooltips / transient popovers that
    /// happen to carry an unusual title.
    @Test func teams_smallNonTabWindow_isNotMeetingByStructure() {
        let windows = [
            snapshot(title: "Andy / JY - skip level 121 | Microsoft Teams", width: 400, height: 200)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .teams, snapshots: windows))
    }

    @Test func zoom_homeWindow_doesNotTrigger() {
        let windows = [
            snapshot(title: "Zoom Workplace", width: 900, height: 700)
        ]

        #expect(!MeetingWindowAnalyzer.hasMeetingWindow(app: .zoom, snapshots: windows))
    }

    @Test func zoom_meetingWindow_triggers() {
        let windows = [
            snapshot(title: "Design Review", width: 1100, height: 760)
        ]

        #expect(MeetingWindowAnalyzer.hasMeetingWindow(app: .zoom, snapshots: windows))
    }
}
