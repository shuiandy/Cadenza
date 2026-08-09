import Foundation
import CoreServices
import Testing
import os

@testable import Cadenza

@Suite("App Launch Behavior")
struct AppLaunchBehaviorTests {
    @MainActor
    @Test func invalidDebugRootHaltsBeforeLiveBootResolution() {
        var liveResolverCalled = false
        let plan = CadenzaApp.resolveBootPlan(
            debugConfiguration: .invalid(reason: "unsafe fixture configuration"),
            resolveLive: {
                liveResolverCalled = true
                return .run(nil)
            }
        )

        #expect(!liveResolverCalled)
        guard case .halted(let reason) = plan else {
            Issue.record("invalid debug configuration did not halt")
            return
        }
        #expect(reason == "unsafe fixture configuration")
        #expect(!CadenzaApp.rootAppStorageUsesSharedDefaults(
            debugConfiguration: .invalid(reason: "unsafe fixture configuration")
        ))
        #expect(CadenzaApp.rootAppStorageUsesSharedDefaults(debugConfiguration: .inactive))
    }

    @MainActor
    @Test func validDebugRootBypassesLiveBootAndSelectsFixturePlan() {
        let root = URL(fileURLWithPath: "/tmp/cadenza-isolated", isDirectory: true)
        let fixedHome = root.appendingPathComponent("home", isDirectory: true)
        var liveResolverCalled = false
        let plan = CadenzaApp.resolveBootPlan(
            debugConfiguration: .isolated(
                root: root,
                fixedUserHome: fixedHome
            ),
            resolveLive: {
                liveResolverCalled = true
                return .halted(reason: "must not run")
            }
        )

        #expect(!liveResolverCalled)
        guard case .isolatedFixture(let acceptedRoot) = plan else {
            Issue.record("valid debug configuration did not select fixture runtime")
            return
        }
        #expect(acceptedRoot == root)
        #expect(CadenzaApp.rootAppStorageUsesSharedDefaults(
            debugConfiguration: .isolated(root: root, fixedUserHome: fixedHome)
        ))
    }

    @MainActor
    @Test func isolatedFixtureStartupPolicyIsLocalOnly() {
        let policy = AppState.StartupPolicy.resolve(
            isRunningTests: false,
            isolatedDataRootIsActive: true
        )

        #expect(policy == .isolatedFixture)
        #expect(policy.loadsFixtureLibrary)
        #expect(!policy.externalAccessEnabled)
        #expect(!policy.startsWebSyncAutomatically)
        #expect(!policy.configuresMeetingPrep)
        #expect(!policy.configuresMarkdownMirror)
        #expect(!policy.inspectsCredentialStore)
        #expect(!policy.checksPermissions)
        #expect(!policy.startsMCP)
        #expect(!policy.startsCalendarMonitoring)
        #expect(!policy.startsMeetingDetection)
        #expect(!policy.registersGlobalHotkeys)
        #expect(!policy.performsAutomaticMaintenance)
        #expect(!policy.performsAutomaticGeneration)
        #expect(!policy.allowsContentGeneration)
        #expect(!policy.allowsHardwareCapture)
    }

    @Test func meetingDetectionIsOptInAndPreservesAnExistingChoice() throws {
        let suiteName = "AppLaunchBehaviorTests.meetingDetection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!AppState.meetingDetectionEnabled(in: defaults))

        defaults.register(defaults: ["enableMeetingDetection": false])
        #expect(!AppState.meetingDetectionEnabled(in: defaults))

        defaults.set(true, forKey: "enableMeetingDetection")
        defaults.register(defaults: ["enableMeetingDetection": false])
        #expect(AppState.meetingDetectionEnabled(in: defaults))

        defaults.set(false, forKey: "enableMeetingDetection")
        #expect(!AppState.meetingDetectionEnabled(in: defaults))
    }

    @Test func meetingDetectionDefaultsFailClosedAtEveryPreferenceEntrypoint() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let menuBar = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/MenuBar/MenuBarView.swift"),
            encoding: .utf8
        )

        #expect(app.contains("\"enableMeetingDetection\": false"))
        #expect(!app.contains("\"enableMeetingDetection\": true"))
        #expect(appState.contains(
            "defaults.object(forKey: \"enableMeetingDetection\") as? Bool ?? false"
        ))
        #expect(!appState.contains(
            "defaults.object(forKey: \"enableMeetingDetection\") as? Bool ?? true"
        ))
        #expect(settings.contains(
            "@AppStorage(\"enableMeetingDetection\") private var enableMeetingDetection = false"
        ))
        #expect(menuBar.contains(
            "@AppStorage(\"enableMeetingDetection\") private var enableMeetingDetection = false"
        ))
        #expect(settings.contains("appState.setMeetingDetectionEnabled(newValue)"))
        #expect(menuBar.contains("appState.setMeetingDetectionEnabled(newValue)"))
    }

    @Test func testAndIsolatedStartupPoliciesNeverStartMeetingDetection() {
        let testHost = AppState.StartupPolicy.resolve(
            isRunningTests: true,
            isolatedDataRootIsActive: false
        )
        let isolatedFixture = AppState.StartupPolicy.resolve(
            isRunningTests: false,
            isolatedDataRootIsActive: true
        )

        #expect(testHost == .testHost)
        #expect(!testHost.startsMeetingDetection)
        #expect(isolatedFixture == .isolatedFixture)
        #expect(!isolatedFixture.startsMeetingDetection)
    }

    @Test func primaryToolbarItemIsOmittedWhenItWouldHaveNoContent() {
        #expect(!MainWindowToolbarPolicy.showsPrimaryAction(
            isRecording: false,
            hasStatusPhase: false,
            allowsHardwareCapture: false
        ))
        #expect(MainWindowToolbarPolicy.showsPrimaryAction(
            isRecording: true,
            hasStatusPhase: false,
            allowsHardwareCapture: false
        ))
        #expect(MainWindowToolbarPolicy.showsPrimaryAction(
            isRecording: false,
            hasStatusPhase: true,
            allowsHardwareCapture: false
        ))
        #expect(MainWindowToolbarPolicy.showsPrimaryAction(
            isRecording: false,
            hasStatusPhase: false,
            allowsHardwareCapture: true
        ))
    }

    @MainActor
    @Test func isolatedAppStateConstructsCalendarWithoutExternalAccess() {
        let state = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .isolatedFixture
        )

        #expect(!state.calendarManager.externalAccessEnabled)
        #expect(state.calendarManager.hasCompletedInitialRefresh)
        #expect(state.upcomingMeetings.isEmpty)
        #expect(!state.googleCalendarConnected)
        #expect(!state.zoomConnected)
    }

    @MainActor
    @Test func isolatedRecordingStartFailsBeforeTheHardwareEngine() async {
        let state = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .isolatedFixture
        )

        await #expect(throws: AppState.LocalOnlyRuntimeError.hardwareCaptureDisabled) {
            try await state.startRecording()
        }
    }

    @MainActor
    @Test func isolatedManualGenerationCommandsAreInert() async throws {
        let state = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .isolatedFixture
        )
        let now = Date()
        let event = MeetingEvent(
            id: "fixture-event",
            title: "Fictional Planning",
            startDate: now,
            endDate: now.addingTimeInterval(1_800),
            meetingURL: nil,
            meetingApp: nil,
            calendarName: "Fixture",
            notes: nil
        )

        let generated = await state.generateMeetingPrepNow(event: event)
        #expect(!generated)
        state.generateSummary(recordingID: UUID(), provider: "apple", language: "en")
        state.retryTranscription(recordingID: UUID())

        let bulkDependencies = try #require(state.exportService.bulkExporter.dependencies)
        #expect(try await bulkDependencies.notionExportedIDs().isEmpty)
        #expect(bulkDependencies.craftExportedIDs().isEmpty)
    }

    @Test func isolatedRuntimeRemovesVisibleAndProgrammaticCaptureEntrypoints() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let mainWindow = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            encoding: .utf8
        )
        let menuBar = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/MenuBar/MenuBarView.swift"),
            encoding: .utf8
        )

        let startFunction = try #require(appState.range(of: "func startRecording("))
        let startGuard = try #require(appState.range(
            of: "guard startupPolicy.allowsHardwareCapture else",
            range: startFunction.upperBound..<appState.endIndex
        ))
        let engineStart = try #require(appState.range(
            of: "recordingEngine.startRecording(",
            range: startFunction.upperBound..<appState.endIndex
        ))
        #expect(startGuard.lowerBound < engineStart.lowerBound)

        let prepareFunction = try #require(appState.range(of: "func prepareSystemAudioCapture()"))
        let prepareGuard = try #require(appState.range(
            of: "guard startupPolicy.allowsHardwareCapture else { return }",
            range: prepareFunction.upperBound..<appState.endIndex
        ))
        let enginePrepare = try #require(appState.range(
            of: "recordingEngine.prepareSystemAudioCapture()",
            range: prepareFunction.upperBound..<appState.endIndex
        ))
        #expect(prepareGuard.lowerBound < enginePrepare.lowerBound)

        let generateSummary = try #require(appState.range(of: "func generateSummary("))
        let generationGuard = try #require(appState.range(
            of: "guard startupPolicy.allowsContentGeneration else { return }",
            range: generateSummary.upperBound..<appState.endIndex
        ))
        let coordinatorGeneration = try #require(appState.range(
            of: "coordinator.generateSummary(",
            range: generateSummary.upperBound..<appState.endIndex
        ))
        #expect(generationGuard.lowerBound < coordinatorGeneration.lowerBound)

        let importFunction = try #require(appState.range(of: "func importAudioFiles(urls:"))
        let importedGenerationGate = try #require(appState.range(
            of: "if startupPolicy.performsAutomaticGeneration {",
            range: importFunction.upperBound..<appState.endIndex
        ))
        let importedPostProcess = try #require(appState.range(
            of: "coordinator?.startPostProcessing(",
            range: importFunction.upperBound..<appState.endIndex
        ))
        #expect(importedGenerationGate.lowerBound < importedPostProcess.lowerBound)

        #expect(app.contains("runningState?.startupPolicy.allowsHardwareCapture == true"))
        #expect(mainWindow.contains("if appState.startupPolicy.allowsHardwareCapture"))
        #expect(menuBar.contains("if appState.startupPolicy.allowsHardwareCapture"))
    }

    @Test func postProcessingBlocksManualAutoAndToolbarRecordingEntrypoints() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        let engine = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Services/Recording/RecordingEngine.swift"),
            encoding: .utf8
        )
        let mainWindow = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            encoding: .utf8
        )

        let appStateStart = try #require(appState.range(of: "func startRecording("))
        let appStateLeaseSignal = try #require(appState.range(
            of: "coordinator?.hasActiveWork == true"
        ))
        let appStateGate = try #require(appState.range(
            of: "guard !isPostProcessingRecordingStartBlocked else",
            range: appStateStart.upperBound..<appState.endIndex
        ))
        let appStateEngineCall = try #require(appState.range(
            of: "recordingEngine.startRecording(",
            range: appStateStart.upperBound..<appState.endIndex
        ))
        #expect(appStateLeaseSignal.lowerBound < appStateStart.lowerBound)
        #expect(appStateGate.lowerBound < appStateEngineCall.lowerBound)

        let engineStart = try #require(engine.range(of: "func startRecording("))
        let engineGate = try #require(engine.range(
            of: "guard let recordingLease = recordingProcessingGate.claimRecording() else",
            range: engineStart.upperBound..<engine.endIndex
        ))
        let providerResolutionBoundary = try #require(engine.range(
            of: "_ = try await resolveConfiguredBatchTranscriptionProvider",
            range: engineStart.upperBound..<engine.endIndex
        ))
        let captureBoundary = try #require(engine.range(
            of: "segmentsDirectoryPath = try await startCapture(",
            range: engineStart.upperBound..<engine.endIndex
        ))
        let persistenceBoundary = try #require(engine.range(
            of: "let saved = await store?.createRecording(",
            range: engineStart.upperBound..<engine.endIndex
        ))
        #expect(engineGate.lowerBound < providerResolutionBoundary.lowerBound)
        #expect(engineGate.lowerBound < captureBoundary.lowerBound)
        #expect(engineGate.lowerBound < persistenceBoundary.lowerBound)
        #expect(engine.contains("isAutoStarted: Bool = false"))

        #expect(mainWindow.contains("let blocked = appState.isRecordingStartBlocked"))
        #expect(mainWindow.contains(".disabled(starting || blocked)"))
        #expect(mainWindow.contains("appState.recordingStartBlockReason"))
    }

    @MainActor
    @Test func sceneLaunchBehaviorReadsLoginItemEventBeforeDelegateCapture() {
        let defaults = UserDefaults(suiteName: "AppLaunchBehaviorTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "openMainWindowOnLaunch")
        MainWindowLaunchPolicy.captureCurrentLaunch(event: nil)

        let behavior = MainWindowLaunchPolicy.sceneLaunchBehavior(
            defaults: defaults,
            event: makeOpenApplicationEvent(launchedAsLoginItem: true)
        )

        #expect(
            String(describing: behavior).contains("suppressed"),
            "Login-item startup with disabled main-window launch should suppress the main scene even before AppDelegate captures launch state."
        )
    }

    @Test func mainWindowLaunchPolicyOnlySuppressesWhenCurrentLaunchIsLoginItem() {
        #expect(MainWindowLaunchPolicy.shouldPresentMainWindow(
            launchedAsLoginItem: false,
            openMainWindowOnLaunch: false
        ))
        #expect(MainWindowLaunchPolicy.shouldPresentMainWindow(
            launchedAsLoginItem: false,
            openMainWindowOnLaunch: true
        ))
        #expect(MainWindowLaunchPolicy.shouldPresentMainWindow(
            launchedAsLoginItem: true,
            openMainWindowOnLaunch: true
        ))
        #expect(!MainWindowLaunchPolicy.shouldPresentMainWindow(
            launchedAsLoginItem: true,
            openMainWindowOnLaunch: false
        ))
    }

    @Test func launchPolicyDetectsLoginItemAppleEvent() throws {
        let loginEvent = makeOpenApplicationEvent(launchedAsLoginItem: true)
        let manualEvent = makeOpenApplicationEvent(launchedAsLoginItem: false)

        #expect(MainWindowLaunchPolicy.wasLaunchedAsLoginItem(event: loginEvent))
        #expect(!MainWindowLaunchPolicy.wasLaunchedAsLoginItem(event: manualEvent))
        #expect(!MainWindowLaunchPolicy.wasLaunchedAsLoginItem(event: nil))
    }

    @Test func appUsesSceneLaunchBehaviorInsteadOfClosingMainWindowAfterItAppears() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )

        #expect(
            appSource.contains(".defaultLaunchBehavior(MainWindowLaunchPolicy.launchBehavior(haltedBoot: isHaltedBoot))"),
            "Startup-minimized behavior should suppress the scene before it creates a visible main window; a halted boot must always present the halt window instead."
        )
        #expect(
            !appSource.contains("window.close()"),
            "Closing the main window after launch causes the visible startup flash."
        )
    }

    @MainActor
    @Test func haltedBootAlwaysPresentsTheMainSceneEvenForLoginItemLaunches() {
        let defaults = UserDefaults(suiteName: "AppLaunchBehaviorTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "openMainWindowOnLaunch")
        let loginItemEvent = makeOpenApplicationEvent(launchedAsLoginItem: true)
        MainWindowLaunchPolicy.captureCurrentLaunch(event: loginItemEvent)
        defer { MainWindowLaunchPolicy.captureCurrentLaunch(event: nil) }

        let halted = MainWindowLaunchPolicy.launchBehavior(
            haltedBoot: true, defaults: defaults, event: loginItemEvent
        )
        let running = MainWindowLaunchPolicy.launchBehavior(
            haltedBoot: false, defaults: defaults, event: loginItemEvent
        )

        #expect(
            String(describing: halted).contains("presented"),
            "The halt window is the process's only surface; login-item suppression must not hide it."
        )
        #expect(
            String(describing: running).contains("suppressed"),
            "A normal boot keeps the login-item suppression policy."
        )
    }

    @Test func haltedBootKeepsDelegateLifecycleInert() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )

        // willFinishLaunching: the halt guard precedes the language
        // override write and the normal defaults registration.
        let willFinish = try #require(source.range(of: "func applicationWillFinishLaunching"))
        let willGuard = try #require(source.range(
            of: "CadenzaApp.bootHaltReason",
            range: willFinish.upperBound..<source.endIndex
        ))
        let languageApply = try #require(source.range(
            of: ".apply()", range: willFinish.upperBound..<source.endIndex
        ))
        let registerDefaults = try #require(source.range(
            of: "UserDefaults.standard.register(defaults:",
            range: willFinish.upperBound..<source.endIndex
        ))
        #expect(willGuard.lowerBound < languageApply.lowerBound)
        #expect(willGuard.lowerBound < registerDefaults.lowerBound)

        // didFinishLaunching: the halt guard precedes the sleep-observer
        // registration.
        let didFinish = try #require(source.range(of: "func applicationDidFinishLaunching"))
        let didGuard = try #require(source.range(
            of: "CadenzaApp.bootHaltReason",
            range: didFinish.upperBound..<source.endIndex
        ))
        let sleepObserver = try #require(source.range(
            of: "NSWorkspace.willSleepNotification",
            range: didFinish.upperBound..<source.endIndex
        ))
        #expect(didGuard.lowerBound < sleepObserver.lowerBound)

        // Closing the halt window must exit the process instead of
        // leaving an invisible one, and must skip the runInBackground
        // bookkeeping writes.
        let lastWindow = try #require(
            source.range(of: "func applicationShouldTerminateAfterLastWindowClosed")
        )
        let lastWindowGuard = try #require(source.range(
            of: "CadenzaApp.bootHaltReason",
            range: lastWindow.upperBound..<source.endIndex
        ))
        let backgroundRead = try #require(source.range(
            of: "\"runInBackground\"",
            range: lastWindow.upperBound..<source.endIndex
        ))
        #expect(lastWindowGuard.lowerBound < backgroundRead.lowerBound)

        // The halt shell exposes no custom commands — quit is the only
        // capability, so every CommandGroup sits behind the halt gate.
        let commandsBlock = try #require(source.range(of: ".commands {"))
        let commandsGate = try #require(source.range(
            of: "if !isHaltedBoot {",
            range: commandsBlock.upperBound..<source.endIndex
        ))
        let firstCommandGroup = try #require(source.range(
            of: "CommandGroup(",
            range: commandsBlock.upperBound..<source.endIndex
        ))
        #expect(commandsGate.lowerBound < firstCommandGroup.lowerBound)
    }

    @Test func transferBootCompletesBeforeNormalServicesAreConstructed() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let dispositionCall = try #require(
            appSource.range(of: "AppBootSequence.resolveLive()")
        )
        let serviceConstruction = try #require(
            appSource.range(of: "let state = AppState(")
        )
        let sequenceSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppBootSequence.swift"),
            encoding: .utf8
        )
        let transferCall = try #require(
            sequenceSource.range(of: "ProfileTransferExecutor.runLive(pending:")
        )
        let completedBranch = try #require(
            sequenceSource.range(of: "case .completed(let targetProfileID):")
        )
        let rerun = try #require(
            sequenceSource.range(
                of: "bootContext = bootstrap()",
                range: completedBranch.upperBound..<sequenceSource.endIndex
            )
        )
        _ = transferCall
        _ = rerun

        // The shell resolves the disposition — which runs the transfer —
        // before any service exists; the sequence re-bootstraps only
        // after a completed transfer (both proven by the ranged
        // requirements above).
        #expect(dispositionCall.lowerBound < serviceConstruction.lowerBound)
    }

    @Test func permissionUsageDescriptionsAndAudioEntitlementMatchReleaseContract() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectYAML = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(projectYAML.contains("NSAudioCaptureUsageDescription:"))
        #expect(projectYAML.contains("LSApplicationCategoryType: public.app-category.productivity"))
        #expect(projectYAML.contains("com.apple.security.device.audio-input: true"))
        #expect(!projectYAML.contains("com.apple.security.audio.capture:"))

        let infoPlistData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Info.plist")
        )
        let infoPlist = try #require(
            try PropertyListSerialization.propertyList(
                from: infoPlistData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(infoPlist["LSApplicationCategoryType"] as? String == "public.app-category.productivity")
        #expect(infoPlist["NSSpeechRecognitionUsageDescription"] == nil)

        let entitlementsData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Cadenza.entitlements")
        )
        let entitlements = try #require(
            try PropertyListSerialization.propertyList(
                from: entitlementsData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements["com.apple.security.audio.capture"] == nil)

        let screenDescription = try #require(
            projectYAML
                .split(separator: "\n")
                .first(where: { $0.contains("NSScreenCaptureUsageDescription:") })
        )
        #expect(!screenDescription.localizedCaseInsensitiveContains("capture meeting audio"))

        let catalogURL = repoRoot.appendingPathComponent("Cadenza/Resources/InfoPlist.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])
        let supportedLanguages = ["en", "zh-Hans", "ja", "ko", "fr", "de", "es"]

        for key in [
            "NSAudioCaptureUsageDescription",
            "NSScreenCaptureUsageDescription",
        ] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in supportedLanguages {
                #expect(
                    localizations[language] != nil,
                    "\(key) must include \(language) in InfoPlist.xcstrings"
                )
            }
        }
    }

    @Test func externalImportPermissionTextHasChineseLocalization() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        )
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let keys = [
            "Allow external recording imports",
            "Lets connected AI tools preview and import meeting notes from other services. Imports never create duplicate entries, keep source history, and do not require provider API tokens.",
            "External import recipe",
            "Copy a preview-first prompt for your AI agent. It lists source metadata incrementally, shows a dry run, and fetches full notes only after review. Cadenza never stores your provider tokens.",
            "Copy recipe",
            "Scopes: %@",
            "Scopes out of date",
            "Last used: %@",
            "Not used yet",
            "Revoke",
            "Legacy token",
            "Reset legacy token?",
            "Resetting this token only disconnects clients configured with the shared legacy token. Per-client access remains active.",
            "Markdown mirror",
            "No folder selected",
            "Keeps one conflict-safe Markdown note per recording. Cadenza skips files you edited instead of overwriting them.",
            "Include full transcript",
            "Choose folder…",
            "Change folder…",
            "Rebuild now",
            "Local knowledge",
            "Could not save folder access: %@",
            "Mirror complete: %lld written, %lld unchanged, %lld conflicts, %lld failed.",
        ]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations["zh-Hans"] != nil, "\(key) must include zh-Hans")
        }
    }

    @Test func menuBarRoutesAutoRecordEnableThroughRecordingNotice() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuBar = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/MenuBar/MenuBarView.swift"),
            encoding: .utf8
        )

        #expect(menuBar.contains("if autoRecordMeetings"))
        #expect(menuBar.contains("Button(\"Auto-record meetings\")"))
        #expect(menuBar.contains("appState.openSettings(category: .recording)"))
        #expect(menuBar.contains("Set Up System Audio Recording…"))
        #expect(!menuBar.contains("Permissions.requestMicrophone()"))
    }

    @Test func menuBarSurfacesRecordingErrorsWhenMainWindowIsHidden() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift"),
            encoding: .utf8
        )
        let menuBar = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/MenuBar/MenuBarView.swift"),
            encoding: .utf8
        )

        #expect(app.contains("state: runningState?.recordingState ?? .idle"))
        #expect(app.contains("hasError: runningState?.recordingError != nil"))
        #expect(menuBar.contains("if let recordingError = appState.recordingError"))
        #expect(menuBar.contains("Permissions.openSystemAudioRecordingSettings()"))
        #expect(menuBar.contains("appState.dismissRecordingError()"))
    }

    @Test func systemAudioSetupWaitsForInFlightRecordingStart() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(settings.contains("!appState.startupPolicy.allowsHardwareCapture"))
        #expect(settings.contains("|| appState.isStartingRecording"))
        #expect(settings.contains("|| appState.isRecording"))
    }

    @MainActor
    @Test func startupBackupRunsOffMainThreadAndRemainsOrderedBeforeMaintenance() async throws {
        let observation = OSAllocatedUnfairLock(
            initialState: (calls: 0, ranOnMainThread: true)
        )

        await AppState.performStartupBackup(plan: .legacy) { _ in
            observation.withLock {
                $0.calls += 1
                $0.ranOnMainThread = Thread.isMainThread
            }
        }

        let captured = observation.withLock { $0 }
        #expect(captured.calls == 1)
        #expect(!captured.ranOnMainThread)

        let skippedCalls = OSAllocatedUnfairLock(initialState: 0)
        await AppState.performStartupBackup(plan: .skip(reason: "test")) { _ in
            skippedCalls.withLock { $0 += 1 }
        }
        #expect(skippedCalls.withLock { $0 } == 0)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        let setup = try #require(source.range(of: "func setup() async"))
        let fixtureGate = try #require(source.range(
            of: "if startupPolicy.loadsFixtureLibrary {",
            range: setup.upperBound..<source.endIndex
        ))
        let fixtureReturn = try #require(source.range(
            of: "return",
            range: fixtureGate.upperBound..<source.endIndex
        ))
        let backup = try #require(source.range(
            of: "await AppState.performStartupBackup(plan: startupBackupPlan)",
            range: setup.upperBound..<source.endIndex
        ))
        let normalize = try #require(source.range(
            of: "await store.normalizeAllTagsIfNeeded()",
            range: setup.upperBound..<source.endIndex
        ))
        let clearGateRelease = try #require(source.range(
            of: "hasCompletedStartupBackup = true",
            range: setup.upperBound..<source.endIndex
        ))
        let pendingCalendarLink = try #require(source.range(
            of: "await self?.autoLinkPendingCalendarCandidates()",
            range: setup.upperBound..<source.endIndex
        ))
        let recovery = try #require(source.range(
            of: "await coordinator.recoverInterrupted()",
            range: setup.upperBound..<source.endIndex
        ))
        let trash = try #require(source.range(
            of: "await store.trashShortUntranscribedRecordings",
            range: setup.upperBound..<source.endIndex
        ))
        let purge = try #require(source.range(
            of: "await store.purgeExpiredTrashWithOutcome()",
            range: setup.upperBound..<source.endIndex
        ))

        #expect(fixtureReturn.lowerBound < backup.lowerBound)
        #expect(backup.lowerBound < clearGateRelease.lowerBound)
        #expect(backup.lowerBound < pendingCalendarLink.lowerBound)
        #expect(clearGateRelease.lowerBound < normalize.lowerBound)
        #expect(backup.lowerBound < normalize.lowerBound)
        #expect(backup.lowerBound < recovery.lowerBound)
        #expect(backup.lowerBound < trash.lowerBound)
        #expect(backup.lowerBound < purge.lowerBound)
        #expect(source.contains("Task.detached(priority: .utility)"))
    }

    @Test func startupBackupPlanningSkipsTestsAndMissingContexts() {
        let profileID = UUID()
        let paths = ProfilePaths(root: URL(fileURLWithPath: "/tmp/cadenza-launch-plan"))
        let profile = ProfileBootContext(
            mode: .profile(profileID),
            storeURL: paths.storeURL(profileID),
            chatHistoryDirectory: paths.chatHistoryDirectory(profileID),
            backupsDirectory: paths.backupsDirectory(profileID)
        )

        #expect(AppState.startupBackupPlan(
            isRunningTests: true,
            context: profile
        ) == .skip(reason: "test run"))
        #expect(AppState.startupBackupPlan(
            isRunningTests: false,
            context: nil
        ) == .skip(reason: "no boot context"))
        #expect(AppState.startupBackupPlan(
            isRunningTests: false,
            context: profile
        ) == .store(paths.storeURL(profileID), into: paths.backupsDirectory(profileID)))
    }

    @MainActor
    @Test func automaticBackupClearIsProfileOnlyAndMapsStructuredResultsToStableFeedback() async {
        let profileID = UUID()
        let paths = ProfilePaths(root: URL(fileURLWithPath: "/tmp/cadenza-clear-feedback"))
        let state = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .standard
        )
        state.profileBootContext = ProfileBootContext(
            mode: .profile(profileID),
            storeURL: paths.storeURL(profileID),
            chatHistoryDirectory: paths.chatHistoryDirectory(profileID),
            backupsDirectory: paths.backupsDirectory(profileID)
        )

        let complete = DatabaseBackupClearOutcome(
            profile: DatabaseBackupClearLocationOutcome(
                backupsRemoved: 2,
                stagingBackupsRemoved: 1,
                managedArtifactsRemoved: 4,
                residualManagedArtifacts: [],
                failures: []
            ),
            legacy: DatabaseBackupClearLocationOutcome(
                backupsRemoved: 1,
                stagingBackupsRemoved: 0,
                managedArtifactsRemoved: 1,
                residualManagedArtifacts: [],
                failures: []
            )
        )
        let partial = DatabaseBackupClearOutcome(
            profile: DatabaseBackupClearLocationOutcome(
                backupsRemoved: 1,
                stagingBackupsRemoved: 0,
                managedArtifactsRemoved: 1,
                residualManagedArtifacts: ["opaque-managed-artifact"],
                failures: ["opaque-failure"]
            ),
            legacy: .empty
        )
        let operationObservation = OSAllocatedUnfairLock(
            initialState: (profileID: UUID?.none, root: String?.none, ranOnMainThread: true)
        )
        var feedback: [AutomaticBackupClearFeedback] = []
        state.automaticBackupClearFeedbackSink = { feedback.append($0) }
        state.automaticBackupClearOperation = { receivedProfileID, receivedPaths in
            operationObservation.withLock {
                $0.profileID = receivedProfileID
                $0.root = receivedPaths.root.path
                $0.ranOnMainThread = Thread.isMainThread
            }
            return complete
        }

        #expect(!state.canClearAutomaticBackups)
        state.markStartupBackupCompletedForTesting()
        #expect(state.canClearAutomaticBackups)
        await state.clearAllAutomaticBackups(paths: paths)
        #expect(feedback == [.completed])
        #expect(!state.isClearingAutomaticBackups)
        let captured = operationObservation.withLock { $0 }
        #expect(captured.profileID == profileID)
        #expect(captured.root == paths.root.path)
        #expect(!captured.ranOnMainThread)

        state.automaticBackupClearOperation = { _, _ in partial }
        await state.clearAllAutomaticBackups(paths: paths)
        #expect(feedback == [.completed, .partial])

        state.automaticBackupClearOperation = { _, _ in
            throw AutomaticBackupClearTestError.simulated
        }
        await state.clearAllAutomaticBackups(paths: paths)
        #expect(feedback == [.completed, .partial, .failed])

        let presentations = feedback.map {
            AutomaticBackupClearToastPresentation.make(
                for: $0,
                locale: Locale(identifier: "en")
            )
        }
        #expect(presentations.map(\.kind) == [.success, .error, .error])
        #expect(presentations[0].title == "Automatic recovery backups were cleared.")
        #expect(presentations[1].title == "Some automatic recovery backups couldn't be cleared. Try again.")
        #expect(presentations[2].title == "Automatic recovery backups couldn't be cleared. Try again.")
        #expect(presentations.allSatisfy { !$0.title.contains("/tmp/") })
        #expect(presentations.allSatisfy { !$0.title.contains("opaque") })
    }

    @MainActor
    @Test func automaticBackupClearNeverCallsStorageOutsideStandardProfileMode() async throws {
        let profileID = UUID()
        let paths = ProfilePaths(root: URL(fileURLWithPath: "/tmp/cadenza-clear-policy"))
        let profileContext = ProfileBootContext(
            mode: .profile(profileID),
            storeURL: paths.storeURL(profileID),
            chatHistoryDirectory: paths.chatHistoryDirectory(profileID),
            backupsDirectory: paths.backupsDirectory(profileID)
        )
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let forbiddenOperation: @Sendable (
            UUID,
            ProfilePaths
        ) throws -> DatabaseBackupClearOutcome = { _, _ in
            calls.withLock { $0 += 1 }
            return DatabaseBackupClearOutcome(profile: .empty, legacy: .empty)
        }

        let pendingStartupState = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .standard
        )
        pendingStartupState.profileBootContext = profileContext
        pendingStartupState.automaticBackupClearOperation = forbiddenOperation
        await pendingStartupState.clearAllAutomaticBackups(paths: paths)
        #expect(!pendingStartupState.canClearAutomaticBackups)

        let testState = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .testHost
        )
        testState.profileBootContext = profileContext
        testState.automaticBackupClearOperation = forbiddenOperation
        await testState.clearAllAutomaticBackups(paths: paths)
        #expect(!testState.canClearAutomaticBackups)

        let fixtureState = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .isolatedFixture
        )
        fixtureState.profileBootContext = profileContext
        fixtureState.automaticBackupClearOperation = forbiddenOperation
        await fixtureState.clearAllAutomaticBackups(paths: paths)
        #expect(!fixtureState.canClearAutomaticBackups)

        let fallbackState = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .standard
        )
        fallbackState.profileBootContext = .legacy(reason: "simulated")
        fallbackState.automaticBackupClearOperation = forbiddenOperation
        await fallbackState.clearAllAutomaticBackups(paths: paths)
        #expect(!fallbackState.canClearAutomaticBackups)
        #expect(calls.withLock { $0 } == 0)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Cadenza/Views/Settings/ExportBackupSection.swift"
            ),
            encoding: .utf8
        )
        #expect(viewSource.contains("if appState.canClearAutomaticBackups"))
        #expect(viewSource.contains("appState.isClearingAutomaticBackups"))
        #expect(viewSource.contains("await appState.clearAllAutomaticBackups()"))

        let appStateSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/App/AppState.swift"),
            encoding: .utf8
        )
        #expect(appStateSource.contains(
            "DatabaseBackup.clearAllAutomaticBackups(for: profileID, paths: paths)"
        ))
    }

    @MainActor
    @Test func automaticBackupClearRejectsDuplicateTriggersWhileRunning() async throws {
        let profileID = UUID()
        let paths = ProfilePaths(root: URL(fileURLWithPath: "/tmp/cadenza-clear-duplicate"))
        let state = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .standard
        )
        state.profileBootContext = ProfileBootContext(
            mode: .profile(profileID),
            storeURL: paths.storeURL(profileID),
            chatHistoryDirectory: paths.chatHistoryDirectory(profileID),
            backupsDirectory: paths.backupsDirectory(profileID)
        )
        state.markStartupBackupCompletedForTesting()
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        state.automaticBackupClearOperation = { _, _ in
            calls.withLock { $0 += 1 }
            release.wait()
            return DatabaseBackupClearOutcome(profile: .empty, legacy: .empty)
        }
        state.automaticBackupClearFeedbackSink = { _ in }

        let first = Task { @MainActor in
            await state.clearAllAutomaticBackups(paths: paths)
        }
        while calls.withLock({ $0 }) == 0 {
            await Task.yield()
        }
        #expect(state.isClearingAutomaticBackups)

        await state.clearAllAutomaticBackups(paths: paths)
        #expect(calls.withLock { $0 } == 1)

        release.signal()
        await first.value
        #expect(!state.isClearingAutomaticBackups)
        #expect(calls.withLock { $0 } == 1)
    }

    private func makeOpenApplicationEvent(launchedAsLoginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if launchedAsLoginItem {
            event.setParam(
                NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem)),
                forKeyword: AEKeyword(keyAEPropData)
            )
        }
        return event
    }
}

private enum AutomaticBackupClearTestError: Error {
    case simulated
}
