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
                Divider()
                writesToggleRow
                Divider()
                externalImportToggleRow
                if externalImportEnabled {
                    externalImportRecipeRow
                }
                Divider()
                meetingContextToggleRow
                Divider()
                portRow
                tokenRow
                Divider()
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
            HStack(alignment: .center) {
                Text("Enable MCP server")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
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

            statusRow
                .padding(.top, 2)
        }
        .padding(.vertical, 10)
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

    private var statusRow: some View {
        HStack(spacing: 6) {
            switch appState.mcpServerStatus {
            case .running(let activePort):
                let runningURL = "http://127.0.0.1:\(activePort)/mcp"
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Running at \(runningURL)")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failed(let message):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Failed: \(message) — is the port in use?")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.red)
            case .stopped:
                Circle().fill(.gray).frame(width: 8, height: 8)
                Text("Stopped")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Port & token

    private var portRow: some View {
        HStack(spacing: 10) {
            Text("Port")
                .font(.cadenza(14, weight: .medium, scale: uiScale))
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
                .frame(width: 80)
                .onSubmit(applyPortChange)
            Text("Changing the port breaks existing client configs — update them too.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var tokenRow: some View {
        HStack(spacing: 10) {
            Text("Legacy token")
                .font(.cadenza(14, weight: .medium, scale: uiScale))
            Text(maskedToken)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                copy(token, label: "token")
            } label: {
                Label(copyFeedback == "token" ? "Copied" : "Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            Button("Reset…") { showRegenerateAlert = true }
                .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Client rows (mirrors ConnectionsInline.connectionRow)

    private func clientIcon(_ client: MCPClientConnector.Client) -> String {
        switch client {
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .geminiCLI: "terminal"
        case .claudeDesktop: "macwindow"
        case .codexCLI: "curlybraces"
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

            VStack(alignment: .leading, spacing: 1) {
                Text(client.rawValue)
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                switch state {
                case .connected:
                    Text(
                        scopesOutOfDate
                            ? String(localized: "Scopes out of date")
                            : String(localized: "Connected")
                    )
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(scopesOutOfDate ? .orange : .green)
                case .stale:
                    Text("Token out of date")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.orange)
                case .disconnected:
                    Text("Not connected")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                case .notInstalled(let hint):
                    Text(hint)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                if let record = accessRecord {
                    Text(String.localizedStringWithFormat(
                        String(localized: "Scopes: %@"),
                        record.scopes.map(\.rawValue).sorted().joined(separator: ", ")
                    ))
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(record.lastUsedAt.map {
                        String.localizedStringWithFormat(
                            String(localized: "Last used: %@"),
                            $0.formatted(date: .abbreviated, time: .shortened)
                        )
                    } ?? String(localized: "Not used yet"))
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                if incompleteRevocations.contains(client.accessID) {
                    Text("Access revoked, but its Keychain item could not be removed.")
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if connectingClients.contains(client) {
                ProgressView().controlSize(.small)
            } else {
                switch state {
                case .stale:
                    Button("Update") { connect(client) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .disconnected:
                    Button("Connect") { connect(client) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .connected where scopesOutOfDate:
                    Button("Update") { connect(client) }
                        .buttonStyle(.bordered)
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
        .padding(.vertical, 10)
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
        switch client {
        case .claudeCode:
            "claude mcp add --transport http cadenza \(appState.mcpServerURL) --header \"Authorization: Bearer \(token)\""
        case .geminiCLI:
            """
            // ~/.gemini/settings.json
            {
              "mcpServers": {
                "cadenza": {
                  "httpUrl": "\(appState.mcpServerURL)",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
              }
            }
            """
        case .claudeDesktop:
            """
            // claude_desktop_config.json (requires Node)
            {
              "mcpServers": {
                "cadenza": {
                  "command": "npx",
                  "args": ["-y", "mcp-remote", "\(appState.mcpServerURL)",
                           "--header", "Authorization:${AUTH_HEADER}"],
                  "env": { "AUTH_HEADER": "Bearer \(token)" }
                }
              }
            }
            """
        case .codexCLI:
            """
            # ~/.codex/config.toml
            [mcp_servers.cadenza]
            url = "\(appState.mcpServerURL)"
            http_headers = { Authorization = "Bearer \(token)" }
            """
        case .hermes:
            """
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
        let scopes = scopesForNewConnection
        Task {
            do {
                let clientToken = try accessStore.token(
                    for: client.accessID,
                    name: client.rawValue,
                    scopes: scopes
                )
                try await connector.connect(client, url: url, token: clientToken)
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
        for client in MCPClientConnector.Client.allCases {
            let expected = accessStore.existingToken(for: client.accessID) ?? token
            clientStatuses[client] = connector.detect(client, url: url, token: expected)
        }
    }

    private var scopesForNewConnection: Set<MCPPermissionScope> {
        var scopes: Set<MCPPermissionScope> = [.recordingRead]
        if writesEnabled {
            scopes.insert(.recordingWrite)
            scopes.insert(.exportWrite)
        }
        if meetingContextEnabled {
            scopes.insert(.calendarContextRead)
            if writesEnabled { scopes.insert(.prepWrite) }
        }
        if externalImportEnabled { scopes.insert(.externalImportWrite) }
        return scopes
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
        refreshAccessRecords()
        refreshClientStatuses()
    }

    private var maskedToken: String {
        guard token.count > 8 else { return "••••••••" }
        return "\(token.prefix(4))…\(token.suffix(4))"
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
