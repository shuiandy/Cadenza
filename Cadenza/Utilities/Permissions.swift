import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit

enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

enum CalendarPermissionRecoveryAction: Equatable, Sendable {
    case alreadyGranted
    case requestAccess
    case openSettings
}

enum AccessibilityPermissionAction: Equatable, Sendable {
    case alreadyGranted
    case requestAccess
}

enum Permissions {
    // MARK: - Microphone

    static var microphoneStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Screen Recording

    /// CoreGraphics exposes only whether access is currently available.
    /// A false result cannot distinguish a denial from a first-time request.
    static var screenRecordingStatus: PermissionStatus {
        screenRecordingStatus(hasAccess: CGPreflightScreenCaptureAccess())
    }

    static func screenRecordingStatus(hasAccess: Bool) -> PermissionStatus {
        hasAccess ? .granted : .notDetermined
    }

    static func checkScreenRecording() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests Screen Recording from an explicit foreground user action.
    /// Background meeting detection continues to use the prompt-free preflight
    /// above and must never call this API on its own.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    /// Check screen recording permission. Opens System Settings if not granted.
    /// Never calls CGRequestScreenCaptureAccess() to avoid unexpected TCC prompts.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        openScreenRecordingSettings()
        return false
    }

    // MARK: - Accessibility

    /// Accessibility does not expose separate denied and not-determined states.
    /// Reading this value never displays the system authorization prompt.
    static var accessibilityStatus: PermissionStatus {
        accessibilityStatus(isTrusted: AXIsProcessTrusted())
    }

    static func accessibilityStatus(isTrusted: Bool) -> PermissionStatus {
        isTrusted ? .granted : .notDetermined
    }

    static func accessibilityAction(
        for status: PermissionStatus
    ) -> AccessibilityPermissionAction {
        status == .granted ? .alreadyGranted : .requestAccess
    }

    /// Requests Accessibility access only from an explicit user action.
    /// The status getter above intentionally remains prompt-free.
    @discardableResult
    static func requestAccessibility() -> Bool {
        requestAccessibility(currentStatus: accessibilityStatus) {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    }

    @discardableResult
    static func requestAccessibility(
        currentStatus: PermissionStatus,
        prompt: () -> Bool
    ) -> Bool {
        switch accessibilityAction(for: currentStatus) {
        case .alreadyGranted:
            return true
        case .requestAccess:
            return prompt()
        }
    }

    // MARK: - Calendar

    static func calendarStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        case .writeOnly: .denied
        @unknown default: .notDetermined
        }
    }

    static func requestCalendar() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    static func calendarRecoveryAction(
        for status: PermissionStatus
    ) -> CalendarPermissionRecoveryAction {
        switch status {
        case .granted: .alreadyGranted
        case .notDetermined: .requestAccess
        case .denied: .openSettings
        }
    }

    /// EventKit does not present its authorization sheet again after a denial.
    /// Route that state to System Settings instead of offering a button that
    /// can only fail silently.
    @discardableResult
    static func requestOrRecoverCalendarAccess(
        currentStatus: PermissionStatus
    ) async -> Bool {
        switch calendarRecoveryAction(for: currentStatus) {
        case .alreadyGranted:
            return true
        case .requestAccess:
            return await requestCalendar()
        case .openSettings:
            openCalendarSettings()
            return false
        }
    }

    // MARK: - Open System Settings

    /// System Settings deep links are undocumented and may change. Keep modern
    /// routes first, with older combined-pane and general-settings fallbacks.
    static let systemAudioRecordingSettingsURLStrings = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
    ]

    static let screenRecordingSettingsURLStrings = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    ]

    static let calendarSettingsURLStrings = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
    ]

    static let accessibilitySettingsURLStrings = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
    ]

    static func openSystemAudioRecordingSettings() {
        openSettings(urlStrings: systemAudioRecordingSettingsURLStrings)
    }

    static func openScreenRecordingSettings() {
        openSettings(urlStrings: screenRecordingSettingsURLStrings)
    }

    static func openAccessibilitySettings() {
        openSettings(urlStrings: accessibilitySettingsURLStrings)
    }

    private static func openSettings(urlStrings: [String]) {
        for urlString in urlStrings {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let settingsURL = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCalendarSettings() {
        openSettings(urlStrings: calendarSettingsURLStrings)
    }
}
