import Foundation
import Testing

@testable import Cadenza

@Suite("First Launch Onboarding")
struct OnboardingFlowTests {
    @Test func standardRuntimePresentsUntilCurrentVersionCompletes() {
        #expect(FirstLaunchOnboarding.shouldPresent(
            completedVersion: 0,
            startedVersion: FirstLaunchOnboarding.currentVersion,
            allowsOnboarding: true
        ))
        #expect(!FirstLaunchOnboarding.shouldPresent(
            completedVersion: FirstLaunchOnboarding.currentVersion,
            startedVersion: FirstLaunchOnboarding.currentVersion,
            allowsOnboarding: true
        ))
        #expect(!FirstLaunchOnboarding.shouldPresent(
            completedVersion: FirstLaunchOnboarding.currentVersion + 1,
            startedVersion: FirstLaunchOnboarding.currentVersion,
            allowsOnboarding: true
        ))
    }

    @Test func nonstandardRuntimesNeverPresent() {
        #expect(!FirstLaunchOnboarding.shouldPresent(
            completedVersion: 0,
            startedVersion: FirstLaunchOnboarding.currentVersion,
            allowsOnboarding: false
        ))
    }

    @Test func existingInstallNeverPresentsOnlyBecauseCompletionKeyIsMissing() {
        #expect(!FirstLaunchOnboarding.shouldPresent(
            completedVersion: 0,
            startedVersion: 0,
            allowsOnboarding: true
        ))
    }

    @Test func interruptedFreshInstallResumesOnNextLaunch() {
        #expect(FirstLaunchOnboarding.shouldPresent(
            completedVersion: 0,
            startedVersion: FirstLaunchOnboarding.currentVersion,
            allowsOnboarding: true
        ))
    }

    @Test func eligibilityIsRecordedOnlyForAnEmptyPreBootstrapInstallation() {
        #expect(FirstLaunchOnboarding.shouldRecordStartedVersion(
            completedVersion: 0,
            startedVersion: 0,
            hasPriorInstallationEvidence: false
        ))
        #expect(!FirstLaunchOnboarding.shouldRecordStartedVersion(
            completedVersion: 0,
            startedVersion: 0,
            hasPriorInstallationEvidence: true
        ))
        #expect(!FirstLaunchOnboarding.shouldRecordStartedVersion(
            completedVersion: FirstLaunchOnboarding.currentVersion,
            startedVersion: 0,
            hasPriorInstallationEvidence: false
        ))
    }

    @Test func installEvidenceProbeFailsClosedAndCoversThePreLegacyStore() {
        let paths = ProfilePaths(root: URL(fileURLWithPath: "/tmp/onboarding-evidence"))
        let missing: (URL) throws -> Void = { _ in
            throw CocoaError(.fileReadNoSuchFile)
        }
        #expect(!ProfileBootstrap.hasPriorInstallationEvidence(paths: paths, probe: missing))

        #expect(ProfileBootstrap.hasPriorInstallationEvidence(paths: paths) { url in
            if url == paths.preLegacyStoreURL { return }
            throw CocoaError(.fileReadNoSuchFile)
        })
        #expect(ProfileBootstrap.hasPriorInstallationEvidence(paths: paths) { _ in
            throw CocoaError(.fileReadNoPermission)
        })
    }

    @Test func appUpdateControllerUsesTheRootDefaultsBoundary() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains(
            "AppUpdateController(\n        defaults: CadenzaApp.rootAppStorageDefaults"
        ))
    }

    @Test func completionKeyIsDeviceLevel() throws {
        let profileInventory = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Services/Profiles/ProfileScopedDefaults.swift"
            ),
            encoding: .utf8
        )

        #expect(!profileInventory.contains(FirstLaunchOnboarding.completionVersionKey))
        #expect(!profileInventory.contains(FirstLaunchOnboarding.startedVersionKey))
    }

    @Test func onboardingUsesExistingMeetingDetectionAuthority() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("appState.setMeetingDetectionEnabled("))
        #expect(appSource.contains("FirstLaunchOnboarding.currentVersion"))
    }

    @Test func onboardingPrioritizesPermissionsInsteadOfAnUpdatePage() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Views/Onboarding/FirstLaunchOnboardingView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("case recordingPermissions"))
        #expect(source.contains("case meetingTools"))
        #expect(source.contains("Permissions.requestMicrophone()"))
        #expect(source.contains("appState.prepareSystemAudioCapture()"))
        #expect(source.contains("Permissions.requestScreenRecordingAccess()"))
        #expect(source.contains("Permissions.requestAccessibility()"))
        #expect(source.contains("@AccessibilityFocusState private var pageTitleIsFocused"))
        #expect(source.contains(".accessibilityFocused($pageTitleIsFocused)"))
        #expect(source.contains(".accessibilityElement(children: .ignore)"))
        #expect(source.contains(".accessibilityLabel(title)"))
        #expect(!source.contains("case updates"))
        #expect(!source.contains("private var updatesPage"))
        #expect(!source.contains("automaticUpdateChecksEnabled"))
        #expect(!source.contains("Button(text(\"Not Now\"))"))
    }

    @Test func permissionCopyTreatsScreenRecordingAsAnOptionalReliabilityBoost() throws {
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(!settingsSource.contains("Required for reliable Teams auto-start and auto-stop."))
        #expect(settingsSource.contains("No screen image is recorded."))
        #expect(settingsSource.contains(
            "requestAttempted ? text(\"Open Settings\") : text(\"Allow global shortcuts\")"
        ))
    }

    @Test func permissionPromptsRemainBehindExplicitButtons() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Views/Onboarding/FirstLaunchOnboardingView.swift"
            ),
            encoding: .utf8
        )

        let microphoneAction = try #require(source.range(of: "private func requestMicrophone()"))
        let systemAudioAction = try #require(source.range(of: "private func prepareSystemAudio()"))
        let screenAction = try #require(source.range(of: "private func requestScreenRecording()"))
        let accessibilityAction = try #require(source.range(of: "private func requestAccessibility()"))

        #expect(microphoneAction.lowerBound < systemAudioAction.lowerBound)
        #expect(systemAudioAction.lowerBound < screenAction.lowerBound)
        #expect(screenAction.lowerBound < accessibilityAction.lowerBound)
        #expect(source[..<microphoneAction.lowerBound].contains("requestMicrophone()"))
        #expect(source[..<systemAudioAction.lowerBound].contains("prepareSystemAudio()"))
        #expect(source[..<screenAction.lowerBound].contains("requestScreenRecording()"))
        #expect(source[..<accessibilityAction.lowerBound].contains("requestAccessibility()"))
        #expect(source.contains("onboarding.microphone"))
        #expect(source.contains("onboarding.systemAudio"))
        #expect(source.contains("onboarding.screenRecording"))
        #expect(source.contains("onboarding.accessibility"))
    }

    @Test func brandRevealUsesTheRealAppIconAndRespectsReduceMotion() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Views/Onboarding/OnboardingBrandReveal.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("AppIconArtwork(variant: variant)"))
        #expect(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(source.contains("guard !isRevealed else { return }"))
    }

    @Test func microphoneChoiceIsPersistedWithoutMutatingUpdatePreference() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let completion = try #require(appSource.range(of: "private func completeOnboarding"))
        let completionSource = String(appSource[completion.lowerBound...])

        #expect(completionSource.contains("choices.captureMicrophoneEnabled"))
        #expect(completionSource.contains("forKey: \"captureMicrophone\""))
        #expect(!completionSource.prefix(900).contains(
            "setAutomaticallyChecksForUpdates"
        ))
    }

    @Test func completionIsPersistedBeforeAccountBindingCanRelaunch() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let completionWrite = try #require(
            appSource.range(of: "onboardingCompletedVersion = FirstLaunchOnboarding.currentVersion")
        )
        let coordinatorCreation = try #require(
            appSource.range(of: "appState.makeProfileLoginCoordinator()")
        )

        #expect(completionWrite.lowerBound < coordinatorCreation.lowerBound)
    }

    @Test func updateChecksAreGatedByExternalAccessPolicy() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("guard appState.startupPolicy.externalAccessEnabled"))
        #expect(appSource.contains("await updateController.monitorAutomaticChecks()"))
    }

    @Test func visualPreviewOverrideRequiresTheIsolatedDataRoot() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Cadenza/Views/Onboarding/FirstLaunchOnboardingView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("DebugDataRoot.isActive"))
        #expect(source.contains("CADENZA_PREVIEW_ONBOARDING"))
    }

    @Test func onboardingCopyCoversEverySupportedLocale() throws {
        let resources = repositoryRoot.appendingPathComponent("Cadenza/Resources")
        let locales = ["zh-Hans", "ja", "ko", "fr", "de", "es"]
        var expectedKeys: Set<String>?

        for locale in locales {
            let data = try Data(contentsOf: resources.appendingPathComponent(
                "\(locale).lproj/Onboarding.strings"
            ))
            let values = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: String]
            )
            #expect(values.values.allSatisfy { !$0.isEmpty })
            if let expectedKeys {
                #expect(Set(values.keys) == expectedKeys, "\(locale) key coverage drifted")
            } else {
                expectedKeys = Set(values.keys)
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
