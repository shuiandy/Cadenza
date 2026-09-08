import SwiftUI
import AppKit

struct IntegrationsSettingsView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    @State private var apiKeyRefreshToken = 0

    /// Set when disconnecting a provider forces the default AI provider to
    /// switch. Lives here (outside the `.id(apiKeyRefreshToken)` subtree) so the
    /// alert survives the ProviderRow rebuild that the same disconnect triggers.
    @State private var defaultProviderSwitch: DefaultProviderSwitch?

    @State private var calendars: [CalendarInfo] = []
    @State private var disabledIDs: Set<String> = []
    @State private var showCalendarSheet = false

    @State private var craftSpaceID = ""
    @AppStorage(ActiveProfileDefaults.key("autoExportToCraft")) private var autoExportToCraft = false

    @State private var craftExpanded = false

    private var groupedCalendars: [(account: String, items: [CalendarInfo])] {
        let grouped = Dictionary(grouping: calendars) { $0.accountName }
        return grouped.keys.sorted().map { key in
            (account: key, items: grouped[key] ?? [])
        }
    }

    var body: some View {
        // craftInlineRow is a @ViewBuilder computed property. @Observable only
        // registers a dependency when the property is read during this body's
        // evaluation, and reads inside a nested ViewBuilder closure don't
        // always reroute back here. Notion has been hoisted into its own View
        // struct (NotionInlineRow) so it tracks itself; Craft only depends on
        // craftIsAvailable, which doesn't change at runtime, so an explicit
        // touch here is enough until it gets the same treatment.
        let _ = appState.craftIsAvailable
        SettingsPageLayout(
            title: "Integrations",
            subtitle: "AI providers, calendars, and export connections"
        ) {
            SettingsSectionCard(title: "Cadenza Account",
                                subtitle: "Sign in to use Web transcripts and cloud-backed integrations") {
                CadenzaAccountInline()
            }

            SettingsSectionCard(title: "AI Providers") {
                VStack(spacing: 0) {
                    let cloudProviders = AIProvider.allCases.filter { $0.requiresAPIKey }
                    ForEach(Array(cloudProviders.enumerated()), id: \.element) { index, provider in
                        ProviderRow(provider: provider,
                                    refreshToken: $apiKeyRefreshToken,
                                    defaultProviderSwitch: $defaultProviderSwitch)

                        if index < cloudProviders.count - 1 {
                            Divider()
                                .padding(.leading, 38)
                        }
                    }
                }
                .id(apiKeyRefreshToken)
            }

            SettingsSectionCard(title: "Connections", subtitle: "Calendar and meeting service accounts") {
                ConnectionsInline()
            }

            SettingsSectionCard(title: "AI Access (MCP)",
                                subtitle: "Let external AI assistants search and read your transcripts") {
                MCPAccessInline()
            }

            SettingsSectionCard(title: "Local knowledge") {
                MarkdownMirrorSettingsView()
            }

            SettingsSectionCard(title: "Calendars") {
                if calendars.isEmpty {
                    Text("No calendars available. Grant calendar access in System Settings.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    let calendarIconSize = CadenzaControlMetrics.squareIconFrame(
                        base: 34,
                        symbolPointSize: 16,
                        scale: uiScale,
                        padding: 13
                    )
                    Button {
                        showCalendarSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar")
                                .font(.cadenza(16, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .frame(width: calendarIconSize, height: calendarIconSize)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 1) {
                                Text("Manage visible calendars")
                                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                                Text("Visibility and color for each calendar")
                                    .font(.cadenza(12, scale: uiScale))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Text("\(calendars.count - disabledIDs.count) of \(calendars.count) enabled")
                                .font(.cadenza(10.5, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 21)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Image(systemName: "chevron.right")
                                .font(.cadenza(.caption, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.cadenzaPlain)
                }
            }

            SettingsSectionCard(title: "Export") {
                NotionInlineRow()

                Divider().padding(.leading, 40)

                // Craft
                craftInlineRow
            }
        }
        .onAppear {
            appState.fetchAvailableCalendars { items in
                calendars = items
            }
            disabledIDs = Set(UserDefaults.standard.stringArray(forKey: "disabledCalendarIDs") ?? [])

            craftSpaceID = UserDefaults.standard.string(forKey: ActiveProfileDefaults.key("craft.spaceID")) ?? ""
        }
        .sheet(isPresented: $showCalendarSheet) {
            CalendarManageSheet(
                groupedCalendars: groupedCalendars,
                disabledIDs: $disabledIDs,
                onSave: { saveDisabledIDs() }
            )
        }
        .alert(
            "Default AI provider changed",
            isPresented: Binding(
                get: { defaultProviderSwitch != nil },
                set: { if !$0 { defaultProviderSwitch = nil } }
            ),
            presenting: defaultProviderSwitch
        ) { _ in
            Button("OK", role: .cancel) { defaultProviderSwitch = nil }
        } message: { change in
            Text("\(change.from.displayName) was your default AI provider for summaries and AI chat. Because you disconnected it, the default was switched to \(change.to.displayName).")
        }
    }

    // MARK: - Craft Inline Row

    @ViewBuilder
    private var craftInlineRow: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.cadenza(16, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text("Craft")
                            .font(.cadenza(14, weight: .medium, scale: uiScale))
                        SettingsStatusCapsule(
                            kind: appState.craftIsAvailable ? .connected : .attention,
                            label: appState.craftIsAvailable ? "Available" : "Not installed"
                        )
                    }
                    Text("Installed on this Mac; exports as Craft documents")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)

            if appState.craftIsAvailable {
                SettingsDependentRow {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Space ID")
                                    .font(.cadenza(14, scale: uiScale))
                                Text("Leave empty to use your default space")
                                    .font(.cadenza(.subheadline, scale: uiScale))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            TextField("Optional", text: $craftSpaceID)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onChange(of: craftSpaceID) { _, value in
                                    UserDefaults.standard.set(value, forKey: ActiveProfileDefaults.key("craft.spaceID"))
                                }
                        }
                        .padding(.vertical, 8)

                        Divider().opacity(0.5)

                        SettingsToggleRow("Auto-export after recording", isOn: $autoExportToCraft)

                        BulkExportRow(destination: .craft)
                    }
                }
            }
        }
    }

    private func saveDisabledIDs() {
        UserDefaults.standard.set(Array(disabledIDs), forKey: "disabledCalendarIDs")
    }
}

