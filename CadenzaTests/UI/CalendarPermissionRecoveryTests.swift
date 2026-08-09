import Foundation
import Testing
@testable import Cadenza

@Suite("Calendar Permission Recovery")
struct CalendarPermissionRecoveryTests {
    @Test func gainingCalendarAccessChangesTheVisibleCalendarReloadKey() {
        let denied = CalendarContentReloadKey(
            dateRange: "2026-08-09-week",
            hasCalendarPermission: false
        )
        let granted = CalendarContentReloadKey(
            dateRange: "2026-08-09-week",
            hasCalendarPermission: true
        )

        #expect(denied != granted)
    }

    @Test func deniedCalendarPermissionRoutesToSystemSettings() {
        #expect(Permissions.calendarRecoveryAction(for: .denied) == .openSettings)
        #expect(Permissions.calendarRecoveryAction(for: .notDetermined) == .requestAccess)
        #expect(Permissions.calendarRecoveryAction(for: .granted) == .alreadyGranted)
        #expect(Permissions.calendarSettingsURLStrings.contains {
            $0.contains("Privacy_Calendars")
        })
    }

    @Test func bothCalendarConnectionSurfacesUseTheRecoveryBoundary() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let connections = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Cadenza/Views/Settings/ConnectionsSection.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Cadenza/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: projectRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: projectRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let calendar = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Cadenza/Views/Calendar/CalendarContainerView.swift"),
            encoding: .utf8
        )

        #expect(connections.contains("Permissions.requestOrRecoverCalendarAccess("))
        #expect(settings.contains("Permissions.requestOrRecoverCalendarAccess("))
        #expect(connections.contains("appState.calendarPermissionStatus == .denied"))
        #expect(settings.contains("appState.calendarPermissionStatus == .denied"))
        #expect(appState.contains("calendarPermissionStatus = calendarStatus"))
        #expect(appState.contains("return !previouslyHadCalendarPermission && hasCalendarPermission"))
        #expect(appState.contains("func checkPermissionsAndRefreshCalendarIfNeeded() async"))
        #expect(appState.contains("refreshCalendars()"))
        #expect(app.contains("func applicationDidBecomeActive"))
        #expect(app.contains("if appState.startupPolicy.checksPermissions"))
        #expect(app.contains("await appState.checkPermissionsAndRefreshCalendarIfNeeded()"))
        #expect(connections.contains("await appState.checkPermissionsAndRefreshCalendarIfNeeded()"))
        #expect(settings.contains("await appState.checkPermissionsAndRefreshCalendarIfNeeded()"))
        #expect(calendar.contains(".task(id: calendarContentReloadKey)"))
        #expect(calendar.contains("hasCalendarPermission: appState.hasCalendarPermission"))
    }
}
