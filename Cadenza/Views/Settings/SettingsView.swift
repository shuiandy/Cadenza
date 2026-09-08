import SwiftUI
import ServiceManagement

private extension SettingsCategory {
    var subtitle: String {
        switch self {
        case .general:
            return String(localized: "System behavior and startup preferences")
        case .recording:
            return String(localized: "Automatic triggers and audio capture")
        case .appearance:
            return String(localized: "Theme and readability")
        case .transcription:
            return String(localized: "Transcript and summary defaults")
        case .integrations:
            return String(localized: "AI providers, calendars, and export connections")
        case .profiles:
            return String(localized: "Accounts, switching, and history sync consent")
        }
    }
}

// MARK: - Workspace Root

/// Locale-injectable production formatters for storage errors. Localization
/// happens here so views receive final strings and tests can drive this
/// exact path.
enum StorageSettingsMessage {
    static func failedToSetDirectory(_ underlying: String, locale: Locale? = nil) -> String {
        LocalizedBundle.string("Failed to set directory: \(underlying)", locale: locale)
    }

    static func migrationError(_ underlying: String, locale: Locale? = nil) -> String {
        LocalizedBundle.string("Migration error: \(underlying)", locale: locale)
    }
}

struct SettingsWorkspaceView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    var body: some View {
        SettingsDetailView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings Sidebar

struct SettingsSidebarView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedSettingsCategory) {
            Section("Settings") {
                ForEach(SettingsCategory.allCases) { category in
                    Label(category.title, systemImage: category.icon)
                        .tag(category)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Settings Detail

struct SettingsDetailView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    private var selectedCategory: SettingsCategory {
        appState.selectedSettingsCategory ?? .general
    }

    @ViewBuilder
    private var currentContent: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsSection()
        case .recording:
            RecordingSettingsSection()
        case .appearance:
            AppearanceSettingsSection()
        case .transcription:
            TranscriptionSettingsSection()
        case .integrations:
            IntegrationsSettingsView()
        case .profiles:
            ProfilesSettingsSection()
        }
    }

    var body: some View {
        currentContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared Layout

struct SettingsPageLayout<Content: View>: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = LocalizedStringKey(title)
        self.subtitle = LocalizedStringKey(subtitle)
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.cadenza(.title, weight: .semibold, scale: uiScale))
                    Text(subtitle)
                        .font(.cadenza(.body, scale: uiScale))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    content
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct SettingsSectionCard<Content: View>: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let iconImage: String?
    let content: Content
    @State private var isHovered = false

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, iconImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.iconImage = iconImage
        self.content = content()
    }

    init(title: String, subtitle: String? = nil, iconImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = LocalizedStringKey(title)
        self.subtitle = subtitle.map { LocalizedStringKey($0) }
        self.iconImage = iconImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let iconImage {
                    Image(iconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.cadenza(15, weight: .semibold, scale: uiScale))
                    if let subtitle {
                        Text(subtitle)
                            .font(.cadenza(.subheadline, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 10)

            Divider()
                .opacity(0.32)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 6)
        }
        .padding(14)
        .appGlassPanel(cornerRadius: 14, accent: .accentColor)
        .scaleEffect(!reduceMotion && isHovered ? 1.006 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct SettingsToggleRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.cadenza(14, scale: uiScale))
                if let subtitle {
                    Text(subtitle)
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
                .accessibilityHint(subtitle.map { Text($0) } ?? Text(""))
        }
        .padding(.vertical, 8)
    }
}

/// Indents a row under its controlling toggle with an accent rail, making a
/// parent-child dependency visible instead of rendering both rows as peers.
struct SettingsDependentRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 2)
            content
        }
        .padding(.leading, 14)
    }
}

struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @Binding var selection: SelectionValue
    let content: Content

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.content = content()
    }

    init(
        _ title: String,
        subtitle: String? = nil,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = LocalizedStringKey(title)
        self.subtitle = subtitle.map { LocalizedStringKey($0) }
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.cadenza(14, scale: uiScale))
                if let subtitle {
                    Text(subtitle)
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)

            Spacer(minLength: 12)

            Picker(title, selection: $selection) {
                content
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(Text(title))
            .accessibilityHint(subtitle.map { Text($0) } ?? Text(""))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - General

// MARK: - Recording Storage

private struct RecordingStorageSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(AppState.self) private var appState
    // Storage state is resolved lazily in onAppear so that simply rendering
    // the Settings sheet doesn't trigger bookmark resolution and 4 separate
    // CloudStorage scans before the user even sees this section.
    @State private var storagePath: String = ""
    @State private var cloudService: StorageLocationManager.CloudService?
    @State private var availableClouds: [StorageLocationManager.CloudService] = []
    @State private var isCustom = false
    @State private var quotaStatus: StorageQuotaStatus?
    @State private var quotaRefreshID: UUID?
    @AppStorage("storageLimitMB") private var storageLimitMB: Int = 0
    @State private var showMigrationAlert = false
    @State private var pendingNewURL: URL?
    @State private var isMigrating = false
    @State private var migrationError: String?
    // Bookmark relink repair, present only in profile mode. The
    // coordinator owns the flow; this view owns only the panel
    // presentation and rendering.
    @State private var relink: AudioRootRelinkCoordinator?

    var body: some View {
        SettingsSectionCard(title: "Recording Storage") {
            // Pre-commit migration failure: legacy layout stays in use and
            // the pipeline retries next launch.
            if case .legacyFallback = appState.profileBootContext?.mode {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Storage upgrade did not complete. The app is continuing with your existing storage layout and will retry on next launch. You can export a backup anytime from Settings → General → Export & Backup.")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }

            RecordingStorageHeaderLayout(stacked: usesAccessibleLayout) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(storagePath)
                        .font(.cadenza(13, design: .monospaced, scale: uiScale))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let cloud = cloudService {
                        HStack(spacing: 4) {
                            Image(systemName: cloud.icon)
                                .font(.cadenza(11, scale: uiScale))
                            Text(cloud.displayName)
                                .font(.cadenza(12, scale: uiScale))
                        }
                        .foregroundStyle(.blue)
                    }
                }
            } actions: {
                RecordingStorageActionLayout(stacked: usesAccessibleLayout) {
                    Button("Custom Folder...") {
                        chooseDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(usesAccessibleLayout ? .regular : .small)
                    .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                    .disabled(appState.startupPolicy == .isolatedFixture)

                    Button("Open in Finder") {
                        let url = StorageLocationManager.recordingsDirectory
                        // Ensure directory exists (iCloud paths may not have a local folder yet)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(usesAccessibleLayout ? .regular : .small)
                    .frame(minHeight: usesAccessibleLayout ? 44 : nil)

                    if isCustom {
                        Button("Reset to Default") {
                            guard appState.startupPolicy != .isolatedFixture else { return }
                            pendingNewURL = StorageLocationManager.resetTargetDirectory
                            showMigrationAlert = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(usesAccessibleLayout ? .regular : .small)
                        .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                        .disabled(appState.startupPolicy == .isolatedFixture)
                    }

                    if isMigrating {
                        ProgressView()
                            .controlSize(usesAccessibleLayout ? .regular : .small)
                    }
                }
            }
            .padding(.vertical, 6)

            if let relink, relink.phase != .unavailable {
                relinkRepairBlock(relink)
            }

            // Cloud service quick-pick (uses cached availableClouds)
            if !availableClouds.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to Cloud")
                        .font(.cadenza(12, weight: .medium, scale: uiScale))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(availableClouds, id: \.displayName) { service in
                            let isActive = cloudService == service
                            Button {
                                guard appState.startupPolicy != .isolatedFixture else { return }
                                if let path = service.suggestedCadenzaPath {
                                    pendingNewURL = path
                                    showMigrationAlert = true
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: service.icon)
                                        .font(.cadenza(12, scale: uiScale))
                                    Text(service.displayName)
                                        .font(.cadenza(12, weight: .medium, scale: uiScale))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isActive ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.cadenzaPlain)
                            .disabled(isActive || appState.startupPolicy == .isolatedFixture)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()

            // Storage stats + limit
            VStack(alignment: .leading, spacing: 8) {
                if let quotaStatus {
                    // Concept J: the two prose blocks become one proportional
                    // bar plus a one-row legend, with the grand total on the
                    // header line — the ratio reads at a glance instead of
                    // being mental arithmetic.
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Usage")
                                .font(.cadenza(12, weight: .medium, scale: uiScale))
                            Spacer()
                            Text("Total: \(formattedSize(quotaStatus.usage.ownedBytes + quotaStatus.usage.externalBytes)) \u{00B7} \(quotaStatus.usage.ownedFileCount + quotaStatus.usage.externalFileCount) files")
                                .font(.cadenza(10.5, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }

                        StorageUsageBar(
                            ownedBytes: quotaStatus.usage.ownedBytes,
                            externalBytes: quotaStatus.usage.externalBytes
                        )

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                usageLegendItem(
                                    "Cadenza recordings",
                                    dot: Color.accentColor,
                                    bytes: quotaStatus.usage.ownedBytes,
                                    count: quotaStatus.usage.ownedFileCount
                                )
                                if quotaStatus.usage.externalBytes > 0 {
                                    usageLegendItem(
                                        "Other files in this folder",
                                        dot: Color.primary.opacity(0.28),
                                        bytes: quotaStatus.usage.externalBytes,
                                        count: quotaStatus.usage.externalFileCount
                                    )
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                usageLegendItem(
                                    "Cadenza recordings",
                                    dot: Color.accentColor,
                                    bytes: quotaStatus.usage.ownedBytes,
                                    count: quotaStatus.usage.ownedFileCount
                                )
                                if quotaStatus.usage.externalBytes > 0 {
                                    usageLegendItem(
                                        "Other files in this folder",
                                        dot: Color.primary.opacity(0.28),
                                        bytes: quotaStatus.usage.externalBytes,
                                        count: quotaStatus.usage.externalFileCount
                                    )
                                }
                            }
                        }
                    }

                    if quotaStatus.advisory == .reviewRequired {
                        Label {
                            Text("Cadenza recordings exceed this limit. Review recordings or empty Trash; storage limit checks never delete active recordings automatically.")
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.cadenza(12, scale: uiScale))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    } else if quotaStatus.advisory == .externalFilesExcluded {
                        Label(
                            "Other files are shown for context but do not count toward the Cadenza storage limit.",
                            systemImage: "info.circle"
                        )
                        .font(.cadenza(10.5, scale: uiScale))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    ProgressView("Calculating storage usage…")
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            SettingsPickerRow(
                "Storage limit",
                subtitle: "Applies only to Cadenza-owned recordings; storage limit checks never delete active recordings automatically",
                selection: $storageLimitMB
            ) {
                Text("Unlimited").tag(0)
                Text("1 GB").tag(1024)
                Text("5 GB").tag(5120)
                Text("10 GB").tag(10240)
                Text("25 GB").tag(25600)
                Text("50 GB").tag(51200)
            }

            if let error = migrationError {
                Text(error)
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .alert("Move Existing Recordings?", isPresented: $showMigrationAlert) {
            Button("Move Existing Recordings") {
                applyNewDirectory(migrate: true)
            }
            Button("Keep Existing, Use New for Future") {
                applyNewDirectory(migrate: false)
            }
            Button("Cancel", role: .cancel) {
                pendingNewURL = nil
            }
        } message: {
            if let url = pendingNewURL {
                Text("New location: \(url.path)\n\nChoose whether to move existing recordings to the new location or keep them where they are.")
            }
        }
        .onAppear {
            refreshState()
        }
        .onChange(of: storageLimitMB) { _, newValue in
            guard let current = quotaStatus else { return }
            quotaStatus = StorageQuotaStatus(
                usage: current.usage,
                limitBytes: StorageQuotaStatus.limitBytes(fromMegabytes: newValue)
            )
        }
    }

    private var usesAccessibleLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
            || uiScale >= CadenzaTextScale.factor(.accessibility1)
    }

    @ViewBuilder
    private func usageLegendItem(
        _ name: LocalizedStringKey,
        dot: Color,
        bytes: Int64,
        count: Int
    ) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.cadenza(10.5, weight: .medium, scale: uiScale))
                .foregroundStyle(.secondary)
            Text("\(formattedSize(bytes)) \u{00B7} \(count) files")
                .font(.cadenza(10.5, scale: uiScale))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func chooseDirectory() {
        guard appState.startupPolicy != .isolatedFixture else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder for recording storage")
        panel.prompt = String(localized: "Select")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingNewURL = url
        showMigrationAlert = true
    }

    private func applyNewDirectory(migrate: Bool) {
        guard appState.startupPolicy != .isolatedFixture else {
            pendingNewURL = nil
            return
        }
        guard let newURL = pendingNewURL else { return }
        let oldDir = StorageLocationManager.recordingsDirectory
        guard oldDir.path != newURL.path else {
            pendingNewURL = nil
            refreshState()
            return
        }

        // Directory changes require exclusive ownership of the storage root.
        // The gate refuses while recording (start through stop finalization)
        // or crash recovery holds a lease; post-processing jobs are checked
        // alongside. The claim is atomic on the MainActor and must be
        // released on every exit path of the flows below.
        guard !(appState.coordinator?.hasActiveWork ?? false),
              StorageMigrationGate.shared.claimMigration() else {
            migrationError = String(
                localized: "Storage location can't be changed while recording or processing."
            )
            pendingNewURL = nil
            return
        }

        if migrate {
            applyMoveMigration(from: oldDir, to: newURL)
        } else {
            applySplitRoot(from: oldDir, to: newURL)
        }
    }

    /// Keep-existing choice: files stay in the old directory, so relative
    /// references are pinned to it before the root switches — afterwards
    /// they would silently re-root to the new directory. The bookmark is
    /// prepared before pinning so a bookmark failure aborts without any
    /// reference rewrite; a pin failure keeps the old root active.
    private func applySplitRoot(from oldDir: URL, to newURL: URL) {
        isMigrating = true
        migrationError = nil
        let isDefaultTarget = newURL.path == StorageLocationManager.resetTargetDirectory.path
        Task {
            do {
                var bookmark: Data?
                if !isDefaultTarget {
                    try FileManager.default.createDirectory(
                        at: newURL, withIntermediateDirectories: true
                    )
                    bookmark = try StorageLocationManager.prepareCustomDirectoryBookmark(newURL)
                }
                let pinned = try await appState.store.pinRelativeReferencesToAbsolute(root: oldDir)
                NSLog("[StorageLocationManager] pinned %d recording(s) to %@", pinned, oldDir.path)
                if let bookmark {
                    try StorageLocationManager.commitCustomDirectory(bookmarkData: bookmark, path: newURL.path)
                } else {
                    try StorageLocationManager.resetToDefault()
                }
                appState.refreshRecordings()
            } catch {
                migrationError = StorageSettingsMessage.failedToSetDirectory(error.localizedDescription)
            }
            StorageMigrationGate.shared.releaseMigration()
            isMigrating = false
            pendingNewURL = nil
            refreshState()
        }
    }

    /// Move choice, copy-staging order: the old root stays complete until
    /// the new root is committed, so a failure or interruption at any point
    /// before the commit leaves everything usable in place, and the only
    /// leftover after a late failure is a duplicate copy.
    /// 1. destination directory + bookmark preflight (nothing changed on failure)
    /// 2. copy + verify into the destination (failure discards the copies)
    /// 3. legacy-row relocation against the explicit copy mapping (failure
    ///    discards the copies)
    /// 4. root commit (UserDefaults write with the prepared bookmark)
    /// 5. source cleanup (failures leave duplicates and are logged)
    /// Relative rows need no rewrite — they follow the root by construction.
    private func applyMoveMigration(from oldDir: URL, to newURL: URL) {
        isMigrating = true
        migrationError = nil
        let isDefaultTarget = newURL.path == StorageLocationManager.resetTargetDirectory.path
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: newURL, withIntermediateDirectories: true
                )
                let bookmark = isDefaultTarget
                    ? nil
                    : try StorageLocationManager.prepareCustomDirectoryBookmark(newURL)

                let outcome = try await Task.detached(priority: .utility) {
                    try StorageLocationManager.migrateFiles(from: oldDir, to: newURL)
                }.value

                do {
                    let relocated = try await appState.store.relocateAudioReferences(
                        copies: outcome.copiedPairs, from: oldDir, to: newURL
                    )
                    NSLog(
                        "[StorageLocationManager] copied %d item(s), relocated %d recording(s)",
                        outcome.count, relocated
                    )
                } catch {
                    await Task.detached(priority: .utility) {
                        StorageLocationManager.discardMigrationCopies(outcome)
                    }.value
                    throw error
                }

                if let bookmark {
                    try StorageLocationManager.commitCustomDirectory(bookmarkData: bookmark, path: newURL.path)
                } else {
                    try StorageLocationManager.resetToDefault()
                }
                // Open views re-resolve their references against the new root.
                appState.refreshRecordings()

                await Task.detached(priority: .utility) {
                    StorageLocationManager.cleanupMigrationSources(outcome)
                }.value
            } catch {
                NSLog("[StorageLocationManager] migration error: %@", error.localizedDescription)
                migrationError = StorageSettingsMessage.migrationError(error.localizedDescription)
            }
            StorageMigrationGate.shared.releaseMigration()
            isMigrating = false
            pendingNewURL = nil
            refreshState()
        }
    }

    private func refreshState() {
        storagePath = StorageLocationManager.displayPath
        cloudService = StorageLocationManager.detectedCloudService
        availableClouds = StorageLocationManager.availableCloudServices
        isCustom = StorageLocationManager.isCustomDirectorySet
        configureRelinkIfNeeded()
        relink?.refresh()
        refreshStats()
    }

    @ViewBuilder
    private func relinkRepairBlock(_ relink: AudioRootRelinkCoordinator) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            if case .repaired = relink.phase {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Access restored.")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Recordings folder access lost")
                        .font(.cadenza(12, weight: .medium, scale: uiScale))
                    Spacer()
                    Button("Relink Folder…") {
                        guard appState.startupPolicy != .isolatedFixture else { return }
                        relink.performRelink()
                        refreshStats()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        appState.startupPolicy == .isolatedFixture
                            || { if case .blocked = relink.phase { true } else { false } }()
                    )
                }
                Text("Cadenza can no longer access this profile's recordings folder. Choose the same folder again to restore access — recordings stay where they are.")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                Text(relink.recordedPath)
                    .font(.cadenza(12, design: .monospaced, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                switch relink.phase {
                case .refused(let message), .saveFailed(let message):
                    Text(message)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.orange)
                case .blocked(let message):
                    Text(message)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.red)
                case .unavailable, .offered, .repaired:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func configureRelinkIfNeeded() {
        guard appState.startupPolicy != .isolatedFixture,
              relink == nil,
              case .profile = appState.profileBootContext?.mode,
              let profile = appState.profileBootContext?.profile else { return }
        relink = AudioRootRelinkCoordinator(
            dependencies: AudioRootRelinkCoordinator.liveDependencies(
                profileID: profile.id,
                pickFolder: Self.presentRelinkPanel
            )
        )
    }

    /// Folder picker for the relink repair, anchored at the recorded
    /// path. Aliases are not resolved: the selection is compared
    /// lexically against the recorded identity, and a resolved alias
    /// would silently substitute a different path.
    private static func presentRelinkPanel(recordedPath: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.directoryURL = URL(fileURLWithPath: recordedPath, isDirectory: true)
            .deletingLastPathComponent()
        panel.message = String(localized: "Choose the original recordings folder to restore access")
        panel.prompt = String(localized: "Select")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func refreshStats() {
        quotaStatus = nil
        let refreshID = UUID()
        quotaRefreshID = refreshID
        Task {
            let measured = await appState.store.storageQuotaStatus()
            guard quotaRefreshID == refreshID else { return }
            quotaStatus = StorageQuotaStatus(
                usage: measured.usage,
                limitBytes: StorageQuotaStatus.limitBytes(fromMegabytes: storageLimitMB)
            )
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Two-segment proportional bar for the storage stats: Cadenza-owned bytes
/// in accent, other files in a muted tone. Tiny nonzero segments are floored
/// at 2% so they stay visible; the legend carries the exact numbers.
private struct StorageUsageBar: View {
    let ownedBytes: Int64
    let externalBytes: Int64

    var body: some View {
        let total = max(1, ownedBytes + externalBytes)
        let ownedFraction = clampedFraction(Double(ownedBytes) / Double(total), nonZero: ownedBytes > 0)
        let externalFraction = clampedFraction(Double(externalBytes) / Double(total), nonZero: externalBytes > 0)
        GeometryReader { proxy in
            HStack(spacing: ownedBytes > 0 && externalBytes > 0 ? 1 : 0) {
                if ownedBytes > 0 {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * ownedFraction / max(0.0001, ownedFraction + externalFraction))
                }
                if externalBytes > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.28))
                }
            }
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }

    private func clampedFraction(_ fraction: Double, nonZero: Bool) -> Double {
        guard nonZero else { return 0 }
        return min(max(fraction, 0.02), 0.98)
    }
}

/// Reflows the storage identity above its controls once scaled, localized
/// actions can no longer leave a useful width for the path.
struct RecordingStorageHeaderLayout<Identity: View, Actions: View>: View {
    let stacked: Bool
    private let identity: Identity
    private let actions: Actions

    init(
        stacked: Bool,
        @ViewBuilder identity: () -> Identity,
        @ViewBuilder actions: () -> Actions
    ) {
        self.stacked = stacked
        self.identity = identity()
        self.actions = actions()
    }

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            identity
            actions
                .frame(maxWidth: stacked ? .infinity : nil, alignment: .trailing)
        }
    }
}

/// Allows the storage actions themselves to wrap into a keyboard-friendly
/// vertical group instead of overflowing the Settings content column.
struct RecordingStorageActionLayout<Content: View>: View {
    let stacked: Bool
    private let content: Content

    init(stacked: Bool, @ViewBuilder content: () -> Content) {
        self.stacked = stacked
        self.content = content()
    }

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            content
        }
    }
}

