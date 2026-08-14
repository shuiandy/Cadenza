import AppKit
import SwiftUI
import AVFoundation
import UserNotifications

/// One-shot payload carrying an in-progress chat from FloatingAIChatButton to AIChatView.
struct AIChatHandoff {
    let provider: AIProvider
    let model: String
    let sessionID: UUID?
}

private enum CalendarAutoLinkResult {
    case linked
    case noMatch
    case deferred
}

enum AudioImportOutcome: Equatable, Sendable {
    case completed(importedCount: Int, totalCount: Int)
    case blockedByStorageMigration(totalCount: Int)
}

struct AudioImportToastPresentation: Equatable, Sendable {
    let kind: ToastKind
    let title: String

    static func make(
        for outcome: AudioImportOutcome,
        locale: Locale? = nil
    ) -> AudioImportToastPresentation {
        switch outcome {
        case .blockedByStorageMigration:
            return AudioImportToastPresentation(
                kind: .info,
                title: LocalizedBundle.string(
                    "Import unavailable while storage is moving. Wait for the move to finish, then try again.",
                    locale: locale
                )
            )

        case .completed(let importedCount, let totalCount):
            let safeTotalCount = max(0, totalCount)
            let safeImportedCount = min(max(0, importedCount), safeTotalCount)
            if safeTotalCount > 0, safeImportedCount == safeTotalCount {
                let format = LocalizedBundle.string(
                    safeImportedCount == 1
                        ? "Imported %lld recording."
                        : "Imported %lld recordings.",
                    locale: locale
                )
                return AudioImportToastPresentation(
                    kind: .success,
                    title: String(format: format, Int64(safeImportedCount))
                )
            }
            if safeImportedCount > 0 {
                let format = LocalizedBundle.string(
                    "Imported %lld of %lld recordings.",
                    locale: locale
                )
                return AudioImportToastPresentation(
                    kind: .error,
                    title: String(
                        format: format,
                        Int64(safeImportedCount),
                        Int64(safeTotalCount)
                    )
                )
            }
            return AudioImportToastPresentation(
                kind: .error,
                title: LocalizedBundle.string(
                    "No recordings were imported. Try again.",
                    locale: locale
                )
            )
        }
    }
}

enum RecordingDeletionFeedback: Equatable, Sendable {
    case moveToTrashFailed
    case permanentDeletionFailed
    case emptyTrashFailed
    case automaticTrashCleanupFailed
    case recoveryNeedsAttention
    case secureCleanupPending
    case blockedByStorageMigration
}

struct RecordingDeletionToastPresentation: Equatable, Sendable {
    let kind: ToastKind
    let title: String

    static func make(
        for feedback: RecordingDeletionFeedback,
        locale: Locale? = nil
    ) -> RecordingDeletionToastPresentation {
        let kind: ToastKind
        let key: String.LocalizationValue
        switch feedback {
        case .moveToTrashFailed:
            kind = .error
            key = "Couldn't move the recording to Trash. It is still in your library."
        case .permanentDeletionFailed:
            kind = .error
            key = "Couldn't permanently delete the recording. It is still in Trash."
        case .emptyTrashFailed:
            kind = .error
            key = "Couldn't empty Trash. Your recordings are still in Trash."
        case .automaticTrashCleanupFailed:
            kind = .error
            key = "Couldn't finish automatic Trash cleanup. Your recordings were kept."
        case .recoveryNeedsAttention:
            kind = .error
            key = "Deletion recovery needs attention. Keep Cadenza open, then try again."
        case .secureCleanupPending:
            kind = .info
            key = "Deletion finished. File cleanup will retry automatically."
        case .blockedByStorageMigration:
            kind = .info
            key = "Deletion is unavailable while storage is moving. Wait for the move to finish, then try again."
        }
        return RecordingDeletionToastPresentation(
            kind: kind,
            title: LocalizedBundle.string(key, locale: locale)
        )
    }
}

enum AutomaticBackupClearFeedback: Equatable, Sendable {
    case completed
    case partial
    case failed
}

struct AutomaticBackupClearToastPresentation: Equatable, Sendable {
    let kind: ToastKind
    let title: String

    static func make(
        for feedback: AutomaticBackupClearFeedback,
        locale: Locale? = nil
    ) -> AutomaticBackupClearToastPresentation {
        let kind: ToastKind
        let key: String.LocalizationValue
        switch feedback {
        case .completed:
            kind = .success
            key = "Automatic recovery backups were cleared."
        case .partial:
            kind = .error
            key = "Some automatic recovery backups couldn't be cleared. Try again."
        case .failed:
            kind = .error
            key = "Automatic recovery backups couldn't be cleared. Try again."
        }
        return AutomaticBackupClearToastPresentation(
            kind: kind,
            title: LocalizedBundle.string(key, locale: locale)
        )
    }
}

@Observable @MainActor
final class AppState {
    /// Shared reference for AppDelegate cleanup on termination.
    static var shared: AppState?
    private static let calendarAutoLinkRemoteRetryDefaultsKey = "calendarAutoLinkRemoteRetryCompleted.v1"

    /// True when the process is hosted by `xcodebuild test`.
    nonisolated static let isRunningTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    enum StartupPolicy: Equatable, Sendable {
        case standard
        case testHost
        case isolatedFixture

        nonisolated static func resolve(
            isRunningTests: Bool,
            isolatedDataRootIsActive: Bool
        ) -> StartupPolicy {
            if isRunningTests { return .testHost }
            if isolatedDataRootIsActive { return .isolatedFixture }
            return .standard
        }

        var externalAccessEnabled: Bool { self == .standard }
        var loadsFixtureLibrary: Bool { self == .isolatedFixture }
        var startsWebSyncAutomatically: Bool { self == .standard }
        var configuresMeetingPrep: Bool { self == .standard }
        var configuresMarkdownMirror: Bool { self == .standard }
        var inspectsCredentialStore: Bool { self == .standard }
        var checksPermissions: Bool { self == .standard }
        var startsMCP: Bool { self == .standard }
        var startsCalendarMonitoring: Bool { self == .standard }
        var startsMeetingDetection: Bool { self == .standard }
        var registersGlobalHotkeys: Bool { self == .standard }
        var performsAutomaticMaintenance: Bool { self == .standard }
        var performsAutomaticGeneration: Bool { self == .standard }
        var allowsContentGeneration: Bool { self != .isolatedFixture }
        var allowsHardwareCapture: Bool { self != .isolatedFixture }
    }

    let startupPolicy: StartupPolicy

    // MARK: - Local Store + Post-Processing

    /// Set by AIRecorderApp after ModelContainer is created.
    var store: RecordingsStore!

    /// Storage-migration exclusion for audio import, deletion, and the orphan
    /// scan; tests inject an isolated gate.
    @ObservationIgnored var migrationGate: StorageMigrationGate = .shared

    /// Live storage-root provider for import and the orphan scan: production
    /// re-reads the active location on every operation; tests inject a
    /// temporary root so no path ever touches the real library.
    @ObservationIgnored var storageRootProvider: @Sendable () -> URL = {
        StorageLocationManager.recordingsDirectory
    }
    /// Injectable presentation boundary: import work reports only structured
    /// counts/reasons, and the live sink owns the app-wide toast delivery.
    @ObservationIgnored var importOutcomeSink: @MainActor (AudioImportOutcome) -> Void = { outcome in
        let presentation = AudioImportToastPresentation.make(for: outcome)
        ToastCenter.shared.show(Toast(kind: presentation.kind, title: presentation.title))
    }
    @ObservationIgnored var deletionFeedbackSink: @MainActor (RecordingDeletionFeedback) -> Void = {
        feedback in
        let presentation = RecordingDeletionToastPresentation.make(for: feedback)
        ToastCenter.shared.show(Toast(kind: presentation.kind, title: presentation.title))
    }
    @ObservationIgnored var batchMutationFailureSink: @MainActor () -> Void = {
        ToastCenter.shared.show(Toast(
            kind: .error,
            title: LocalizedBundle.string(
                "The change couldn't be saved — try again.",
                locale: nil
            )
        ))
    }
    @ObservationIgnored var automaticBackupClearOperation: @Sendable (
        UUID,
        ProfilePaths
    ) throws -> DatabaseBackupClearOutcome = { profileID, paths in
        try DatabaseBackup.clearAllAutomaticBackups(for: profileID, paths: paths)
    }
    @ObservationIgnored var automaticBackupClearFeedbackSink: @MainActor (
        AutomaticBackupClearFeedback
    ) -> Void = { feedback in
        let presentation = AutomaticBackupClearToastPresentation.make(for: feedback)
        ToastCenter.shared.show(Toast(kind: presentation.kind, title: presentation.title))
    }
#if DEBUG
    /// Releases the Settings clear-backup gate without running live startup
    /// work. Production reaches the same state only after awaiting backup.
    func markStartupBackupCompletedForTesting() {
        hasCompletedStartupBackup = true
    }

    /// Suspension point inside the import task so tests can hold the import
    /// mid-flight and assert the migration claim is refused until it ends.
    @ObservationIgnored var importAwaitHookForTesting: (() async -> Void)?
    /// Holds a hard-delete task after it acquires its migration activity lease.
    @ObservationIgnored var deletionAwaitHookForTesting: (() async -> Void)?
    /// Holds automatic journal recovery while the deletion activity lease is
    /// still owned, so tests can prove a migration remains refused.
    @ObservationIgnored var deletionRecoveryAwaitHookForTesting: (() async -> Void)?
#endif
    /// Set by AIRecorderApp after store is created.
    var coordinator: PostProcessingCoordinator!
    /// Set by AIRecorderApp once `store` is available. Drives meeting-prep artifact
    /// generation from `refreshCalendarState()` (gated by `meetingPrepEnabled`).
    private var meetingPrepScheduler: MeetingPrepScheduler?
    var webSync: WebSyncCoordinator!

    // MARK: - MCP Server (AI access)

    @ObservationIgnored private var mcpServer: MCPServer?
    var mcpServerStatus: MCPServer.Status = .stopped

    // MARK: - Markdown Mirror

    @ObservationIgnored private var markdownMirrorService: MarkdownMirrorService?
    @ObservationIgnored private var markdownMirrorObserver: NSObjectProtocol?
    @ObservationIgnored private var markdownMirrorRefreshTask: Task<Void, Never>?

    // MARK: - Calendar + OAuth + Export (main process — no XPC)

    let oauthTokenManager = OAuthTokenManager()
    /// Injected at construction (§5.3): the live app resolves the active
    /// ProfileContext first and builds the profile-bound service from it;
    /// tests and previews fall back to a fully in-memory, unbound service
    /// (INV-8) that owns no token slot and can never issue requests.
    let cadenzaAuth: CadenzaAuthService
    private(set) var calendarManager: CalendarManager!
    private(set) var exportService: ExportService!

    // MARK: - Recording Engine (main process — no XPC in hot path)

    let recordingEngine = RecordingEngine()
    @ObservationIgnored lazy var meetingDetector = MeetingDetector()

    // MARK: - Recording State (forwarded from RecordingEngine)

    var recordingState: RecordingState {
        if recordingEngine.recordingState == .idle,
           let phase = coordinator?.postProcessingPhase {
            switch phase {
            case "transcribing": return .transcribing
            case "summarizing": return .summarizing
            default: break
            }
        }
        return recordingEngine.recordingState
    }
    var currentRecordingID: UUID? { recordingEngine.currentRecordingID }
    var currentMeetingName: String? { recordingEngine.currentMeetingName }
    var recordingStartDate: Date? { recordingEngine.recordingStartDate }
    var recordingDuration: TimeInterval { recordingEngine.recordingDuration }
    var currentSegmentStart: Date? { recordingEngine.currentSegmentStart }
    var pauseAccumulatedDuration: TimeInterval { recordingEngine.pauseAccumulatedDuration }
    var audioLevel: Float { recordingEngine.audioLevel }
    var autoStopCountdown: Int { recordingEngine.autoStopCountdown }
    var showMicPrompt: Bool {
        get { recordingEngine.showMicPrompt }
        set { recordingEngine.showMicPrompt = newValue }
    }
    var liveTranscriptSegments: [TranscriptSegmentDTO] { recordingEngine.liveTranscriptSegments }
    var realtimeHint: String? { recordingEngine.realtimeHint }
    /// True while either a recording start or the user-initiated system-audio
    /// setup owns the capture service. UI disables competing start actions.
    var isStartingRecording: Bool {
        recordingEngine.isStarting || recordingEngine.isPreparingSystemAudioCapture
    }
    var summaryStreamedText: String {
        get { coordinator?.summaryStreamedText ?? "" }
        set { coordinator?.summaryStreamedText = newValue }
    }
    var postProcessingError: String? {
        get { coordinator?.postProcessingError }
        set { coordinator?.postProcessingError = newValue }
    }
    var postProcessingCompletedToken: Int {
        get { coordinator?.postProcessingCompletedToken ?? 0 }
        set { /* coordinator owns this */ }
    }

    // MARK: - Non-recording State (all main process now)

    var transcriptionChunksDone: Int { coordinator?.transcriptionChunksDone ?? 0 }
    var transcriptionChunksTotal: Int { coordinator?.transcriptionChunksTotal ?? 0 }
    func isGeneratingSummary(for recordingID: UUID) -> Bool {
        coordinator?.isGeneratingSummary(for: recordingID) ?? false
    }
    func isEnrichingSummary(for recordingID: UUID) -> Bool {
        coordinator?.isEnrichingSummary(for: recordingID) ?? false
    }
    func quickSummaryResult(for recordingID: UUID) -> SummaryResult? {
        coordinator?.quickSummaryResult(for: recordingID)
    }
    var isMeetingLikelyActive: Bool { recordingEngine.isMeetingCurrentlyActive }
    var activeMeetingAppName: String? { recordingEngine.detectedMeetingAppName }

    // Calendar (from CalendarManager directly)
    var upcomingMeetings: [MeetingEventDTO] = []
    var currentMeeting: MeetingEventDTO?
    @ObservationIgnored private var calendarStateSyncTimer: Timer?

    // Permissions (checked directly in main process)
    var hasMicrophonePermission: Bool = false
    var hasScreenRecordingPermission: Bool = false
    var hasAccessibilityPermission: Bool = false
    var hasCalendarPermission: Bool = false
    var calendarPermissionStatus: PermissionStatus = .notDetermined

