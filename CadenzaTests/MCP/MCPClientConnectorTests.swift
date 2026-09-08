import Foundation
import Testing
@testable import Cadenza

@Suite("MCPClientConnector")
struct MCPClientConnectorTests {

    private let url = "http://127.0.0.1:8585/mcp"
    private let token = "tok123"
    private let bridge = "/Applications/Cadenza.app/Contents/MacOS/cadenza-mcp"

    private func makeTempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connector-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func connector(home: URL, apps: URL? = nil) -> MCPClientConnector {
        MCPClientConnector(home: home, applicationsDirectory: apps ?? home.appendingPathComponent("Applications"))
    }

    /// Detection shorthand: bridge clients count as connected only when the
    /// stored credential matches, so the default mirrors a healthy Connect.
    private func detect(
        _ connector: MCPClientConnector,
        _ client: MCPClientConnector.Client,
        token expectedToken: String? = nil,
        stored: String?? = nil,
        bridgePath: String? = nil
    ) -> MCPClientConnector.ConnectionState {
        let expected = expectedToken ?? token
        return connector.detect(
            client,
            bridgePath: bridgePath ?? bridge,
            url: url,
            token: expected,
            storedCredential: stored ?? expected
        )
    }

    @Test func clientsHaveStableDistinctAccessIDsForPerClientTokens() {
        let ids = MCPClientConnector.Client.allCases.map(\.accessID)
        #expect(Set(ids).count == MCPClientConnector.Client.allCases.count)
        #expect(ids.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }

    @Test func bridgeArgumentsCarryTheAccessID() {
        for client in MCPClientConnector.Client.allCases {
            #expect(MCPClientConnector.bridgeArguments(for: client) == ["--client", client.accessID])
        }
        #expect(MCPClientConnector.Client.hermes.usesBridge == false)
        #expect(MCPClientConnector.Client.allCases.filter(\.usesBridge).count == 5)
    }

    // MARK: - Pure merge

    @Test func upsertIntoEmptyConfigCreatesStructure() throws {
        let data = try MCPClientConnector.upsertServerEntry(in: nil, configPath: "/x", entry: ["command": "c"])
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entry = (root?["mcpServers"] as? [String: Any])?["cadenza"] as? [String: Any]
        #expect(entry?["command"] as? String == "c")
    }

    @Test func upsertPreservesUnrelatedKeys() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "theme": "dark",
            "mcpServers": [
                "other": ["command": "foo"],
                "cadenza": ["httpUrl": "OLD"],
            ],
        ])
        let data = try MCPClientConnector.upsertServerEntry(in: existing, configPath: "/x", entry: ["command": "NEW"])
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(root?["theme"] as? String == "dark")
        let servers = root?["mcpServers"] as? [String: Any]
        #expect((servers?["other"] as? [String: Any])?["command"] as? String == "foo")
        let cadenza = servers?["cadenza"] as? [String: Any]
        #expect(cadenza?["command"] as? String == "NEW")
        // The entry is replaced wholesale — the legacy HTTP key is gone.
        #expect(cadenza?["httpUrl"] == nil)
    }

    @Test func upsertRefusesNonObjectConfig() {
        let bogus = Data("[1,2,3]".utf8)
        #expect(throws: MCPClientConnector.ConnectorError.self) {
            _ = try MCPClientConnector.upsertServerEntry(in: bogus, configPath: "/x", entry: [:])
        }
    }

    // MARK: - TOML string arrays

    @Test func tomlStringArrayParsesSupportedShapes() {
        #expect(MCPClientConnector.tomlStringArray(#"["--client", "codex-cli"]"#) == ["--client", "codex-cli"])
        #expect(MCPClientConnector.tomlStringArray(#"["a","b"]"#) == ["a", "b"])
        #expect(MCPClientConnector.tomlStringArray(#"[ 'lit', "esc\"q" ]"#) == ["lit", "esc\"q"])
        #expect(MCPClientConnector.tomlStringArray(#"["one",]"#) == ["one"])  // trailing comma is legal TOML
        #expect(MCPClientConnector.tomlStringArray(#"["x"] # comment"#) == ["x"])
        #expect(MCPClientConnector.tomlStringArray("[]") == [])
    }

    @Test func tomlStringArrayRejectsMalformedShapes() {
        let malformed = [
            #"["unterminated]"#,
            #"[bare, "x"]"#,
            #"["a" "b"]"#,
            #"[, "a"]"#,
            #"["a",, "b"]"#,
            #"["a"] trailing"#,
            #"not-an-array"#,
            #"[1, 2]"#,
        ]
        for raw in malformed {
            #expect(MCPClientConnector.tomlStringArray(raw) == nil, "should reject: \(raw)")
        }
    }

    // MARK: - Gemini CLI

    @Test func geminiLifecycle() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        // Not installed: no ~/.gemini (hint text is localized — match the case only)
        if case .notInstalled = detect(connector, .geminiCLI) {} else {
            Issue.record("expected notInstalled without ~/.gemini")
        }

        // Installed but unconfigured
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"),
                                                withIntermediateDirectories: true)
        #expect(detect(connector, .geminiCLI) == .disconnected)

        // Connect → connected
        try await connector.connect(.geminiCLI, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .geminiCLI) == .connected)

        // Credential drift (reset/revoke/profile switch) → stale; the config
        // itself carries no token, so only the stored credential can drift.
        #expect(detect(connector, .geminiCLI, stored: .some("rotated")) == .stale)
        #expect(detect(connector, .geminiCLI, stored: .some(nil)) == .stale)

        // Moved app bundle → stale, reconnect heals
        #expect(detect(connector, .geminiCLI, bridgePath: "/elsewhere/cadenza-mcp") == .stale)
        try await connector.connect(.geminiCLI, bridgePath: "/elsewhere/cadenza-mcp", url: url, token: token)
        #expect(detect(connector, .geminiCLI, bridgePath: "/elsewhere/cadenza-mcp") == .connected)
    }

    @Test func geminiConnectPreservesExistingSettingsAndMigratesLegacyEntry() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        let settingsDir = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let settings = settingsDir.appendingPathComponent("settings.json")
        try Data(#"{"selectedAuthType":"oauth","mcpServers":{"github":{"command":"gh-mcp"},"cadenza":{"httpUrl":"OLD","headers":{"Authorization":"Bearer OLD"}}}}"#.utf8)
            .write(to: settings)

        // The legacy HTTP entry reads as stale, and Connect migrates it.
        #expect(detect(connector, .geminiCLI) == .stale)
        try await connector.connect(.geminiCLI, bridgePath: bridge, url: url, token: token)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        #expect(root?["selectedAuthType"] as? String == "oauth")
        let servers = root?["mcpServers"] as? [String: Any]
        #expect(servers?["github"] != nil)
        let entry = servers?["cadenza"] as? [String: Any]
        #expect(entry?["command"] as? String == bridge)
        #expect(entry?["args"] as? [String] == ["--client", "gemini-cli"])
        #expect(entry?["httpUrl"] == nil)
        #expect(entry?["headers"] == nil)
    }

    // MARK: - Claude Desktop

    @Test func claudeDesktopLifecycle() async throws {
        let home = try makeTempHome()
        let apps = home.appendingPathComponent("Applications")
        let connector = connector(home: home, apps: apps)

        // No Claude.app → not installed
        if case .notInstalled = detect(connector, .claudeDesktop) {} else {
            Issue.record("expected notInstalled")
        }

        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude.app"),
                                                withIntermediateDirectories: true)
        #expect(detect(connector, .claudeDesktop) == .disconnected)

        // Connect creates intermediate dirs + the bridge entry — no npx, no
        // mcp-remote, no token anywhere in the file.
        try await connector.connect(.claudeDesktop, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .claudeDesktop) == .connected)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: connector.claudeDesktopConfigURL)) as? [String: Any]
        let entry = (root?["mcpServers"] as? [String: Any])?["cadenza"] as? [String: Any]
        #expect(entry?["command"] as? String == bridge)
        #expect(entry?["args"] as? [String] == ["--client", "claude-desktop"])
        let raw = try String(contentsOf: connector.claudeDesktopConfigURL, encoding: .utf8)
        #expect(!raw.contains(token))
        #expect(!raw.contains("mcp-remote"))
    }

    @Test func claudeDesktopLegacyMcpRemoteEntryMigrates() async throws {
        let home = try makeTempHome()
        let apps = home.appendingPathComponent("Applications")
        let connector = connector(home: home, apps: apps)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude.app"),
                                                withIntermediateDirectories: true)
        let configDir = home.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let legacy = """
        {"mcpServers":{"cadenza":{"command":"npx","args":["-y","mcp-remote","\(url)","--header","Authorization:${AUTH_HEADER}"],"env":{"AUTH_HEADER":"Bearer \(token)"}}}}
        """
        try Data(legacy.utf8).write(to: connector.claudeDesktopConfigURL)

        #expect(detect(connector, .claudeDesktop) == .stale)
        try await connector.connect(.claudeDesktop, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .claudeDesktop) == .connected)
        let raw = try String(contentsOf: connector.claudeDesktopConfigURL, encoding: .utf8)
        #expect(!raw.contains("mcp-remote"))
        #expect(!raw.contains("AUTH_HEADER"))
    }

    // MARK: - Codex CLI (TOML text-level upsert)

    @Test func codexUpsertIntoEmptyConfig() throws {
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: nil, bridgePath: bridge, clientID: "codex-cli")
        #expect(out.contains("[mcp_servers.cadenza]"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(out.contains("args = [\"--client\", \"codex-cli\"]"))
    }

    @Test func codexUpsertPreservesOtherSectionsAndMigratesLegacyEntry() throws {
        let existing = """
        model = "gpt-5.4"

        [mcp_servers.docker]
        command = "docker"
        args = ["mcp"]

        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"
        http_headers = { Authorization = "Bearer OLD" }

        [projects."/tmp/cadenza-test-fixtures/repo"]
        trust_level = "trusted"
        """
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing, bridgePath: bridge, clientID: "codex-cli")
        #expect(out.contains("model = \"gpt-5.4\""))
        #expect(out.contains("[mcp_servers.docker]"))
        #expect(out.contains("[projects.\"/tmp/cadenza-test-fixtures/repo\"]"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(!out.contains("Bearer OLD"))
        #expect(!out.contains("9999"))
        #expect(!out.contains("http_headers"))
        // exactly one cadenza section, docker untouched
        #expect(out.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
        #expect(out.contains("command = \"docker\""))
    }

    @Test func codexLifecycle() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        if case .notInstalled = detect(connector, .codexCLI) {} else {
            Issue.record("expected notInstalled without ~/.codex")
        }

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        #expect(detect(connector, .codexCLI) == .disconnected)

        try await connector.connect(.codexCLI, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .codexCLI) == .connected)

        // Credential drift → stale; reconnect (same entry) stays single-section.
        #expect(detect(connector, .codexCLI, stored: .some("rotated")) == .stale)
        try await connector.connect(.codexCLI, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .codexCLI) == .connected)
        let text = try String(contentsOf: connector.codexConfigURL, encoding: .utf8)
        #expect(text.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
        #expect(!text.contains(token))  // no secret in the config
    }

    @Test func codexLegacyNestedHeadersTableIsRemovedOnUpsert() throws {
        let existing = """
        model = "gpt-5.4"

        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"

        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer OLD"
        X-Cadenza-Trace = "was-ours"

        [projects."/x"]
        trust_level = "trusted"
        """
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing, bridgePath: bridge, clientID: "codex-cli")
        #expect(!out.contains("http_headers"))
        #expect(!out.contains("Bearer OLD"))
        #expect(!out.contains("X-Cadenza-Trace"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(out.contains("model = \"gpt-5.4\""))
        #expect(out.contains("[projects.\"/x\"]"))
    }

    @Test func codexSubTableSurvivesUpsert() throws {
        let existing = """
        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"

        [mcp_servers.cadenza.env]
        SOME_VAR = "user-added"
        """
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing, bridgePath: bridge, clientID: "codex-cli")
        #expect(out.contains("[mcp_servers.cadenza.env]"))
        #expect(out.contains("SOME_VAR"))
        #expect(out.contains("command = \"\(bridge)\""))
    }

    @Test func codexUpsertPreservesUnmanagedParentFieldsAndComments() throws {
        let existing = """
        [mcp_servers.cadenza] # user settings below
        enabled = false
        startup_timeout_sec = 15
        url = "http://127.0.0.1:9999/mcp"
        http_headers = { Authorization = "Bearer OLD" }
        # keep this note

        [projects."/x"]
        trust_level = "trusted"
        """

        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing, bridgePath: bridge, clientID: "codex-cli")

        #expect(out.contains("[mcp_servers.cadenza] # user settings below"))
        #expect(out.contains("enabled = false"))
        #expect(out.contains("startup_timeout_sec = 15"))
        #expect(out.contains("# keep this note"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(!out.contains("Bearer OLD"))
    }

    @Test func codexEquivalentQuotedOrSpacedFormsAreRefused() {
        let ambiguous = [
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:9999/mcp"

            [mcp_servers."cadenza".http_headers]
            Authorization = "Bearer OLD"
            """,
            """
            [mcp_servers . cadenza]
            url = "http://127.0.0.1:9999/mcp"
            http_headers = { Authorization = "Bearer OLD" }
            """,
            """
            mcp_servers . "cadenza" = { url = "http://127.0.0.1:9999/mcp" }
            """,
            """
            [[mcp_servers.cadenza]]
            url = "http://127.0.0.1:9999/mcp"
            """,
        ]

        for config in ambiguous {
            #expect(throws: MCPClientConnector.ConnectorError.self) {
                _ = try MCPClientConnector.upsertCodexBridgeEntry(
                    in: config, bridgePath: bridge, clientID: "codex-cli")
            }
        }
    }

    /// Inline and nested headers together are a duplicate key to TOML
    /// parsers; the stdio upsert removes both and passes validation.
    @Test func codexDualHeaderCorruptionSelfHealsOnUpsert() throws {
        let existing = """
        [mcp_servers.cadenza]
        url = "http://127.0.0.1:8585/mcp"
        http_headers = { Authorization = "Bearer STALE" }
        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer OLDER"

        [mcp_servers.other]
        command = "x"
        """
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing, bridgePath: bridge, clientID: "codex-cli")
        #expect(!out.contains("http_headers"))
        #expect(!out.contains("STALE"))
        #expect(!out.contains("OLDER"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(out.contains("[mcp_servers.other]"))
        try MCPClientConnector.validateCodexBridgeMergeResult(out, configPath: "test")
    }

    @Test func codexMergeValidatorRejectsBrokenShapes() {
        let broken = [
            // legacy url survives
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            url = "http://127.0.0.1:8585/mcp"
            """,
            // legacy headers survive
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            http_headers = { Authorization = "Bearer A" }
            """,
            // nested legacy table survives
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            [mcp_servers.cadenza.http_headers]
            Authorization = "Bearer B"
            """,
            // duplicate command
            """
            [mcp_servers.cadenza]
            command = "/x"
            command = "/y"
            args = ["--client", "codex-cli"]
            """,
            // missing args
            """
            [mcp_servers.cadenza]
            command = "/x"
            """,
            // unparseable args
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = [broken]
            """,
        ]
        for text in broken {
            #expect(throws: MCPClientConnector.ConnectorError.self) {
                try MCPClientConnector.validateCodexBridgeMergeResult(text, configPath: "test")
            }
        }
    }

    /// Cosmetic serializer rewrites (spacing, quote style) must not read as
    /// stale.
    @Test func codexManagedValuesTolerateCosmeticRewrites() {
        let variants = [
            """
            [mcp_servers.cadenza]
            command = "/opt/cadenza-mcp"
            args = ["--client", "codex-cli"]
            """,
            """
            [mcp_servers.cadenza]
            command="/opt/cadenza-mcp"
            args=["--client","codex-cli"]
            """,
            """
            [mcp_servers.cadenza]
            command = '/opt/cadenza-mcp'
            args = [ '--client', 'codex-cli' ]
            """,
        ]
        for section in variants {
            let values = MCPClientConnector.codexBridgeManagedValues(inSection: section)
            #expect(values.command == "/opt/cadenza-mcp", "command mismatch in: \(section)")
            #expect(values.args == ["--client", "codex-cli"], "args mismatch in: \(section)")
        }
    }

    /// Duplicate TOML keys are illegal, not last-wins — and any legacy HTTP
    /// key invalidates the read so the repair entry point stays visible.
    @Test func codexManagedValuesRejectDuplicatesAndLegacyKeys() {
        let invalidSections = [
            // duplicate command
            """
            [mcp_servers.cadenza]
            command = "/x"
            command = "/x"
            args = ["--client", "codex-cli"]
            """,
            // duplicate args
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            args = ["--client", "codex-cli"]
            """,
            // legacy url
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            url = "http://127.0.0.1:8585/mcp"
            """,
            // legacy inline headers
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            http_headers = { Authorization = "Bearer t" }
            """,
            // legacy nested headers table (combined section)
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = ["--client", "codex-cli"]
            [mcp_servers.cadenza.http_headers]
            Authorization = "Bearer t"
            """,
            // unparseable args
            """
            [mcp_servers.cadenza]
            command = "/x"
            args = [oops]
            """,
        ]
        for section in invalidSections {
            let values = MCPClientConnector.codexBridgeManagedValues(inSection: section)
            #expect(values.command == nil && values.args == nil, "should reject: \(section)")
        }
    }

    @Test func codexLegacyHTTPEntryReadsStaleAndConnectMigrates() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.cadenza]
        url = "\(url)"

        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer \(token)"
        """.utf8).write(to: connector.codexConfigURL)

        #expect(detect(connector, .codexCLI) == .stale)
        try await connector.connect(.codexCLI, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .codexCLI) == .connected)
        let text = try String(contentsOf: connector.codexConfigURL, encoding: .utf8)
        #expect(!text.contains("http_headers"))
        #expect(!text.contains(token))
    }

    @Test func codexDuplicateParentTablesAreRefusedWithoutChangingFile() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        let original = Data("""
        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"
        http_headers = { Authorization = "Bearer OLD-1" }

        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9998/mcp"
        http_headers = { Authorization = "Bearer OLD-2" }
        """.utf8)
        try original.write(to: connector.codexConfigURL)

        await #expect(throws: MCPClientConnector.ConnectorError.self) {
            try await connector.connect(.codexCLI, bridgePath: bridge, url: url, token: token)
        }
        #expect(try Data(contentsOf: connector.codexConfigURL) == original)
    }

    @Test func codexQuotedEquivalentTableIsRefusedWithoutChangingFile() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        let original = Data("""
        [mcp_servers."cadenza"]
        url = "http://127.0.0.1:9999/mcp"
        http_headers = { Authorization = "Bearer OLD" }
        """.utf8)
        try original.write(to: connector.codexConfigURL)

        await #expect(throws: MCPClientConnector.ConnectorError.self) {
            try await connector.connect(.codexCLI, bridgePath: bridge, url: url, token: token)
        }
        #expect(try Data(contentsOf: connector.codexConfigURL) == original)
    }

    // MARK: - Grok CLI (legacy field `headers`, not Codex `http_headers`)

    @Test func grokUpsertIntoEmptyConfigWritesBridgeEntry() throws {
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: nil,
            bridgePath: bridge,
            clientID: "grok-cli",
            legacyHeadersField: .headers
        )
        #expect(out.contains("[mcp_servers.cadenza]"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(out.contains("args = [\"--client\", \"grok-cli\"]"))
    }

    @Test func grokUpsertPreservesOtherSectionsAndMigratesLegacyEntry() throws {
        let existing = """
        model = "grok-4"

        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"

        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"
        headers = { Authorization = "Bearer OLD" }
        """
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing,
            bridgePath: bridge,
            clientID: "grok-cli",
            legacyHeadersField: .headers
        )
        #expect(out.contains("model = \"grok-4\""))
        // Another server's url is unmanaged — it must survive untouched.
        #expect(out.contains("[mcp_servers.linear]"))
        #expect(out.contains("https://mcp.linear.app/mcp"))
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(!out.contains("Bearer OLD"))
        #expect(!out.contains("9999"))
        #expect(out.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
    }

    @Test func grokLifecycle() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        if case .notInstalled = detect(connector, .grokCLI) {} else {
            Issue.record("expected notInstalled without ~/.grok")
        }

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"),
                                                withIntermediateDirectories: true)
        #expect(detect(connector, .grokCLI) == .disconnected)

        try await connector.connect(.grokCLI, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .grokCLI) == .connected)

        let text = try String(contentsOf: connector.grokConfigURL, encoding: .utf8)
        #expect(text.contains("args = [\"--client\", \"grok-cli\"]"))
        #expect(!text.contains(token))

        #expect(detect(connector, .grokCLI, stored: .some("rotated")) == .stale)
        try await connector.connect(.grokCLI, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .grokCLI) == .connected)
        let rewritten = try String(contentsOf: connector.grokConfigURL, encoding: .utf8)
        #expect(rewritten.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
    }

    // MARK: - Review regressions: never clobber unreadable/unexpected configs

    @Test func unreadableJSONConfigIsNotOverwritten() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        // A DIRECTORY at the settings path: fileExists == true, but reading
        // as Data throws — must be treated as unreadable, not absent.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gemini/settings.json"), withIntermediateDirectories: true)

        await #expect(throws: MCPClientConnector.ConnectorError.self) {
            try await connector.connect(.geminiCLI, bridgePath: bridge, url: url, token: token)
        }
        // Still a directory — nothing was written over it.
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: connector.geminiSettingsURL.path, isDirectory: &isDir)
        #expect(isDir.boolValue)
    }

    @Test func invalidUTF8TOMLIsNotOverwritten() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        let garbage = Data([0xFF, 0xFE, 0x00, 0x80])
        try garbage.write(to: connector.codexConfigURL)

        await #expect(throws: MCPClientConnector.ConnectorError.self) {
            try await connector.connect(.codexCLI, bridgePath: bridge, url: url, token: token)
        }
        #expect(try Data(contentsOf: connector.codexConfigURL) == garbage)  // untouched
    }

    @Test func nonObjectMcpServersIsRefused() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        let dir = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data(#"{"mcpServers": ["not", "an", "object"]}"#.utf8)
        try original.write(to: connector.geminiSettingsURL)

        await #expect(throws: MCPClientConnector.ConnectorError.self) {
            try await connector.connect(.geminiCLI, bridgePath: bridge, url: url, token: token)
        }
        #expect(try Data(contentsOf: connector.geminiSettingsURL) == original)  // untouched
    }

    @Test func codexHeaderWithLeadingWhitespaceAndCommentIsReplaced() throws {
        let existing = """
        [mcp_servers.docker]
        command = "docker"

          [mcp_servers.cadenza]   # managed by Cadenza
          url = "http://127.0.0.1:9999/mcp"
          http_headers = { Authorization = "Bearer OLD" }

        [projects."/x"]
        trust_level = "trusted"
        """
        let out = try MCPClientConnector.upsertCodexBridgeEntry(
            in: existing, bridgePath: bridge, clientID: "codex-cli")
        // Replaced in place — NOT appended as a duplicate table (which would
        // make the whole TOML invalid).
        #expect(out.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
        #expect(out.contains("command = \"\(bridge)\""))
        #expect(!out.contains("Bearer OLD"))
        #expect(out.contains("[mcp_servers.docker]"))
        #expect(out.contains("[projects.\"/x\"]"))
    }

    @Test func truncatedCLIOutputTrimsAndCaps() {
        let output = "  error: something failed\n" + String(repeating: "x", count: 500)
        let truncated = MCPClientConnector.truncatedCLIOutput(output)
        #expect(truncated.hasPrefix("error: something failed"))
        #expect(truncated.count <= 300)
    }

    @Test func shellQuotedEscapesSingleQuotes() {
        #expect(MCPClientConnector.shellQuoted("/plain/path") == "'/plain/path'")
        #expect(MCPClientConnector.shellQuoted("/it's here") == "'/it'\\''s here'")
    }

    // MARK: - Hermes (YAML block replacement — stays on direct HTTP)

    private func hermesUpsert(_ text: String?) throws -> String {
        try MCPClientConnector.upsertHermesServerEntry(in: text, url: url, token: token, configPath: "/x")
    }

    @Test func hermesInjectsHeadersIntoExistingEntry() throws {
        // The real 401 case: cadenza exists with url but no headers.
        let existing = """
        gateway:
          idle_minutes: 1440
          mode: both
        mcp_servers:
          cadenza:
            url: \(url)
            timeout: 300
            connect_timeout: 60

        # ── Fallback Model ──
        fallback: []
        """
        let out = try hermesUpsert(existing)
        // headers injected, token present
        #expect(out.contains("Authorization: Bearer \(token)"))
        // siblings preserved
        #expect(out.contains("timeout: 300"))
        #expect(out.contains("connect_timeout: 60"))
        // surrounding config untouched
        #expect(out.contains("idle_minutes: 1440"))
        #expect(out.contains("# ── Fallback Model ──"))
        #expect(out.contains("fallback: []"))
        // exactly one cadenza key, one headers, one url
        #expect(out.components(separatedBy: "cadenza:").count == 2)
        #expect(out.components(separatedBy: "headers:").count == 2)
        #expect(out.components(separatedBy: "url:").count == 2)
        // re-parsing sees the token
        #expect(MCPClientConnector.hermesCadenzaBlock(in: out)?.contains("Bearer \(token)") == true)
    }

    @Test func hermesReplacesStaleToken() throws {
        let existing = """
        mcp_servers:
          cadenza:
            url: \(url)
            headers:
              Authorization: Bearer OLDTOKEN
            timeout: 300
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("Bearer \(token)"))
        #expect(!out.contains("OLDTOKEN"))
        #expect(out.contains("timeout: 300"))
        #expect(out.components(separatedBy: "headers:").count == 2)  // no dup
        #expect(out.components(separatedBy: "Authorization:").count == 2)
    }

    @Test func hermesCreatesEntryUnderExistingMcpServers() throws {
        let existing = """
        mcp_servers:
          github:
            command: npx
            args: ["-y", "server-github"]
        other_top: value
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("github:"))          // sibling kept
        #expect(out.contains("other_top: value")) // top-level kept
        #expect(out.contains("cadenza:"))
        #expect(out.contains("Authorization: Bearer \(token)"))
        // cadenza nested at server indent (2), not at top level
        #expect(out.contains("  cadenza:"))
    }

    @Test func hermesCreatesMcpServersWhenAbsent() throws {
        let existing = """
        gateway:
          mode: both
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("gateway:"))
        #expect(out.contains("mcp_servers:"))
        #expect(out.contains("  cadenza:"))
        #expect(out.contains("Authorization: Bearer \(token)"))
    }

    @Test func hermesFromNilCreatesMinimal() throws {
        let out = try hermesUpsert(nil)
        #expect(out.hasPrefix("mcp_servers:\n"))
        #expect(out.contains("    url: \(url)"))
        #expect(out.contains("      Authorization: Bearer \(token)"))
    }

    @Test func hermesRefusesTabIndentation() {
        let existing = "mcp_servers:\n\tcadenza:\n\t\turl: \(url)\n"
        #expect(throws: MCPClientConnector.ConnectorError.self) {
            _ = try hermesUpsert(existing)
        }
    }

    @Test func hermesUpdatesURLOnPortChange() throws {
        // cadenza pointed at an old port; upsert must rewrite url too.
        let existing = """
        mcp_servers:
          cadenza:
            url: http://127.0.0.1:9999/mcp
            headers:
              Authorization: Bearer \(token)
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("url: \(url)"))
        #expect(!out.contains("9999"))
    }

    @Test func hermesRefusesInlineMcpServers() {
        for bad in ["mcp_servers: {}", "mcp_servers: []", "mcp_servers: {cadenza: {url: x}}"] {
            #expect(throws: MCPClientConnector.ConnectorError.self, "should refuse: \(bad)") {
                _ = try hermesUpsert("gateway:\n  mode: both\n\(bad)\n")
            }
        }
    }

    @Test func hermesRefusesInlineCadenza() {
        let existing = """
        mcp_servers:
          cadenza: {url: \(url), timeout: 300}
        """
        #expect(throws: MCPClientConnector.ConnectorError.self) {
            _ = try hermesUpsert(existing)
        }
    }

    @Test func hermesFindsCadenzaPastCommentBetweenSiblings() throws {
        // A comment at column 0 must NOT be read as ending the mapping —
        // otherwise cadenza is "not found" and a duplicate gets appended.
        let existing = """
        mcp_servers:
          github:
            url: g
        # a stray top-level-looking comment
          cadenza:
            url: \(url)
        """
        let out = try hermesUpsert(existing)
        #expect(out.components(separatedBy: "cadenza:").count == 2)  // exactly one, not duplicated
        #expect(out.contains("Authorization: Bearer \(token)"))
        #expect(out.contains("github:"))
        #expect(out.contains("# a stray top-level-looking comment"))
    }

    @Test func hermesRemovesStaleAuthAcrossBlankLine() throws {
        // Blank line between `headers:` and Authorization — the subtree skip
        // must still drop the old Authorization, or last-wins YAML keeps 401.
        let existing = """
        mcp_servers:
          cadenza:
            url: \(url)
            headers:

              Authorization: Bearer OLDTOKEN
            timeout: 300
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("Bearer \(token)"))
        #expect(!out.contains("OLDTOKEN"))
        #expect(out.components(separatedBy: "Authorization:").count == 2)  // exactly one
        #expect(out.contains("timeout: 300"))
    }

    @Test func hermesReplacesFoldedURL() throws {
        // Old url is a folded scalar with a continuation line — we discard the
        // whole old value and write a clean inline url, with no orphan line.
        let existing = """
        mcp_servers:
          cadenza:
            url: >
              http://old-host/mcp
            timeout: 300
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("url: \(url)"))
        #expect(!out.contains("old-host"))
        #expect(!out.contains(">"))
        #expect(out.contains("timeout: 300"))
        #expect(out.contains("Authorization: Bearer \(token)"))
        #expect(out.components(separatedBy: "url:").count == 2)
    }

    @Test func hermesReplacesPlainMultilineURL() throws {
        // `url:` empty value + indented continuation (plain multiline scalar).
        let existing = """
        mcp_servers:
          cadenza:
            url:
              http://old-host/mcp
            timeout: 300
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("url: \(url)"))
        #expect(!out.contains("old-host"))
        #expect(out.contains("timeout: 300"))
        #expect(out.components(separatedBy: "url:").count == 2)
    }

    @Test func hermesIgnoresNestedCadenzaUnderAnotherServer() throws {
        // A `cadenza:` nested INSIDE another server is not ours — must not be
        // edited; a real top-level mcp_servers.cadenza gets created instead.
        let existing = """
        mcp_servers:
          github:
            cadenza:
              url: nested-should-stay
            url: g
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("nested-should-stay"))   // github's nested key untouched
        #expect(out.contains("url: g"))                // github's own url untouched
        #expect(out.contains("Authorization: Bearer \(token)"))
        // a real cadenza now exists at server indent (2 spaces)
        #expect(out.contains("\n  cadenza:"))
    }

    @Test func hermesPreservesSeparatorCommentAfterCadenza() throws {
        // The trailing blank + next-section comment must survive untouched.
        let existing = """
        mcp_servers:
          cadenza:
            url: \(url)
            timeout: 300

        # ── Next Section ──
        other: value
        """
        let out = try hermesUpsert(existing)
        #expect(out.contains("# ── Next Section ──"))
        #expect(out.contains("other: value"))
        #expect(out.contains("Authorization: Bearer \(token)"))
        #expect(out.contains("timeout: 300"))
    }

    @Test func hermesLifecycleDetection() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        if case .notInstalled = detect(connector, .hermes) {} else {
            Issue.record("expected notInstalled without ~/.hermes")
        }

        let dir = home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // installed but no config file yet
        #expect(detect(connector, .hermes) == .disconnected)

        try await connector.connect(.hermes, bridgePath: bridge, url: url, token: token)
        #expect(detect(connector, .hermes) == .connected)

        // Hermes carries the token in its config, so rotation reads stale
        // from the file itself — the stored credential is irrelevant.
        #expect(detect(connector, .hermes, token: "rotated", stored: .some("rotated")) == .stale)
        try await connector.connect(.hermes, bridgePath: bridge, url: url, token: "rotated")
        #expect(detect(connector, .hermes, token: "rotated") == .connected)
    }

    // MARK: - Claude Code (file-based detection only; connect goes via CLI)

    @Test func claudeCodeDetection() throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        if case .notInstalled = detect(connector, .claudeCode) {} else {
            Issue.record("expected notInstalled without ~/.claude.json")
        }

        try Data("{}".utf8).write(to: connector.claudeCodeConfigURL)
        #expect(detect(connector, .claudeCode) == .disconnected)

        // The stdio entry the CLI writes for `claude mcp add … -- cmd args`.
        let configured = """
        {"mcpServers":{"cadenza":{"type":"stdio","command":"\(bridge)","args":["--client","claude-code"],"env":{}}}}
        """
        try Data(configured.utf8).write(to: connector.claudeCodeConfigURL)
        #expect(detect(connector, .claudeCode) == .connected)
        #expect(detect(connector, .claudeCode, stored: .some("other")) == .stale)
        #expect(detect(connector, .claudeCode, bridgePath: "/moved/cadenza-mcp") == .stale)

        // The pre-bridge HTTP entry reads as stale → "Update" migrates it.
        let legacy = """
        {"mcpServers":{"cadenza":{"type":"http","url":"\(url)","headers":{"Authorization":"Bearer \(token)"}}}}
        """
        try Data(legacy.utf8).write(to: connector.claudeCodeConfigURL)
        #expect(detect(connector, .claudeCode) == .stale)
    }
}
