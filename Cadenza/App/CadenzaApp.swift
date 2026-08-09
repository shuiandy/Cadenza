import SwiftUI
import SwiftData
import CoreServices

enum MainWindowLaunchPolicy {
    @MainActor private(set) static var currentLaunchWasLoginItem = false

    static func shouldPresentMainWindow(
        launchedAsLoginItem: Bool,
        openMainWindowOnLaunch: Bool
    ) -> Bool {
        !launchedAsLoginItem || openMainWindowOnLaunch
    }

    static func openMainWindowOnLaunch(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: "openMainWindowOnLaunch") != nil else {
            return true
        }
        return defaults.bool(forKey: "openMainWindowOnLaunch")
    }

    static func wasLaunchedAsLoginItem(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> Bool {
        guard let event else { return false }
        let launchMode = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        return event.eventID == AEEventID(kAEOpenApplication)
            && launchMode == OSType(keyAELaunchedAsLogInItem)
    }

    @MainActor
    static func captureCurrentLaunch(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) {
        currentLaunchWasLoginItem = wasLaunchedAsLoginItem(event: event)
    }

    @MainActor
    static func sceneLaunchBehavior(
        defaults: UserDefaults = .standard,
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> SceneLaunchBehavior {
        let launchedAsLoginItem = currentLaunchWasLoginItem || wasLaunchedAsLoginItem(event: event)
        currentLaunchWasLoginItem = launchedAsLoginItem

        return shouldPresentMainWindow(
            launchedAsLoginItem: launchedAsLoginItem,
            openMainWindowOnLaunch: openMainWindowOnLaunch(defaults: defaults)
        ) ? .presented : .suppressed
    }

    /// The halt window is the process's only surface, so it must present
    /// unconditionally; login-item suppression applies to the normal
    /// shell alone.
    @MainActor
    static func launchBehavior(
        haltedBoot: Bool,
        defaults: UserDefaults = .standard,
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> SceneLaunchBehavior {
        haltedBoot ? .presented : sceneLaunchBehavior(defaults: defaults, event: event)
    }
}

@main
struct CadenzaApp: App {
    /// The process either runs with fully-wired services or halts behind
    /// an inert surface; there is no in-between state to reach.
    enum AppRuntime {
        case running(AppState)
        case halted(reason: String)
    }

    enum BootPlan {
        case standard(ProfileBootContext?)
        case isolatedFixture(root: URL)
        case halted(reason: String)
    }

    /// Resolves the DEBUG isolation boundary before the profile bootstrap.
    /// An invalid or valid fixture configuration must never call the live
    /// resolver: invalid input halts, while valid input opens only the direct
    /// fixture store with ephemeral authorities.
    @MainActor
    static func resolveBootPlan(
        debugConfiguration: DebugDataRoot.Configuration = DebugDataRoot.configuration,
        resolveLive: () -> AppBootDisposition = { AppBootSequence.resolveLive() }
    ) -> BootPlan {
        switch debugConfiguration {
        case .invalid(let reason):
            return .halted(reason: reason)
        case .isolated(let root, _):
            return .isolatedFixture(root: root)
        case .inactive:
            switch resolveLive() {
            case .run(let context):
                return .standard(context)
            case .halted(let reason):
                return .halted(reason: reason)
            }
        }
    }

    @MainActor
    static var bootHaltReason: String? {
        switch DebugDataRoot.configuration {
        case .invalid(let reason):
            return reason
        case .isolated:
            return nil
        case .inactive:
            return AppBootSequence.haltedBootReason
        }
    }

    /// SwiftUI updates every root `@AppStorage` property before evaluating
    /// the halt view. An invalid DEBUG override may omit `CFFIXED_USER_HOME`
    /// or point it at an unsafe location, so those wrappers must not inspect
    /// the real standard domain while the process is failing closed.
    static func rootAppStorageUsesSharedDefaults(
        debugConfiguration: DebugDataRoot.Configuration
    ) -> Bool {
        guard case .invalid = debugConfiguration else { return true }
        return false
    }

    private static let rootAppStorageDefaults: UserDefaults = {
        guard rootAppStorageUsesSharedDefaults(
            debugConfiguration: DebugDataRoot.configuration
        ) else {
            // A process-unique suite has no pre-existing user values. The
            // halt shell never mutates these properties, so this remains an
            // inert read domain even when the supplied fixed home is unsafe.
            return UserDefaults(
                suiteName: "com.shuiandy.Cadenza.debug-boot-halt.\(UUID().uuidString)"
            )!
        }
        return .standard
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var runtime: AppRuntime = {
        // §5.3: the active ProfileContext is resolved before any session
        // or sync service exists. A halted boot constructs no AppState
        // and adds no writes of its own; the bootstrap or transfer that
        // halted may already hold durable, resumable progress.
        let plan = CadenzaApp.resolveBootPlan()
        if case .halted(let reason) = plan {
            NSLog("[CadenzaApp] Boot halted before opening the library")
            return .halted(reason: reason)
        }
        let bootContext: ProfileBootContext?
        let isolatedFixture: Bool
        switch plan {
        case .standard(let resolvedContext):
            bootContext = resolvedContext
            isolatedFixture = false
        case .isolatedFixture:
            bootContext = nil
            isolatedFixture = true
        case .halted:
            preconditionFailure("halted plan returned above")
        }

        if !isolatedFixture {
            // Migrate legacy provider raw values before any code reads UserDefaults.
            // qwenLocal was removed; coerce to apple so the picker/picker-fallbacks
            // don't silently swap to .openai (which would fail without an API key).
            let ud = UserDefaults.standard
            if ud.string(forKey: "defaultAIProvider") == "qwenLocal" {
                ud.set(AIProvider.apple.rawValue, forKey: "defaultAIProvider")
            }

            // Existing users who explicitly enabled auto-record before this flag
            // existed have already opted into the process-tap workflow. Preserve
            // that setup once; registered defaults and fresh installs do not count.
            SystemAudioCapturePreparation.migrateLegacyAutoRecordUser(
                legacyAutoRecordWasExplicitlyEnabled: ud.object(forKey: "autoRecordMeetings") as? Bool == true,
                defaults: ud
            )
        }

        if isolatedFixture, let audioRoot = DebugDataRoot.audioDirectory {
            ActiveProfileDefaults.activateEphemeral()
            StorageLocationManager.configureProfileRoot(.init(
                bookmark: nil,
                path: audioRoot.path,
                kind: .appManaged,
                profileDefaultPath: audioRoot.path,
                recordRefreshedBookmark: { _ in },
                recordRootChange: { _, _, _ in }
            ))
        } else if case .profile = bootContext?.mode, let profile = bootContext?.profile {
            // The registry's per-profile directory is the audio-root
            // authority from here on; the global defaults keys serve only
            // the pre-commit legacy fallback.
            StorageLocationManager.configureProfileRoot(
                ProfileAudioRootWriter.liveAuthority(for: profile)
            )
        }
        if !isolatedFixture {
            switch bootContext?.mode {
        case .profile(let profileID):
            // Every inventoried preference consumer addresses the scoped
            // twin from here on; value-typed keys re-register their code
            // defaults under the scoped names.
            ActiveProfileDefaults.activate(profileID: profileID)
        case .legacyFallback:
            ActiveProfileDefaults.activateLegacyFallback()
        case .transfer:
            break
        case nil:
            // TestHost: explicit ephemeral passthrough for preferences and
            // an ephemeral audio root, so a forgotten consumer can never
            // resolve the real legacy directory or bookmark (INV-8).
            ActiveProfileDefaults.activateEphemeral()
            if AppState.isRunningTests,
               case .ephemeral(let base) = ProfileEnvironment.current() {
                let audioRoot = base.appendingPathComponent("AudioRoot", isDirectory: true).path
                StorageLocationManager.configureProfileRoot(.init(
                    bookmark: nil,
                    path: audioRoot,
                    kind: .appManaged,
                    profileDefaultPath: audioRoot,
                    recordRefreshedBookmark: { _ in },
                    recordRootChange: { _, _, _ in }
                ))
            }
        case .halted:
            break
            }
        }
        let startupPolicy = AppState.StartupPolicy.resolve(
            isRunningTests: AppState.isRunningTests,
            isolatedDataRootIsActive: isolatedFixture
        )
        let state = AppState(
            cadenzaAuth: CadenzaApp.makeAuthService(bootContext: bootContext),
            startupPolicy: startupPolicy
        )
        // Create ModelContainer and wire store + coordinator before any UI appears.
        // RecordingEngine gets its dependencies here (synchronous) so recording
        // works immediately — not deferred to the async setup() call.
        do {
            // Tests get an in-memory container: the TestHost runs this same App
            // struct, and it must never open (or schema-migrate) the real user
            // store while the production app may be running. Test suites build
            // their own in-memory containers and never touch this one. The
            // profile bootstrap (including the M1 migration) is reachable only
            // from the live branch.
            let container: ModelContainer
            if isolatedFixture {
                guard let storeURL = DebugDataRoot.fixtureStoreURL else {
                    preconditionFailure("isolated fixture plan has no store URL")
                }
                try FileManager.default.createDirectory(
                    at: storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let chatDirectory = DebugDataRoot.fixtureChatHistoryDirectory {
                    state.chatHistory.configure(directory: chatDirectory)
                }
                container = try RecordingsStore.makeContainer(storeURL: storeURL)
            } else if let bootContext {
                state.profileBootContext = bootContext
                // Chat persistence follows the boot mode strictly: profile
                // boots use the profile directory or stay in-memory when it
                // is unavailable — never the legacy location, which belongs
                // to the pre-commit fallback alone.
                switch bootContext.mode {
                case .profile:
                    if let chatDirectory = bootContext.chatHistoryDirectory {
                        state.chatHistory.configure(directory: chatDirectory)
                    } else {
                        NSLog("[CadenzaApp] chat history disabled: profile directory unavailable")
                    }
                case .legacyFallback:
                    state.chatHistory.configure(directory: ChatHistoryManager.legacyDirectory)
                case .halted, .transfer:
                    break
                }
                if let storeURL = bootContext.storeURL {
                    container = try RecordingsStore.makeContainer(storeURL: storeURL)
                } else {
                    container = try RecordingsStore.makeContainer()
                }
                if case .profile(let profileID) = bootContext.mode {
                    // The materialization flag must be durable before
                    // anything can write user data: a store created now
                    // but not recorded could later be lost and silently
                    // recreated empty.
                    do {
                        try ProfileBootstrap.recordStoreMaterializedLive(profileID: profileID)
                    } catch {
                        fatalError(
                            "[CadenzaApp] store materialization record failed: \(error)"
                        )
                    }
                }
            } else {
                container = try RecordingsStore.makeContainer(inMemory: true)
            }
            let store = RecordingsStore(modelContainer: container)
            let coordinator = PostProcessingCoordinator(store: store)
            state.store = store
            state.coordinator = coordinator
            state.webSync = WebSyncCoordinator(
                store: store,
                auth: state.cadenzaAuth,
                startAutomatically: startupPolicy.startsWebSyncAutomatically,
                shouldPauseHistoricalAudio: { [weak state] in
                    state?.isRecording == true
                        || state?.coordinator?.hasActiveWork == true
                }
            )
            state.recordingEngine.store = store
            state.recordingEngine.coordinator = coordinator
            state.configureMeetingPrepScheduler()
            state.configureMarkdownMirror()
        } catch {
            fatalError("[CadenzaApp] Failed to create ModelContainer: \(error)")
        }
        AppState.shared = state
        return .running(state)
    }()

    /// The running state, or nil behind the halt surface.
    private var runningState: AppState? {
        if case .running(let state) = runtime { return state }
        return nil
    }

    /// True when this process is a halt shell: nothing exists behind the
    /// halt window, so scene policy must always present it and custom
    /// commands must not appear.
    private var isHaltedBoot: Bool {
        if case .halted = runtime { return true }
        return false
    }

    /// Builds the one profile-bound auth service for this process (§5.3).
    /// Anything without a resolved profile — TestHost, previews, and the
    /// pre-commit legacy fallback — runs an unbound in-memory session: it
    /// owns no token slot and can never issue requests, so the fallback
    /// simply has no account features until the migration succeeds
    /// (INV-5: no global session state remains to fall back to).
    private static func makeAuthService(bootContext: ProfileBootContext?) -> CadenzaAuthService {
        guard let bootContext,
              case .profile = bootContext.mode,
              let profile = bootContext.profile else {
            return CadenzaAuthService.ephemeral()
        }
        let paths = ProfilePaths.live()
        let fileOperations = LiveFileOperations()
        do {
            // Classified evidence load: unknown or corrupt session
            // artifacts halt the boot here rather than booting a guessed
            // session state.
            return try CadenzaAuthService.bootstrapped(
                sessionProfile: .init(profile: profile),
                secretStore: KeychainAuthSecretStore(),
                sessionUserStore: FileSessionUserStore(
                    url: paths.sessionUserURL(profile.id),
                    fileOperations: fileOperations
                ),
                registry: DiskProfileRegistry(
                    registryURL: paths.registryURL, fileOperations: fileOperations
                )
            )
        } catch {
            fatalError("[CadenzaApp] session evidence unreadable: \(error)")
        }
    }

    @AppStorage("appTheme", store: CadenzaApp.rootAppStorageDefaults)
    private var appTheme: AppTheme = .system
    @AppStorage("appIconVariant", store: CadenzaApp.rootAppStorageDefaults)
    private var appIconVariant: AppIconVariant = .classic
    @AppStorage("showMenuBarIcon", store: CadenzaApp.rootAppStorageDefaults)
    private var showMenuBarIcon = true
    @AppStorage("showDockIcon", store: CadenzaApp.rootAppStorageDefaults)
    private var showDockIcon = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Main Window
        Window("Cadenza", id: "main") {
            if AppState.isRunningTests {
                Color.clear
                    .frame(width: 1, height: 1)
            } else if case .halted(let reason) = runtime {
                BootHaltView(reason: reason)
            } else if let appState = runningState {
                MainWindow()
                    .environment(appState)
                    .frame(minWidth: 800, minHeight: 600)
                    .onAppear {
                        setupIfNeeded()
                        applyTheme(appTheme)
                        applyDockVisibility()
                        appDelegate.setMenuBarIconVisible(showMenuBarIcon)
                        appDelegate.openMainWindow = { [openWindow] in
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    .task { [appState] in
                        appState.openMainWindowAndAnchor = { @MainActor in
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                            return NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })
                                ?? NSApp.keyWindow
                                ?? NSApp.mainWindow
                        }
                        if appState.startupPolicy.externalAccessEnabled {
                            OAuthCoordinator.shared.attachAnchor { @MainActor [weak appState] in
                                appState?.bringMainWindowToFront()
                            }
                        }
                    }
                    .onChange(of: appIconVariant) { _, newValue in
                        AppIconManager.apply(variant: newValue)
                    }
                    .onOpenURL { url in
                        guard appState.startupPolicy.externalAccessEnabled else { return }
                        CadenzaURLSchemeRouter.shared.handle(url)
                    }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultLaunchBehavior(MainWindowLaunchPolicy.launchBehavior(haltedBoot: isHaltedBoot))
        .commands {
            if !isHaltedBoot {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings...") {
                        guard let appState = runningState else { return }
                        appState.openSettings(category: .general)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button("Import Audio Files...") {
                        runningState?.importAudioFiles()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
        }

        // Menu Bar Extra (SwiftUI-native, works on macOS 26)
        MenuBarExtra(isInserted: Binding(
            get: {
                runningState?.startupPolicy.allowsHardwareCapture == true
                    && !AppState.isRunningTests
                    && showMenuBarIcon
            },
            set: {
                if runningState?.startupPolicy.allowsHardwareCapture == true,
                   !AppState.isRunningTests {
                    showMenuBarIcon = $0
                }
            }
        )) {
            if let appState = runningState {
                MenuBarView()
                    .environment(appState)
            }
        } label: {
            MenuBarIcon(
                state: runningState?.recordingState ?? .idle,
                hasError: runningState?.recordingError != nil
            )
        }
    }

    private func setupIfNeeded() {
        guard let appState = runningState else { return }
        AppState.shared = appState
        if !appState.hasBeenSetUp {
            Task { await appState.setup() }
        }
    }

    private func applyTheme(_ theme: AppTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyDockVisibility() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Once-guard: ensures reply(toApplicationShouldTerminate:) is called exactly once.
    private var terminateReplySent = false

    /// Set by AIRecorderApp when SwiftUI's openWindow environment action becomes available.
    /// Used to reliably re-open the main window from AppDelegate callbacks.
    var openMainWindow: (() -> Void)?

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AppState.isRunningTests,
              let appState = AppState.shared else { return }

        if appState.startupPolicy.checksPermissions {
            Task {
                await appState.checkPermissionsAndRefreshCalendarIfNeeded()
            }
        }

        guard appState.startupPolicy.externalAccessEnabled else { return }
        appState.webSync?.reconcile()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CadenzaApp.bootHaltReason != nil {
            // Halted boot: the only job is making the halt window
            // reachable. Language override, defaults registration,
            // migrations, icon, and dock policy stay untouched (zero
            // writes); the dock icon is forced on so an accessory-policy
            // launch cannot hide the window.
            NSApp.setActivationPolicy(.regular)
            return
        }
        MainWindowLaunchPolicy.captureCurrentLaunch()

        // Apply language override before any UI loads
        let langRaw = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        (AppLanguage(rawValue: langRaw) ?? .system).apply()

        // Register defaults so UserDefaults reads match @AppStorage fallbacks
        UserDefaults.standard.register(defaults: [
            "tagBlocklist": ["meeting", "security", "会议", "安全",
                // generic process / action / status words — no discriminating value
                "跟踪", "状态", "状态更新", "同步", "sync", "规划", "排期", "日程", "跟进",
                "测试", "调试", "报告", "整改", "扫描", "分流", "自动化", "工作流", "集成",
                "团队更新", "团队对齐", "目标设定", "容量规划", "周同步", "工作量", "工作进展",
                "内容整理", "中断", "敏捷", "工程", "架构", "后端", "运营", "身份", "权限",
                "绩效评估", "远程办公", "请假", "职业发展"],
            "showMenuBarIcon": true,
            "showDockIcon": true,
            "enableMeetingDetection": false,
            "appIconVariant": AppIconVariant.classic.rawValue,
            "runInBackground": false,
            "openMainWindowOnLaunch": true,
            "captureMicrophone": false,
            SpeakerMemoryConsent.defaultsKey: false,
            "autoRecordMeetings": false,
            "autoStopOnMicClose": true,
            "silenceWatchdogMinutes": 15,
            "transcriptionLanguage": "auto",
            "summaryLanguage": "auto",
            "summaryDetailLevel": "detailed",
            "defaultAIProvider": "apple",
            "contentViewMode": "grid",
            "recordingsSort": "dateNewest",
            ActiveProfileDefaults.key("autoExportToNotion"): false,
            ActiveProfileDefaults.key("autoExportToCraft"): false,
            AutomaticRecapGeneration.defaultsKey: false,
            "enableRealtimeTranscription": false,
            "transcriptionProvider": "apple",
            "realtimeTranscriptionProvider": "openai",
            ActiveProfileDefaults.key("meetingPrepEnabled"): false,
            ActiveProfileDefaults.key("meetingPrepLeadMinutes"): 30,
            "mcpMeetingContextEnabled": false,
            "mcpExternalImportEnabled": false,
        ])
        if !DebugDataRoot.isActive {
            migrateLegacyGeminiModelDefaults()
        }

        let showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        AppIconManager.applySavedSelection()
    }

    private func migrateLegacyGeminiModelDefaults() {
        let defaults = UserDefaults.standard
        let legacyDefaultModels: Set<String> = [
            "gemini-3.1-pro-preview",
            "gemini-3.1-flash-lite",
            "gemini-3.1-flash-lite-preview"
        ]

        if let savedModel = defaults.string(forKey: "model.gemini"),
           legacyDefaultModels.contains(savedModel) {
            defaults.set(AIProvider.gemini.defaultModel, forKey: "model.gemini")
        }

        // transcriptionModel.<provider> was a dead key for several releases
        // (written by an old Settings build, read by nobody). Now that
        // AIProvider.transcriptionModel resolves it again, purge stale values
        // so a years-old model ID doesn't silently take over batch
        // transcription. Removing (not rewriting) means "use code default".
        if let saved = defaults.string(forKey: "transcriptionModel.gemini"),
           legacyDefaultModels.contains(saved) {
            defaults.removeObject(forKey: "transcriptionModel.gemini")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppState.isRunningTests else { return }

        // Halted boot: no services exist to set up or observe; the halt
        // window activates itself when it appears.
        if CadenzaApp.bootHaltReason != nil { return }

        setupAppStateIfNeeded()

        // Stop recording gracefully before system sleep (lid close, etc.)
        // to prevent data loss — macOS may kill the process during sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let appState = AppState.shared,
                      appState.isRecording || appState.recordingEngine.isStopping else { return }
                NSLog("[AppDelegate] system going to sleep, stopping recording to preserve audio")
                appState.stopRecording()
            }
        }

        if MainWindowLaunchPolicy.shouldPresentMainWindow(
            launchedAsLoginItem: MainWindowLaunchPolicy.currentLaunchWasLoginItem,
            openMainWindowOnLaunch: MainWindowLaunchPolicy.openMainWindowOnLaunch()
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func setupAppStateIfNeeded() {
        guard let appState = AppState.shared, !appState.hasBeenSetUp else { return }
        Task { await appState.setup() }
    }

    func setMenuBarIconVisible(_ isVisible: Bool) {
        // Menu bar visibility is now managed by SwiftUI MenuBarExtra's isInserted binding.
        // This method is kept as a no-op for any remaining callers.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared?.removeGlobalHotkeys()

        guard let appState = AppState.shared else {
            return .terminateNow
        }

        // Detect any orphan capture resources that survived a forceReset. If present,
        // go through the async teardown path so process taps cannot outlive the app.
        let hasOrphanCapture = appState.recordingEngine.audioMixer.isCaptureActive

        let needsGracefulStop = appState.isRecording
            || appState.recordingEngine.isStopping
            || appState.coordinator?.hasActiveWork == true
            || hasOrphanCapture

        guard needsGracefulStop else {
            return .terminateNow
        }

        terminateReplySent = false

        let replyOnce: () -> Void = { [weak self] in
            guard let self, !self.terminateReplySent else { return }
            self.terminateReplySent = true
            sender.reply(toApplicationShouldTerminate: true)
        }

        // Hard timeout: audio stop (30s) + post-processing buffer
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            NSLog("[AppDelegate] applicationShouldTerminate: hard timeout, forcing terminate")
            replyOnce()
        }

        Task { @MainActor in
            // Wait for recording stop + merge
            if appState.isRecording || appState.recordingEngine.isStopping {
                await appState.recordingEngine.stopRecordingAndWait()
            }
            // Wait for post-processing to finish
            while appState.coordinator?.hasActiveWork == true {
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Final defense: tear down any leftover process-tap resources. The
            // 60s hard timeout above still fires replyOnce and unblocks termination.
            await appState.recordingEngine.audioMixer.tearDownCaptureIfActive()
            replyOnce()
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A halted boot owns exactly one surface — the halt window. Once
        // it closes there is nothing left to reach (no menu bar icon, no
        // services), so the process must exit instead of lingering
        // invisibly.
        if CadenzaApp.bootHaltReason != nil { return true }
        let runInBackground = UserDefaults.standard.bool(forKey: "runInBackground")
        if runInBackground {
            NSApp.setActivationPolicy(.accessory)
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let runInBackground = UserDefaults.standard.bool(forKey: "runInBackground")
        if runInBackground {
            NSApp.setActivationPolicy(.regular)
        }

        // Try to bring an existing main window to the front.
        for window in NSApp.windows {
            if window.identifier?.rawValue.contains("main") == true ||
               window.title == "Cadenza" {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return false
            }
        }

        // Window is closed — open it via the stored SwiftUI openWindow action.
        // This works even when the menu bar icon is invisible (full menu bar).
        if let open = openMainWindow {
            open()
            return false
        }

        // Fallback: let SwiftUI handle it (may not work reliably for Window scenes).
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