// MARK: - Notion Inline Row

/// Settings row for the Notion integration. Composes `RequiresSignInConnectionRow`
/// for the gated state, with `NotionDatabasePicker` as the connected detail.
private struct NotionInlineRow: View {    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        let auth = appState.cadenzaAuth
        let notion = appState.exportService.notionService

        let reauthProvider: String? = {
            if case .integrationReauthRequired(let provider) = auth.lastError, provider == "notion" {
                return "Notion"
            }
            if notion.needsForcedReconnect { return "Notion" }
            return nil
        }()

        RequiresSignInConnectionRow(
            icon: .asset("notion-icon"),
            title: "Notion",
            subtitleConnected: notion.workspaceName.isEmpty
                ? String(localized: "Connected")
                : String(localized: "Connected — \(notion.workspaceName)"),
            subtitleDisconnected: String(localized: "Connect to export meetings to a database."),
            isSignedIn: auth.isSignedIn,
            isConnected: notion.isConnected,
            isConnecting: notion.isConnecting,
            reauthRequiredFor: reauthProvider,
            error: notion.lastError,
            connect: {
                guard appState.startupPolicy.externalAccessEnabled else { return }
                Task { try? await notion.connect() }
            },
            disconnect: {
                guard appState.startupPolicy.externalAccessEnabled else { return }
                appState.exportService.bulkExporter.cancelActiveRun(for: .notion)
                notion.disconnect()
            }
        ) {
            NotionDatabasePicker()
                .environment(appState)
        }
    }
}

