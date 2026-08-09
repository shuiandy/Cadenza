import Foundation
import Testing
@testable import Cadenza

@Suite("MCPClientConnector")
struct MCPClientConnectorTests {

    private let url = "http://127.0.0.1:8585/mcp"
    private let token = "tok123"

    private func makeTempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connector-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func connector(home: URL, apps: URL? = nil) -> MCPClientConnector {
        MCPClientConnector(home: home, applicationsDirectory: apps ?? home.appendingPathComponent("Applications"))
    }

    @Test func clientsHaveStableDistinctAccessIDsForPerClientTokens() {
        let ids = MCPClientConnector.Client.allCases.map(\.accessID)
        #expect(Set(ids).count == MCPClientConnector.Client.allCases.count)
        #expect(ids.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }

    // MARK: - Pure merge

    @Test func upsertIntoEmptyConfigCreatesStructure() throws {
        let data = try MCPClientConnector.upsertServerEntry(in: nil, configPath: "/x", entry: ["httpUrl": "u"])
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entry = (root?["mcpServers"] as? [String: Any])?["cadenza"] as? [String: Any]
        #expect(entry?["httpUrl"] as? String == "u")
    }

    @Test func upsertPreservesUnrelatedKeys() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "theme": "dark",
            "mcpServers": [
                "other": ["command": "foo"],
                "cadenza": ["httpUrl": "OLD"],
            ],
        ])
        let data = try MCPClientConnector.upsertServerEntry(in: existing, configPath: "/x", entry: ["httpUrl": "NEW"])
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(root?["theme"] as? String == "dark")
        let servers = root?["mcpServers"] as? [String: Any]
        #expect((servers?["other"] as? [String: Any])?["command"] as? String == "foo")
        #expect((servers?["cadenza"] as? [String: Any])?["httpUrl"] as? String == "NEW")
    }

    @Test func upsertRefusesNonObjectConfig() {
        let bogus = Data("[1,2,3]".utf8)
        #expect(throws: MCPClientConnector.ConnectorError.self) {
            _ = try MCPClientConnector.upsertServerEntry(in: bogus, configPath: "/x", entry: [:])
        }
    }

    // MARK: - Gemini CLI

    @Test func geminiLifecycle() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        // Not installed: no ~/.gemini (hint text is localized — match the case only)
        if case .notInstalled = connector.detect(.geminiCLI, url: url, token: token) {} else {
            Issue.record("expected notInstalled without ~/.gemini")
        }

        // Installed but unconfigured
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"),
                                                withIntermediateDirectories: true)
        #expect(connector.detect(.geminiCLI, url: url, token: token) == .disconnected)

        // Connect → connected
        try await connector.connect(.geminiCLI, url: url, token: token)
        #expect(connector.detect(.geminiCLI, url: url, token: token) == .connected)

        // Token rotation → stale, reconnect heals
        #expect(connector.detect(.geminiCLI, url: url, token: "rotated") == .stale)
        try await connector.connect(.geminiCLI, url: url, token: "rotated")
        #expect(connector.detect(.geminiCLI, url: url, token: "rotated") == .connected)
    }

    @Test func geminiConnectPreservesExistingSettings() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        let settingsDir = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let settings = settingsDir.appendingPathComponent("settings.json")
        try Data(#"{"selectedAuthType":"oauth","mcpServers":{"github":{"command":"gh-mcp"}}}"#.utf8)
            .write(to: settings)

        try await connector.connect(.geminiCLI, url: url, token: token)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        #expect(root?["selectedAuthType"] as? String == "oauth")
        let servers = root?["mcpServers"] as? [String: Any]
        #expect(servers?["github"] != nil)
        #expect(servers?["cadenza"] != nil)
    }

    // MARK: - Claude Desktop

    @Test func claudeDesktopLifecycle() async throws {
        let home = try makeTempHome()
        let apps = home.appendingPathComponent("Applications")
        let connector = connector(home: home, apps: apps)

        // No Claude.app → not installed
        if case .notInstalled = connector.detect(.claudeDesktop, url: url, token: token) {} else {
            Issue.record("expected notInstalled")
        }

        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude.app"),
                                                withIntermediateDirectories: true)
        #expect(connector.detect(.claudeDesktop, url: url, token: token) == .disconnected)

        // Connect creates intermediate dirs + correct mcp-remote entry
        try await connector.connect(.claudeDesktop, url: url, token: token)
        #expect(connector.detect(.claudeDesktop, url: url, token: token) == .connected)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: connector.claudeDesktopConfigURL)) as? [String: Any]
        let entry = (root?["mcpServers"] as? [String: Any])?["cadenza"] as? [String: Any]
        #expect(entry?["command"] as? String == "npx")
        let args = entry?["args"] as? [String] ?? []
        #expect(args.contains(url))
        #expect(args.contains("Authorization:${AUTH_HEADER}"))  // env-var form: Desktop splits args on spaces
        #expect((entry?["env"] as? [String: Any])?["AUTH_HEADER"] as? String == "Bearer \(token)")
    }

    // MARK: - Codex CLI (TOML text-level upsert)

    @Test func codexUpsertIntoEmptyConfig() throws {
        let out = try MCPClientConnector.upsertCodexServerEntry(in: nil, url: url, token: token)
        #expect(out.contains("[mcp_servers.cadenza]"))
        #expect(out.contains("url = \"\(url)\""))
        #expect(out.contains("http_headers = { Authorization = \"Bearer \(token)\" }"))
    }

    @Test func codexUpsertPreservesOtherSectionsAndReplacesOurs() throws {
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
        let out = try MCPClientConnector.upsertCodexServerEntry(in: existing, url: url, token: token)
        #expect(out.contains("model = \"gpt-5.4\""))
        #expect(out.contains("[mcp_servers.docker]"))
        #expect(out.contains("[projects.\"/tmp/cadenza-test-fixtures/repo\"]"))
        #expect(out.contains("Bearer \(token)"))
        #expect(!out.contains("Bearer OLD"))
        #expect(!out.contains("9999"))
        // exactly one cadenza section
        #expect(out.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
    }

    @Test func codexLifecycle() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        if case .notInstalled = connector.detect(.codexCLI, url: url, token: token) {} else {
            Issue.record("expected notInstalled without ~/.codex")
        }

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        #expect(connector.detect(.codexCLI, url: url, token: token) == .disconnected)

        try await connector.connect(.codexCLI, url: url, token: token)
        #expect(connector.detect(.codexCLI, url: url, token: token) == .connected)

        // Token rotation → stale, reconnect heals and stays single-section
        #expect(connector.detect(.codexCLI, url: url, token: "rotated") == .stale)
        try await connector.connect(.codexCLI, url: url, token: "rotated")
        #expect(connector.detect(.codexCLI, url: url, token: "rotated") == .connected)
        let text = try String(contentsOf: connector.codexConfigURL, encoding: .utf8)
        #expect(text.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
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
            try await connector.connect(.geminiCLI, url: url, token: token)
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
            try await connector.connect(.codexCLI, url: url, token: token)
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
            try await connector.connect(.geminiCLI, url: url, token: token)
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
        let out = try MCPClientConnector.upsertCodexServerEntry(in: existing, url: url, token: token)
        // Replaced in place — NOT appended as a duplicate table (which would
        // make the whole TOML invalid).
        #expect(out.components(separatedBy: "[mcp_servers.cadenza]").count == 2)
        #expect(out.contains("Bearer \(token)"))
        #expect(!out.contains("Bearer OLD"))
        #expect(out.contains("[mcp_servers.docker]"))
        #expect(out.contains("[projects.\"/x\"]"))
    }

    @Test func codexSubTableSurvivesUpsert() throws {
        let existing = """
        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"

        [mcp_servers.cadenza.env]
        SOME_VAR = "user-added"
        """
        let out = try MCPClientConnector.upsertCodexServerEntry(in: existing, url: url, token: token)
        #expect(out.contains("[mcp_servers.cadenza.env]"))
        #expect(out.contains("SOME_VAR"))
        #expect(out.contains("Bearer \(token)"))
    }

    @Test func codexNestedHTTPHeadersStayValidAndPreserveOtherHeaders() throws {
        let existing = """
        model = "gpt-5.4"

        [mcp_servers.cadenza]
        url = "http://127.0.0.1:9999/mcp"

        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer OLD"
        X-Cadenza-Trace = "keep-me"

        [projects."/x"]
        trust_level = "trusted"
        """

        let out = try MCPClientConnector.upsertCodexServerEntry(in: existing, url: url, token: token)

        #expect(!out.contains("http_headers = {"))
        #expect(out.components(separatedBy: "[mcp_servers.cadenza.http_headers]").count == 2)
        #expect(out.components(separatedBy: "Authorization =").count == 2)
        #expect(out.contains("Authorization = \"Bearer \(token)\""))
        #expect(!out.contains("Bearer OLD"))
        #expect(out.contains("X-Cadenza-Trace = \"keep-me\""))
        #expect(out.contains("model = \"gpt-5.4\""))
        #expect(out.contains("[projects.\"/x\"]"))
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

        let out = try MCPClientConnector.upsertCodexServerEntry(in: existing, url: url, token: token)

        #expect(out.contains("[mcp_servers.cadenza] # user settings below"))
        #expect(out.contains("enabled = false"))
        #expect(out.contains("startup_timeout_sec = 15"))
        #expect(out.contains("# keep this note"))
        #expect(out.contains("Bearer \(token)"))
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
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:9999/mcp"
            http_headers.Authorization = "Bearer OLD"
            """,
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:9999/mcp"
            http_headers = { Authorization = "Bearer OLD", X-Trace = "keep-me" }
            """,
        ]

        for config in ambiguous {
            #expect(throws: MCPClientConnector.ConnectorError.self) {
                _ = try MCPClientConnector.upsertCodexServerEntry(in: config, url: url, token: token)
            }
        }
    }

    /// Inline and nested headers together are a duplicate key to TOML
    /// parsers; upsert must self-heal to a single form and pass validation.
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
        let out = try MCPClientConnector.upsertCodexServerEntry(in: existing, url: url, token: token)
        // Healed to the nested form only: no inline header, one Authorization.
        #expect(!out.contains("http_headers = {"))
        #expect(out.components(separatedBy: "Authorization").count == 2)
        #expect(out.contains("Bearer \(token)"))
        #expect(!out.contains("STALE"))
        #expect(!out.contains("OLDER"))
        #expect(out.contains("[mcp_servers.other]"))
        try MCPClientConnector.validateCodexMergeResult(out, configPath: "test")
    }

    @Test func codexMergeValidatorRejectsDualHeaderShape() {
        let corrupted = """
        [mcp_servers.cadenza]
        url = "http://127.0.0.1:8585/mcp"
        http_headers = { Authorization = "Bearer A" }
        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer B"
        """
        #expect(throws: MCPClientConnector.ConnectorError.self) {
            try MCPClientConnector.validateCodexMergeResult(corrupted, configPath: "test")
        }
    }

    /// Cosmetic serializer rewrites (spacing, quotes, inline vs nested)
    /// must not read as stale.
    @Test func codexManagedValuesTolerateCosmeticRewrites() {
        let variants = [
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            http_headers = { Authorization = "Bearer tok-1" }
            """,
            """
            [mcp_servers.cadenza]
            url="http://127.0.0.1:8585/mcp"
            http_headers={Authorization="Bearer tok-1"}
            """,
            """
            [mcp_servers.cadenza]
            url = 'http://127.0.0.1:8585/mcp'
            [mcp_servers.cadenza.http_headers]
            Authorization = 'Bearer tok-1'
            """,
        ]
        for section in variants {
            let values = MCPClientConnector.codexManagedValues(inSection: section)
            #expect(values.url == "http://127.0.0.1:8585/mcp", "url mismatch in: \(section)")
            #expect(values.token == "tok-1", "token mismatch in: \(section)")
        }
    }

    /// Duplicate TOML keys are illegal, not last-wins: reporting such
    /// configs connected would hide the repair entry point.
    @Test func codexManagedValuesRejectDuplicateOrMisplacedKeys() {
        let invalidSections = [
            // duplicate url
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            url = "http://127.0.0.1:8585/mcp"
            http_headers = { Authorization = "Bearer tok-1" }
            """,
            // duplicate Authorization in the nested table
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            [mcp_servers.cadenza.http_headers]
            Authorization = "Bearer tok-1"
            Authorization = "Bearer tok-1"
            """,
            // Authorization directly in the parent (misplaced)
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            Authorization = "Bearer tok-1"
            """,
            // url misplaced into the nested headers table
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            [mcp_servers.cadenza.http_headers]
            Authorization = "Bearer tok-1"
            url = "http://127.0.0.1:8585/mcp"
            """,
            // inline header without a Bearer value
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            http_headers = { Authorization = "tok-1" }
            """,
        ]
        for section in invalidSections {
            let values = MCPClientConnector.codexManagedValues(inSection: section)
            #expect(values.url == nil && values.token == nil, "should reject: \(section)")
        }
    }

    @Test func codexMergeValidatorRejectsInlineHeaderWithoutBearer() {
        let broken = [
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            http_headers = { X-Custom = "y" }
            """,
            """
            [mcp_servers.cadenza]
            url = "http://127.0.0.1:8585/mcp"
            http_headers = { Authorization = "no-bearer-prefix" }
            """,
        ]
        for text in broken {
            #expect(throws: MCPClientConnector.ConnectorError.self) {
                try MCPClientConnector.validateCodexMergeResult(text, configPath: "test")
            }
        }
    }

    @Test func codexNestedHTTPHeadersLifecycle() async throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.cadenza]
        url = "\(url)"

        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer OLD"
        """.utf8).write(to: connector.codexConfigURL)

        #expect(connector.detect(.codexCLI, url: url, token: token) == .stale)
        try await connector.connect(.codexCLI, url: url, token: token)
        #expect(connector.detect(.codexCLI, url: url, token: token) == .connected)
    }

    @Test func codexDetectionRejectsDuplicateHeaderDefinitions() throws {
        let home = try makeTempHome()
        let connector = connector(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.cadenza]
        url = "\(url)"
        http_headers = { Authorization = "Bearer \(token)" }

        [mcp_servers.cadenza.http_headers]
        Authorization = "Bearer \(token)"
        """.utf8).write(to: connector.codexConfigURL)

        #expect(connector.detect(.codexCLI, url: url, token: token) == .disconnected)
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
            try await connector.connect(.codexCLI, url: url, token: token)
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
            try await connector.connect(.codexCLI, url: url, token: token)
        }
        #expect(try Data(contentsOf: connector.codexConfigURL) == original)
    }

    @Test func redactingTokenScrubsAndTruncates() {
        let secret = "33a2deadbeef"
        let output = "error: header 'Authorization: Bearer \(secret)' rejected\n" + String(repeating: "x", count: 500)
        let redacted = MCPClientConnector.redactingToken(output, token: secret)
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("●●●"))
        #expect(redacted.count <= 300)
    }

    // MARK: - Hermes (YAML block replacement)

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
        // re-parsing detects it as connected
        let connector = MCPClientConnector()
        #expect(MCPClientConnector.hermesCadenzaBlock(in: out)?.contains("Bearer \(token)") == true)
        _ = connector
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

        if case .notInstalled = connector.detect(.hermes, url: url, token: token) {} else {
            Issue.record("expected notInstalled without ~/.hermes")
        }

        let dir = home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // installed but no config file yet
        #expect(connector.detect(.hermes, url: url, token: token) == .disconnected)

        try await connector.connect(.hermes, url: url, token: token)
        #expect(connector.detect(.hermes, url: url, token: token) == .connected)

        #expect(connector.detect(.hermes, url: url, token: "rotated") == .stale)
        try await connector.connect(.hermes, url: url, token: "rotated")
        #expect(connector.detect(.hermes, url: url, token: "rotated") == .connected)
    }

    // MARK: - Claude Code (file-based detection only; connect goes via CLI)

    @Test func claudeCodeDetection() throws {
        let home = try makeTempHome()
        let connector = connector(home: home)

        if case .notInstalled = connector.detect(.claudeCode, url: url, token: token) {} else {
            Issue.record("expected notInstalled without ~/.claude.json")
        }

        try Data("{}".utf8).write(to: connector.claudeCodeConfigURL)
        #expect(connector.detect(.claudeCode, url: url, token: token) == .disconnected)

        let configured = """
        {"mcpServers":{"cadenza":{"type":"http","url":"\(url)","headers":{"Authorization":"Bearer \(token)"}}}}
        """
        try Data(configured.utf8).write(to: connector.claudeCodeConfigURL)
        #expect(connector.detect(.claudeCode, url: url, token: token) == .connected)
        #expect(connector.detect(.claudeCode, url: url, token: "other") == .stale)
    }
}
