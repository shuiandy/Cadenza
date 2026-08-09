import Foundation
import UserNotifications

/// Monitors calendar and meeting apps to auto-start recording.
@Observable @MainActor
final class AutoRecordScheduler {
    private let calendarManager: CalendarManager
    private let meetingDetector: MeetingDetector
    private var checkTimer: Timer?

    private(set) var isEnabled = false
    private(set) var pendingMeeting: MeetingEvent?

    /// Called when auto-record should start
    var onShouldStartRecording: ((MeetingEvent) -> Void)?

    init(calendarManager: CalendarManager, meetingDetector: MeetingDetector) {
        self.calendarManager = calendarManager
        self.meetingDetector = meetingDetector
    }

    // MARK: - Enable/Disable

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        // Check every 30 seconds
        checkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpcomingMeetings()
            }
        }

        // Initial check
        checkForUpcomingMeetings()
    }

    func disable() {
        isEnabled = false
        checkTimer?.invalidate()
        checkTimer = nil
        pendingMeeting = nil
    }

    // MARK: - Check Logic

    private func checkForUpcomingMeetings() {
        let leadTime = UserDefaults.standard.integer(forKey: "autoRecordLeadTime")

        // Find next meeting starting soon
        guard let meeting = calendarManager.nextMeetingStartingSoon(withinMinutes: max(leadTime, 1)) else {
            pendingMeeting = nil
            return
        }

        // Avoid re-triggering for the same meeting
        if pendingMeeting?.id == meeting.id { return }

        // Check if corresponding meeting app is running (if we know which app)
        if let meetingApp = meeting.meetingApp {
            let appRunning = meetingDetector.runningMeetingApps.contains { $0.app == meetingApp }
            if appRunning || meeting.isHappening {
                pendingMeeting = meeting
                onShouldStartRecording?(meeting)
                sendNotification(for: meeting)
            }
        } else if meeting.isHappening && !meetingDetector.runningMeetingApps.isEmpty {
            // Meeting is happening and some meeting app is running
            pendingMeeting = meeting
            onShouldStartRecording?(meeting)
            sendNotification(for: meeting)
        }
    }

    private func sendNotification(for meeting: MeetingEvent) {
        let content = UNMutableNotificationContent()
        // UNMutableNotificationContent takes plain String rather than a
        // LocalizedStringKey, so notification copy must resolve explicitly.
        content.title = String(localized: "Auto-recording started")
        content.body = String(localized: "Recording “\(meeting.title)”")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "autoRecord-\(meeting.id)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