    // Connections (read directly from services)
    var googleCalendarConnected: Bool {
        startupPolicy.externalAccessEnabled
            && (calendarManager?.googleCalendarService.isConnected ?? false)
    }
    var googleCalendarConnecting: Bool {
        startupPolicy.externalAccessEnabled
            && (calendarManager?.googleCalendarService.isConnecting ?? false)
    }
    var googleCalendarError: String? {
        startupPolicy.externalAccessEnabled ? calendarManager?.googleCalendarService.error : nil
    }
    var zoomConnected: Bool {
        startupPolicy.externalAccessEnabled
            && (calendarManager?.zoomMeetingService.isConnected ?? false)
    }
    var zoomConnecting: Bool {
        startupPolicy.externalAccessEnabled
            && (calendarManager?.zoomMeetingService.isConnecting ?? false)
    }
    var zoomError: String? {
        startupPolicy.externalAccessEnabled ? calendarManager?.zoomMeetingService.error : nil
    }
    var notionConnected: Bool {
        startupPolicy.externalAccessEnabled
            && (exportService?.notionService.isConnected ?? false)
    }
    var notionConnecting: Bool {
        startupPolicy.externalAccessEnabled
            && (exportService?.notionService.isConnecting ?? false)
    }
    var notionError: String? {
        startupPolicy.externalAccessEnabled
            ? exportService?.notionService.lastError?.errorDescription : nil
    }
    var notionWorkspaceName: String {
        startupPolicy.externalAccessEnabled ? (exportService?.notionService.workspaceName ?? "") : ""
    }
    var notionDatabaseID: String {
        get {
            startupPolicy.externalAccessEnabled
                ? (exportService?.notionService.databaseID ?? "") : ""
        }
        set {
            guard startupPolicy.externalAccessEnabled else { return }
            exportService?.notionService.databaseID = newValue
        }
    }
    var craftIsAvailable: Bool {
        startupPolicy.externalAccessEnabled
            && (exportService?.craftService.isAvailable ?? false)
    }

    // API keys
    var hasAnyAPIKey = false

    var recordingDiscardedReason: String?

    // Manual retry states
    func isRetryingTranscription(for recordingID: UUID) -> Bool {
        coordinator?.isRetryingTranscription(for: recordingID) ?? false
    }

    func isProcessing(recordingID: UUID) -> Bool {
        coordinator?.isProcessing(recordingID: recordingID) ?? false
    }

    // MARK: - Local UI-Only State

    var showMainWindow = false
    var selectedRecordingID: UUID?
    var missingAPIKeyProvider: AIProvider? { recordingEngine.missingAPIKeyProvider }
    var showAPIKeyAlert: Bool {
        get { recordingEngine.showAPIKeyAlert }
        set { recordingEngine.showAPIKeyAlert = newValue }
    }
    var recordingError: String? {
        get { recordingEngine.recordingError }
        set {
            if let newValue {
                recordingEngine.recordingError = newValue
            } else {
                recordingEngine.dismissRecordingError()
            }
        }
    }
    var recordingErrorOffersSystemAudioSettings: Bool {
        recordingEngine.recordingErrorOffersSystemAudioSettings
    }
    var hasPreparedSystemAudioCapture: Bool {
        recordingEngine.hasPreparedSystemAudioCapture
    }
    var isPreparingSystemAudioCapture: Bool {
        recordingEngine.isPreparingSystemAudioCapture
    }
    var showSettings = false
    var selectedSettingsCategory: SettingsCategory? = .general
    let overlayController = RecordingOverlayController()
    /// Holds the in-window AI-chat sidebar's expand/collapse state. See FloatingChatPanel.swift.
    let floatingChatController = FloatingChatPanelController()
    var showRecordingOverlay = false
    var stopRequestTime: Date?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    /// Tracks the monitor lifecycle separately from the opaque monitor tokens.
    /// AppKit can return `nil` for a global key monitor before Accessibility is
    /// granted, but a later grant must still retry the registration exactly once.
    private var areGlobalHotkeysRegistered = false
    private var isMeetingDetectionActive = false

    // MARK: - Window helper for OAuth presentation anchors

    /// Set by `CadenzaApp.body` once the SwiftUI environment is available.
    /// The closure is responsible for:
    ///   1. Calling `openWindow(id: "main")` if no window exists.
    ///   2. Calling `makeKeyAndOrderFront`.
    ///   3. Calling `NSApp.activate(ignoringOtherApps: true)` (best-effort —
    ///      deprecated but still effective for the OAuth presentation anchor).
    ///   4. Returning a stable `NSWindow?` for `ASWebAuthSession`.
    var openMainWindowAndAnchor: (@MainActor () -> NSWindow?)?

    /// `OAuthCoordinator.presentationAnchor(for:)` calls this. Falls back to
    /// `nil` when the closure isn't installed yet (`OAuthCoordinator` then
    /// uses its own `ASPresentationAnchor()` default).
    func bringMainWindowToFront() -> NSWindow? {
        openMainWindowAndAnchor?()
    }

    // MARK: - Navigation State

    var activeDestination: NavigationDestination = .allRecordings
    var recordingDetailTitle: String?
    private(set) var hasBeenSetUp = false

    // MARK: - AI Chat State

    var aiChatMessages: [ChatMessage] = []
    /// Recording IDs that scope the AI assistant page's context (mirrors floating panel's
    /// session scope so handoff preserves "@recording" mentions).
    var aiChatScopeIDs: Set<UUID> = []
    /// One-shot handoff payload from FloatingAIChatButton → AIChatView. AIChatView reads
    /// this on appear and clears it; subsequent appearances do not re-adopt.
    var aiChatHandoff: AIChatHandoff?
    let chatHistory = ChatHistoryManager()

    /// Boot decision from ProfileBootstrap, set by CadenzaApp before the
    /// container is wired. nil in the TestHost; `.legacyFallback` when a
    /// pre-commit migration failure kept the legacy locations in use.
    var profileBootContext: ProfileBootContext?

    enum StartupBackupPlan: Equatable, Sendable {
        case skip(reason: String)
        case store(URL, into: URL)
        case legacy
    }

    /// Where (and whether) the startup database backup runs. In profile
    /// mode the backup writes the profile's own directory or is skipped —
    /// a committed profile must never touch the legacy locations. The
    /// legacy backup is reserved for the pre-commit fallback boot, and
    /// test runs never back anything up.
    nonisolated static func startupBackupPlan(
        isRunningTests: Bool, context: ProfileBootContext?
    ) -> StartupBackupPlan {
        if isRunningTests { return .skip(reason: "test run") }
        guard let context else { return .skip(reason: "no boot context") }
        switch context.mode {
        case .profile:
            guard let storeURL = context.storeURL,
                  let backupsDirectory = context.backupsDirectory else {
                return .skip(reason: "profile backups directory unavailable")
            }
            return .store(storeURL, into: backupsDirectory)
        case .legacyFallback:
            return .legacy
        case .halted:
            return .skip(reason: "boot halted")
        case .transfer:
            return .skip(reason: "transfer mode")
        }
    }

    /// Runs the synchronous SQLite backup away from the main actor while
    /// allowing `setup()` to await completion before any normalization or
    /// recovery mutates the live store. A skipped plan never invokes the
    /// operation, which keeps test, fixture, and non-profile startup inert.
    nonisolated static func performStartupBackup(
        plan: StartupBackupPlan,
        operation: @escaping @Sendable (StartupBackupPlan) -> Void = { plan in
            switch plan {
            case .skip:
                break
            case .store(let storeURL, let backupsDirectory):
                DatabaseBackup.performBackup(
                    storeURL: storeURL,
                    backupsDirectory: backupsDirectory
                )
            case .legacy:
                DatabaseBackup.performBackup()
            }
        }
    ) async {
        guard case .skip(let reason) = plan else {
            await Task.detached(priority: .utility) {
                operation(plan)
            }.value
            return
        }
        NSLog("[AppState] startup backup skipped: %@", reason)
    }

    var canClearAutomaticBackups: Bool {
        hasCompletedStartupBackup && automaticBackupClearProfileID != nil
    }

    private(set) var hasCompletedStartupBackup = false
    private(set) var isClearingAutomaticBackups = false

    /// Clears both the active profile backup directory and the pre-profile
    /// legacy directory. The operation remains unavailable in test, fixture,
    /// fallback, halted, and transfer modes, even if invoked programmatically.
    func clearAllAutomaticBackups(paths: ProfilePaths = .live()) async {
        guard !isClearingAutomaticBackups,
              hasCompletedStartupBackup,
              let profileID = automaticBackupClearProfileID else { return }

        isClearingAutomaticBackups = true
        defer { isClearingAutomaticBackups = false }

        let operation = automaticBackupClearOperation
        let feedback = await Task.detached(priority: .utility) {
            do {
                let outcome = try operation(profileID, paths)
                return outcome.isComplete
                    ? AutomaticBackupClearFeedback.completed
                    : AutomaticBackupClearFeedback.partial
            } catch {
                return AutomaticBackupClearFeedback.failed
            }
        }.value
        automaticBackupClearFeedbackSink(feedback)
    }

    private var automaticBackupClearProfileID: UUID? {
        guard startupPolicy == .standard,
              case .profile(let profileID) = profileBootContext?.mode else {
            return nil
        }
        return profileID
    }

    // MARK: - Cached Data

    var recordings: [RecordingDTO] = []
    var trashedRecordings: [RecordingDTO] = []
    var folders: [FolderDTO] = []
    var recaps: [RecapDTO] = []
    var searchQuery: String = ""
    var searchResults: [RecordingDTO] = []
    var isSearchingRecordings = false
    var recordingsChangedToken: Int = 0
    var smartFolderOverridesChangedToken: Int = 0
    var isLoadingRecordings = true
    private(set) var isBatchMutationInProgress = false

#if DEBUG
    /// Test seam proving post-processing cancellation happens only after the
    /// corresponding Trash persistence has committed.
    @ObservationIgnored var discardCancellationSinkForTesting: @MainActor (UUID) -> Void = { _ in }
#endif

    @ObservationIgnored private var smartFolderOverrideStore = SmartFolderOverrideStore()
    @ObservationIgnored private var smartFolderCache = SmartFolderCache()
    @ObservationIgnored private var recordingSearchCoordinator: RecordingSearchCoordinator?

    var trashCount: Int { trashedRecordings.count }
    var smartFolders: [SmartFolderDTO] {
        _ = recordingsChangedToken
        _ = smartFolderOverridesChangedToken
        return smartFolderCache.folders
    }
    var smartFolderTargets: [SmartFolderDTO] { smartFolderCache.targets }
    var sidebarSmartFolders: [SmartFolderDTO] {
        _ = recordingsChangedToken
        _ = smartFolderOverridesChangedToken
        return smartFolderCache.sidebarFolders
    }

    // MARK: - Computed

    var isRecording: Bool {
        recordingState == .recording || recordingState == .paused
    }

    var isFinalizingRecording: Bool {
        recordingEngine.isStopping
    }

    /// Capture is only unavailable while the previous recording's durable stop
    /// finalization runs. Post-processing (transcription/summary) proceeds in
    /// parallel with a new recording and never blocks the start controls.
    var isRecordingStartBlocked: Bool {
        isFinalizingRecording
    }

    var recordingStartBlockReason: String? {
        guard isRecordingStartBlocked else { return nil }
        return RecordingStartError.finalizationInProgress.errorDescription
    }