/// Database picker + auto-export toggle, rendered as `connectedDetail` inside
/// `NotionInlineRow`. Only mounted while the integration is connected.
private struct NotionDatabasePicker: View {    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    @State private var notionDatabases: [NotionDatabaseDTO] = []
    @State private var selectedDatabaseID = ""
    @State private var isFetchingDatabases = false
    @State private var isCreatingDB = false
    @State private var createDBError: String?
    @State private var showDBCreatedTip = false
    @AppStorage(ActiveProfileDefaults.key("autoExportToNotion")) private var autoExportToNotion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text("Database")
                    .font(.cadenza(14, scale: uiScale))
                Spacer(minLength: 12)
                Picker("", selection: $selectedDatabaseID) {
                    Text("Select a database").tag("")
                    ForEach(notionDatabases, id: \.id) { database in
                        Text(database.title).tag(database.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: selectedDatabaseID) { _, value in
                    UserDefaults.standard.set(value, forKey: ActiveProfileDefaults.key("notion.databaseID"))
                }

                Button {
                    refreshNotionDatabases()
                } label: {
                    Group {
                        if isFetchingDatabases {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetchingDatabases || !appState.startupPolicy.externalAccessEnabled)
                .help("Refresh database list")

                Button {
                    createNotionDatabase()
                } label: {
                    Group {
                        if isCreatingDB {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCreatingDB || !appState.startupPolicy.externalAccessEnabled)
                .help("Create a new database in Notion")
            }
            .padding(.vertical, 8)

            if let error = createDBError {
                Text(error)
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            }

            if showDBCreatedTip {
                Text("Tip: Add a Calendar view in Notion to visualize meetings by date.")
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            Divider()

            SettingsToggleRow("Auto-export after recording", isOn: $autoExportToNotion)

            BulkExportRow(destination: .notion)
        }
        .onAppear {
            selectedDatabaseID = appState.notionDatabaseID
        }
        .task {
            if notionDatabases.isEmpty && !isFetchingDatabases {
                refreshNotionDatabases()
            }
        }
    }

    private func refreshNotionDatabases() {
        guard appState.startupPolicy.externalAccessEnabled else { return }
        isFetchingDatabases = true
        appState.fetchNotionDatabases { databases in
            notionDatabases = databases
            isFetchingDatabases = false
        }
    }

    private func createNotionDatabase() {
        guard appState.startupPolicy.externalAccessEnabled else { return }
        isCreatingDB = true
        createDBError = nil
        showDBCreatedTip = false

        appState.createNotionDatabase { database in
            if let database {
                notionDatabases.append(database)
                selectedDatabaseID = database.id
                UserDefaults.standard.set(database.id, forKey: ActiveProfileDefaults.key("notion.databaseID"))
                showDBCreatedTip = true
            } else {
                createDBError = String(localized: "Failed to create database")
            }
            isCreatingDB = false
        }
    }
}

// MARK: - Cadenza Account Inline Row

private struct CadenzaAccountInline: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @State private var confirmingSignOut = false

    var body: some View {
        let auth = appState.cadenzaAuth
        let entitlements = EntitlementsPresentation.current(appState.webSync)
        let webSyncStatus = WebSyncStatusPresentation.resolve(
            isSyncing: appState.webSync.isSyncing,
            lastError: appState.webSync.lastError
        )
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                avatar(for: auth.currentUser)
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.currentUser?.displayName ?? String(localized: "Cadenza Account"))
                        .font(.cadenza(.headline, scale: uiScale))
                    Text(auth.currentUser?.email ?? String(localized: "Sign in to sync transcripts and summaries. Audio upload stays off until you turn it on."))
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailingControl(auth: auth)
            }
            AuthErrorBanner(error: auth.lastError)
            if let user = auth.currentUser {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcripts available on Web")
                            .font(.cadenza(14, weight: .medium, scale: uiScale))
                        Text("Recording details, transcripts, and summaries sync automatically.")
                            .font(.cadenza(.caption, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // The official web app is offered only to an account proven
                    // to be on the official service; a self-hosted deployment's
                    // address is never guessed.
                    if let webApp = entitlements?.webAppURL {
                        Link("Open Web App", destination: webApp)
                    }
                }
                WebSyncStatusRow(
                    presentation: webSyncStatus,
                    canRetry: appState.startupPolicy.externalAccessEnabled
                        && appState.profileTransitionBlockReason == nil
                ) {
                    guard appState.startupPolicy.externalAccessEnabled else { return }
                    appState.webSync.retryNow()
                }
                let audioControl = entitlements?.audioControl ?? .deniedNoAuthority
                HStack(spacing: 12) {
                    Text("Upload audio for web playback")
                        .font(.cadenza(14, scale: uiScale))
                    Spacer(minLength: 12)
                    Toggle("Upload audio for web playback", isOn: Binding(
                        get: { appState.webSync.audioUploadEnabled(userID: user.id) },
                        // A denial disables the control, so this setter is only
                        // reachable while uploads are permitted and never writes a
                        // value the user did not choose.
                        set: { appState.webSync.setAudioUploadEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!audioControl.isAvailable)
                    .accessibilityLabel(Text("Upload audio for web playback"))
                }
                if let denial = EntitlementsCopy.audioControlDenial(audioControl) {
                    Text(verbatim: denial)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Turn this off to keep audio only on this Mac. Transcripts and summaries still sync.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .alert("Sign out of Cadenza?", isPresented: $confirmingSignOut) {
            Button("Sign out", role: .destructive) { Task { await appState.signOutFromProfile() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All cloud integrations will become inaccessible until you sign in again.")
        }
    }

    @ViewBuilder
    private func avatar(for user: CadenzaAuthService.SignedInUser?) -> some View {
        let size: CGFloat = 34
        Group {
            if let url = user?.pictureURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.circle.fill")
                            .font(.cadenza(size, scale: 1))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.cadenza(size, scale: 1))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder
    private func trailingControl(auth: CadenzaAuthService) -> some View {
        switch auth.sessionState {
        case .signingIn:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser…").foregroundStyle(.secondary)
            }
        case .signedIn:
            Button("Sign out") { confirmingSignOut = true }
                .disabled(appState.profileTransitionBlockReason != nil)
                .help(appState.profileTransitionBlockReason ?? String(localized: "Sign out of this profile."))
        case .signedOut, .expired:
            Button(auth.sessionState == .expired
                ? String(localized: "Sign in again")
                : String(localized: "Sign in with Google")) {
                if auth.sessionState == .expired {
                    Task { await appState.signInToCadenza() }
                } else {
                    appState.presentSignIn()
                }
            }
        }
    }
}

// MARK: - Web Sync Status

/// A deliberately lossy presentation boundary. Coordinator diagnostics may
/// contain provider, transport, or server details, so the UI consumes only
/// whether an error exists and renders fixed, localized copy.
enum WebSyncStatusPresentation: Equatable {
    case syncing
    case retrying
    case automatic

    static func resolve(isSyncing: Bool, lastError: String?) -> Self {
        if isSyncing { return .syncing }
        if lastError != nil { return .retrying }
        return .automatic
    }

    var title: LocalizedStringKey {
        switch self {
        case .syncing:
            "Syncing to Web…"
        case .retrying:
            "Sync failed. Retrying automatically."
        case .automatic:
            "Web sync is automatic."
        }
    }

    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .syncing:
            String(localized: "Syncing to Web…", locale: locale)
        case .retrying:
            String(localized: "Sync failed. Retrying automatically.", locale: locale)
        case .automatic:
            String(localized: "Web sync is automatic.", locale: locale)
        }
    }

    var showsRetryAction: Bool { self == .retrying }
}

enum WebSyncStatusLayoutPolicy {
    static func usesStackedLayout(scale: CGFloat) -> Bool {
        scale >= CadenzaTextScale.factor(.accessibility1)
    }
}

struct WebSyncStatusRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let presentation: WebSyncStatusPresentation
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        let stacked = WebSyncStatusLayoutPolicy.usesStackedLayout(scale: uiScale)
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        layout {
            statusLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            if presentation.showsRetryAction {
                Button("Retry now", action: retry)
                    .font(.cadenza(.caption, scale: uiScale))
                    .controlSize(stacked ? .regular : .small)
                    .frame(
                        maxWidth: stacked ? .infinity : nil,
                        minHeight: stacked ? 44 : nil,
                        alignment: .trailing
                    )
                    .disabled(!canRetry)
                    .accessibilityIdentifier("web-sync-retry")
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            indicator
            Text(presentation.title)
                .font(.cadenza(.caption, scale: uiScale))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch presentation {
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .retrying:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .automatic:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Calendar Sheet

private struct CalendarManageSheet: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let groupedCalendars: [(account: String, items: [CalendarInfo])]
    @Binding var disabledIDs: Set<String>
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var enabledCount: Int {
        let allIDs = groupedCalendars.flatMap { $0.items.map(\.id) }
        return allIDs.filter { !disabledIDs.contains($0) }.count
    }

    private var totalCount: Int {
        groupedCalendars.flatMap(\.items).count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Calendars")
                        .font(.cadenza(.title2, weight: .semibold, scale: uiScale))
                    Text("\(enabledCount) of \(totalCount) calendars enabled")
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Calendar list
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(groupedCalendars, id: \.account) { group in
                        // Concept Q: one color swatch per row (the picker IS
                        // the identity dot), an enabled count on the group
                        // header, and disabled calendars dimmed.
                        let enabledInGroup = group.items.filter { !disabledIDs.contains($0.id) }.count
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle")
                                    .foregroundStyle(.secondary)
                                Text(group.account)
                                    .font(.cadenza(15, weight: .semibold, scale: uiScale))
                                Spacer()
                                Text("\(enabledInGroup) of \(group.items.count) enabled")
                                    .font(.cadenza(10.5, scale: uiScale))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)

                            Divider().opacity(0.32)

                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, calendar in
                                    let isEnabled = !disabledIDs.contains(calendar.id)
                                    HStack(spacing: 10) {
                                        CalendarItemColorPicker(calendarID: calendar.id, defaultHex: calendar.defaultColorHex)

                                        Text(calendar.title)
                                            .font(.cadenza(14, scale: uiScale))
                                            .foregroundStyle(isEnabled ? .primary : .secondary)

                                        Spacer(minLength: 8)

                                        Toggle("", isOn: Binding(
                                            get: { !disabledIDs.contains(calendar.id) },
                                            set: { enabled in
                                                if enabled {
                                                    disabledIDs.remove(calendar.id)
                                                } else {
                                                    disabledIDs.insert(calendar.id)
                                                }
                                                onSave()
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 6)

                                    if index < group.items.count - 1 {
                                        Divider().opacity(0.32)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding(14)
                        .appGlassPanel(cornerRadius: 14, accent: .accentColor)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 460, minHeight: 380)
    }

    private func calendarColor(for calendar: CalendarInfo) -> Color {
        if let raw = UserDefaults.standard.string(forKey: "calColor.\(calendar.id)"),
           let option = CalendarColorOption(rawValue: raw) {
            return option.color
        }
        return Color(hex: calendar.defaultColorHex)
    }
}

// MARK: - Status Capsule

/// Connection-state chip shared by the integration rows: a filled dot for
/// connected, a hollow dot for disconnected, and a warning triangle for
/// states that need the user (permission, reauth).
struct SettingsStatusCapsule: View {
    enum Kind {
        case connected
        case disconnected
        case attention
    }

    @Environment(\.uiScale) private var uiScale: CGFloat

    let kind: Kind
    private let label: Text

    init(kind: Kind, label: LocalizedStringKey) {
        self.kind = kind
        self.label = Text(label)
    }

    /// For labels already localized elsewhere (e.g. the Onboarding table).
    init(kind: Kind, verbatimLabel: String) {
        self.kind = kind
        self.label = Text(verbatim: verbatimLabel)
    }

    var body: some View {
        HStack(spacing: 5) {
            switch kind {
            case .connected:
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            case .disconnected:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.2)
                    .frame(width: 7, height: 7)
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.cadenza(8, scale: uiScale))
                    .foregroundStyle(.orange)
            }

            label
                .font(.cadenza(10.5, weight: .semibold, scale: uiScale))
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 21)
        .background(backgroundColor, in: Capsule())
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
        .fixedSize()
    }

    private var labelColor: Color {
        switch kind {
        case .connected: .green
        case .disconnected: .secondary
        case .attention: .orange
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .connected: Color.green.opacity(0.12)
        case .disconnected: Color.primary.opacity(0.05)
        case .attention: Color.orange.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .connected: Color.green.opacity(0.35)
        case .disconnected: Color.primary.opacity(0.14)
        case .attention: Color.orange.opacity(0.4)
        }
    }
}

// MARK: - Provider Row

/// Payload for the "default AI provider changed" alert: disconnecting `from`
/// forced the default to switch to `to`.
private struct DefaultProviderSwitch {
    let from: AIProvider
    let to: AIProvider
}

private struct ProviderRow: View {
    private static let apiKeyMutationCoordinator = AIProviderAPIKeyMutationCoordinator()

    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let provider: AIProvider
    @Binding var refreshToken: Int

    /// Reported upward when disconnecting this provider forces the default AI
    /// provider to switch. Must NOT be local @State: the same disconnect bumps
    /// `refreshToken`, and the parent's `.id(apiKeyRefreshToken)` rebuilds this
    /// row, which would drop local state before the alert could present.
    @Binding var defaultProviderSwitch: DefaultProviderSwitch?

    @Environment(AppState.self) private var appState
    @State private var showCopied = false
    @State private var showFullKey = false
    @State private var isExpanded = false
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var mutationError: String?
    @State private var apiKeyPresentation: AIProviderAPIKeyPresentationState

    private var isConnected: Bool {
        apiKeyPresentation.isConnected
    }

    init(
        provider: AIProvider,
        refreshToken: Binding<Int>,
        defaultProviderSwitch: Binding<DefaultProviderSwitch?>
    ) {
        self.provider = provider
        _refreshToken = refreshToken
        _defaultProviderSwitch = defaultProviderSwitch
        _apiKeyPresentation = State(
            initialValue: AIProviderAPIKeyPresentationState(provider: provider)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Concept D row anatomy: logo tile · name + status capsule over the
            // purpose line · masked key chip · one clear action. The key chip
            // rides inline while it fits and drops below the row otherwise
            // (accessibility scales, revealed keys).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    rowHeader
                    Spacer(minLength: 8)
                    if isConnected, let existingKey = apiKeyPresentation.currentAPIKey {
                        apiKeyPill(existingKey)
                    }
                    rowAction
                }
                .padding(.vertical, 10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        rowHeader
                        Spacer(minLength: 8)
                        rowAction
                    }
                    if isConnected, let existingKey = apiKeyPresentation.currentAPIKey {
                        apiKeyPill(existingKey)
                            .padding(.leading, 40)
                    }
                }
                .padding(.vertical, 10)
            }

            if let mutationError {
                Text(mutationError)
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.red)
                    .padding(.leading, 40)
                    .padding(.bottom, 6)
            }

            // Inline connect form
            if isExpanded && !isConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.cadenza(.caption, weight: .bold, scale: uiScale))

                    HStack(spacing: 8) {
                        Group {
                            if showKey {
                                TextField(provider.apiKeyPlaceholder, text: $apiKey)
                            } else {
                                SecureField(provider.apiKeyPlaceholder, text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    if let error = validationError {
                        Text(error)
                            .font(.cadenza(.caption, scale: uiScale))
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 8) {
                        Button {
                            guard appState.startupPolicy.externalAccessEnabled else { return }
                            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            validationError = nil
                            mutationError = nil
                            isValidating = true
                            Task {
                                guard appState.startupPolicy.externalAccessEnabled else {
                                    isValidating = false
                                    return
                                }
                                let credentialValidator = AIProviderCredentialValidator()
                                let result = await credentialValidator.validateAPIKey(
                                    trimmed,
                                    provider: provider
                                )
                                isValidating = false
                                if let error = result {
                                    validationError = error
                                } else {
                                    guard appState.startupPolicy.externalAccessEnabled else { return }
                                    let mutationResult = Self.apiKeyMutationCoordinator.saveAPIKey(
                                        trimmed,
                                        for: provider
                                    )
                                    switch apiKeyPresentation.applySaveResult(
                                        mutationResult,
                                        savedAPIKey: trimmed
                                    ) {
                                    case .failure(let message):
                                        validationError = message
                                    case .success(let state):
                                        appState.hasAnyAPIKey = state.hasAnyAPIKey
                                        apiKey = ""
                                        showKey = false
                                        validationError = nil
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                            isExpanded = false
                                            refreshToken += 1
                                        }
                                    }
                                }
                            }
                        } label: {
                            if isValidating {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("Verifying...")
                                }
                            } else {
                                Text("Save")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            !appState.startupPolicy.externalAccessEnabled
                                || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isValidating
                        )

                        Button("Cancel") {
                            apiKey = ""
                            showKey = false
                            validationError = nil
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                isExpanded = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isValidating)
                    }
                }
                .padding(.leading, 40)
                .padding(.bottom, 10)
            }
        }
    }

    private var rowHeader: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        return HStack(spacing: 12) {
            Group {
                if NSImage(named: provider.iconName) != nil {
                    Image(provider.iconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: provider.iconFallbackSymbol)
                        .font(.cadenza(16, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.cadenza(14, weight: .medium, scale: uiScale))
                    SettingsStatusCapsule(
                        kind: isConnected ? .connected : .disconnected,
                        label: isConnected ? "Connected" : "Not Connected"
                    )
                }
                Text(
                    isDefaultProvider
                        ? String(localized: "\(provider.subtitle) · Default")
                        : provider.subtitle
                )
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rowAction: some View {
        if isConnected {
            Button("Disconnect", role: .destructive) {
                disconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button("Connect") {
                guard appState.startupPolicy.externalAccessEnabled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!appState.startupPolicy.externalAccessEnabled)
        }
    }

    private var isDefaultProvider: Bool {
        UserDefaults.standard.string(forKey: "defaultAIProvider") == provider.rawValue
    }

    @ViewBuilder
    private func apiKeyPill(_ key: String) -> some View {
        HStack(spacing: 6) {
            Text(showFullKey ? key : maskedKey(key))
                .font(.cadenza(11, design: .monospaced, scale: uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: showFullKey ? 240 : nil)

            Button {
                showFullKey.toggle()
            } label: {
                Image(systemName: showFullKey ? "eye.slash" : "eye")
                    .font(.cadenza(10, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.cadenzaPlain)
            .accessibilityLabel(Text(showFullKey ? "Hide API key" : "Show API key"))
            .help(showFullKey ? "Hide API key" : "Show API key")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopied = false
                }
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.cadenza(10, scale: uiScale))
                    .foregroundStyle(showCopied ? .green : .secondary)
            }
            .buttonStyle(.cadenzaPlain)
            .help("Copy API key")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showCopied)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 22)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func disconnect() {
        mutationError = nil
        let currentDefault = UserDefaults.standard
            .string(forKey: "defaultAIProvider")
            .flatMap(AIProvider.init(rawValue:))

        let mutationResult = Self.apiKeyMutationCoordinator.disconnect(
            provider: provider,
            currentDefaultProvider: currentDefault
        )
        switch apiKeyPresentation.applyDisconnectResult(mutationResult) {
        case .failure(let message):
            mutationError = message
        case .success(let state):
            appState.hasAnyAPIKey = state.hasAnyAPIKey
            if let replacement = state.replacementDefaultProvider {
                UserDefaults.standard.set(replacement.rawValue, forKey: "defaultAIProvider")
                defaultProviderSwitch = DefaultProviderSwitch(from: provider, to: replacement)
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                refreshToken += 1
            }
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 5 else { return key }
        return "\u{2022}\u{2022}\u{2022}\u{2022}" + key.suffix(5)
    }

}
