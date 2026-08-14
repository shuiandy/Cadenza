import Foundation
import Testing
@testable import Cadenza

@Suite("AppState Permission Refresh")
struct AppStatePermissionTests {
    @Test func accessibilityRefreshUsesOnlyTheUntrustedToTrustedEdge() {
        #expect(!AppState.accessibilityPermissionWasGranted(
            previouslyGranted: false,
            currentStatus: .notDetermined
        ))
        #expect(!AppState.accessibilityPermissionWasGranted(
            previouslyGranted: false,
            currentStatus: .denied
        ))
        #expect(AppState.accessibilityPermissionWasGranted(
            previouslyGranted: false,
            currentStatus: .granted
        ))
        #expect(!AppState.accessibilityPermissionWasGranted(
            previouslyGranted: true,
            currentStatus: .granted
        ))
        #expect(!AppState.accessibilityPermissionWasGranted(
            previouslyGranted: true,
            currentStatus: .notDetermined
        ))
    }

    @Test func accessibilityPermissionIsVisibleAppState() throws {
        let source = try appStateSource()

        #expect(source.contains("var hasAccessibilityPermission: Bool = false"))
        #expect(source.contains("let accessibilityStatus = Permissions.accessibilityStatus"))
        #expect(source.contains("hasAccessibilityPermission = accessibilityStatus == .granted"))
    }

    @Test func accessibilityGrantRefreshesOnlyAnExistingHotkeyRegistration() throws {
        let source = try appStateSource()
        let checkPermissions = try #require(source.range(of: "func checkPermissions() async"))
        let permissionEdge = try #require(source.range(
            of: "let accessibilityWasGranted = Self.accessibilityPermissionWasGranted(",
            range: checkPermissions.upperBound..<source.endIndex
        ))
        let refreshCall = try #require(source.range(
            of: "refreshGlobalHotkeysForAccessibility()",
            range: permissionEdge.upperBound..<source.endIndex
        ))
        #expect(permissionEdge.lowerBound < refreshCall.lowerBound)

        let refreshFunction = try #require(source.range(
            of: "func refreshGlobalHotkeysForAccessibility()"
        ))
        let registrationGuard = try #require(source.range(
            of: "areGlobalHotkeysRegistered else { return }",
            range: refreshFunction.upperBound..<source.endIndex
        ))
        let removeTokens = try #require(source.range(
            of: "removeGlobalHotkeyMonitorTokens()",
            range: refreshFunction.upperBound..<source.endIndex
        ))
        let registerAgain = try #require(source.range(
            of: "registerGlobalHotkeys()",
            range: removeTokens.upperBound..<source.endIndex
        ))
        #expect(registrationGuard.lowerBound < removeTokens.lowerBound)
        #expect(removeTokens.lowerBound < registerAgain.lowerBound)
    }

    @Test func hotkeyRegistrationAndRemovalAreIdempotent() throws {
        let source = try appStateSource()
        let registerFunction = try #require(source.range(of: "private func registerGlobalHotkeys()"))
        let idempotenceGuard = try #require(source.range(
            of: "!areGlobalHotkeysRegistered else { return }",
            range: registerFunction.upperBound..<source.endIndex
        ))
        let registerGlobal = try #require(source.range(
            of: "NSEvent.addGlobalMonitorForEvents",
            range: registerFunction.upperBound..<source.endIndex
        ))
        #expect(idempotenceGuard.lowerBound < registerGlobal.lowerBound)

        let removeFunction = try #require(source.range(of: "func removeGlobalHotkeys()"))
        let clearsLifecycle = try #require(source.range(
            of: "areGlobalHotkeysRegistered = false",
            range: removeFunction.upperBound..<source.endIndex
        ))
        #expect(removeFunction.lowerBound < clearsLifecycle.lowerBound)
    }

    @Test func systemAudioPreparationReportsWhetherSetupSucceeded() throws {
        let source = try appStateSource()
        let function = try #require(source.range(
            of: "func prepareSystemAudioCapture() async -> Bool"
        ))
        let hardwareGuard = try #require(source.range(
            of: "guard startupPolicy.allowsHardwareCapture else { return false }",
            range: function.upperBound..<source.endIndex
        ))
        let success = try #require(source.range(
            of: "return true",
            range: hardwareGuard.upperBound..<source.endIndex
        ))
        let errorPresentation = try #require(source.range(
            of: "recordingEngine.presentStartError(error)",
            range: success.upperBound..<source.endIndex
        ))
        let failure = try #require(source.range(
            of: "return false",
            range: errorPresentation.upperBound..<source.endIndex
        ))

        #expect(hardwareGuard.lowerBound < success.lowerBound)
        #expect(success.lowerBound < errorPresentation.lowerBound)
        #expect(errorPresentation.lowerBound < failure.lowerBound)
    }

    private func appStateSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
    }
}
