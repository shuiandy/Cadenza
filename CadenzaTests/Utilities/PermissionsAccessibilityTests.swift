import Foundation
import Testing
@testable import Cadenza

@Suite("Accessibility permission policy")
struct PermissionsAccessibilityTests {
    @Test func accessibilityStatusNeverInventsADeniedState() {
        #expect(Permissions.accessibilityStatus(isTrusted: true) == .granted)
        #expect(Permissions.accessibilityStatus(isTrusted: false) == .notDetermined)
    }

    @Test func screenRecordingStatusUsesTheSameObservableBoundary() {
        #expect(Permissions.screenRecordingStatus(hasAccess: true) == .granted)
        #expect(Permissions.screenRecordingStatus(hasAccess: false) == .notDetermined)
    }

    @Test func screenRecordingRequestRemainsSeparateFromPromptFreePreflight() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Utilities/Permissions.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("static func requestScreenRecordingAccess() -> Bool"))
        #expect(source.contains("return CGRequestScreenCaptureAccess()"))
        #expect(source.contains("static func checkScreenRecording() async -> Bool"))
    }

    @Test func trustedAccessibilitySkipsThePrompt() {
        var promptCount = 0

        let result = Permissions.requestAccessibility(currentStatus: .granted) {
            promptCount += 1
            return false
        }

        #expect(result)
        #expect(promptCount == 0)
    }

    @Test func unresolvedAccessibilityUsesTheUserInitiatedPrompt() {
        var promptCount = 0

        let result = Permissions.requestAccessibility(currentStatus: .notDetermined) {
            promptCount += 1
            return true
        }

        #expect(result)
        #expect(promptCount == 1)
    }

    @Test func deniedCompatibilityStateAlsoOffersRecovery() {
        #expect(Permissions.accessibilityAction(for: .denied) == .requestAccess)
    }

    @Test func accessibilitySettingsPreferTheModernPrivacyPaneWithFallbacks() {
        #expect(
            Permissions.accessibilitySettingsURLStrings.first
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        #expect(Permissions.accessibilitySettingsURLStrings.contains {
            $0 == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        })
        #expect(
            Permissions.accessibilitySettingsURLStrings.last
                == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        )
        #expect(Permissions.accessibilitySettingsURLStrings.allSatisfy {
            URL(string: $0) != nil
        })
    }
}