private struct GeneralSettingsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("runInBackground") private var runInBackground = false
    @AppStorage("openMainWindowOnLaunch") private var openMainWindowOnLaunch = true
    @State private var launchAtLogin = false

    var body: some View {
        SettingsPageLayout(title: SettingsCategory.general.title, subtitle: SettingsCategory.general.subtitle) {
            RecordingStorageSection()

            ExportBackupSection()

            SettingsSectionCard(title: "Interface & Startup") {
                SettingsToggleRow(
                    "Show menu bar icon",
                    subtitle: "Keep quick controls available in the menu bar",
                    isOn: $showMenuBarIcon
                )
                .onChange(of: showMenuBarIcon) { _, newValue in
                    if !newValue && !showDockIcon {
                        showDockIcon = true
                    }
                }

                Divider()

                SettingsToggleRow(
                    "Show Dock icon",
                    subtitle: "Show the app in Dock and app switcher",
                    isOn: $showDockIcon
                )
                .onChange(of: showDockIcon) { _, newValue in
                    if !newValue && !showMenuBarIcon {
                        showMenuBarIcon = true
                    }
                    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                }

                Divider()

                SettingsToggleRow(
                    "Keep running when window is closed",
                    subtitle: "Hide to menu bar instead of quitting",
                    isOn: $runInBackground
                )
                .onChange(of: runInBackground) { _, newValue in
                    if newValue {
                        showMenuBarIcon = true
                    }
                }

                Divider()

                SettingsToggleRow(
                    "Launch at login",
                    subtitle: "Start Cadenza automatically after sign in",
                    isOn: $launchAtLogin
                )
                .disabled(!appState.startupPolicy.externalAccessEnabled)
                .onChange(of: launchAtLogin) { _, newValue in
                    guard appState.startupPolicy.externalAccessEnabled else { return }
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }

                // Dependent child of "Launch at login": the rail plus indent
                // makes the dependency visible, and the toggle only operates
                // while its parent is on (concept J).
                SettingsDependentRow {
                    SettingsToggleRow(
                        "Open main window after login",
                        subtitle: "When Launch at login is enabled, show the main window after sign in",
                        isOn: $openMainWindowOnLaunch
                    )
                    .disabled(!launchAtLogin)
                }
            }

            if appState.startupPolicy.externalAccessEnabled {
                UpdateSettingsSection()
                DiagnosticsSection(store: appState.store, meetingDetector: appState.meetingDetector)
            }
        }
        .onAppear {
            guard appState.startupPolicy.externalAccessEnabled else {
                launchAtLogin = false
                return
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let store: RecordingsStore
    let meetingDetector: MeetingDetector
    @State private var funcRunner = FunctionalTestRunner.shared
    @State private var qualityRunner = QualityComparisonRunner.shared
    @State private var systemRunner = SystemDiagnosticRunner.shared
    @State private var showFuncPicker = false
    @State private var showQualityPicker = false
    @State private var showRealtimePicker = false
    @State private var speakerMemoryRunner = SpeakerMemoryDiagnosticRunner.shared
    @State private var showSpeakerMemoryPicker = false
    @State private var activeReport: String?
#if DEBUG
    @State private var confirmSummaryEvaluation = false
    @State private var evaluationMode = 0
#endif

    private var isRunning: Bool { funcRunner.isRunning || qualityRunner.isRunning || systemRunner.isRunning || speakerMemoryRunner.isRunning }
    private var currentStatus: String {
        if funcRunner.isRunning { return funcRunner.currentStatus }
        if qualityRunner.isRunning { return qualityRunner.currentStatus }
        if speakerMemoryRunner.isRunning { return speakerMemoryRunner.currentStatus }
        return systemRunner.currentStatus
    }

    var body: some View {
        SettingsSectionCard(title: "Diagnostics") {
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(currentStatus)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                if qualityRunner.isEvaluatingSummary {
                    Button("Cancel") { qualityRunner.cancelSummaryEvaluation() }
                }
            } else {
                HStack(spacing: 12) {
                    Button("System Check") {
                        activeReport = nil
                        Task {
                            await systemRunner.run(
                                store: store,
                                meetingDetector: meetingDetector
                            )
                            activeReport = systemRunner.report
                        }
                    }
                    Button("Smoke Test...") { activeReport = nil; showFuncPicker = true }
                    Button("Quality Compare...") { activeReport = nil; showQualityPicker = true }
                    Button("Realtime Test...") { activeReport = nil; showRealtimePicker = true }
                    Button("Speaker Memory...") { activeReport = nil; showSpeakerMemoryPicker = true }
                }
                .fileImporter(isPresented: $showFuncPicker, allowedContentTypes: [.audio]) { result in
                    if case .success(let url) = result {
                        Task {
                            await SecurityScopedResourceAccess.withAccess(to: url) {
                                await funcRunner.run(audioURL: url)
                            }
                            activeReport = funcRunner.report
                        }
                    }
                }
                .fileImporter(isPresented: $showQualityPicker, allowedContentTypes: [.audio]) { result in
                    if case .success(let url) = result {
                        Task {
                            await SecurityScopedResourceAccess.withAccess(to: url) {
                                await qualityRunner.run(audioURL: url)
                            }
                            activeReport = qualityRunner.report
                        }
                    }
                }
                .fileImporter(isPresented: $showRealtimePicker, allowedContentTypes: [.audio]) { result in
                    if case .success(let url) = result {
                        Task {
                            await SecurityScopedResourceAccess.withAccess(to: url) {
                                await qualityRunner.runRealtimeOnly(audioURL: url)
                            }
                            activeReport = qualityRunner.report
                        }
                    }
                }
                .fileImporter(isPresented: $showSpeakerMemoryPicker, allowedContentTypes: [.audio]) { result in
                    if case .success(let url) = result {
                        Task {
                            await SecurityScopedResourceAccess.withAccess(to: url) {
                                await speakerMemoryRunner.run(audioURL: url)
                            }
                            activeReport = speakerMemoryRunner.report
                        }
                    }
                }
                .padding(.vertical, 4)

#if DEBUG
                Menu("Summary Evaluation") {
                    Button("Summary") { evaluationMode = 0; confirmSummaryEvaluation = true }
                    Button("Meeting context") { evaluationMode = 1; confirmSummaryEvaluation = true }
                    Button("Review follow-up") { evaluationMode = 2; confirmSummaryEvaluation = true }
                }
                .alert("Run a paid summary evaluation?", isPresented: $confirmSummaryEvaluation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Run Evaluation") {
                        activeReport = nil
                        qualityRunner.startSummaryEvaluation(personalOnly: evaluationMode == 1, focused: evaluationMode == 2)
                    }
                } message: {
                    Text("This developer evaluation can send hundreds of requests and take over 20 minutes. Your AI provider may charge for them. Only fictional meetings are used.")
                }
                Text("Uses fictional meetings with your selected AI provider and a smaller model when available. API usage charges may apply.")
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
#endif

                Text("System Check: audio, database, storage, meeting detection, exports. Smoke Test: AI providers. Quality Compare: side-by-side output. Speaker Memory: embedding extraction and cosine scoring.")
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

            if let report = activeReport, !report.isEmpty {
                Divider()
                ScrollView {
                    Text(report)
                        .font(.cadenza(11, design: .monospaced, scale: uiScale))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 400)
                .padding(.vertical, 4)

                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Recording

/// The view never reads TCC directly. This boundary makes permission status
/// fail closed for test and isolated-fixture policies before touching AVFoundation.
@MainActor
struct RecordingMicrophonePermissionReader {
    static let live = RecordingMicrophonePermissionReader {
        Permissions.microphoneStatus
    }

    private let readStatus: () -> PermissionStatus

    init(readStatus: @escaping () -> PermissionStatus) {
        self.readStatus = readStatus
    }

    func status(for startupPolicy: AppState.StartupPolicy) -> PermissionStatus {
        guard startupPolicy.checksPermissions else { return .notDetermined }
        return readStatus()
    }
}

enum RecordingSettingsMessage {
    private static let trashRetentionPolicyKey: String.LocalizationValue =
        "Deleted recordings move to Trash and are removed from the active library after the selected number of days. Cadenza-owned audio files and derived data are included; imported source files remain in their original location. Automatic recovery backups may retain copies until rotation or explicit deletion."

    static func trashRetentionPolicy(locale: Locale? = nil) -> String {
        LocalizedBundle.string(trashRetentionPolicyKey, locale: locale)
    }
}

private struct RecordingSettingsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    private let permissionReader: RecordingMicrophonePermissionReader
    @AppStorage("enableMeetingDetection") private var enableMeetingDetection = false
    @AppStorage("autoRecordMeetings") private var autoRecordMeetings = false
    @AppStorage("autoStopOnMicClose") private var autoStopOnMicClose = true
    @AppStorage("captureMicrophone") private var captureMicrophone = false
    @AppStorage("trashRetentionDays") private var trashRetentionDays = 7
    @State private var microphoneStatus: PermissionStatus = .notDetermined
    @State private var isRequestingMicrophone = false
    @State private var showMicrophonePermissionMessage = false

    init(permissionReader: RecordingMicrophonePermissionReader = .live) {
        self.permissionReader = permissionReader
    }

    var body: some View {
        SettingsPageLayout(title: SettingsCategory.recording.title, subtitle: SettingsCategory.recording.subtitle) {
            SettingsSectionCard(title: "Meeting Detection") {
                SettingsToggleRow(
                    "Detect meeting apps",
                    subtitle: "Monitor supported meeting apps and surface meeting activity across the app",
                    isOn: $enableMeetingDetection
                )
                .onChange(of: enableMeetingDetection) { _, newValue in
                    appState.setMeetingDetectionEnabled(newValue)
                }

                // Both automatic behaviors depend on meeting detection; the
                // rail-indented rows make that chain visible (concept K).
                SettingsDependentRow {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsToggleRow(
                            "Auto-record meetings",
                            subtitle: "Automatically start recording when a meeting app and microphone are detected",
                            isOn: autoRecordBinding
                        )
                        .disabled(
                            !enableMeetingDetection
                                || !appState.hasPreparedSystemAudioCapture
                                || isRequestingMicrophone
                        )

                        if showMicrophonePermissionMessage {
                            Text("Microphone access is required for automatic meeting recording. Auto-record stays on and will resume once access is granted.")
                                .font(.cadenza(.caption, scale: uiScale))
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("recording.autoRecord.microphoneRequired")
                        }

                        Text("Make sure everyone knows the meeting is being recorded. Follow applicable laws and workplace policies.")
                            .font(.cadenza(.caption, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        SettingsToggleRow(
                            "Auto-stop when mic closes",
                            subtitle: "Stop recording after a 5-second countdown when microphone is released",
                            isOn: $autoStopOnMicClose
                        )
                    }
                }

                Divider()

                ScreenRecordingPermissionRow()

                Divider()

                AccessibilityPermissionRow()
            }
            .disabled(!appState.startupPolicy.checksPermissions)

            SettingsSectionCard(title: "Audio Capture") {
                SystemAudioCapturePreparationRow()

                Divider()

                SettingsToggleRow(
                    "Capture microphone",
                    subtitle: "Include your microphone audio when manually starting a recording. Auto-recording requires microphone permission and never prompts in the background.",
                    isOn: $captureMicrophone
                )

                Divider()

                MicrophonePermissionRow(
                    status: microphoneStatus,
                    isRequesting: isRequestingMicrophone,
                    grantAccess: { requestMicrophoneAccess() },
                    openSettings: {
                        guard appState.startupPolicy.checksPermissions else { return }
                        Permissions.openMicrophoneSettings()
                    }
                )
            }
            .disabled(!appState.startupPolicy.checksPermissions)

            SettingsSectionCard(title: "Trash") {
                HStack {
                    Text("Auto-empty Trash")
                    Spacer()
                    Picker("", selection: $trashRetentionDays) {
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                        Text("15 days").tag(15)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Text(RecordingSettingsMessage.trashRetentionPolicy())
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

        }
        .task {
            guard appState.startupPolicy.checksPermissions else {
                refreshMicrophonePermission()
                return
            }
            await appState.checkPermissions()
            refreshMicrophonePermission()
        }
    }

    private var autoRecordBinding: Binding<Bool> {
        Binding(
            get: { autoRecordMeetings },
            set: { requestedValue in
                guard requestedValue else {
                    // Turning the toggle off is the only path that clears the
                    // stored intent. Missing permission never rewrites it;
                    // RecordingEngine fails closed at auto-start time instead.
                    autoRecordMeetings = false
                    showMicrophonePermissionMessage = false
                    return
                }
                guard appState.startupPolicy.checksPermissions else { return }

                autoRecordMeetings = true
                let status = permissionReader.status(for: appState.startupPolicy)
                switch MicrophoneAutoRecordPolicy.action(for: status) {
                case .enable:
                    microphoneStatus = .granted
                    showMicrophonePermissionMessage = false
                case .request:
                    requestMicrophoneAccess()
                case .suspend:
                    microphoneStatus = .denied
                    showMicrophonePermissionMessage = true
                }
            }
        )
    }

    private func requestMicrophoneAccess() {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        guard appState.startupPolicy.checksPermissions else { return }
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true

        Task { @MainActor in
            guard appState.startupPolicy.checksPermissions else {
                isRequestingMicrophone = false
                return
            }
            _ = await Permissions.requestMicrophone()
            await appState.checkPermissions()
            isRequestingMicrophone = false
            refreshMicrophonePermission()
        }
    }

    private func refreshMicrophonePermission() {
        microphoneStatus = permissionReader.status(for: appState.startupPolicy)
        showMicrophonePermissionMessage = MicrophoneAutoRecordPolicy.showsPermissionMessage(
            autoRecordEnabled: autoRecordMeetings,
            status: microphoneStatus
        )
    }
}

private struct MicrophonePermissionRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let status: PermissionStatus
    let isRequesting: Bool
    let grantAccess: () -> Void
    let openSettings: () -> Void

    var body: some View {
        SettingsPermissionRowLayout {
            // Status icon trails so the text aligns with sibling toggle rows.
            VStack(alignment: .leading, spacing: 3) {
                Text("Microphone")
                    .font(.cadenza(14, scale: uiScale))
                Text(permissionDescription)
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } controls: {
            switch status {
            case .granted:
                SettingsStatusCapsule(kind: .connected, label: "Granted")
                    .accessibilityLabel("Microphone")
                    .accessibilityValue("Granted")
            case .notDetermined:
                Button(action: grantAccess) {
                    if isRequesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Grant Access", systemImage: "mic")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(usesAccessibleLayout ? .regular : .small)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .disabled(isRequesting)
                .accessibilityLabel("Grant microphone access")
            case .denied:
                Button(action: openSettings) {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(usesAccessibleLayout ? .regular : .small)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .accessibilityLabel("Open microphone settings")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var usesAccessibleLayout: Bool {
        CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }

    private var permissionDescription: LocalizedStringKey {
        switch status {
        case .granted:
            "Available for manual and automatic recordings."
        case .notDetermined:
            "Grant access here before enabling automatic recording."
        case .denied:
            "Automatic recording is disabled until access is granted in System Settings."
        }
    }
}

private struct ScreenRecordingPermissionRow: View {
    private static let table = "Onboarding"

    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPermissionRowLayout {
            VStack(alignment: .leading, spacing: 3) {
                Text(text("Screen Recording"))
                    .font(.cadenza(14, scale: uiScale))
                Text(text("Lets Cadenza read meeting window information for more reliable Teams start and stop detection. No screen image is recorded."))
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } controls: {
            if appState.hasScreenRecordingPermission {
                SettingsStatusCapsule(kind: .connected, verbatimLabel: text("Granted"))
                    .accessibilityLabel(text("Screen Recording"))
                    .accessibilityValue(text("Granted"))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Button {
                    guard appState.startupPolicy.allowsHardwareCapture else { return }
                    _ = Permissions.requestScreenRecording()
                    Task { await appState.checkPermissions() }
                } label: {
                    Label(text("Open Settings"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(usesAccessibleLayout ? .regular : .small)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .disabled(!appState.startupPolicy.allowsHardwareCapture)
                .accessibilityLabel(text("Open Settings"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var usesAccessibleLayout: Bool {
        CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: Self.table)
    }
}

private struct AccessibilityPermissionRow: View {
    private static let table = "Onboarding"

    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState
    @State private var requestAttempted = false

    var body: some View {
        SettingsPermissionRowLayout {
            VStack(alignment: .leading, spacing: 3) {
                Text(text("Accessibility"))
                    .font(.cadenza(14, scale: uiScale))
                Text(text("Allows global recording shortcuts to work while another app is active."))
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } controls: {
            if appState.hasAccessibilityPermission {
                SettingsStatusCapsule(kind: .connected, verbatimLabel: text("Granted"))
                    .accessibilityLabel(text("Accessibility"))
                    .accessibilityValue(text("Granted"))
            } else {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Button {
                    guard appState.startupPolicy.checksPermissions else { return }
                    if requestAttempted {
                        Permissions.openAccessibilitySettings()
                    } else {
                        let granted = Permissions.requestAccessibility()
                        requestAttempted = !granted
                        Task { await appState.checkPermissions() }
                    }
                } label: {
                    Label(
                        requestAttempted ? text("Open Settings") : text("Allow"),
                        systemImage: requestAttempted ? "gearshape" : "accessibility"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(usesAccessibleLayout ? .regular : .small)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .accessibilityLabel(
                    requestAttempted ? text("Open Settings") : text("Allow global shortcuts")
                )
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var usesAccessibleLayout: Bool {
        CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: Self.table)
    }
}

private struct SystemAudioCapturePreparationRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPermissionRowLayout {
            VStack(alignment: .leading, spacing: 3) {
                Text("System Audio Recording")
                    .font(.cadenza(14, scale: uiScale))
                Text(
                    appState.hasPreparedSystemAudioCapture
                        ? "Setup completed. If access changes, open System Settings."
                        : "Enable once before Cadenza can auto-record meetings."
                )
                .font(.cadenza(.subheadline, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } controls: {
            if appState.hasPreparedSystemAudioCapture {
                SettingsStatusCapsule(kind: .connected, label: "Ready")
                    .accessibilityLabel(Text("System Audio Recording"))
                    .accessibilityValue(Text("Ready"))
                Button {
                    guard appState.startupPolicy.allowsHardwareCapture else { return }
                    Permissions.openSystemAudioRecordingSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(usesAccessibleLayout ? .regular : .small)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .disabled(!appState.startupPolicy.allowsHardwareCapture)
            } else {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Button {
                    guard appState.startupPolicy.allowsHardwareCapture else { return }
                    Task { await appState.prepareSystemAudioCapture() }
                } label: {
                    if appState.isPreparingSystemAudioCapture {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Enabling…")
                        }
                    } else {
                        Label("Enable", systemImage: "waveform")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(usesAccessibleLayout ? .regular : .small)
                .frame(minHeight: usesAccessibleLayout ? 44 : nil)
                .disabled(
                    !appState.startupPolicy.allowsHardwareCapture
                        || appState.isStartingRecording
                        || appState.isRecording
                )
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var usesAccessibleLayout: Bool {
        CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }
}

private struct SettingsPermissionRowLayout<Information: View, Controls: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let information: Information
    let controls: Controls

    init(
        @ViewBuilder information: () -> Information,
        @ViewBuilder controls: () -> Controls
    ) {
        self.information = information()
        self.controls = controls()
    }

    var body: some View {
        Group {
            if CadenzaTextScale.isAccessibilitySize(dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 12) {
                    information
                    HStack(spacing: 10) { controls }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    information
                    Spacer(minLength: 12)
                    HStack(spacing: 10) { controls }
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @AppStorage("appIconVariant") private var appIconVariant: AppIconVariant = .classic
    @AppStorage("backgroundTheme") private var backgroundTheme: BackgroundTheme = .none
    @AppStorage("uiScale") private var uiScalePreset: UIScalePreset = .default

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)]
    // Concept L: compact swatch tiles — every colorway visible in one screen.
    private let iconColumns = [GridItem(.adaptive(minimum: 76, maximum: 104), spacing: 6)]
    private let themeColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        SettingsPageLayout(title: SettingsCategory.appearance.title, subtitle: SettingsCategory.appearance.subtitle) {
            SettingsSectionCard(title: "App Icon", subtitle: "Pick a colorway for the Dock and app switcher icon") {
                LazyVGrid(columns: iconColumns, spacing: 10) {
                    ForEach(AppIconVariant.allCases) { variant in
                        AppIconVariantCard(
                            variant: variant,
                            isSelected: appIconVariant == variant
                        ) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                appIconVariant = variant
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            SettingsSectionCard(title: "Theme", subtitle: "Use system appearance or force one theme") {
                // Concept L: the dropdown becomes three mini-window previews
                // so light/dark/system are visible before choosing.
                LazyVGrid(columns: themeColumns, spacing: 10) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        ThemePreviewTile(
                            theme: theme,
                            isSelected: appTheme == theme
                        ) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                appTheme = theme
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            SettingsSectionCard(title: "Language") {
                SettingsPickerRow("Language", subtitle: "App interface language. Restart required to take effect.", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: appLanguage) { _, newLang in
                    newLang.apply()
                }
            }

            SettingsSectionCard(title: "Background", subtitle: "Choose a tint for the app background") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(BackgroundTheme.allCases) { theme in
                        BackgroundThemeCard(
                            theme: theme,
                            isSelected: backgroundTheme == theme
                        ) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                backgroundTheme = theme
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            SettingsSectionCard(title: "Size") {
                SettingsPickerRow(
                    "UI Scale",
                    subtitle: "Scale fonts and icons across the app.",
                    selection: $uiScalePreset
                ) {
                    ForEach(UIScalePreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
            }
        }
        .onAppear { applyTheme(appTheme) }
        .onChange(of: appTheme) { _, newValue in applyTheme(newValue) }
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
}

private struct BackgroundThemeCard: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let theme: BackgroundTheme
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                let colors = colorScheme == .dark ? theme.darkColors : theme.lightColors
                Group {
                    if colors.isEmpty {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.background)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .frame(height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 0.5)
                )

                Text(theme.displayName)
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.top, 5)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.cadenzaPlain)
    }
}

/// Compact colorway swatch (concept L): icon plus name only — the flavor
/// subtitles were decorative — with a ring and check badge marking the
/// selection so the current icon is findable at a glance.
private struct AppIconVariantCard: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let variant: AppIconVariant
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                AppIconArtwork(variant: variant)
                    .frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.10), radius: 5, y: 2)

                Text(variant.displayName)
                    .font(.cadenza(11, weight: isSelected ? .semibold : .regular, scale: uiScale))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.cadenza(7, weight: .bold, scale: uiScale))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.accentColor))
                        .padding(4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.cadenzaPlain)
        .accessibilityLabel(Text(variant.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Mini-window theme preview (concept L): a light card, a dark card, and a
/// diagonally split card for "system", each a literal picture of the choice.
private struct ThemePreviewTile: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let theme: AppTheme
    let isSelected: Bool
    let onSelect: () -> Void

    private static let lightBackground = Color(red: 0.965, green: 0.93, blue: 0.885)
    private static let darkBackground = Color(red: 0.13, green: 0.10, blue: 0.078)

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                preview
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )

                Text(theme.displayName)
                    .font(.cadenza(11, weight: isSelected ? .semibold : .regular, scale: uiScale))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.cadenza(7, weight: .bold, scale: uiScale))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.accentColor))
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.cadenzaPlain)
        .accessibilityLabel(Text(theme.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch theme {
        case .light:
            miniWindow(background: Self.lightBackground, line: Color.black.opacity(0.22))
        case .dark:
            miniWindow(background: Self.darkBackground, line: Color.white.opacity(0.3))
        case .system:
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Self.lightBackground, location: 0.5),
                        .init(color: Self.darkBackground, location: 0.5),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                miniWindowLines(line: Color.primary.opacity(0.3))
            }
        }
    }

    private func miniWindow(background: Color, line: Color) -> some View {
        ZStack {
            background
            miniWindowLines(line: line)
        }
    }

    private func miniWindowLines(line: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(line).frame(width: 42, height: 5)
            Capsule().fill(line.opacity(0.5)).frame(width: 62, height: 4)
            Capsule().fill(line.opacity(0.5)).frame(width: 54, height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
    }
}

// MARK: - Transcription

/// Settings row with a free-form model-ID override. Empty = use the built-in
/// default (shown as the placeholder). Backed by UserDefaults directly because
/// the key changes with the selected provider — @AppStorage can't switch keys.
private struct ModelOverrideRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let key: String
    let placeholder: String

    @State private var fieldState: ModelOverrideFieldState

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        key: String,
        placeholder: String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.key = key
        self.placeholder = placeholder
        _fieldState = State(initialValue: ModelOverrideFieldState(key: key))
    }

    private var usesRecommendedModel: Bool {
        !fieldState.hasOverride
            || fieldState.text.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cadenza(13, scale: uiScale))
                Text(subtitle)
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            // Concept M: recommendation state lives inline beside the field —
            // a green tag while the effective model IS the recommended one
            // (empty field or an override typed to the same value), a single
            // restore action once it differs. No second line under the field.
            if usesRecommendedModel {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.cadenza(8, weight: .bold, scale: uiScale))
                    Text("Recommended")
                        .font(.cadenza(10.5, weight: .semibold, scale: uiScale))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .frame(minHeight: 20)
                .background(Color.green.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.3), lineWidth: 1))
                .accessibilityElement(children: .combine)
            } else {
                Button("Use recommended") {
                    fieldState.useRecommended()
                }
                .buttonStyle(.borderless)
                .font(.cadenza(.caption2, weight: .medium, scale: uiScale))
                .help(Text("Recommended: \(placeholder)"))
            }

            TextField(
                placeholder,
                text: Binding(
                    get: { fieldState.text },
                    set: { fieldState.updateText($0) }
                )
            )
                .textFieldStyle(.roundedBorder)
                .font(.cadenza(12, design: .monospaced, scale: uiScale))
                .frame(width: 260)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(subtitle))
                .accessibilityIdentifier("settings.modelOverride.\(key)")
        }
        .padding(.vertical, 4)
        .onChange(of: key) { _, newKey in
            fieldState.activate(key: newKey)
        }
    }
}

/// Small provider logo tile leading an engine/provider picker row, matching
/// the row anatomy of the Integrations page (concept M).
private struct ProviderLogoTile: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let provider: AIProvider

    var body: some View {
        Group {
            if NSImage(named: provider.iconName) != nil {
                Image(provider.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: provider.iconFallbackSymbol)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Tinted disclosure line for data-egress notes (concept M): what leaves the
/// machine deserves an info row, not a caption buried under a toggle.
private struct SettingsInfoNote: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    private let text: Text

    init(_ key: LocalizedStringKey) {
        self.text = Text(key)
    }

    init(verbatim value: String) {
        self.text = Text(verbatim: value)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.cadenza(10, weight: .semibold, scale: uiScale))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            text
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptionSettingsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState

    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: TranscriptionLanguage = .auto
    @AppStorage("summaryLanguage") private var summaryLanguage: TranscriptionLanguage = .auto
    @AppStorage(SummaryDetailLevel.defaultsKey) private var detailLevel: SummaryDetailLevel = .detailed
    @AppStorage("transcriptionProvider") private var transcriptionProvider: AIProvider = .apple
    @AppStorage("defaultAIProvider") private var defaultProvider: AIProvider = .apple
    @AppStorage("enableRealtimeTranscription") private var enableRealtimeTranscription = false
    @AppStorage("realtimeTranscriptionProvider") private var realtimeProvider: AIProvider = .openai
    @AppStorage(SpeakerMemoryConsent.defaultsKey) private var speakerMemoryEnabled = false
    @AppStorage("aiChatDefaultTimeRange") private var aiChatTimeRange = "allTime"
    @AppStorage(AutomaticRecapGeneration.defaultsKey) private var automaticRecapsEnabled = false
    @AppStorage(ActiveProfileDefaults.key("userName")) private var userName = ""
    @AppStorage(ActiveProfileDefaults.key("userJobTitle")) private var userJobTitle = ""
    @AppStorage(ActiveProfileDefaults.key("summaryFocus")) private var summaryFocus = ""
    @AppStorage(ActiveProfileDefaults.key("meetingPrepEnabled")) private var meetingPrepEnabled = false
    @AppStorage(ActiveProfileDefaults.key("meetingPrepLeadMinutes")) private var meetingPrepLeadMinutes = 30
    @State private var showDeleteSpeakerMemoryAlert = false
    @State private var isDeletingSpeakerMemory = false
    @State private var speakerMemoryDeletionError: String?

    private var summaryProviderPicker: some View {
        SettingsPickerRow("AI Provider", subtitle: "Used for summaries, AI chat, and other AI tasks", selection: $defaultProvider) {
            // Always include Apple plus every provider with a stored key.
            // Additionally include the currently-stored provider even if its
            // key is missing, so the menu never silently drops the value the
            // app will actually use. The missing-key case is labeled so the
            // user can see why summaries will fail until a key is added.
            ForEach(aiProviderOptions) { provider in
                if provider.requiresAPIKey && !KeychainManager.shared.hasAPIKey(for: provider) {
                    Text("\(provider.displayName) (API key missing)").tag(provider)
                } else {
                    Text(provider.displayName).tag(provider)
                }
            }
        }
    }

    /// Options for the "AI Provider" picker. Always offers Apple and every
    /// provider that has a stored API key. Crucially, it also includes the
    /// currently-selected `defaultProvider` even when its key is missing —
    /// otherwise its tag would not exist among the menu items and the Picker
    /// would render a blank/incorrect selection that no longer reflects the
    /// value the app actually uses for summaries.
    private var aiProviderOptions: [AIProvider] {
        var options: [AIProvider] = [.apple]
        options += AIProvider.allCases.filter {
            $0.requiresAPIKey && KeychainManager.shared.hasAPIKey(for: $0)
        }
        if !options.contains(defaultProvider) {
            options.append(defaultProvider)
        }
        return options
    }

    var body: some View {
        SettingsPageLayout(title: SettingsCategory.transcription.title, subtitle: SettingsCategory.transcription.subtitle) {
            SettingsSectionCard(title: "Transcription") {
                HStack(alignment: .top, spacing: 10) {
                    ProviderLogoTile(provider: transcriptionProvider)
                        .padding(.top, 6)
                    SettingsPickerRow("Engine", subtitle: "Speech-to-text provider for post-recording transcription", selection: $transcriptionProvider) {
                        Text("Apple (Local)").tag(AIProvider.apple)
                        Text("Whisper (Local)").tag(AIProvider.whisperLocal)
                        Text("OpenAI").tag(AIProvider.openai)
                        Text("Gemini").tag(AIProvider.gemini)
                    }
                }

                if transcriptionProvider == .apple {
                    Text("Free, fast, offline. No speaker identification.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }

                if transcriptionProvider == .whisperLocal {
                    WhisperModelPicker(
                        externalAccessEnabled: appState.startupPolicy.externalAccessEnabled
                    )
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }

                if transcriptionProvider.requiresAPIKey {
                    ModelOverrideRow(
                        title: "Model",
                        subtitle: "Model ID for \(transcriptionProvider.displayName) transcription. Leave empty for the default.",
                        key: "transcriptionModel.\(transcriptionProvider.rawValue)",
                        placeholder: transcriptionProvider.defaultTranscriptionModel
                    )
                }

                Divider()

                SettingsPickerRow("Language", subtitle: "Language preference for speech-to-text", selection: $transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            SettingsSectionCard(title: "Speaker Identification") {
                @Bindable var diarizer = SpeakerDiarizer.shared
                SettingsToggleRow(
                    "Identify speakers",
                    subtitle: "Detect who said what after transcription. On-device, ~15s for 1h audio.",
                    isOn: $diarizer.isEnabled
                )

                // Only states needing attention get a row; the row
                // disappearing after a download is the completion signal.
                if diarizer.isEnabled, !diarizer.isReady {
                    Divider()

                    if diarizer.downloadProgress > 0
                                && diarizer.downloadProgress < 1 {
                        HStack(spacing: 8) {
                            ProgressView(value: diarizer.downloadProgress)
                                .frame(width: 100)
                                .controlSize(.small)
                            Text("\(Int(diarizer.downloadProgress * 100))%")
                                .font(.cadenza(.caption, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button("Download Speaker Model (~80 MB)") {
                            guard appState.startupPolicy.externalAccessEnabled else { return }
                            Task {
                                try? await diarizer.prepare(
                                    externalAccessEnabled: appState.startupPolicy.externalAccessEnabled
                                )
                            }
                        }
                        .padding(.vertical, 4)
                        .disabled(!appState.startupPolicy.externalAccessEnabled)
                    }
                }

                Divider()

                // Concept M: the destructive action lives on the row it acts
                // on instead of floating below the card as an orphan button.
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remember voices across recordings")
                            .font(.cadenza(14, scale: uiScale))
                        Text("Store reusable voice embeddings on this Mac to suggest or apply speaker names in future recordings. This is separate from per-recording speaker identification.")
                            .font(.cadenza(.subheadline, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    if isDeletingSpeakerMemory {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button("Delete Voice Memory", role: .destructive) {
                        showDeleteSpeakerMemoryAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDeletingSpeakerMemory)

                    Toggle("Remember voices across recordings", isOn: $speakerMemoryEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Remember voices across recordings"))
                        .disabled(
                            SpeakerMemoryConsent.isSettingsToggleDisabled(
                                diarizationEnabled: diarizer.isEnabled,
                                memoryEnabled: speakerMemoryEnabled,
                                isDeleting: isDeletingSpeakerMemory
                            )
                        )
                }
                .padding(.vertical, 8)

                if let speakerMemoryDeletionError {
                    Text(speakerMemoryDeletionError)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.red)
                }
            }

            SettingsSectionCard(title: "Live Transcription") {
                SettingsToggleRow(
                    "Enable live transcription",
                    subtitle: "Transcribe meeting/system audio during recording with the provider you select.",
                    isOn: $enableRealtimeTranscription
                )

                if enableRealtimeTranscription {
                    Divider()

                    HStack(alignment: .top, spacing: 10) {
                        ProviderLogoTile(provider: realtimeProvider)
                            .padding(.top, 6)
                        SettingsPickerRow("Engine", subtitle: "Provider for real-time transcription", selection: $realtimeProvider) {
                            Text("OpenAI").tag(AIProvider.openai)
                            Text("Gemini").tag(AIProvider.gemini)
                            Text("Apple (Local)").tag(AIProvider.apple)
                        }
                    }

                    if realtimeProvider == .apple {
                        SettingsInfoNote("Apple live transcription is processed on this Mac. No API key is required.")
                        Text("Live transcription uses the meeting/system audio track only. Microphone audio is not sent to realtime providers.")
                            .font(.cadenza(.caption, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    } else {
                        SettingsInfoNote(
                            verbatim: String(
                                format: String(localized: "Meeting/system audio is sent to %@ for live transcription. Microphone audio is not sent."),
                                realtimeProvider.displayName
                            )
                        )
                            .padding(.bottom, realtimeProvider == .gemini ? 0 : 4)

                        if realtimeProvider == .gemini {
                            Text("Uses Gemini Live API. May have higher latency than OpenAI.")
                                .font(.cadenza(.caption, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 4)
                        }
                    }

                    if realtimeProvider.requiresAPIKey {
                        ModelOverrideRow(
                            title: "Model",
                            subtitle: "Model ID for live captions. Leave empty for the default.",
                            key: "realtimeModel.\(realtimeProvider.rawValue)",
                            placeholder: realtimeProvider.defaultRealtimeModel
                        )
                    }
                }
            }

            SettingsSectionCard(title: "Summary & AI") {
                HStack(alignment: .top, spacing: 10) {
                    ProviderLogoTile(provider: defaultProvider)
                        .padding(.top, 6)
                    summaryProviderPicker
                }

                if defaultProvider.requiresAPIKey {
                    ModelOverrideRow(
                        title: "Summary model",
                        subtitle: "Used for summaries. AI chat models are selected in chat.",
                        key: "model.\(defaultProvider.rawValue)",
                        placeholder: defaultProvider.defaultModel
                    )
                }

                Divider()

                SettingsToggleRow(
                    "Generate recaps automatically",
                    subtitle: "At app startup, aggregate meeting titles, dates, tags, summaries, decisions, and action items with the selected AI provider. Cloud providers receive this data.",
                    isOn: $automaticRecapsEnabled
                )

                Divider()

                SettingsPickerRow("AI chat searches", subtitle: "How far back chat looks when your question doesn't name a time range. Asking e.g. \"last week\" always narrows to that period.", selection: $aiChatTimeRange) {
                    Text("All recordings").tag("allTime")
                    Text("Last 90 days").tag("last90Days")
                    Text("Last 30 days").tag("last30Days")
                }

                Divider()

                SettingsPickerRow("Summary language", subtitle: "Output language for generated summaries", selection: $summaryLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    SettingsPickerRow("Detail level", subtitle: "How deep the generated summary should be", selection: $detailLevel) {
                        ForEach(SummaryDetailLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }

                    Text(detailLevel.description)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)

                    Text("Applies to new and regenerated summaries. Existing summaries stay unchanged.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)

                    if detailLevel == .fullBreakdown {
                        Text("Detailed summaries may take longer. Coverage depends on the transcript and model.")
                            .font(.cadenza(.caption, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Name")
                    TextField("Your name", text: $userName)
                        .textFieldStyle(.roundedBorder)
                    Text("AI will identify tasks and action items assigned to you.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Job Title")
                    TextField("Engineering Manager", text: $userJobTitle)
                        .textFieldStyle(.roundedBorder)
                    Text("Used for optional personal notes. The meeting record stays complete.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            SettingsSectionCard(title: "Personal summary context") {
                TextField("Usual focus", text: $summaryFocus, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Text("Personal context is stored by the app locally and excluded from sync, standard exports and MCP summaries.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Used when you update personal notes in a meeting. Your selected AI provider receives your name, role and chosen context. Calendar details and related history are optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsSectionCard(title: "Meeting Prep") {
                SettingsToggleRow(
                    "Auto-generate prep briefs",
                    subtitle: "Before each eligible meeting, generate a preparation brief from related meeting history using your default AI provider.",
                    isOn: $meetingPrepEnabled
                )

                if meetingPrepEnabled {
                    Divider()

                    SettingsPickerRow("Generate", subtitle: "How long before the meeting to generate the brief", selection: $meetingPrepLeadMinutes) {
                        Text("15 minutes before").tag(15)
                        Text("30 minutes before").tag(30)
                        Text("60 minutes before").tag(60)
                    }
                }
            }

            TagManagementCard()
        }
        .alert("Delete all voice memory?", isPresented: $showDeleteSpeakerMemoryAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                speakerMemoryEnabled = false
                isDeletingSpeakerMemory = true
                speakerMemoryDeletionError = nil
                Task {
                    let deleted = await appState.store.deleteAllSpeakerMemory()
                    isDeletingSpeakerMemory = false
                    if !deleted {
                        speakerMemoryDeletionError = String(
                            localized: "Voice memory could not be deleted. Your data was kept."
                        )
                    }
                }
            }
        } message: {
            Text("This permanently deletes reusable voice embeddings and generated speaker suggestions, and turns off cross-recording voice memory. Explicit speaker names and mappings are kept.")
        }
        .onChange(of: speakerMemoryEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            Task {
                await appState.store.invalidateSpeakerMemoryWriteSessions()
            }
        }
    }
}

/// Tags settings: edit the blocklist (dropped from all recordings) and view the
/// auto-converging vocabulary with usage counts.
private struct TagManagementCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.uiScale) private var uiScale: CGFloat

    @State private var blocklist: [String] = []
    @State private var newBlockTag = ""
    @State private var vocab: [TagCountDTO] = []
    @State private var isWorking = false

    var body: some View {
        SettingsSectionCard(title: "Tags") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hidden tags")
                    .font(.cadenza(13, scale: uiScale))
                Text("These tags are removed from new and existing recordings.")
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)

                if blocklist.isEmpty {
                    Text("None")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(blocklist, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag).font(.cadenza(12, scale: uiScale))
                                Button {
                                    Task { await removeBlock(tag) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").imageScale(.small)
                                }
                                .buttonStyle(.cadenzaPlain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }

                HStack {
                    TextField("Add a tag to hide", text: $newBlockTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await addBlock() } }
                    Button("Add") { Task { await addBlock() } }
                        .disabled(newBlockTag.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
            .padding(.vertical, 4)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Tags in use")
                    .font(.cadenza(13, scale: uiScale))
                if vocab.isEmpty {
                    Text("No tags yet")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(vocab, id: \.tag) { item in
                        HStack {
                            Text(item.tag).font(.cadenza(12, scale: uiScale))
                            Spacer()
                            Text("\(item.count)")
                                .font(.cadenza(.caption, scale: uiScale))
                                .foregroundStyle(.secondary)
                            Button("Hide") { Task { await block(item.tag) } }
                                .font(.cadenza(.caption, scale: uiScale))
                                .buttonStyle(.cadenzaPlain)
                                .foregroundStyle(.tint)
                                .disabled(isWorking)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .task { await reload() }
    }

    private func reload() async {
        blocklist = (UserDefaults.standard.stringArray(forKey: "tagBlocklist") ?? []).sorted()
        vocab = await appState.store.distinctTags()
    }

    private func addBlock() async {
        let tag = newBlockTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        newBlockTag = ""
        await applyBlocklist(adding: tag)
    }

    private func block(_ tag: String) async {
        await applyBlocklist(adding: tag)
    }

    private func removeBlock(_ tag: String) async {
        var list = UserDefaults.standard.stringArray(forKey: "tagBlocklist") ?? []
        let key = TagNormalizer.formatKey(tag)
        list.removeAll { TagNormalizer.formatKey($0) == key }
        UserDefaults.standard.set(list, forKey: "tagBlocklist")
        await applyAndReload()
    }

    private func applyBlocklist(adding tag: String) async {
        var list = UserDefaults.standard.stringArray(forKey: "tagBlocklist") ?? []
        let key = TagNormalizer.formatKey(tag)
        if !list.contains(where: { TagNormalizer.formatKey($0) == key }) {
            list.append(tag)
        }
        UserDefaults.standard.set(list, forKey: "tagBlocklist")
        await applyAndReload()
    }

    private func applyAndReload() async {
        isWorking = true
        await appState.store.normalizeAllTagsIfNeeded(force: true)
        appState.refreshRecordings()
        await reload()
        isWorking = false
    }
}

// MARK: - Calendars & Connections

struct CalendarsSettingsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @State private var calendars: [CalendarInfo] = []
    @State private var disabledIDs: Set<String> = []

    private var groupedCalendars: [(account: String, items: [CalendarInfo])] {
        let grouped = Dictionary(grouping: calendars) { $0.accountName }
        return grouped.keys.sorted().map { key in
            (account: key, items: grouped[key] ?? [])
        }
    }

    var body: some View {
        SettingsPageLayout(title: "Calendars & Connections", subtitle: "Calendar visibility and integrations") {
            if calendars.isEmpty {
                SettingsSectionCard(title: "Calendars") {
                    Text("No calendars available. Grant calendar access in System Settings.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } else {
                ForEach(groupedCalendars, id: \.account) { group in
                    SettingsSectionCard(title: group.account) {
                        ForEach(group.items) { calendar in
                            HStack(spacing: 10) {
                                Toggle(isOn: Binding(
                                    get: { !disabledIDs.contains(calendar.id) },
                                    set: { enabled in
                                        if enabled {
                                            disabledIDs.remove(calendar.id)
                                        } else {
                                            disabledIDs.insert(calendar.id)
                                        }
                                        saveDisabledIDs()
                                    }
                                )) {
                                    Text(calendar.title)
                                }

                                Spacer(minLength: 8)

                                CalendarItemColorPicker(calendarID: calendar.id, defaultHex: calendar.defaultColorHex)
                            }
                            .padding(.vertical, 8)

                            if calendar.id != group.items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            SettingsSectionCard(title: "Connections") {
                ConnectionsInline()
            }
        }
        .onAppear {
            appState.fetchAvailableCalendars { items in
                calendars = items
            }
            disabledIDs = Set(UserDefaults.standard.stringArray(forKey: "disabledCalendarIDs") ?? [])
        }
    }

    private func saveDisabledIDs() {
        UserDefaults.standard.set(Array(disabledIDs), forKey: "disabledCalendarIDs")
    }
}

struct ConnectionsInline: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Calendar
            connectionRow(
                icon: "calendar",
                name: String(localized: "Apple Calendar"),
                subtitle: String(localized: "On-device calendar events"),
                status: appState.hasCalendarPermission ? .connected : .attention,
                statusLabel: appState.hasCalendarPermission ? "Connected" : "Calendar access required"
            ) {
                if !appState.hasCalendarPermission {
                    Button(calendarPermissionActionLabel) {
                        guard appState.startupPolicy.externalAccessEnabled else { return }
                        Task {
                            let granted = await Permissions.requestOrRecoverCalendarAccess(
                                currentStatus: appState.calendarPermissionStatus
                            )
                            await appState.applyCalendarAccessRequestOutcome(granted: granted)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!appState.startupPolicy.externalAccessEnabled)
                }
            }

            Divider().padding(.leading, 40)

            // Google Calendar
            GoogleCalendarInlineRow()

            Divider().padding(.leading, 40)

            // Zoom
            ZoomInlineRow()
        }
        .disabled(!appState.startupPolicy.externalAccessEnabled)
    }

    private var calendarPermissionActionLabel: LocalizedStringKey {
        appState.calendarPermissionStatus == .denied ? "Open Settings" : "Grant Access"
    }

    private func connectionRow<Actions: View>(
        icon: String,
        name: String,
        subtitle: String,
        status: SettingsStatusCapsule.Kind,
        statusLabel: LocalizedStringKey,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.cadenza(16, scale: uiScale))
                .frame(width: iconSize, height: iconSize)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.cadenza(14, weight: .medium, scale: uiScale))
                    SettingsStatusCapsule(kind: status, label: statusLabel)
                }
                Text(subtitle)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            actions()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Google Calendar Inline Row

private struct GoogleCalendarInlineRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState
    @State private var isExpanded = false
    @State private var clientID = ""
    @State private var clientSecret = ""

    private var presentation: GoogleCalendarConnectionPresentation {
        .make(
            isConnected: appState.googleCalendarConnected,
            isConnecting: appState.googleCalendarConnecting,
            error: appState.googleCalendarError
        )
    }

    var body: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "g.circle")
                    .font(.cadenza(16, scale: uiScale))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Google Calendar")
                            .font(.cadenza(14, weight: .medium, scale: uiScale))
                        SettingsStatusCapsule(
                            kind: presentation.phase == .connected
                                ? .connected
                                : (presentation.phase == .error ? .attention : .disconnected),
                            label: presentation.phase == .connected ? "Connected" : "Not Connected"
                        )
                    }
                    Text("Sync Google Calendar events")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                    if presentation.phase == .error {
                        Text(presentation.statusText)
                            .font(.cadenza(11, scale: uiScale))
                            .foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 8)

                if appState.googleCalendarConnected {
                    Button("Disconnect", role: .destructive) {
                        appState.disconnectGoogleCalendar()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if appState.googleCalendarConnecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Connect") {
                        if clientID.isEmpty {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded = true }
                        } else {
                            appState.connectGoogleCalendar()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 10)

            if isExpanded && !appState.googleCalendarConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google OAuth2 Credentials")
                        .font(.cadenza(.caption, weight: .bold, scale: uiScale))
                    TextField("Client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret (optional for PKCE)", text: $clientSecret)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        Button("Save & Connect") {
                            if saveAndConnect() {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded = false }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(clientID.isEmpty)

                        Button("Cancel") {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded = false }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear {
            let credentials = appState.googleCalendarCredentials()
            clientID = credentials.clientID
            clientSecret = credentials.clientSecret
        }
    }

    @discardableResult
    private func saveAndConnect() -> Bool {
        guard appState.saveGoogleCalendarCredentials(
            clientID: clientID,
            clientSecret: clientSecret
        ) else { return false }
        appState.connectGoogleCalendar()
        return true
    }
}

// MARK: - Zoom Inline Row
//
// Cadenza is a Zoom Marketplace public PKCE OAuth app — there is no
// per-user client_id / client_secret to enter. One tap opens the browser.

private struct ZoomInlineRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    private var presentation: GoogleCalendarConnectionPresentation {
        .make(
            isConnected: appState.zoomConnected,
            isConnecting: appState.zoomConnecting,
            error: appState.zoomError
        )
    }

    var body: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "video")
                    .font(.cadenza(16, scale: uiScale))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Zoom")
                            .font(.cadenza(14, weight: .medium, scale: uiScale))
                        SettingsStatusCapsule(
                            kind: presentation.phase == .connected
                                ? .connected
                                : (presentation.phase == .error ? .attention : .disconnected),
                            label: presentation.phase == .connected ? "Connected" : "Not Connected"
                        )
                    }
                    Text("Import Zoom cloud recordings")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if appState.zoomConnected {
                    Button(
                        presentation.phase == .error
                            ? String(localized: "Retry Disconnect")
                            : String(localized: "Disconnect"),
                        role: .destructive
                    ) {
                        appState.disconnectZoom()
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if appState.zoomConnecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Connect") { appState.connectZoom() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 10)

            if let error = appState.zoomError, !appState.zoomConnected {
                Text(error)
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
    }
}

enum CalendarColorSwatchMetrics {
    static func swatchSize(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 22,
            symbolPointSize: 10,
            scale: scale,
            padding: 6
        )
    }

    static func hitSize(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 32,
            symbolPointSize: 10,
            scale: scale,
            padding: 14
        )
    }
}

struct CalendarColorSwatchButton: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let option: CalendarColorOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let swatchSize = CalendarColorSwatchMetrics.swatchSize(scale: uiScale)
        let hitSize = CalendarColorSwatchMetrics.hitSize(scale: uiScale)

        Button(action: action) {
            ZStack {
                Circle()
                    .fill(option.color)
                    .frame(width: swatchSize, height: swatchSize)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.cadenza(.caption2, weight: .bold, scale: uiScale))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.cadenzaPlain)
        .accessibilityLabel(Text(option.localizedName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(option.localizedName))
    }
}

struct CalendarItemColorPicker: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let calendarID: String
    let defaultHex: String

    @State private var selectedOption: CalendarColorOption?
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            Circle()
                .fill(currentColor)
                .frame(width: 16, height: 16)
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.cadenzaPlain(in: Circle()))
        .accessibilityLabel(Text("Calendar Color"))
        .accessibilityValue(Text(selectedOption?.localizedName ?? String(localized: "Default")))
        .popover(isPresented: $showPicker) {
            VStack(spacing: 8) {
                Text("Calendar Color")
                    .font(.cadenza(.caption, weight: .bold, scale: uiScale))

                HStack(spacing: 8) {
                    Button {
                        selectedOption = nil
                        UserDefaults.standard.removeObject(forKey: "calColor.\(calendarID)")
                        showPicker = false
                    } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(Color(hex: defaultHex))
                                .frame(width: 22, height: 22)
                            Text("Default")
                                .font(.cadenza(.caption2, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.cadenzaPlain)
                    .accessibilityLabel(Text("Default"))
                    .accessibilityAddTraits(selectedOption == nil ? .isSelected : [])

                    ForEach(CalendarColorOption.allCases, id: \.self) { option in
                        CalendarColorSwatchButton(
                            option: option,
                            isSelected: selectedOption == option
                        ) {
                            selectedOption = option
                            UserDefaults.standard.set(option.rawValue, forKey: "calColor.\(calendarID)")
                            showPicker = false
                        }
                    }
                }
            }
            .padding(12)
        }
        .onAppear { loadColor() }
    }

    private var currentColor: Color {
        if let selectedOption {
            return selectedOption.color
        }
        return Color(hex: defaultHex)
    }

    private func loadColor() {
        if let raw = UserDefaults.standard.string(forKey: "calColor.\(calendarID)"),
           let option = CalendarColorOption(rawValue: raw) {
            selectedOption = option
        }
    }
}


#Preview("Settings Workspace") {
    SettingsWorkspaceView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