    var statusText: String {
        if isFinalizingRecording {
            return String(localized: "Saving recording…")
        }
        switch recordingState {
        case .idle:
            if isMeetingLikelyActive {
                return String(localized: "Meeting detected — \(activeMeetingAppName ?? String(localized: "Active"))")
            }
            if let app = activeMeetingAppName {
                return String(localized: "Meeting detected — \(app)")
            }
            return String(localized: "Ready")
        case .recording:
            let minutes = Int(recordingDuration) / 60
            let seconds = Int(recordingDuration) % 60
            return String(localized: "Recording") + String(format: " %02d:%02d", minutes, seconds)
        case .paused:
            let minutes = Int(recordingDuration) / 60
            let seconds = Int(recordingDuration) % 60
            return String(localized: "Paused") + String(format: " %02d:%02d", minutes, seconds)
        case .transcribing:
            return String(localized: "Transcribing...")
        case .summarizing:
            return String(localized: "Generating summary...")
        }
    }

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let minutes = (Int(recordingDuration) % 3600) / 60
        let seconds = Int(recordingDuration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Init

    init(
        cadenzaAuth: CadenzaAuthService? = nil,
        startupPolicy: StartupPolicy? = nil
    ) {
        // The nil default exists for tests and SwiftUI previews only — the
        // live startup must resolve the profile context first and inject
        // the profile-bound service (§5.3). The guard makes a production
        // no-arg construction impossible instead of silently unbound.
        if cadenzaAuth == nil {
            precondition(
                AppState.isRunningTests
                    || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1",
                "live AppState requires an injected profile-bound auth service"
            )
        }
        let resolvedStartupPolicy = startupPolicy ?? StartupPolicy.resolve(
            isRunningTests: Self.isRunningTests,
            isolatedDataRootIsActive: DebugDataRoot.isActive
        )
        self.startupPolicy = resolvedStartupPolicy
        self.cadenzaAuth = cadenzaAuth ?? CadenzaAuthService.ephemeral()
        // Initialize calendar and export services
        calendarManager = CalendarManager(
            tokenManager: oauthTokenManager,
            externalAccessEnabled: resolvedStartupPolicy.externalAccessEnabled
        )
        exportService = ExportService(cadenzaAuth: self.cadenzaAuth)

        // Wire openURL handlers directly — no XPC needed
        if resolvedStartupPolicy.externalAccessEnabled {
            calendarManager.googleCalendarService.openURLHandler = { url in
                NSWorkspace.shared.open(url)
            }
            calendarManager.zoomMeetingService.openURLHandler = { url in
                NSWorkspace.shared.open(url)
            }
            self.cadenzaAuth.openURLHandler = { url in
                NSWorkspace.shared.open(url)
            }
            exportService.craftService.openURLHandler = { url in
                NSWorkspace.shared.open(url)
            }
            exportService.craftService.checkAppAvailableHandler = {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.lukilabs.lukiapp") != nil ||
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.lukilabs.lukiapp-setapp") != nil
            }
        } else {
            exportService.craftService.checkAppAvailableHandler = { false }
        }

        exportService.bulkExporter.dependencies = .init(
            listRecordings: { [weak self] in
                guard let self else { return [] }
                // Oldest-first: bulk export pushes in meeting-timeline order.
                return await self.store.fetchRecordingDTOs(
                    sortKey: "dateOldest", folderID: nil, tagFilter: nil)
            },
            fetchDetail: { [weak self] id in
                await self?.store.fetchRecordingDetail(recordingID: id)
            },
            notionExportedIDs: { [weak self] in
                guard let self else { return [] }
                guard self.startupPolicy.externalAccessEnabled else { return [] }
                return try await self.exportService.notionService.fetchExportedRecordingIDs()
            },
            exportToNotion: { [weak self] detail in
                guard let self else { return }
                guard self.startupPolicy.externalAccessEnabled else {
                    throw CancellationError()
                }
                try await self.exportService.notionService.exportRecording(detail)
            },
            craftExportedIDs: { [weak self] in
                guard let self, self.startupPolicy.externalAccessEnabled else { return [] }
                return self.exportService.craftService.exportedRecordingIDs
            },
            exportToCraft: { [weak self] detail in
                guard let self else { return }
                guard self.startupPolicy.externalAccessEnabled else {
                    throw CancellationError()
                }
                try await self.exportService.craftService.exportRecording(detail)
            },
            interItemDelay: { destination in
                // craftdocs:// opens activate Craft each time — pace them.
                destination == .craft ? .milliseconds(400) : .zero
            })

        // 导出/归档一律走 uncached fetch：批量枚举不把全库 transcript 钉进 detailCache。
        exportService.batchFileExporter.dependencies = .init(
            fetchDetail: { [weak self] id in
                await self?.store.fetchRecordingDetailUncached(recordingID: id)
            },
            fetchAudioPaths: { [weak self] ids in
                guard let self else { return [:] }
                return try await self.store.fetchAudioPaths(recordingIDs: ids)
            },
            fetchFolders: { [weak self] in
                await self?.store.fetchFolders() ?? []
            })

        exportService.archiveExporter.makeSource = { [weak self] in
            let store = self?.store
            // Chat in the archive follows the boot policy exactly: the
            // resolved profile's own directory, the legacy directory only
            // in the pre-commit fallback, and no chat at all when neither
            // is configured — a global path here would export another
            // profile's history.
            let chatDir: URL?
            switch self?.profileBootContext?.mode {
            case .profile:
                chatDir = self?.profileBootContext?.chatHistoryDirectory
            case .legacyFallback:
                chatDir = ChatHistoryManager.legacyDirectory
            case .halted, .transfer, nil:
                chatDir = nil
            }
            return PortableArchiveSource(
                catalog: {
                    guard let store else { throw CancellationError() }
                    return try await store.fetchArchiveCatalog()
                },
                record: { try await store?.fetchArchiveRecording(recordingID: $0) },
                voiceSamples: {
                    guard let store else { return [] }
                    return try await store.fetchArchiveVoiceSamples(recordingID: $0)
                },
                chatHistoryDirectory: chatDir,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            )
        }

        // Wire RecordingEngine lifecycle callbacks
        recordingEngine.onRecordingStarted = { [weak self] in
            guard let self else { return }
            showRecordingOverlay = true
            overlayController.show(appState: self)
            if let recID = recordingEngine.currentRecordingID {
                openRecordingDetail(recordingID: recID, title: recordingEngine.currentMeetingName)
            }
        }
        recordingEngine.onRecordingStopped = { [weak self] in
            guard let self else { return }
            showRecordingOverlay = false
            overlayController.dismiss()
            meetingDetector.resetNotificationState()
            refreshRecordings()
        }
    }

    /// Wires up the meeting-prep scheduler once `store` is available. Called from
    /// CadenzaApp right after `state.store = store` (synchronous, same as
    /// recordingEngine.store/coordinator wiring).
    func configureMeetingPrepScheduler() {
        guard startupPolicy.configuresMeetingPrep,
              meetingPrepScheduler == nil else { return }
        // provider 由 scheduler 的 providerResolver 在每次生成时从 `defaultAIProvider` 解析
        // (与 PostProcessingCoordinator 每 job 读取一致),Settings 切换无需重启。
        meetingPrepScheduler = MeetingPrepScheduler(store: store)
    }

    /// UI 门面:读取某事件的 prep artifact(popover 用)。
    func fetchMeetingPrep(event: MeetingEvent) async -> AgentArtifactDTO? {
        let slot = ArtifactTargetKey.slotKey(kind: "meetingPrep", targetType: "calendarEvent",
                                             targetKey: event.artifactTargetKey)
        return await store.fetchArtifact(slotKey: slot)
    }

    /// UI 门面:手动「立即(重)生成」。返回是否成功(失败=无 key/网络/被更新的 external 挡回)。
    func generateMeetingPrepNow(event: MeetingEvent) async -> Bool {
        guard startupPolicy.allowsContentGeneration else { return false }
        return await meetingPrepScheduler?.generateNow(event: event) ?? false
    }

    // MARK: - Lifecycle

    func setup() async {
        guard !hasBeenSetUp else { return }
        hasBeenSetUp = true

        // MCP server FIRST (off by default). It only needs `store`, which CadenzaApp
        // wires synchronously before setup() runs — so there is no reason to make
        // external MCP clients wait behind this method's keychain scan, TCC permission
        // checks, DB sweep and orphaned-audio disk scan below. Cadenza and Claude are
        // both login items and race at boot: with this call at the end of setup(), the
        // client's connect attempt lost that race and surfaced "Server disconnected".
        if startupPolicy.startsMCP {
            syncMCPServer()
        }

        if startupPolicy != .testHost {
            chatHistory.loadAll()
        }

        // Note: recordingEngine.store and .coordinator are wired in CadenzaApp init
        // (synchronous) so recording works before setup() completes.

        // Wire coordinator callbacks
        coordinator.onRecordingsChanged = { [weak self] in
            self?.refreshRecordings()
        }
        coordinator.onRecordingDiscarded = { [weak self] recordingID, reason in
            self?.recordingDiscardedReason = reason
            // The toolbar banner above is invisible when the discard follows an
            // auto-started/auto-stopped recording with no window open — the
            // 2026-08-13 silent-opening incident trashed a meeting recording
            // without the user ever noticing. A notification survives that.
            self?.notifyRecordingDiscarded(reason: reason)
            // Only navigate away if we're viewing the specific discarded recording
            if case .recordingDetail(let viewingID) = self?.activeDestination, viewingID == recordingID {
                self?.closeDetail()
            }
        }
        coordinator.onPostProcessingCompleted = { [weak self] recordingID in
            guard let self else { return }
            if self.startupPolicy.externalAccessEnabled {
                self.webSync?.recordingDidComplete(recordingID)
            }
            guard self.startupPolicy.startsCalendarMonitoring else { return }
            Task {
                guard let detail = await self.store.fetchRecordingDetail(recordingID: recordingID),
                      detail.linkedCalendarEventID == nil else { return }
                let endDate = detail.endDate ?? detail.startDate.addingTimeInterval(detail.duration)
                self.autoLinkCalendarEvent(recordingID: recordingID, startDate: detail.startDate, endDate: endDate)
            }
        }
        coordinator.exportService = exportService
        coordinator.store = store

        // Check local API key state
        if startupPolicy.inspectsCredentialStore {
            hasAnyAPIKey = AIProvider.allCases.filter { $0.requiresAPIKey }.contains {
                KeychainManager.shared.hasAPIKey(for: $0)
            }
        } else {
            hasAnyAPIKey = false
        }

        // Check permissions directly (no XPC needed)
        if startupPolicy.checksPermissions {
            await checkPermissions()
        }

        guard startupPolicy != .testHost else {
            NSLog("[AppState] setup: test environment detected — skipping live services")
            return
        }

        if startupPolicy.loadsFixtureLibrary {
            // The fixture runtime is intentionally read/local-only at startup:
            // it renders the supplied store but performs no recovery, cleanup,
            // migrations, permission probes, networking, or generation.
            refreshRecordings()
            refreshFolders()
            refreshTrash()
            NSLog("[AppState] setup: isolated fixture runtime — local library only")
            return
        }

        // Wire meeting detector callbacks synchronously on MainActor so lifecycle
        // transitions preserve order (ending → recovery → ending cannot be
        // reordered by nested Tasks). Each callback still checks whether meeting
        // detection is enabled before mutating RecordingEngine.
        meetingDetector.onMeetingActivityDetected = { [weak self] reason in
            guard let self, self.isMeetingDetectionActive else { return }
            let bundleID = self.meetingDetector.activeBundleID ?? ""
            let appName = self.meetingDetector.sessionState.currentApp?.displayName
                ?? self.meetingDetector.activeMeetingApp?.displayName
                ?? ""
            NSLog(
                "[AppState] meetingDetector: activity detected bundleID=%@ app=%@ reason=%@",
                bundleID,
                appName,
                reason.rawValue
            )
            self.recordingEngine.handleMeetingActivity(
                bundleID: bundleID,
                appName: appName,
                reason: reason
            )
        }
        meetingDetector.onMeetingAppTerminated = { [weak self] bundleID in
            guard let self, self.isMeetingDetectionActive else { return }
            NSLog("[AppState] meetingDetector: app terminated bundleID=%@", bundleID)
            self.recordingEngine.handleMeetingTerminated(bundleID: bundleID)
        }
        meetingDetector.onMeetingEnding = { [weak self] event in
            guard let self, self.isMeetingDetectionActive else { return }
            NSLog("[AppState] meetingDetector: meeting ending reason=%@", event.reason.rawValue)
            self.recordingEngine.handleMeetingEnding(event)
        }
        meetingDetector.onMeetingRecovered = { [weak self] reason in
            guard let self, self.isMeetingDetectionActive else { return }
            NSLog("[AppState] meetingDetector: meeting recovered reason=%@", reason.rawValue)
            self.recordingEngine.handleMeetingRecovered(reason)
        }
        meetingDetector.onMicrophoneDeactivated = { [weak self] in
            guard let self, self.isMeetingDetectionActive else { return }
            NSLog("[AppState] meetingDetector: mic deactivated")
            self.recordingEngine.handleMicDeactivated()
        }
        recordingEngine.confirmMeetingEndedBeforeAuthoritativeStop = { [weak self] in
            guard let self, self.isMeetingDetectionActive else { return .unavailable }
            return self.meetingDetector.confirmAuthoritativeTeamsCallEnded()
        }
        recordingEngine.isPerProcessMicSessionEverActive = { [weak self] in
            self?.meetingDetector.perProcessMicEverDetectedInSession ?? false
        }
        // Register global hotkeys
        if startupPolicy.registersGlobalHotkeys {
            registerGlobalHotkeys()
        }

        // Start calendar monitoring
        if startupPolicy.startsCalendarMonitoring {
            calendarManager.startMonitoring()
            startCalendarPolling()
        }
        if startupPolicy.startsMeetingDetection {
            updateMeetingDetection(enabled: isMeetingDetectionEnabled, force: true)
        }

        // Local data: load immediately
        refreshRecordings()
        refreshFolders()
        refreshTrash()

        // Back up the live store off the main actor. Awaiting here preserves
        // the recovery point before normalization, recovery, and purge work.
        let startupBackupPlan = AppState.startupBackupPlan(
            isRunningTests: AppState.isRunningTests, context: profileBootContext
        )
        await AppState.performStartupBackup(plan: startupBackupPlan)
        hasCompletedStartupBackup = true

        Task { @MainActor [weak self] in
            await self?.autoLinkPendingCalendarCandidates()
        }

        // Normalize tags once (collapse variants + drop blocklist) — after backup, before recovery.
        await store.normalizeAllTagsIfNeeded()
        refreshRecordings()

        // Recover interrupted recordings BEFORE auto-trash, because interrupted
        // recordings have duration 0 and no transcript — they'd be trashed otherwise.
        await coordinator.recoverInterrupted()

        // Auto-trash short recordings without transcripts (< 30s, not worth transcribing)
        await store.trashShortUntranscribedRecordings(minDuration: 30)
        refreshRecordings()

        // Auto-recover orphaned audio files (database lost but files remain on disk)
        await recoverOrphanedAudioFiles()

        // Purge expired trash + orphaned empty recordings
        Task {
            guard let migrationLease = migrationGate.claimActivity() else {
                NSLog("[AppState] Trash purge deferred: storage migration in progress")
                return
            }
            defer { migrationGate.releaseActivity(migrationLease) }
            let purgeOutcome = await store.purgeExpiredTrashWithOutcome()
            switch purgeOutcome {
            case .deleted(let count):
                NSLog("[AppState] purged %d expired trash recordings", count)
                refreshTrash()
            case .cleanupPending(let count):
                NSLog("[AppState] purged %d expired trash recordings; file cleanup pending", count)
                deletionFeedbackSink(.secureCleanupPending)
                refreshTrash()
            case .nothingToDelete:
                break
            case .failed(let failure):
                deletionFeedbackSink(deletionFeedback(
                    for: failure,
                    fallback: .automaticTrashCleanupFailed
                ))
            }
            await waitForDeletionRecoveryIfNeeded(purgeOutcome)

            let orphanOutcome = await store.purgeOrphanedEmptyRecordingsWithOutcome()
            switch orphanOutcome {
            case .deleted(let count):
                NSLog("[AppState] purged %d orphaned empty recordings", count)
                refreshRecordings()
            case .cleanupPending(let count):
                NSLog(
                    "[AppState] purged %d orphaned empty recordings; file cleanup pending",
                    count
                )
                deletionFeedbackSink(.secureCleanupPending)
                refreshRecordings()
            case .nothingToDelete:
                break
            case .failed(let failure):
                deletionFeedbackSink(deletionFeedback(
                    for: failure,
                    fallback: .automaticTrashCleanupFailed
                ))
            }
            await waitForDeletionRecoveryIfNeeded(orphanOutcome)
        }

        // Generate missing recaps
        Task {
            await AutomaticRecapGeneration.runIfEnabled {
                let generator = RecapGenerator(store: store)
                await generator.generateMissingRecaps()
            }
            recaps = await store.fetchRecaps()
        }

        // F3: detect legacy Notion token → surface forced-reconnect banner if needed.
        detectNotionForcedReconnect()
    }

    /// Post a user notification when post-processing moves a recording to
    /// Trash (too short / empty transcript). The in-window toolbar banner is
    /// the primary surface, but auto-started recordings are typically discarded
    /// with no window open, so this is the only signal the user ever gets that
    /// a recording existed and where to recover it.
    private func notifyRecordingDiscarded(reason: String) {
        guard !AppState.isRunningTests else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            // Nothing in the app requests notification authorization up front,
            // so the first discard would otherwise fail with notDetermined and
            // the user would never learn a recording went to Trash. Provisional
            // authorization delivers quietly (Notification Center, no system
            // prompt); the user can upgrade it in System Settings.
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(
                        options: [.alert, .sound, .provisional]
                    )
                } catch {
                    NSLog("[AppState] notification authorization failed: %@", error.localizedDescription)
                }
            }
            let content = UNMutableNotificationContent()
            // UNMutableNotificationContent takes plain String rather than a
            // LocalizedStringKey, so notification copy must resolve explicitly.
            content.title = String(localized: "Recording moved to Trash")
            content.body = reason
            let request = UNNotificationRequest(
                identifier: "recordingDiscarded-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                // Denied or restricted: the toolbar banner remains the only
                // surface. Record why so a silent discard stays diagnosable.
                NSLog("[AppState] discard notification not delivered: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - MCP Server

    /// Reconcile the MCP server with current settings. Called at startup and
    /// whenever the Settings toggles/port change. The writes sub-switch needs
    /// no restart — the registry reads it per call.
    func syncMCPServer() {
        guard startupPolicy.startsMCP else {
            if let server = mcpServer {
                mcpServer = nil
                Task { await server.stop() }
            }
            mcpServerStatus = .stopped
            return
        }
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: MCPServer.Constants.enabledDefaultsKey)
        guard enabled, !Self.isRunningTests else {
            if let server = mcpServer {
                mcpServer = nil
                Task { await server.stop() }
            }
            mcpServerStatus = .stopped
            return
        }

        let token = MCPServer.loadOrCreateToken()
        let registry = MCPToolRegistry(
            store: store,
            writesEnabled: {
                UserDefaults.standard.bool(forKey: MCPServer.Constants.writesEnabledDefaultsKey)
            },
            externalImportEnabled: {
                UserDefaults.standard.bool(forKey: MCPServer.Constants.externalImportEnabledDefaultsKey)
            },
            meetingContextEnabled: {
                UserDefaults.standard.bool(forKey: MCPServer.Constants.meetingContextEnabledDefaultsKey)
            },
            upcomingEvents: { [weak self] in
                await MainActor.run { self?.calendarManager.upcomingMeetings ?? [] }
            },
            calendarIsReady: { [weak self] in
                await MainActor.run { self?.calendarManager.hasCompletedInitialRefresh ?? false }
            })
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let router = MCPRouter(tools: registry, serverVersion: version)

        let server = mcpServer ?? MCPServer()
        mcpServer = server
        Task { [self] in
            // start() tears down any previous listener first, so port/token
            // changes are plain restarts.
            await server.start(port: mcpServerPort, token: token, router: router, onStatus: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.mcpServerStatus = status
                }
            })
        }
    }

    var mcpServerPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: MCPServer.Constants.portDefaultsKey)
        guard let port = UInt16(exactly: stored), port > 0 else { return MCPServer.Constants.defaultPort }
        return port
    }

    var mcpServerURL: String {
        "http://127.0.0.1:\(mcpServerPort)/mcp"
    }

    /// Mint a new shared legacy token and restart the server with it.
    /// Per-client credentials remain valid.
    func regenerateMCPToken() {
        guard startupPolicy.startsMCP else { return }
        _ = MCPServer.regenerateToken()
        syncMCPServer()
    }

    func configureMarkdownMirror() {
        guard startupPolicy.configuresMarkdownMirror else { return }
        markdownMirrorService = MarkdownMirrorService(store: store)
        if let observer = markdownMirrorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        markdownMirrorObserver = NotificationCenter.default.addObserver(
            forName: .cadenzaRecordingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.markdownMirrorRefreshTask?.cancel()
                self.markdownMirrorRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled,
                          let service = self?.markdownMirrorService else { return }
                    _ = await service.refreshIfEnabled()
                }
            }
        }
    }

    func rebuildMarkdownMirror() async -> MarkdownMirrorRunSummary {
        guard let markdownMirrorService else { return MarkdownMirrorRunSummary(failed: 1) }
        return await markdownMirrorService.rebuildAll(
            includeTranscript: UserDefaults.standard.bool(
                forKey: MarkdownMirrorLocationManager.includeTranscriptDefaultsKey
            )
        )
    }

    // MARK: - Calendar Polling

    private func startCalendarPolling() {
        guard startupPolicy.startsCalendarMonitoring else { return }
        // Push calendar state to meetingDetector and local properties
        refreshCalendarState()

        // CalendarManager handles its own polling via startMonitoring.
        // We just need to periodically sync cached results to local state.
        // 5s strikes a balance between "30s feels broken at meeting start"
        // and "2s creates main-actor contention during active recording."
        calendarStateSyncTimer?.invalidate()
        calendarStateSyncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCalendarState()
            }
        }
    }

    private func refreshCalendarState() {
        guard startupPolicy.startsCalendarMonitoring else { return }
        calendarManager.refreshCurrentMeetingFromCache()
        let meetings = calendarManager.upcomingMeetings
        upcomingMeetings = meetings.map { MeetingEventDTO(from: $0) }

        let previousDetectorMeeting = meetingDetector.currentCalendarMeeting
        let previousMeetingID = previousDetectorMeeting?.id

        if let current = calendarManager.currentMeeting {
            let dto = MeetingEventDTO(from: current)
            currentMeeting = dto
            meetingDetector.currentCalendarMeeting = dto
        } else {
            currentMeeting = nil
            if let previousDetectorMeeting, previousDetectorMeeting.isWithinDetectionContext() {
                meetingDetector.currentCalendarMeeting = previousDetectorMeeting
            } else if let contextMeeting = calendarManager.currentMeetingForDetectionContext() {
                meetingDetector.currentCalendarMeeting = MeetingEventDTO(from: contextMeeting)
            } else {
                meetingDetector.currentCalendarMeeting = nil
            }
        }

        let newMeetingID = meetingDetector.currentCalendarMeeting?.id

        // Only reevaluate when the active calendar meeting actually changes
        // (entered/exited a meeting window). Calling reevaluateNow on every
        // 5s tick ran a fresh CGWindowList enumeration on the main actor,
        // which compounded UI commit pressure during recording.
        if isMeetingDetectionActive && previousMeetingID != newMeetingID {
            meetingDetector.reevaluateNow(reason: "calendarSync")
        }

        if UserDefaults.standard.bool(forKey: ActiveProfileDefaults.key("meetingPrepEnabled")) {
            let events = calendarManager.upcomingMeetings
            // 每 tick 刷新提前量,设置变更(meetingPrepLeadMinutes)无需重启即生效。
            let lead = UserDefaults.standard.integer(forKey: ActiveProfileDefaults.key("meetingPrepLeadMinutes"))
            meetingPrepScheduler?.leadMinutes = lead > 0 ? lead : 30
            Task { [weak self] in await self?.meetingPrepScheduler?.tick(events: events, now: Date()) }
        }
    }

    // MARK: - Permissions (direct — no XPC)

    nonisolated static func accessibilityPermissionWasGranted(
        previouslyGranted: Bool,
        currentStatus: PermissionStatus
    ) -> Bool {
        !previouslyGranted && currentStatus == .granted
    }

    @discardableResult
    func checkPermissions() async -> Bool {
        guard startupPolicy.checksPermissions else { return false }
        let previouslyHadCalendarPermission = hasCalendarPermission
        hasMicrophonePermission = Permissions.microphoneStatus == .granted
        hasScreenRecordingPermission = await Permissions.checkScreenRecording()
        let accessibilityStatus = Permissions.accessibilityStatus
        let accessibilityWasGranted = Self.accessibilityPermissionWasGranted(
            previouslyGranted: hasAccessibilityPermission,
            currentStatus: accessibilityStatus
        )
        hasAccessibilityPermission = accessibilityStatus == .granted
        if accessibilityWasGranted {
            refreshGlobalHotkeysForAccessibility()
        }
        let calendarStatus = Permissions.calendarStatus()
        calendarPermissionStatus = calendarStatus
        hasCalendarPermission = calendarStatus == .granted
        recordingEngine.refreshSystemAudioCapturePreparation()
        return !previouslyHadCalendarPermission && hasCalendarPermission
    }

    /// Refresh the calendar cache only on the denied/not-determined → granted
    /// edge. Both in-app recovery buttons and AppDelegate activation use this
    /// boundary so returning from the TCC sheet cannot leave the visible
    /// calendar stuck on its pre-authorization empty state.
    func checkPermissionsAndRefreshCalendarIfNeeded() async {
        let calendarAccessWasGranted = await checkPermissions()
        guard calendarAccessWasGranted,
              startupPolicy.externalAccessEnabled else { return }
        refreshCalendars()
    }

    // MARK: - Recording Commands

    /// Refused while a profile transition could not be classified: the
    /// process no longer provably owns the registry's active store, so no
    /// new data may be produced until restart.
    struct ProfileTransitionHaltedError: LocalizedError {
        var errorDescription: String? {
            String(localized: "A profile change didn't finish. Quit and reopen Cadenza to continue.")
        }
    }

    enum LocalOnlyRuntimeError: Error, Equatable {
        case hardwareCaptureDisabled
    }

    func startRecording(meetingName: String? = nil, captureMicrophone: Bool? = nil) async throws {
        guard startupPolicy.allowsHardwareCapture else {
            throw LocalOnlyRuntimeError.hardwareCaptureDisabled
        }
        guard profileTransitionPhase == .idle else {
            throw ProfileTransitionHaltedError()
        }
        stopRequestTime = nil
        try await recordingEngine.startRecording(meetingName: meetingName, captureMicrophone: captureMicrophone)
    }

    @discardableResult
    func prepareSystemAudioCapture() async -> Bool {
        guard startupPolicy.allowsHardwareCapture else { return false }
        do {
            try await recordingEngine.prepareSystemAudioCapture()
            return true
        } catch {
            recordingEngine.presentStartError(error)
            return false
        }
    }

    /// Surface a `startRecording` failure through the correct alert channel.
    /// Delegates to RecordingEngine so the `noTranscriptionKey` → showAPIKeyAlert
    /// special case (avoiding a stacked second alert) stays in one place.
    func presentStartRecordingError(_ error: Error) {
        guard startupPolicy.allowsHardwareCapture else { return }
        recordingEngine.presentStartError(error)
    }

    func dismissRecordingError() {
        recordingEngine.dismissRecordingError()
    }

    func stopRecording() {
        NSLog("[AppState] stopRecording: ENTER")

        stopRequestTime = Date()
        showRecordingOverlay = false
        overlayController.dismiss()

        recordingEngine.stopRecording()

        stopRequestTime = nil
    }

    func cancelPostProcessing() {
        coordinator?.cancelCurrentJob()
    }

    func forceResetRecordingState() {
        recordingEngine.forceReset()
        stopRequestTime = nil
        showRecordingOverlay = false
        overlayController.dismiss()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refreshRecordings()
            self?.refreshTrash()
        }
    }

    func pauseRecording() {
        recordingEngine.pauseRecording()
    }

    func resumeRecording() {
        recordingEngine.resumeRecording()
    }

    func dismissMicPrompt() {
        recordingEngine.dismissMicPrompt()
        overlayController.dismissPrompt()
    }

    func cancelAutoStop() {
        recordingEngine.keepRecordingAndCancelAutoStop()
    }

    // MARK: - Post-Processing Commands (via local coordinator)

    func generateSummary(recordingID: UUID, provider: String, language: String) {
        guard startupPolicy.allowsContentGeneration else { return }
        Task {
            await coordinator.generateSummary(recordingID: recordingID, provider: provider, language: language)
            refreshRecordings()
        }
    }

    func retryTranscription(recordingID: UUID) {
        guard startupPolicy.allowsContentGeneration else { return }
        Task {
            await coordinator.retryTranscription(recordingID: recordingID)
            refreshRecordings()
        }
    }

    // MARK: - Import

    func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = String(localized: "Select audio files to import")

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importAudioFiles(urls: panel.urls)
    }

    func importAudioFiles(urls: [URL], rejectedCount: Int = 0) {
        let safeRejectedCount = max(0, rejectedCount)
        let totalCount = urls.count + safeRejectedCount
        guard totalCount > 0 else { return }

        Task {
            // The lease is claimed before the root snapshot and held for the
            // whole import — transcodes await for a long time and the files
            // written must land in a root that stays active.
            guard let migrationLease = migrationGate.claimActivity() else {
                NSLog("[AppState] import deferred: storage migration in progress")
                importOutcomeSink(.blockedByStorageMigration(totalCount: totalCount))
                return
            }
            defer { migrationGate.releaseActivity(migrationLease) }
#if DEBUG
            if let importAwaitHookForTesting {
                await importAwaitHookForTesting()
            }
#endif
            let documentsDir = storageRootProvider()
            try? FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
            let transcriptionLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"

            var importedCount = 0
            for url in urls {
                let id = UUID()
                let filename = url.lastPathComponent
                let title = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "recording_", with: "")
                    .replacingOccurrences(of: "_", with: " ")

                // Convert to M4A (AAC) and copy to Cadenza directory.
                // Normalizes any format (MP3, MP4, WAV, etc.) so AVFAudio/SpeakerKit can read it.
                // PreferPreciseDurationAndTiming forces a full parse so the duration
                // is exact and the resilient exporter can seek-and-resume precisely
                // past any frame AVFoundation's decoder rejects mid-track.
                guard let importPlan = StorageOwnership.importPlan(
                    for: url,
                    storageRoot: documentsDir
                ) else {
                    NSLog("[AppState] import: invalid or unreachable source %@", filename)
                    continue
                }
                let canonicalSource = importPlan.sourceURL
                let asset = AVURLAsset(
                    url: canonicalSource,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                )
                let duration = (try? await asset.load(.duration).seconds) ?? 0

                let finalURL: URL
                let ownership: AudioFileOwnership
                switch importPlan.disposition {
                case .rejectInvalidSource:
                    NSLog("[AppState] import: invalid or unreachable source %@", filename)
                    continue

                case .reuseOwnedFile:
                    // The file already sat in storage but the app did not
                    // write it in this flow — provenance stays unprovable.
                    finalURL = canonicalSource
                    ownership = .unknownLegacy

                case .copyIntoStorage:
                    let m4aName = "\(id.uuidString.prefix(8))_\(canonicalSource.deletingPathExtension().lastPathComponent).m4a"
                    let destURL = documentsDir.appendingPathComponent(m4aName)
                    do {
                        try StorageOwnership.copyRegularFile(from: canonicalSource, to: destURL)
                        finalURL = destURL
                        ownership = .appCreated
                    } catch {
                        NSLog("[AppState] import: failed to copy %@: %@", filename, error.localizedDescription)
                        continue
                    }

                case .transcodeIntoStorage:
                    let m4aName = "\(id.uuidString.prefix(8))_\(canonicalSource.deletingPathExtension().lastPathComponent).m4a"
                    let destURL = documentsDir.appendingPathComponent(m4aName)
                    do {
                        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                            NSLog("[AppState] import: no audio track in %@", filename)
                            continue
                        }
                        try await AudioExporter.exportToM4A(
                            asset: asset,
                            track: track,
                            outputURL: destURL,
                            settings: .importQuality
                        )
                        finalURL = destURL
                        ownership = .appCreated
                    } catch {
                        NSLog("[AppState] import: conversion failed for %@: %@", filename, error.localizedDescription)
                        try? FileManager.default.removeItem(at: destURL)
                        continue
                    }
                }

                // Derive start date from filename or file attributes
                let startDate = Self.parseDateFromFilename(filename) ??
                    (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.creationDate] as? Date) ??
                    Date()

                let saved = await store.importAudioFile(
                    id: id, title: title, startDate: startDate,
                    duration: duration, audioURL: finalURL, ownership: ownership,
                    language: transcriptionLanguage
                )
                if saved {
                    importedCount += 1
                    if startupPolicy.startsCalendarMonitoring {
                        autoLinkCalendarEvent(
                            recordingID: id,
                            startDate: startDate,
                            endDate: startDate.addingTimeInterval(duration)
                        )
                    }
                    if startupPolicy.performsAutomaticGeneration {
                        await coordinator?.startPostProcessing(
                            recordingID: id,
                            audioURL: finalURL,
                            meetingTitle: title,
                            origin: .importedAudio
                        )
                    }
                } else {
                    NSLog("[AppState] import persistence failed for %@", id.uuidString)
                    Self.rollbackCreatedImportFile(
                        at: finalURL,
                        ownership: ownership,
                        recordingID: id
                    )
                }
            }

            refreshRecordings()
            importOutcomeSink(.completed(
                importedCount: importedCount,
                totalCount: totalCount
            ))
            NSLog("[AppState] imported %d audio file(s)", importedCount)
        }
    }

    /// Persistence failure must not leave an untracked app-created copy on
    /// disk. User-owned and legacy files are never deleted here.
    nonisolated static func rollbackCreatedImportFile(
        at url: URL,
        ownership: AudioFileOwnership,
        recordingID: UUID
    ) {
        guard ownership == .appCreated else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return
        } catch {
            let nsError = error as NSError
            NSLog(
                "[AppState] import rollback cleanup failed for %@ (%@:%ld)",
                recordingID.uuidString,
                nsError.domain,
                nsError.code
            )
        }
    }

    /// Scans the Cadenza audio directory for .m4a files not tracked in the database.
    /// Automatically re-creates Recording entries for orphaned files (e.g., after DB reset).
    private func recoverOrphanedAudioFiles() async {
        guard let migrationLease = migrationGate.claimActivity() else {
            NSLog("[AppState] orphan scan deferred: storage migration in progress")
            return
        }
        defer { migrationGate.releaseActivity(migrationLease) }
        let recovered = await OrphanAudioRecovery.run(
            storageRoot: storageRootProvider(), store: store
        )
        if recovered > 0 {
            refreshRecordings()
            NSLog("[AppState] recovered %d orphaned recording(s)", recovered)
        }
    }

    private static func parseDateFromFilename(_ filename: String) -> Date? {
        RecordingFilenameDateParser.parse(filename)
    }

    // MARK: - Data Commands (via local store)

    private func deletionFeedback(
        for failure: RecordingsStore.PermanentDeletionFailure,
        fallback: RecordingDeletionFeedback
    ) -> RecordingDeletionFeedback {
        switch failure {
        case .rollbackIncomplete, .pendingCleanupRecoveryFailed:
            .recoveryNeedsAttention
        case .fileStagingFailed, .persistenceFailed:
            fallback
        }
    }

    /// A durable journal means the root cannot safely change yet. Keep the
    /// caller's migration activity lease alive and retry on that same active
    /// root until recovery succeeds; releasing early could strand a staged
    /// payload after Settings switches roots.
    private func waitForDeletionRecoveryIfNeeded(
        _ outcome: RecordingsStore.PermanentDeletionOutcome
    ) async {
        let needsRecovery: Bool
        let feedbackAlreadyReportsRecoveryFailure: Bool
        switch outcome {
        case .cleanupPending:
            needsRecovery = true
            feedbackAlreadyReportsRecoveryFailure = false
        case .failed(.rollbackIncomplete), .failed(.pendingCleanupRecoveryFailed):
            needsRecovery = true
            feedbackAlreadyReportsRecoveryFailure = true
        case .deleted, .nothingToDelete, .failed:
            needsRecovery = false
            feedbackAlreadyReportsRecoveryFailure = false
        }
        guard needsRecovery else { return }

#if DEBUG
        if let deletionRecoveryAwaitHookForTesting {
            await deletionRecoveryAwaitHookForTesting()
        }
#endif
        var reportedRecoveryFailure = feedbackAlreadyReportsRecoveryFailure
        while !(await store.recoverPendingDeletionTransactions()) {
            if !reportedRecoveryFailure {
                deletionFeedbackSink(.recoveryNeedsAttention)
                reportedRecoveryFailure = true
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func updateRecordingTitle(recordingID: UUID, title: String) {
        Task {
            await store.updateTitle(recordingID: recordingID, title: title)
        }
    }

    func updateRecordingDate(recordingID: UUID, newDate: Date) {
        Task {
            await store.updateStartDate(recordingID: recordingID, startDate: newDate)
            refreshRecordings()
        }
    }

    private func claimBatchMutation(
        requestedCount: Int
    ) -> RecordingsStore.BatchMutationResult? {
        guard !isBatchMutationInProgress else {
            return .failed(
                requestedCount: requestedCount,
                failure: .operationInProgress
            )
        }
        isBatchMutationInProgress = true
        return nil
    }

    private func completeBatchMutation(
        _ result: RecordingsStore.BatchMutationResult,
        completion: @MainActor (RecordingsStore.BatchMutationResult) -> Void
    ) {
        isBatchMutationInProgress = false
        completion(result)
    }

    func deleteRecording(
        recordingID: UUID,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        Task {
            guard await store.deleteRecording(recordingID: recordingID) else {
                deletionFeedbackSink(.moveToTrashFailed)
                completion(false)
                return
            }
#if DEBUG
            discardCancellationSinkForTesting(recordingID)
#endif
            coordinator?.cancelJob(for: recordingID, disposition: .discard)
            if startupPolicy.externalAccessEnabled {
                webSync?.recordingDidChange(recordingID)
            }
            refreshRecordings()
            refreshTrash()
            completion(true)
        }
    }

    func deleteRecordings(
        recordingIDs: Set<UUID>,
        completion: @escaping @MainActor (RecordingsStore.BatchMutationResult) -> Void = { _ in }
    ) {
        let targetIDs = recordingIDs
        if let blockedResult = claimBatchMutation(requestedCount: targetIDs.count) {
            completion(blockedResult)
            return
        }
        Task {
            let result = await store.trashRecordings(
                recordingIDs: targetIDs,
                reason: "user_batch"
            )
            guard result.didCommit else {
                NSLog("[AppState] batch trash failed: %@", String(describing: result.failure))
                deletionFeedbackSink(.moveToTrashFailed)
                completeBatchMutation(result, completion: completion)
                return
            }
            for recordingID in targetIDs {
#if DEBUG
                discardCancellationSinkForTesting(recordingID)
#endif
                coordinator?.cancelJob(for: recordingID, disposition: .discard)
            }
            if result.committedCount > 0 {
                if startupPolicy.externalAccessEnabled {
                    webSync?.reconcile()
                }
                await reloadBatchMutationSurfaces(includeTrash: true)
            }
            completeBatchMutation(result, completion: completion)
        }
    }

    func restoreRecording(recordingID: UUID) {
        Task {
            guard await store.restoreRecording(recordingID: recordingID) else { return }
            if startupPolicy.externalAccessEnabled {
                webSync?.recordingDidChange(recordingID)
            }
            refreshRecordings()
            refreshTrash()
        }
    }

    func permanentlyDeleteRecording(recordingID: UUID) {
        Task {
            guard let migrationLease = migrationGate.claimActivity() else {
                deletionFeedbackSink(.blockedByStorageMigration)
                return
            }
            defer { migrationGate.releaseActivity(migrationLease) }
#if DEBUG
            if let deletionAwaitHookForTesting { await deletionAwaitHookForTesting() }
#endif
            let deletionPreparation = await coordinator?.prepareForDeletion(
                recordingIDs: [recordingID]
            )
            defer {
                if let deletionPreparation {
                    coordinator?.finishDeletionPreparation(deletionPreparation)
                }
            }
            let outcome = await store.permanentlyDeleteWithOutcome(recordingID: recordingID)
            switch outcome {
            case .deleted:
                break
            case .cleanupPending:
                deletionFeedbackSink(.secureCleanupPending)
            case .nothingToDelete:
                refreshTrash()
                return
            case .failed(let failure):
                deletionFeedbackSink(deletionFeedback(
                    for: failure,
                    fallback: .permanentDeletionFailed
                ))
                await waitForDeletionRecoveryIfNeeded(outcome)
                return
            }
            await waitForDeletionRecoveryIfNeeded(outcome)
            if startupPolicy.externalAccessEnabled { webSync?.reconcile() }
            refreshTrash()
        }
    }

    func emptyTrash() {
        Task {
            guard let migrationLease = migrationGate.claimActivity() else {
                deletionFeedbackSink(.blockedByStorageMigration)
                return
            }
            defer { migrationGate.releaseActivity(migrationLease) }
#if DEBUG
            if let deletionAwaitHookForTesting { await deletionAwaitHookForTesting() }
#endif
            let targetIDs = await store.fetchTrashedRecordings().map(\.id)
            let deletionPreparation = await coordinator?.prepareForDeletion(
                recordingIDs: targetIDs
            )
            defer {
                if let deletionPreparation {
                    coordinator?.finishDeletionPreparation(deletionPreparation)
                }
            }
            let outcome = await store.deleteTrashedRecordingsWithOutcome(
                recordingIDs: targetIDs
            )
            switch outcome {
            case .deleted:
                break
            case .cleanupPending:
                deletionFeedbackSink(.secureCleanupPending)
            case .nothingToDelete:
                return
            case .failed(let failure):
                deletionFeedbackSink(deletionFeedback(
                    for: failure,
                    fallback: .emptyTrashFailed
                ))
                await waitForDeletionRecoveryIfNeeded(outcome)
                return
            }
            await waitForDeletionRecoveryIfNeeded(outcome)
            if startupPolicy.externalAccessEnabled { webSync?.reconcile() }
            refreshTrash()
        }
    }

    func signInToCadenza() async {
        guard startupPolicy.externalAccessEnabled else { return }
        do {
            // Re-login of the bound profile; sign-in never implies
            // historical upload (INV-15) — the consent tri-state alone
            // decides what pre-binding rows may sync.
            try await cadenzaAuth.signIn()
            detectNotionForcedReconnect()
        } catch {
            // CadenzaAuthService classifies and publishes the error for the UI.
        }
    }

    // MARK: - Profile session orchestration (§5.5, §6.1, §7)

    /// Registry surface for profile UI actions; nil in TestHost and
    /// outside profile mode, which disables the whole surface.
    private var liveProfileRegistry: (any ProfileRegistryProviding)? {
#if DEBUG
        if let profileRegistryForTesting { return profileRegistryForTesting }
#endif
        guard profileBootContext?.profile != nil, !AppState.isRunningTests else { return nil }
        let paths = ProfilePaths.live()
        return DiskProfileRegistry(
            registryURL: paths.registryURL, fileOperations: LiveFileOperations()
        )
    }

    var profileActionError: String? {
        get { profileActionErrorStorage }
        set { profileActionErrorStorage = newValue }
    }
    private var profileActionErrorStorage: String?

    /// Fresh registry snapshot for the switcher UI; errors surface instead
    /// of silently presenting an empty list.
    func loadProfileDocument() -> ProfileRegistryDocument? {
        guard profileTransitionPhase == .idle, let registry = liveProfileRegistry else { return nil }
        do {
            return try registry.load()
        } catch {
            NSLog("[AppState] profile registry read failed: %@", String(describing: error))
            profileActionError = String(localized: "Profile settings couldn't be read. Try again.")
            return nil
        }
    }

    func makeProfileLoginCoordinator() -> ProfileLoginCoordinator? {
        guard profileTransitionPhase == .idle,
              let profile = profileBootContext?.profile,
              let registry = liveProfileRegistry else { return nil }
        let paths = ProfilePaths.live()
        let fileOperations = LiveFileOperations()
        return ProfileLoginCoordinator(dependencies: .init(
            auth: cadenzaAuth,
            registry: registry,
            secretStore: KeychainAuthSecretStore(),
            sessionUserStore: { id in
                FileSessionUserStore(
                    url: paths.sessionUserURL(id), fileOperations: fileOperations
                )
            },
            marker: SwiftDataHistoricalConsentMarker(),
            storeURL: { paths.storeURL($0) },
            storePresence: ProfileBindingTransaction.classifiedStorePresence(
                fileOperations: fileOperations
            ),
            defaults: .standard,
            activeStore: .init(
                markAll: { [weak self] transactionID in
                    guard let store = self?.store else {
                        throw ProfileBindingTransaction.BindingError.inconsistentState(
                            "store unavailable"
                        )
                    }
                    return try await store.markAllRecordingsAwaitingHistoricalConsent(
                        transactionID: transactionID
                    )
                },
                clearMarks: { [weak self] transactionID in
                    guard let store = self?.store else {
                        throw ProfileBindingTransaction.BindingError.inconsistentState(
                            "store unavailable"
                        )
                    }
                    return try await store.clearHistoricalConsentMarks(
                        transactionID: transactionID
                    )
                }
            ),
            activeProfile: profile,
            now: { Date() },
            relaunch: { [weak self] in self?.performProfileRelaunch() },
            transferRelaunch: { [weak self] in self?.performTransferRelaunch() },
            haltTransition: { [weak self] reason in
                self?.haltProfileTransition(reason: reason)
            },
            transitionRefusal: { [weak self] in self?.profileTransitionBlockReason },
            prepareTransition: { [weak self] in
                await self?.prepareProfileTransition() ?? false
            },
            resumeAfterRefusedTransition: { [weak self] in
                self?.resumeProfileServicesAfterRefusedTransition()
            },
            beginTransfer: { request in
                try ProfileTransfer.begin(
                    request: request,
                    dependencies: .init(
                        registry: registry,
                        storeURL: { paths.storeURL($0) },
                        inspector: LiveTransferStoreInspector(
                            fileOperations: fileOperations
                        ),
                        fileOperations: fileOperations,
                        now: { Date() }
                    )
                )
            }
        ))
    }

    /// Profile-transition runtime phase: `relaunching` starts the moment
    /// an active-profile change is durably committed — the old process no
    /// longer owns the registry's active store, so every data, recording,
    /// and profile command refuses until the replacement instance takes
    /// over. `halted` is the terminal unknown state that requires a
    /// manual restart. Only a proven rollback returns to `idle` and
    /// explicitly resumes the old profile's services.
    enum ProfileTransitionPhase: Equatable {
        case idle
        /// Bounded quiescence ahead of any registry authority change: new
        /// commands refuse, sync stops, and MCP drains its in-flight
        /// handlers. A failed drain refuses the transition and resumes.
        case preparing
        case relaunching
        case halted(String)
    }

    private(set) var profileTransitionPhase: ProfileTransitionPhase = .idle

    var transitionHaltReason: String? {
        if case .halted(let reason) = profileTransitionPhase { return reason }
        return nil
    }

    /// True whenever the process may not produce or serve data.
    var isProfileTransitionActive: Bool { profileTransitionPhase != .idle }

    func haltProfileTransition(reason: String) {
        profileTransitionPhase = .halted(reason)
        stopExternalSurfaces()
    }

#if DEBUG
    /// Test seam: replaces the NSWorkspace relaunch with a scripted hook.
    var relaunchHandlerForTesting: ((@escaping @MainActor (String) -> Void) -> Void)?
    /// Test seam: replaces the MCP drain with a scripted awaitable.
    var mcpDrainForTesting: (() async -> Bool)?
#endif

    /// Quiesces every old-store surface ahead of the registry authority
    /// changes: gates commands (phase `preparing`), stops sync, and
    /// drains MCP's in-flight handlers within a bound. False refuses the
    /// transition — services resume and nothing was committed.
    func prepareProfileTransition() async -> Bool {
        guard profileTransitionPhase == .idle else { return false }
        profileTransitionPhase = .preparing
        var drained = true
        if let sync = webSync {
            drained = await sync.stopAndWait()
        }
#if DEBUG
        if let scripted = mcpDrainForTesting {
            drained = await scripted() && drained
        } else if let server = mcpServer, drained {
            mcpServer = nil
            drained = await server.stopAndWait()
            mcpServerStatus = .stopped
        }
#else
        if let server = mcpServer, drained {
            mcpServer = nil
            drained = await server.stopAndWait()
            mcpServerStatus = .stopped
        }
#endif
        if !drained {
            resumeProfileServicesAfterRefusedTransition()
            return false
        }
        return true
    }

    /// Proven-untouched registry: return to idle and restart the old
    /// profile's services explicitly.
    func resumeProfileServicesAfterRefusedTransition() {
        profileTransitionPhase = .idle
        webSync?.resume()
        syncMCPServer()
    }

    /// Synchronously initiates shutdown of every surface that could keep
    /// reading or writing the old store across a transition: sync and the
    /// MCP listener.
    private func stopExternalSurfaces() {
        webSync?.stop()
        if let server = mcpServer {
            mcpServer = nil
            Task { await server.stop() }
        }
        mcpServerStatus = .stopped
    }

    /// Whether the active profile is bound to an account: the direct
    /// re-auth entry applies only then — unbound profiles sign in through
    /// the Profiles login flow, which decides binding.
    var activeProfileIsBound: Bool {
        profileBootContext?.profile?.boundAccount != nil
    }

    /// Live INV-13 state for UI: non-nil (localized) while switching,
    /// sign-out, or relaunch entry points must stay disabled.
    var profileTransitionBlockReason: String? {
        if profileTransitionPhase != .idle {
            return String(localized: "A profile change is already in progress.")
        }
        if recordingEngine.isStopping {
            return String(localized: "Finish or stop the current recording before switching profiles.")
        }
        if isRecording {
            return String(localized: "Finish or stop the current recording before switching profiles.")
        }
        if coordinator?.hasActiveWork == true {
            return String(localized: "Wait for transcription and summary to finish before switching profiles.")
        }
        if StorageMigrationGate.shared.isMigrationClaimed {
            return String(localized: "Wait for the storage location change to finish before switching profiles.")
        }
        return nil
    }

    /// Routes a sign-in tap by binding state: bound profiles re-auth in
    /// place; unbound profiles go to the Profiles pane, where the login
    /// flow decides binding.
    func presentSignIn() {
        if activeProfileIsBound {
            Task { await signInToCadenza() }
        } else {
            openSettings(category: .profiles)
        }
    }

    /// Applies a classified commit outcome for a transition whose target
    /// became the registry's active profile.
    private func completeActiveTransition(_ outcome: ProfileSwitchCoordinator.CommitOutcome) {
        switch outcome {
        case .committed:
            performProfileRelaunch()
        case .notCommitted(let detail):
            NSLog("[AppState] profile switch not committed: %@", detail)
            resumeProfileServicesAfterRefusedTransition()
            profileActionError = String(
                localized: "The profile switch was not saved — nothing changed."
            )
        case .indeterminate(let detail):
            haltProfileTransition(reason: detail)
        }
    }

    /// Relaunch after a committed active-profile write. If no new instance
    /// launches, the disk authority names a profile this process is not
    /// serving: roll the active ID back to this process's profile; if even
    /// that cannot be proven, halt.
    func performProfileRelaunch() {
        // The registry now names a profile this process is not serving:
        // every command keeps refusing while the replacement spawns.
        profileTransitionPhase = .relaunching
        stopExternalSurfaces()
        let onFailure: @MainActor (String) -> Void = { [weak self] detail in
            guard let self else { return }
            guard let registry = self.liveProfileRegistryIgnoringPhase,
                  let currentID = self.profileBootContext?.profile?.id else {
                self.haltProfileTransition(reason: "relaunch failed: \(detail)")
                return
            }
            let rollback = ProfileSwitchCoordinator.commitActiveProfile(
                to: currentID,
                registry: registry,
                precondition: { _ in nil },
                mutate: { _ in }
            )
            switch rollback {
            case .committed:
                // Proven rollback: the old profile owns the registry again
                // — return to idle and resume its services explicitly.
                self.profileTransitionPhase = .idle
                self.webSync?.resume()
                self.syncMCPServer()
                self.profileActionError = String(
                    localized: "Cadenza couldn't restart itself. The switch was undone — please quit and reopen to try again."
                )
            case .notCommitted(let rollbackDetail), .indeterminate(let rollbackDetail):
                self.haltProfileTransition(
                    reason: "relaunch failed and rollback unproven: \(rollbackDetail)"
                )
            }
        }
#if DEBUG
        if let handler = relaunchHandlerForTesting {
            handler(onFailure)
            return
        }
#endif
        ProfileSwitchCoordinator.relaunch(onFailure: onFailure)
    }

    /// Relaunch with a durable pendingTransfer in the registry. The
    /// switch-style rollback does not apply: activeProfileID never moved,
    /// so a rollback save would merely re-prove the source while leaving
    /// the transfer intent in place — and resuming WebSync/MCP would run
    /// source services against a store the next boot hands to the
    /// transfer executor. A spawn failure therefore halts this session,
    /// keeps pendingTransfer untouched, and never resumes services.
    func performTransferRelaunch() {
        profileTransitionPhase = .relaunching
        stopExternalSurfaces()
        let onFailure: @MainActor (String) -> Void = { [weak self] detail in
            self?.haltProfileTransition(
                reason: "relaunch failed with a pending transfer: \(detail)"
            )
        }
#if DEBUG
        if let handler = relaunchHandlerForTesting {
            handler(onFailure)
            return
        }
#endif
        ProfileSwitchCoordinator.relaunch(onFailure: onFailure)
    }

    /// Registry access for the rollback path, which must work while the
    /// transition phase blocks every ordinary action.
    private var liveProfileRegistryIgnoringPhase: (any ProfileRegistryProviding)? {
#if DEBUG
        if let profileRegistryForTesting { return profileRegistryForTesting }
#endif
        guard profileBootContext?.profile != nil, !AppState.isRunningTests else { return nil }
        let paths = ProfilePaths.live()
        return DiskProfileRegistry(
            registryURL: paths.registryURL, fileOperations: LiveFileOperations()
        )
    }

#if DEBUG
    /// Test seam: scripted registry for profile-action tests, which the
    /// TestHost guard otherwise disables.
    var profileRegistryForTesting: (any ProfileRegistryProviding)?
#endif

    /// Relaunch-based switch (§7) behind the INV-13 guards, with the
    /// quiescence barrier ahead of the authority change.
    func switchProfile(to targetID: UUID) async {
        guard profileTransitionPhase == .idle, let registry = liveProfileRegistry else { return }
        guard await prepareProfileTransition() else {
            profileActionError = String(
                localized: "Cadenza couldn't pause background work — nothing changed. Try again."
            )
            return
        }
        let outcome = ProfileSwitchCoordinator.performSwitch(
            to: targetID,
            registry: registry,
            isRecording: isRecording || recordingEngine.isStopping,
            isPostProcessing: coordinator?.hasActiveWork == true,
            isStorageMigrationActive: StorageMigrationGate.shared.isMigrationClaimed
        )
        completeActiveTransition(outcome)
    }

    static func switchRefusalMessage(_ refusal: ProfileSwitchCoordinator.Refusal) -> String {
        switch refusal {
        case .recordingActive:
            return String(localized: "Finish or stop the current recording before switching profiles.")
        case .postProcessingActive:
            return String(localized: "Wait for transcription and summary to finish before switching profiles.")
        case .storageMigrationActive:
            return String(localized: "Wait for the storage location change to finish before switching profiles.")
        case .operationInFlight:
            return String(localized: "Another profile operation is in progress — try again when it finishes.")
        case .targetMissing:
            return String(localized: "That profile no longer exists.")
        case .targetLocked:
            return String(localized: "That profile is locked. Sign in with its account to unlock it.")
        case .alreadyActive:
            return String(localized: "That profile is already active.")
        }
    }

    /// Sign out of the bound profile (§6.1). Order: the INV-13 guards
    /// refuse first; sync stops synchronously; the local credential is
    /// durably invalidated (a failed cleanup aborts — never a claimed
    /// sign-out with a live credential at rest); then one classified
    /// registry commit carries the disposition, the optional lock, and
    /// the switch back to Local; the backend revoke stays best-effort. A
    /// registry failure after the local cleanup leaves the profile
    /// tokenless and retryable.
    func signOutFromProfile() async {
        guard profileTransitionPhase == .idle else { return }
        guard let profile = profileBootContext?.profile,
              let expectedBound = profile.boundAccount,
              let registry = liveProfileRegistry else { return }
        let document: ProfileRegistryDocument
        do {
            document = try registry.load()
        } catch {
            NSLog("[AppState] sign-out registry read failed: %@", String(describing: error))
            profileActionError = String(localized: "Profile settings couldn't be read. Try again.")
            return
        }
        guard let local = document.profiles.first(where: { $0.kind == .system }),
              !local.isLocked else {
            profileActionError = String(
                localized: "The Local profile is missing — sign-out cannot continue."
            )
            return
        }
        if let refusal = ProfileSwitchCoordinator.refusal(
            document: document,
            targetID: local.id,
            isRecording: isRecording || recordingEngine.isStopping,
            isPostProcessing: coordinator?.hasActiveWork == true,
            isStorageMigrationActive: StorageMigrationGate.shared.isMigrationClaimed
        ), refusal != .alreadyActive {
            profileActionError = Self.switchRefusalMessage(refusal)
            return
        }
        guard document.activeProfileID == profile.id,
              let current = document.profiles.first(where: { $0.id == profile.id }),
              !current.isLocked,
              let currentBound = current.boundAccount,
              AccountIdentity.matches(currentBound.userID, expectedBound.userID),
              AccountIdentity.matches(currentBound.originKey, expectedBound.originKey),
              AccountIdentity.matches(currentBound.issuerOrigin, expectedBound.issuerOrigin),
              AccountIdentity.matches(currentBound.apiBaseURL, expectedBound.apiBaseURL) else {
            profileActionError = String(
                localized: "The profile changed — sign out again to retry."
            )
            return
        }

        guard await prepareProfileTransition() else {
            profileActionError = String(
                localized: "Cadenza couldn't pause background work — nothing changed. Try again."
            )
            return
        }
        guard cadenzaAuth.signOut() else {
            resumeProfileServicesAfterRefusedTransition()
            profileActionError = AuthError.sessionCleanupFailed.localizedMessage()
            return
        }
        // Bounded chance for the best-effort backend revoke before the
        // process goes away; expiry never depends on it.
        if let revoke = cadenzaAuth.pendingRevokeTask {
            _ = await TaskDrain.awaitAll([revoke], timeout: .seconds(2))
        }

        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: local.id,
            registry: registry,
            precondition: { fresh in
                guard fresh.pendingBinding == nil, fresh.pendingTransfer == nil else {
                    return "operation in flight"
                }
                guard fresh.activeProfileID == profile.id,
                      fresh.profiles.contains(where: { candidate in
                          guard candidate.id == profile.id,
                                let bound = candidate.boundAccount else { return false }
                          return AccountIdentity.matches(bound.userID, expectedBound.userID)
                              && AccountIdentity.matches(bound.originKey, expectedBound.originKey)
                              && AccountIdentity.matches(
                                  bound.issuerOrigin, expectedBound.issuerOrigin
                              )
                              && AccountIdentity.matches(
                                  bound.apiBaseURL, expectedBound.apiBaseURL
                              )
                      }) else {
                    return "profile changed during sign-out"
                }
                return nil
            },
            mutate: { fresh in
                guard let index = fresh.profiles.firstIndex(where: { $0.id == profile.id })
                else { return }
                fresh.profiles[index].sessionDisposition = .explicitlySignedOut
                fresh.profiles[index].isLocked = fresh.profiles[index].lockOnSignOut
            }
        )
        switch outcome {
        case .committed:
            performProfileRelaunch()
        case .notCommitted(let detail):
            NSLog("[AppState] sign-out not committed: %@", detail)
            resumeProfileServicesAfterRefusedTransition()
            profileActionError = String(
                localized: "Your session was cleared, but the profile switch didn't save — this profile now shows as expired. Sign out again to finish."
            )
        case .indeterminate(let detail):
            haltProfileTransition(reason: detail)
        }
    }

    /// Arms or disarms the lock-on-sign-out flag for the active profile.
    /// Returns the value durably in effect after the attempt, so the UI
    /// reflects a save that provably landed despite throwing and rolls
    /// back only a proven-uncommitted one.
    @discardableResult
    func setLockOnSignOut(_ enabled: Bool) -> Bool {
        let entryValue = profileBootContext?.profile?.lockOnSignOut ?? !enabled
        guard profileTransitionPhase == .idle,
              let profile = profileBootContext?.profile,
              let registry = liveProfileRegistry else { return entryValue }
        let document: ProfileRegistryDocument
        do {
            document = try registry.load()
        } catch {
            NSLog("[AppState] setLockOnSignOut read failed: %@", String(describing: error))
            profileActionError = String(localized: "Profile settings couldn't be read. Try again.")
            return entryValue
        }
        guard let index = document.profiles.firstIndex(where: { $0.id == profile.id }) else {
            profileActionError = String(localized: "The active profile is missing from the registry.")
            return entryValue
        }
        // Fresh authority proof: a stale process must not mutate a
        // security policy on a profile no longer its own.
        guard document.activeProfileID == profile.id else {
            profileActionError = String(
                localized: "This profile is no longer active, so the change was not saved."
            )
            return entryValue
        }
        guard !document.profiles[index].isLocked else {
            profileActionError = String(localized: "This profile is locked.")
            return entryValue
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            profileActionError = String(
                localized: "Another profile operation is in progress — try again when it finishes."
            )
            return entryValue
        }
        guard AccountIdentity.boundTupleMatches(
            document.profiles[index].boundAccount, profile.boundAccount
        ) else {
            profileActionError = String(localized: "The change couldn't be saved — try again.")
            return entryValue
        }
        let priorValue = document.profiles[index].lockOnSignOut
        guard priorValue != enabled else {
            profileBootContext?.profile?.lockOnSignOut = enabled
            return enabled
        }
        var intended = document
        intended.profiles[index].lockOnSignOut = enabled
        switch ProfileSwitchCoordinator.classifiedSave(
            old: document, intended: intended, registry: registry
        ) {
        case .committed:
            profileBootContext?.profile?.lockOnSignOut = enabled
            return enabled
        case .notCommitted(let detail):
            NSLog("[AppState] setLockOnSignOut not committed: %@", detail)
            profileActionError = String(localized: "The change couldn't be saved — try again.")
            profileBootContext?.profile?.lockOnSignOut = priorValue
            return priorValue
        case .indeterminate(let detail):
            NSLog("[AppState] setLockOnSignOut indeterminate: %@", detail)
            // Effective value unknown from the write alone: a readable
            // registry decides; an unreadable one reports and keeps the
            // last proven value.
            do {
                let reread = try registry.load()
                guard let current = reread.profiles.first(where: { $0.id == profile.id }) else {
                    profileActionError = String(
                        localized: "The change couldn't be verified. Quit and reopen Cadenza, then check this setting."
                    )
                    return priorValue
                }
                profileActionError = String(
                    localized: "The change couldn't be verified. Quit and reopen Cadenza, then check this setting."
                )
                profileBootContext?.profile?.lockOnSignOut = current.lockOnSignOut
                return current.lockOnSignOut
            } catch {
                profileActionError = String(
                    localized: "The change couldn't be verified. Quit and reopen Cadenza, then check this setting."
                )
                return priorValue
            }
        }
    }

    func removeTag(recordingID: UUID, tag: String) {
        Task {
            await store.removeTag(recordingID: recordingID, tag: tag)
            refreshRecordings()
        }
    }

    func toggleActionItem(recordingID: UUID, actionItemID: UUID) {
        Task {
            await store.toggleActionItem(recordingID: recordingID, actionItemID: actionItemID)
            recordingsChangedToken += 1
        }
    }

    func updateActionItem(recordingID: UUID, actionItemID: UUID, task: String? = nil, assignee: String? = nil, deadline: String? = nil, priority: ActionPriority? = nil) {
        Task {
            await store.updateActionItem(recordingID: recordingID, actionItemID: actionItemID, task: task, assignee: assignee, deadline: deadline, priority: priority)
            recordingsChangedToken += 1
        }
    }

    func addActionItem(recordingID: UUID, task: String) {
        Task {
            await store.addActionItem(recordingID: recordingID, task: task)
            recordingsChangedToken += 1
        }
    }

    func moveRecordingToFolder(recordingID: UUID, folderID: UUID?) {
        Task {
            await store.moveToFolder(recordingID: recordingID, folderID: folderID)
            refreshRecordings()
        }
    }

    func moveRecordingsToFolder(
        recordingIDs: Set<UUID>,
        folderID: UUID?,
        completion: @escaping @MainActor (RecordingsStore.BatchMutationResult) -> Void = { _ in }
    ) {
        let targetIDs = recordingIDs
        if let blockedResult = claimBatchMutation(requestedCount: targetIDs.count) {
            completion(blockedResult)
            return
        }
        Task {
            let result = await store.moveRecordingsToFolder(
                recordingIDs: targetIDs,
                folderID: folderID
            )
            guard result.didCommit else {
                NSLog("[AppState] batch folder move failed: %@", String(describing: result.failure))
                batchMutationFailureSink()
                completeBatchMutation(result, completion: completion)
                return
            }
            if result.committedCount > 0 {
                if startupPolicy.externalAccessEnabled {
                    webSync?.reconcile()
                }
                await reloadBatchMutationSurfaces(includeFolders: true)
            }
            completeBatchMutation(result, completion: completion)
        }
    }

    func smartFolder(id: String) -> SmartFolderDTO? {
        smartFolderCache.folder(id: id)
    }

    func recordings(inSmartFolder id: String) -> [RecordingDTO] {
        smartFolderCache.recordings(in: id)
    }

    @discardableResult
    func pinRecordingToSmartFolder(recordingID: UUID, smartFolderID: String) -> Bool {
        pinRecordingsToSmartFolder(
            recordingIDs: [recordingID],
            smartFolderID: smartFolderID
        )
    }

    @discardableResult
    func pinRecordingsToSmartFolder(
        recordingIDs: Set<UUID>,
        smartFolderID: String
    ) -> Bool {
        let result = smartFolderOverrideStore.pin(
            recordingIDs: recordingIDs,
            to: smartFolderID
        )
        guard result.didCommit else {
            NSLog("[AppState] Smart Folder pin failed: %@", String(describing: result.failure))
            batchMutationFailureSink()
            return false
        }
        if result.changedCount > 0 {
            rebuildSmartFolderCache()
            smartFolderOverridesChangedToken += 1
        }
        return true
    }

    @discardableResult
    func excludeRecordingFromSmartFolder(recordingID: UUID, smartFolderID: String) -> Bool {
        excludeRecordingsFromSmartFolder(
            recordingIDs: [recordingID],
            smartFolderID: smartFolderID
        )
    }

    @discardableResult
    func excludeRecordingsFromSmartFolder(
        recordingIDs: Set<UUID>,
        smartFolderID: String
    ) -> Bool {
        let result = smartFolderOverrideStore.exclude(
            recordingIDs: recordingIDs,
            from: smartFolderID
        )
        guard result.didCommit else {
            NSLog("[AppState] Smart Folder exclusion failed: %@", String(describing: result.failure))
            batchMutationFailureSink()
            return false
        }
        if result.changedCount > 0 {
            rebuildSmartFolderCache()
            smartFolderOverridesChangedToken += 1
        }
        return true
    }

    @discardableResult
    func resetSmartFolderOverride(recordingID: UUID, smartFolderID: String) -> Bool {
        resetSmartFolderOverrides(
            recordingIDs: [recordingID],
            smartFolderID: smartFolderID
        )
    }

    @discardableResult
    func resetSmartFolderOverrides(
        recordingIDs: Set<UUID>,
        smartFolderID: String
    ) -> Bool {
        let result = smartFolderOverrideStore.clear(
            recordingIDs: recordingIDs,
            in: smartFolderID
        )
        guard result.didCommit else {
            NSLog("[AppState] Smart Folder reset failed: %@", String(describing: result.failure))
            batchMutationFailureSink()
            return false
        }
        if result.changedCount > 0 {
            rebuildSmartFolderCache()
            smartFolderOverridesChangedToken += 1
        }
        return true
    }

#if DEBUG
    func setSmartFolderOverrideStoreForTesting(_ store: SmartFolderOverrideStore) {
        smartFolderOverrideStore = store
    }
#endif

    func saveSmartFolderAsFolder(
        smartFolderID: String,
        completion: @escaping @MainActor (RecordingsStore.BatchMutationResult) -> Void = { _ in }
    ) {
        guard let smartFolder = smartFolder(id: smartFolderID) else {
            completion(.failed(requestedCount: 0, failure: .fetchFailed))
            return
        }
        let recordingIDs = Set(smartFolder.recordingIDs)
        if let blockedResult = claimBatchMutation(requestedCount: recordingIDs.count) {
            completion(blockedResult)
            return
        }
        Task {
            guard let folder = await store.createFolder(
                name: smartFolder.title,
                icon: smartFolder.icon,
                iconColor: smartFolder.iconColor
            ) else {
                NSLog("[AppState] save Smart Folder folder creation failed")
                batchMutationFailureSink()
                completeBatchMutation(
                    .failed(
                        requestedCount: recordingIDs.count,
                        failure: .persistenceFailed
                    ),
                    completion: completion
                )
                return
            }

            let result = await store.moveRecordingsToFolder(
                recordingIDs: recordingIDs,
                folderID: folder.id
            )
            guard result.didCommit else {
                NSLog(
                    "[AppState] save Smart Folder batch move failed: %@",
                    String(describing: result.failure)
                )
                if !(await store.deleteFolder(id: folder.id)) {
                    NSLog("[AppState] failed to roll back empty folder after batch move")
                }
                batchMutationFailureSink()
                completeBatchMutation(result, completion: completion)
                return
            }
            if result.committedCount > 0, startupPolicy.externalAccessEnabled {
                webSync?.reconcile()
            }
            await reloadBatchMutationSurfaces(includeFolders: true)
            completeBatchMutation(result, completion: completion)
        }
    }

    func createFolder(name: String, icon: String, iconColor: String) {
        Task {
            _ = await store.createFolder(name: name, icon: icon, iconColor: iconColor)
            refreshFolders()
        }
    }

    func updateFolder(folderID: UUID, name: String, icon: String, iconColor: String) {
        Task {
            await store.updateFolder(id: folderID, name: name, icon: icon, iconColor: iconColor)
            refreshFolders()
        }
    }

    func deleteFolder(folderID: UUID) {
        Task {
            await store.deleteFolder(id: folderID)
            refreshFolders()
        }
    }

    func linkCalendarEvent(recordingID: UUID, calendarEventID: String?) {
        Task {
            await store.linkCalendarEvent(recordingID: recordingID, calendarEventID: calendarEventID)
            recordingsChangedToken += 1
        }
    }

    /// Auto-link a recording to the best-matching calendar event by time overlap.
    func autoLinkCalendarEvent(recordingID: UUID, startDate: Date, endDate: Date) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.linkBestCalendarEvent(recordingID: recordingID, startDate: startDate, endDate: endDate) == .linked {
                self.refreshRecordings()
            }
        }
    }

    private func autoLinkPendingCalendarCandidates() async {
        guard hasCalendarPermission || googleCalendarConnected || zoomConnected else { return }

        let repaired = await store.repairCalendarAutoLinkDatesFromAudioFilenames()
        if repaired > 0 {
            NSLog("[AppState] repaired %d recording date(s) from audio filenames before calendar auto-link", repaired)
        }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.calendarAutoLinkRemoteRetryDefaultsKey) {
            let requeued = await store.requeueCalendarAutoLinkNoMatchesForRetry()
            if requeued > 0 {
                NSLog("[AppState] requeued %d prior no-match recording(s) for calendar auto-link retry", requeued)
            }
            defaults.set(true, forKey: Self.calendarAutoLinkRemoteRetryDefaultsKey)
        }

        let candidates = await store.fetchCalendarAutoLinkCandidates()
        guard !candidates.isEmpty else { return }

        var linkedCount = 0
        var noMatchCount = 0
        var deferredCount = 0
        for candidate in candidates {
            switch await linkBestCalendarEvent(
                recordingID: candidate.id,
                startDate: candidate.startDate,
                endDate: candidate.endDate
            ) {
            case .linked:
                linkedCount += 1
            case .noMatch:
                noMatchCount += 1
            case .deferred:
                deferredCount += 1
            }
        }

        if linkedCount > 0 || deferredCount > 0 {
            NSLog(
                "[AppState] auto-linked %d recording(s) to calendar events, noMatch=%d, deferred=%d",
                linkedCount,
                noMatchCount,
                deferredCount
            )
        }
        if linkedCount > 0 {
            refreshRecordings()
        }
    }

    private func linkBestCalendarEvent(recordingID: UUID, startDate: Date, endDate: Date) async -> CalendarAutoLinkResult {
        guard hasCalendarPermission || googleCalendarConnected || zoomConnected else { return .deferred }

        let windowStart = Calendar.current.date(byAdding: .minute, value: -2, to: startDate) ?? startDate
        let windowEnd = Calendar.current.date(byAdding: .minute, value: 5, to: endDate) ?? endDate
        let fetchResult = await calendarManager.fetchEventsForAutoLink(from: windowStart, to: windowEnd)
        guard let event = CalendarAutoLinkResolver.bestEvent(
            startDate: startDate,
            endDate: endDate,
            events: fetchResult.events
        ) else {
            guard fetchResult.canConcludeNoMatch else { return .deferred }
            _ = await store.markCalendarAutoLinkNoMatch(recordingID: recordingID)
            return .noMatch
        }
        let saved = await store.linkCalendarEvent(recordingID: recordingID, calendarEventID: event.id)
        if saved {
            recordingsChangedToken += 1
        }
        return saved ? .linked : .deferred
    }

    /// Fetch the linked calendar event for a recording, if any.
    func fetchLinkedCalendarEvent(
        calendarEventID: String,
        around startDate: Date? = nil,
        endDate: Date? = nil
    ) -> MeetingEventDTO? {
        let from: Date
        let to: Date
        if let startDate {
            let calendar = Calendar.current
            let startDay = calendar.startOfDay(for: startDate)
            let endDay = calendar.startOfDay(for: endDate ?? startDate)
            from = calendar.date(byAdding: .day, value: -1, to: startDay) ?? startDay
            to = calendar.date(byAdding: .day, value: 2, to: max(startDay, endDay)) ?? endDay
        } else {
            // Fallback for older call sites without recording context.
            let now = Date()
            from = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            to = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        }
        let events = calendarManager.fetchEvents(from: from, to: to)
        if let match = events.first(where: { $0.id == calendarEventID }) {
            return MeetingEventDTO(from: match)
        }
        return nil
    }

    /// Fetch candidate calendar events for linking (events around the recording time).
    func fetchCandidateEvents(around startDate: Date, endDate: Date?) -> [MeetingEventDTO] {
        let dayStart = Calendar.current.startOfDay(for: startDate)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let events = calendarManager.fetchEvents(from: dayStart, to: dayEnd)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        return events.map { MeetingEventDTO(from: $0) }
    }

    // MARK: - Calendar Commands (direct — no XPC)

    func refreshCalendars() {
        calendarManager.refreshAll()
        refreshCalendarState()
    }

    nonisolated static func meetingDetectionEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "enableMeetingDetection") as? Bool ?? false
    }

    var isMeetingDetectionEnabled: Bool {
        Self.meetingDetectionEnabled(in: .standard)
    }

    func setMeetingDetectionEnabled(_ enabled: Bool) {
        updateMeetingDetection(enabled: enabled, force: false)
        if !enabled {
            overlayController.dismissPrompt()
        }
    }

    func fetchEvents(from: Date, to: Date, completion: @escaping ([MeetingEventDTO]) -> Void) {
        let events = calendarManager.fetchEvents(from: from, to: to)
        completion(events.map { MeetingEventDTO(from: $0) })
    }

    // MARK: - Export (direct — no XPC)

    func exportToNotion(recordingID: UUID) async throws {
        guard startupPolicy.externalAccessEnabled else { throw CancellationError() }
        guard let detail = await store.fetchRecordingDetail(recordingID: recordingID) else {
            throw ExportError.recordingNotFound
        }
        try await exportService.exportToNotion(detail)
    }

    func exportToCraft(recordingID: UUID) async throws {
        guard startupPolicy.externalAccessEnabled else { throw CancellationError() }
        guard let detail = await store.fetchRecordingDetail(recordingID: recordingID) else {
            throw ExportError.recordingNotFound
        }
        try await exportService.exportToCraft(detail)
    }

    // MARK: - OAuth (direct — no XPC)

    func googleCalendarCredentials() -> GoogleCalendarService.OAuthCredentials {
        guard startupPolicy.externalAccessEnabled else {
            return .init(clientID: "", clientSecret: "")
        }
        return calendarManager.googleCalendarService.configuredCredentials()
    }

    @discardableResult
    func saveGoogleCalendarCredentials(clientID: String, clientSecret: String) -> Bool {
        guard startupPolicy.externalAccessEnabled else { return false }
        do {
            try calendarManager.googleCalendarService.saveCredentials(
                clientID: clientID,
                clientSecret: clientSecret
            )
            calendarManager.googleCalendarService.error = nil
            return true
        } catch {
            calendarManager.googleCalendarService.error = Self.googleCredentialSaveFailureMessage(
                for: error
            )
            NSLog(
                "[AppState] Google Calendar credential save failed: %@",
                error.localizedDescription
            )
            return false
        }
    }

    func connectGoogleCalendar() {
        guard startupPolicy.externalAccessEnabled else { return }
        Task {
            do {
                try await calendarManager.googleCalendarService.connect()
                refreshCalendars()
            } catch {
                calendarManager.googleCalendarService.error = error.localizedDescription
                NSLog("[AppState] connectGoogleCalendar error: \(error)")
            }
        }
    }

    func disconnectGoogleCalendar() {
        guard startupPolicy.externalAccessEnabled else { return }
        do {
            try calendarManager.googleCalendarService.disconnect()
            calendarManager.googleCalendarService.error = nil
        } catch {
            calendarManager.googleCalendarService.error = Self.googleDisconnectFailureMessage(
                for: error
            )
            NSLog("[AppState] disconnectGoogleCalendar failed: %@", error.localizedDescription)
        }
    }

    /// Stable user-facing credential failures. The underlying Keychain/OAuth
    /// error is intentionally accepted but never interpolated; raw detail is
    /// retained only in the adjacent private diagnostic log.
    static func googleCredentialSaveFailureMessage(
        for _: any Error,
        locale: Locale? = nil
    ) -> String {
        LocalizedBundle.string(
            "API key could not be saved securely. Please try again.",
            locale: locale
        )
    }

    static func googleDisconnectFailureMessage(
        for _: any Error,
        locale: Locale? = nil
    ) -> String {
        LocalizedBundle.string(
            "API key could not be removed securely. Please try again.",
            locale: locale
        )
    }

    func connectZoom() {
        guard startupPolicy.externalAccessEnabled else { return }
        Task {
            do {
                try await calendarManager.zoomMeetingService.connect()
                refreshCalendars()
            } catch {
                calendarManager.zoomMeetingService.error = error.localizedDescription
                NSLog("[AppState] connectZoom error: \(error)")
            }
        }
    }

    func disconnectZoom() {
        guard startupPolicy.externalAccessEnabled else { return }
        do {
            try calendarManager.zoomMeetingService.disconnect()
        } catch {
            NSLog("[AppState] disconnectZoom failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Notion (direct — no XPC)

    func connectNotion() {
        guard startupPolicy.externalAccessEnabled else { return }
        Task {
            do {
                try await exportService.notionService.connect()
            } catch {
                // NotionExportService.connect() already populated lastError
                // via AuthError.classify(); no need to re-set it here.
                NSLog("[AppState] connectNotion error: \(error)")
            }
        }
    }

    func disconnectNotion() {
        guard startupPolicy.externalAccessEnabled else { return }
        exportService.notionService.disconnect()
    }

    /// Surface "Reconnect Notion to Cadenza Cloud" UI when a legacy token
    /// exists in keychain but the backend vault doesn't have a row.
    func detectNotionForcedReconnect() {
        guard startupPolicy.externalAccessEnabled else { return }
        Task { await exportService.notionService.detectForcedReconnect() }
    }

    func fetchNotionDatabases(completion: @escaping ([NotionDatabaseDTO]) -> Void) {
        guard startupPolicy.externalAccessEnabled else {
            completion([])
            return
        }
        Task {
            do {
                let dbs = try await exportService.notionService.fetchDatabases()
                completion(dbs.map { NotionDatabaseDTO(id: $0.id, title: $0.title) })
            } catch {
                NSLog("[AppState] fetchNotionDatabases error: \(error)")
                completion([])
            }
        }
    }

    func createNotionDatabase(completion: @escaping (NotionDatabaseDTO?) -> Void) {
        guard startupPolicy.externalAccessEnabled else {
            completion(nil)
            return
        }
        Task {
            do {
                let container = try await exportService.notionService.createContainerPage(title: "Cadenza")
                let db = try await exportService.notionService.createDatabase(
                    parentPageID: container.id, title: "Cadenza Meetings")
                completion(NotionDatabaseDTO(id: db.id, title: db.title))
            } catch {
                NSLog("[AppState] createNotionDatabase error: \(error)")
                completion(nil)
            }
        }
    }

    // MARK: - Calendar Info (direct — no XPC)

    func fetchAvailableCalendars(completion: @escaping ([CalendarInfo]) -> Void) {
        completion(calendarManager.availableCalendars())
    }

    // MARK: - Data Refresh (via local store)

    /// Batch mutations already own one MainActor task. Reload every affected
    /// surface inside that task, rebuild Smart Folders once, and advance the
    /// recording token once rather than spawning one refresh task per ID.
    private func reloadBatchMutationSurfaces(
        includeTrash: Bool = false,
        includeFolders: Bool = false
    ) async {
        let sortKey = UserDefaults.standard.string(forKey: "recordingsSort") ?? "dateNewest"
        recordings = await store.fetchRecordingDTOs(
            sortKey: sortKey,
            folderID: nil,
            tagFilter: nil
        )
        if includeTrash {
            trashedRecordings = await store.fetchTrashedRecordings()
        }
        if includeFolders {
            folders = await store.fetchFolders()
        }
        rebuildSmartFolderCache()
        isLoadingRecordings = false
        recordingsChangedToken += 1
    }

    func refreshRecordings() {
        let sortKey = UserDefaults.standard.string(forKey: "recordingsSort") ?? "dateNewest"
        Task {
            let dtos = await store.fetchRecordingDTOs(sortKey: sortKey, folderID: nil, tagFilter: nil)
            self.recordings = dtos
            self.rebuildSmartFolderCache()
            self.isLoadingRecordings = false
            self.recordingsChangedToken += 1
        }
    }

    private func rebuildSmartFolderCache() {
        smartFolderCache.rebuild(
            recordings: recordings,
            overrides: smartFolderOverrideStore.load(),
            userName: UserDefaults.standard.string(forKey: ActiveProfileDefaults.key("userName")) ?? ""
        )
    }

    func refreshTrash() {
        Task {
            self.trashedRecordings = await store.fetchTrashedRecordings()
        }
    }

    func refreshFolders() {
        Task {
            self.folders = await store.fetchFolders()
        }
    }

    // MARK: - Folder Detail

    func fetchFolderDetail(folderID: UUID, completion: @escaping (FolderDetailDTO?) -> Void) {
        Task {
            let detail = await store.fetchFolderDetail(folderID: folderID)
            completion(detail)
        }
    }

    // MARK: - Speaker Profiles

    func fetchSpeakerProfiles(completion: @escaping ([SpeakerProfileDTO]) -> Void) {
        Task {
            let profiles = await store.fetchSpeakerProfiles()
            completion(profiles)
        }
    }

    func createSpeakerProfile(displayName: String, completion: ((SpeakerProfileDTO?) -> Void)? = nil) {
        Task {
            let profile = await store.createSpeakerProfile(displayName: displayName)
            completion?(profile)
        }
    }

    func setSpeakerMapping(recordingID: UUID, rawLabel: String, profileID: UUID, completion: (() -> Void)? = nil) {
        Task {
            await store.setSpeakerMapping(recordingID: recordingID, rawLabel: rawLabel, profileID: profileID)
            completion?()
        }
    }

    func removeSpeakerMapping(recordingID: UUID, rawLabel: String) {
        Task {
            await store.removeSpeakerMapping(recordingID: recordingID, rawLabel: rawLabel)
        }
    }

    func searchRecordings(query: String, sortKey: String, folderID: UUID?, tagFilter: String?) {
        if recordingSearchCoordinator == nil {
            guard let store else {
                searchResults = []
                isSearchingRecordings = false
                return
            }
            recordingSearchCoordinator = RecordingSearchCoordinator(
                search: { request in
                    await store.searchRecordingDTOs(
                        query: request.query,
                        sortKey: request.sortKey,
                        folderID: request.folderID,
                        tagFilter: request.tagFilter
                    )
                },
                receive: { [weak self] results in
                    self?.searchResults = results
                    self?.isSearchingRecordings = false
                }
            )
        }

        let request = RecordingSearchRequest(
            query: query,
            sortKey: sortKey,
            folderID: folderID,
            tagFilter: tagFilter
        )
        isSearchingRecordings = !request.isBlank
        recordingSearchCoordinator?.submit(request)
    }

    func cancelRecordingSearch(clearResults: Bool = true) {
        recordingSearchCoordinator?.cancel(clearResults: clearResults)
        isSearchingRecordings = false
        if clearResults, recordingSearchCoordinator == nil {
            searchResults = []
        }
    }

    func fetchRecordingDetail(recordingID: UUID, completion: @escaping (RecordingDetailDTO?) -> Void) {
        Task {
            let detail = await store.fetchRecordingDetail(recordingID: recordingID)
            completion(detail)
        }
    }

    // MARK: - Navigation

    /// 覆盖式页面的返回栈。详情页不在 sidebar 上，关掉它必须知道「从哪来」——
    /// 旧实现硬编码回 `.allRecordings`，于是从「回顾」点进详情再关掉会掉到「全部录音」，
    /// 从文件夹 / 标签点进录音同理（2026-08-06）。
    private(set) var navigationReturnStack: [NavigationDestination] = []

    /// 异常路径下防止无限增长；正常最多两三层（回顾 → 回顾详情 → 录音详情）。
    private static let maxReturnStackDepth = 8

    /// sidebar 式导航：换的是「当前位置」，返回栈作废。
    func navigate(to destination: NavigationDestination) {
        // 需要出口的页面即使从 sidebar 点进去也按覆盖式处理，
        // 否则关闭按钮只能把用户丢回「全部录音」，而不是他刚才那一页。
        guard !destination.requiresExplicitExit else {
            present(destination)
            return
        }
        navigationReturnStack.removeAll()
        searchQuery = ""
        cancelRecordingSearch()
        setActiveDestination(destination)
    }

    /// 覆盖式进入：记住当前页面，`closeDetail()` 回到它。
    /// 不清 `searchQuery`——从搜索结果点进详情再返回，搜索词得还在。
    func present(_ destination: NavigationDestination) {
        guard activeDestination != destination else { return }
        navigationReturnStack.append(activeDestination)
        if navigationReturnStack.count > Self.maxReturnStackDepth {
            navigationReturnStack.removeFirst()
        }
        setActiveDestination(destination)
    }

    /// 关闭当前覆盖式页面，回到进入它之前的位置。
    func closeDetail() {
        let target = navigationReturnStack.popLast() ?? activeDestination.fallbackReturnTarget
        setActiveDestination(target)
    }

    private func setActiveDestination(_ destination: NavigationDestination) {
        if case .recordingDetail = destination {} else {
            recordingDetailTitle = nil
        }
        activeDestination = destination
    }

    func openRecordingDetail(recordingID: UUID, title: String?) {
        present(.recordingDetail(recordingID))
        recordingDetailTitle = title
    }

    func openSettings(category: SettingsCategory? = nil) {
        if let category {
            selectedSettingsCategory = category
        }
        present(.settings)
    }

    // MARK: - Global Hotkeys

    private func registerGlobalHotkeys() {
        guard startupPolicy.registersGlobalHotkeys,
              !areGlobalHotkeysRegistered else { return }
        areGlobalHotkeysRegistered = true

        // ⌘⇧R — toggle recording
        // ⌘⇧P — pause/resume

        // Global monitor: works when app is NOT focused
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        // Local monitor: works when app IS focused
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyEvent(event)
            return event
        }
    }

    /// Rebuild the event monitors after Accessibility changes from unavailable
    /// to granted. During initial setup `checkPermissions()` runs before monitor
    /// registration, so this deliberately does nothing until registration owns
    /// the lifecycle. Subsequent calls are safe because registration is itself
    /// idempotent.
    func refreshGlobalHotkeysForAccessibility() {
        guard startupPolicy.registersGlobalHotkeys,
              areGlobalHotkeysRegistered else { return }
        removeGlobalHotkeyMonitorTokens()
        areGlobalHotkeysRegistered = false
        registerGlobalHotkeys()
    }

    private func handleHotkeyEvent(_ event: NSEvent) {
        guard event.modifierFlags.contains([.command, .shift]) else { return }
        let key = event.charactersIgnoringModifiers?.lowercased()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch key {
            case "r":
                if self.isRecording {
                    self.stopRecording()
                } else {
                    do { try await self.startRecording() }
                    catch { self.presentStartRecordingError(error) }
                }
            case "p":
                if self.recordingState == .recording {
                    self.recordingEngine.pauseRecording()
                } else if self.recordingState == .paused {
                    self.recordingEngine.resumeRecording()
                }
            default:
                break
            }
        }
    }

    private func updateMeetingDetection(enabled: Bool, force: Bool) {
        guard startupPolicy.startsMeetingDetection,
              hasBeenSetUp,
              !Self.isRunningTests else { return }

        if enabled {
            guard force || !isMeetingDetectionActive else { return }
            refreshCalendarState()
            meetingDetector.startMonitoring()
            isMeetingDetectionActive = true
            return
        }

        guard force || isMeetingDetectionActive else { return }
        meetingDetector.stopMonitoring()
        // If detection auto-started a recording, stop it now — otherwise the only
        // path that would auto-stop it (the detector callbacks) is gone.
        if recordingEngine.isCurrentRecordingMeetingTriggered {
            recordingEngine.stopRecording()
        }
        recordingEngine.resetMeetingDetectionState()
        isMeetingDetectionActive = false
    }

    func removeGlobalHotkeys() {
        removeGlobalHotkeyMonitorTokens()
        areGlobalHotkeysRegistered = false
    }

    private func removeGlobalHotkeyMonitorTokens() {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalHotkeyMonitor = nil
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotkeyMonitor = nil
        }
    }
}
