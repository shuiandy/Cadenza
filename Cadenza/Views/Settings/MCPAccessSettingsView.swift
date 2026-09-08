import AppKit
import SwiftUI

/// "AI Access (MCP)" section body for Integrations settings.
/// Local MCP server exposing transcripts to external AI assistants.
/// Layout mirrors ConnectionsInline's connectionRow language: 34pt icon
/// tile, 14pt medium name, 12pt status subtitle (green when connected).
struct MCPAccessInline: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState

    @AppStorage(MCPServer.Constants.enabledDefaultsKey) private var serverEnabled = false
    @AppStorage(MCPServer.Constants.writesEnabledDefaultsKey) private var writesEnabled = false
    @AppStorage(MCPServer.Constants.externalImportEnabledDefaultsKey) private var externalImportEnabled = false
    @AppStorage(MCPServer.Constants.meetingContextEnabledDefaultsKey) private var meetingContextEnabled = false
    @AppStorage(MCPServer.Constants.portDefaultsKey) private var port = Int(MCPServer.Constants.defaultPort)

    @State private var token = ""
    @State private var showFullToken = false
    @State private var showRegenerateAlert = false
    @State private var copyFeedback: String?
    @State private var connectFailure: ConnectFailure?

    struct ConnectFailure {
        let client: MCPClientConnector.Client
        let message: String
        let token: String
    }

    private let connector = MCPClientConnector()
    private let accessStore = MCPClientAccessStore.shared
    private let bridgeRuntime = MCPBridgeRuntime.standard()
    @State private var clientStatuses: [MCPClientConnector.Client: MCPClientConnector.ConnectionState] = [:]
    @State private var accessRecords: [String: MCPClientAccessRecord] = [:]
    /// Clients whose access was revoked but whose Keychain item survived the delete.
    @State private var incompleteRevocations: Set<String> = []
    @State private var connectingClients: Set<MCPClientConnector.Client> = []
    @State private var connectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serverToggleRow
            if serverEnabled {
                // Concept O: everything the server switch controls rides a
                // dependency rail — address/port, the permission switches —
                // so turning the server off visibly disables the chain.
                SettingsDependentRow {
                    VStack(alignment: .leading, spacing: 0) {
                        addressRow
                        Divider().opacity(0.5)
                        writesToggleRow
                        Divider().opacity(0.5)
                        externalImportToggleRow
                        if externalImportEnabled {
                            externalImportRecipeRow
                        }
                        Divider().opacity(0.5)
                        meetingContextToggleRow
                    }
                }

                Divider()
                tokenRow
                Divider()

                clientsHeaderRow
                ForEach(Array(MCPClientConnector.Client.allCases.enumerated()), id: \.element) { index, client in
                    clientRow(client)
                    if index < MCPClientConnector.Client.allCases.count - 1 {
                        Divider().padding(.leading, 46)
                    }
                }
                // Manual configuration only surfaces when one-click connect
                // actually failed — the normal path never shows it.
                if let failure = connectFailure {
                    connectFailureView(failure)
                }
            }
        }
        .onAppear {
            refreshToken()
            refreshAccessRecords()
            refreshClientStatuses()
        }
        .alert("Reset legacy token?", isPresented: $showRegenerateAlert) {
            Button("Reset", role: .destructive) {
                appState.regenerateMCPToken()
                refreshToken()
                refreshClientStatuses()  // connected clients flip to "Update"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Resetting this token only disconnects clients configured with the shared legacy token. Per-client access remains active.")
        }
    }

    // MARK: - Server toggles

    /// Title + a SMALL switch pinned to the title line (so the two switches
    /// align regardless of subtitle height), subtitle running full width.
    private var serverToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                Text("Enable MCP server")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                serverStatusCapsule
                Spacer()
                Toggle("", isOn: $serverEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: serverEnabled) {
                        refreshToken()
                        appState.syncMCPServer()
                        refreshClientStatuses()
                    }
            }
            Text("Lets AI assistants like Claude Code and Codex search and read your transcripts. Only reachable on this Mac — never exposed to the network.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = appState.mcpServerStatus {
                Text("Failed: \(message). Is the port in use?")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var serverStatusCapsule: some View {
        switch appState.mcpServerStatus {
        case .running:
            SettingsStatusCapsule(kind: .connected, label: "Running")
        case .failed:
            SettingsStatusCapsule(kind: .attention, label: "Failed")
        case .stopped:
            SettingsStatusCapsule(kind: .disconnected, label: "Stopped")
        }
    }

    private var writesToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Allow write operations")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                Spacer()
                Toggle("", isOn: $writesEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("Lets AI rename recordings, edit tags, and manage action items. Every change is logged.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var meetingContextToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Allow meeting-context access")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                Spacer()
                Toggle("", isOn: $meetingContextEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("Lets connected AI tools see upcoming calendar meetings — titles, attendees, and related meeting history — and write prep briefs. More sensitive than transcripts; leave off unless you use an external agent for meeting prep.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var externalImportToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Allow external recording imports")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                Spacer()
                Toggle("", isOn: $externalImportEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("Lets connected AI tools preview and import meeting notes from other services. Imports never create duplicate entries, keep source history, and do not require provider API tokens.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var externalImportRecipeRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("External import recipe")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                Text("Copy a preview-first prompt for your AI agent. It lists source metadata incrementally, shows a dry run, and fetches full notes only after review. Cadenza never stores your provider tokens.")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                copy(ExternalImportRecipe.prompt, label: "externalImportRecipe")
            } label: {
                Label(
                    copyFeedback == "externalImportRecipe" ? "Copied" : "Copy recipe",
                    systemImage: "doc.on.doc"
                )
            }
            .controlSize(.small)
        }
        .padding(.bottom, 10)
    }

    // MARK: - Address & token

    private var addressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Address")
                    .font(.cadenza(13, weight: .medium, scale: uiScale))

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Text(verbatim: appState.mcpServerURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        copy(appState.mcpServerURL, label: "url")
                    } label: {
                        Image(systemName: copyFeedback == "url" ? "checkmark" : "doc.on.doc")
                            .font(.cadenza(10, scale: uiScale))
                            .foregroundStyle(copyFeedback == "url" ? .green : .secondary)
                    }
                    .buttonStyle(.cadenzaPlain)
                    .accessibilityLabel(Text("Copy"))
                    .help("Copy")
                }
                .padding(.horizontal, 9)
                .frame(minHeight: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                TextField(
                    value: $port,
                    format: .number.grouping(.never),
                    prompt: Text(verbatim: "8585")
                ) {
                    Text("Port")
                }
                    .labelsHidden()
                    .accessibilityLabel(Text("Port"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit(applyPortChange)
            }
            Text("Changing the port breaks existing client configs. Update them too.")
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var tokenRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Legacy token")
                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                Text("Only for clients not yet migrated to per-client access.")
                    .font(.cadenza(10.5, scale: uiScale))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(showFullToken ? token : maskedToken)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: showFullToken ? 200 : nil)
                Button {
                    showFullToken.toggle()
                } label: {
                    Image(systemName: showFullToken ? "eye.slash" : "eye")
                        .font(.cadenza(10, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.cadenzaPlain)
                .accessibilityLabel(Text(showFullToken ? "Hide API key" : "Show API key"))
                Button {
                    copy(token, label: "token")
                } label: {
                    Image(systemName: copyFeedback == "token" ? "checkmark" : "doc.on.doc")
                        .font(.cadenza(10, scale: uiScale))
                        .foregroundStyle(copyFeedback == "token" ? .green : .secondary)
                }
                .buttonStyle(.cadenzaPlain)
                .accessibilityLabel(Text("Copy"))
                .help("Copy")
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 22)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Button("Reset…") { showRegenerateAlert = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Clients header

    private var clientsHeaderRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Connected clients")
                .font(.cadenza(12, weight: .bold, scale: uiScale))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(connectedClientCount) of \(MCPClientConnector.Client.allCases.count) connected")
                .font(.cadenza(10.5, scale: uiScale))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var connectedClientCount: Int {
        clientStatuses.values.filter {
            if case .connected = $0 { return true }
            return false
        }.count
    }

    // MARK: - Client rows (mirrors ConnectionsInline.connectionRow)

    private func clientIcon(_ client: MCPClientConnector.Client) -> String {
        switch client {
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .geminiCLI: "terminal"
        case .claudeDesktop: "macwindow"
        case .codexCLI: "curlybraces"
        case .grokCLI: "sparkles"
        case .hermes: "cross.case"
        }
    }

    private func clientRow(_ client: MCPClientConnector.Client) -> some View {
        let state = clientStatuses[client] ?? .disconnected
        let accessRecord = accessRecords[client.accessID]
        let scopesOutOfDate = accessRecord.map { $0.scopes != scopesForNewConnection } ?? false
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        return HStack(spacing: 12) {
            Image(systemName: clientIcon(client))
                .font(.cadenza(16, scale: uiScale))
                .frame(width: iconSize, height: iconSize)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(client.rawValue)
                        .font(.cadenza(14, weight: .medium, scale: uiScale))
                    clientStateCapsule(state, scopesOutOfDate: scopesOutOfDate)
                }

                if let record = accessRecord {
                    // Concept O: raw scope IDs become readable mini chips and
                    // the last-used stamp rides the same line.
                    HStack(spacing: 5) {
                        ForEach(record.scopes.map(\.rawValue).sorted(), id: \.self) { raw in
                            Text(Self.scopeChipLabel(raw))
                                .font(.cadenza(9, weight: .semibold, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .frame(minHeight: 16)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        Text(record.lastUsedAt.map {
                            String.localizedStringWithFormat(
                                String(localized: "Last used: %@"),
                                $0.formatted(date: .abbreviated, time: .shortened)
                            )
                        } ?? String(localized: "Not used yet"))
                            .font(.cadenza(10.5, scale: uiScale))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)
                    }
                } else if case .notInstalled(let hint) = state {
                    Text(hint)
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                if incompleteRevocations.contains(client.accessID) {
                    Text("Access revoked, but its Keychain item could not be removed.")
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.orange)
                }
                if client == .grokCLI {
                    Text("Connect applies to Grok CLI on this Mac; a remote bot connects from Cadenza Web settings.")
                        .font(.cadenza(10.5, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if connectingClients.contains(client) {
                ProgressView().controlSize(.small)
            } else {
                switch state {
                case .stale:
                    Button("Update") { connect(client) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                case .disconnected:
                    Button("Connect") { connect(client) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .connected where scopesOutOfDate:
                    Button("Update") { connect(client) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                case .connected, .notInstalled:
                    if accessRecord != nil {
                        Button("Revoke", role: .destructive) { revoke(client) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func clientStateCapsule(
        _ state: MCPClientConnector.ConnectionState,
        scopesOutOfDate: Bool
    ) -> some View {
        switch state {
        case .connected where scopesOutOfDate:
            SettingsStatusCapsule(kind: .attention, label: "Scopes out of date")
        case .connected:
            SettingsStatusCapsule(kind: .connected, label: "Connected")
        case .stale:
            SettingsStatusCapsule(kind: .attention, label: "Token out of date")
        case .disconnected, .notInstalled:
            SettingsStatusCapsule(kind: .disconnected, label: "Not connected")
        }
    }

    /// Readable label for a stored permission-scope ID. Unknown scopes from a
    /// newer build fall back to their raw ID rather than disappearing.
    private static func scopeChipLabel(_ raw: String) -> String {
        switch MCPPermissionScope(rawValue: raw) {
        case .recordingRead: String(localized: "Read")
        case .recordingWrite: String(localized: "Write")
        case .exportWrite: String(localized: "Export")
        case .calendarContextRead: String(localized: "Calendar")
        case .prepWrite: String(localized: "Prep brief")
        case .externalImportWrite: String(localized: "Import")
        case nil: raw
        }
    }

    // MARK: - Connect failure fallback (the only place manual config appears)

    private func connectFailureView(_ failure: ConnectFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failure.message)
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Text("Automatic setup didn't work. You can add this configuration to \(failure.client.rawValue) manually:")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .trailing, spacing: 4) {
                Text(manualSnippet(for: failure.client, token: failure.token))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                Button {
                    copy(manualSnippet(for: failure.client, token: failure.token), label: "fallback")
                } label: {
                    Label(copyFeedback == "fallback" ? "Copied" : "Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private func manualSnippet(for client: MCPClientConnector.Client, token: String) -> String {
        let bridge = appState.mcpBridgePath
        switch client {
        case .claudeCode:
            return "claude mcp add cadenza -s user -- \(MCPClientConnector.shellQuoted(bridge)) --client \(client.accessID)"
        case .geminiCLI:
            return """
            // ~/.gemini/settings.json
            {
              "mcpServers": {
                "cadenza": {
                  "command": "\(bridge)",
                  "args": ["--client", "\(client.accessID)"]
                }
              }
            }
            """
        case .claudeDesktop:
            return """
            // claude_desktop_config.json
            {
              "mcpServers": {
                "cadenza": {
                  "command": "\(bridge)",
                  "args": ["--client", "\(client.accessID)"]
                }
              }
            }
            """
        case .codexCLI:
            return """
            # ~/.codex/config.toml
            [mcp_servers.cadenza]
            command = "\(bridge)"
            args = ["--client", "\(client.accessID)"]
            """
        case .grokCLI:
            return """
            # ~/.grok/config.toml
            [mcp_servers.cadenza]
            command = "\(bridge)"
            args = ["--client", "\(client.accessID)"]
            """
        case .hermes:
            return """
            # ~/.hermes/config.yaml
            mcp_servers:
              cadenza:
                url: \(appState.mcpServerURL)
                headers:
                  Authorization: Bearer \(token)
            """
        }
    }

    // MARK: - Actions

    private func connect(_ client: MCPClientConnector.Client) {
        connectingClients.insert(client)
        connectFailure = nil
        let url = appState.mcpServerURL
        let bridgePath = appState.mcpBridgePath
        let scopes = scopesForNewConnection
        Task {
            do {
                let clientToken = try accessStore.token(
                    for: client.accessID,
                    name: client.rawValue,
                    scopes: scopes
                )
                // The credential file must exist before any client launches
                // the bridge — including a user applying the manual snippet
                // after an automatic-setup failure.
                if client.usesBridge {
                    try bridgeRuntime.writeCredential(clientToken, for: client.accessID)
                }
                try await connector.connect(client, bridgePath: bridgePath, url: url, token: clientToken)
            } catch {
                NSLog(
                    "[MCPAccess] %@ automatic setup failed: %@",
                    client.rawValue,
                    String(describing: error)
                )
                let clientToken = accessStore.existingToken(for: client.accessID) ?? token
                connectFailure = ConnectFailure(
                    client: client,
                    message: MCPClientConnector.userVisibleMessage(for: error),
                    token: clientToken
                )
            }
            connectingClients.remove(client)
            refreshAccessRecords()
            refreshClientStatuses()
        }
    }

    private func refreshClientStatuses() {
        guard serverEnabled, !token.isEmpty else {
            clientStatuses = [:]
            return
        }
        let url = appState.mcpServerURL
        let bridgePath = appState.mcpBridgePath
        for client in MCPClientConnector.Client.allCases {
            let expected = accessStore.existingToken(for: client.accessID) ?? token
            clientStatuses[client] = connector.detect(
                client,
                bridgePath: bridgePath,
                url: url,
                token: expected,
                storedCredential: bridgeRuntime.credential(for: client.accessID)
            )
        }
    }

    // The toggles above are @AppStorage-backed, so standard defaults always
    // hold their current values — one shared helper keeps this in lockstep
    // with the auto-provisioned CLI credential.
    private var scopesForNewConnection: Set<MCPPermissionScope> {
        MCPServer.scopesForNewConnection()
    }

    private func refreshAccessRecords() {
        accessRecords = Dictionary(uniqueKeysWithValues: accessStore.records().map { ($0.id, $0) })
    }

    private func revoke(_ client: MCPClientConnector.Client) {
        // Access is gone either way; a false result only means the Keychain blob
        // outlived it. Say so rather than dropping the result on the floor.
        if accessStore.revoke(clientID: client.accessID) {
            incompleteRevocations.remove(client.accessID)
        } else {
            incompleteRevocations.insert(client.accessID)
        }
        // The bridge credential file is dead either way — the server no
        // longer accepts its token.
        try? bridgeRuntime.removeCredential(for: client.accessID)
        refreshAccessRecords()
        refreshClientStatuses()
    }

    private var maskedToken: String {
        guard token.count > 4 else { return "••••••••" }
        return "\u{2022}\u{2022}\u{2022}\u{2022}\(token.suffix(4))"
    }

    private func refreshToken() {
        token = serverEnabled ? MCPServer.loadOrCreateToken() : ""
    }

    private func applyPortChange() {
        if port < 1024 || port > 65535 {
            port = Int(MCPServer.Constants.defaultPort)
        }
        appState.syncMCPServer()
        refreshClientStatuses()  // configured clients now point at the old port → show "Update"
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyFeedback = label
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyFeedback == label { copyFeedback = nil }
        }
    }
}
