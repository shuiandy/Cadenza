import Foundation
import Synchronization

/// Detects external MCP clients and writes their configuration in one click.
///
/// Every client except Hermes is configured with the SAME stdio entry — run
/// the bundled `cadenza-mcp` bridge with `--client <id>` — so a client config
/// never carries a URL, a port, or a token. Endpoint and credential live in
/// the app's own runtime files (`MCPBridgeRuntime`), which is why a token
/// reset or port change no longer invalidates anything written here.
///
/// Detection is purely filesystem-based (no shell calls — fast and testable):
/// a client counts as installed when its config root exists. Connecting:
/// - Claude Code goes through the official `claude mcp add` CLI (its
///   ~/.claude.json is a live state file other processes write to; the CLI
///   is the supported mutation path).
/// - Gemini CLI / Claude Desktop get a semantic JSON merge: parse, upsert
///   `mcpServers.cadenza`, rewrite. Every other key/value is preserved
///   (formatting and key order are JSONSerialization's).
/// - Codex / Grok are TOML: no Swift stdlib parser, so we do a text-level
///   replacement of ONLY our own `cadenza` table, refusing (throwing) on any
///   structure we don't recognize so we never corrupt the user's hand-tuned
///   config. Upserting also removes the legacy managed `url`/header keys
///   from the pre-bridge HTTP layout. On refusal the UI shows a copyable
///   snippet.
/// - Hermes stays on direct HTTP (YAML `url` + `headers.Authorization`
///   block replacement) — its gateway has no verified stdio transport.
struct MCPClientConnector: Sendable {
    enum Client: String, CaseIterable, Identifiable, Sendable {
        case claudeCode = "Claude Code"
        case geminiCLI = "Gemini CLI"
        case claudeDesktop = "Claude Desktop"
        case codexCLI = "Codex (GPT)"
        case grokCLI = "Grok"
        case hermes = "Hermes"
        var id: String { rawValue }
        var accessID: String {
            switch self {
            case .claudeCode: "claude-code"
            case .geminiCLI: "gemini-cli"
            case .claudeDesktop: "claude-desktop"
            case .codexCLI: "codex-cli"
            case .grokCLI: "grok-cli"
            case .hermes: "hermes"
            }
        }
        /// Hermes connects straight to the loopback HTTP endpoint; everyone
        /// else runs the stdio bridge.
        var usesBridge: Bool { self != .hermes }
    }

    enum ConnectionState: Equatable, Sendable {
        case notInstalled(hint: String)
        case disconnected
        case connected
        /// Configured, but not in the exact shape Connect would write today
        /// (legacy HTTP entry, moved app bundle, or a credential file that
        /// no longer matches the access store).
        case stale
    }

    enum ConnectorError: Error, LocalizedError {
        case cliNotFound
        case cliFailed(String)
        case configNotAnObject(String)
        case configUnreadable(String)
        case configUnrecognized(String)
        case configurationFailed(String)

        var errorDescription: String? { localizedMessage() }

        func localizedMessage(locale: Locale? = nil) -> String {
            switch self {
            case .cliNotFound:
                LocalizedBundle.string(
                    "The claude CLI was not found on PATH. Install Claude Code first.",
                    locale: locale
                )
            case .cliFailed, .configNotAnObject, .configUnreadable,
                 .configUnrecognized, .configurationFailed:
                LocalizedBundle.string(
                    "Automatic setup couldn't update this client's configuration safely. Copy the manual configuration below instead.",
                    locale: locale
                )
            }
        }
    }

    static let serverName = "cadenza"

    /// The one argv every bridge-based client entry carries.
    static func bridgeArguments(for client: Client) -> [String] {
        ["--client", client.accessID]
    }

    /// Injectable roots so tests run against a temp directory.
    let home: URL
    let applicationsDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.home = home
        self.applicationsDirectory = applicationsDirectory
    }

    // MARK: - Config locations

    var claudeCodeConfigURL: URL { home.appendingPathComponent(".claude.json") }
    var geminiSettingsURL: URL { home.appendingPathComponent(".gemini/settings.json") }
    var claudeDesktopConfigURL: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
    var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    var grokConfigURL: URL { home.appendingPathComponent(".grok/config.toml") }
    var hermesConfigURL: URL { home.appendingPathComponent(".hermes/config.yaml") }

    // MARK: - Detection

    /// `storedCredential` is the current content of our own credential file
    /// for this client (`MCPBridgeRuntime.credential(for:)`): a bridge entry
    /// only counts as connected when that file still carries the expected
    /// token — the config itself has no secret to compare.
    func detect(
        _ client: Client,
        bridgePath: String,
        url: String,
        token: String,
        storedCredential: String?
    ) -> ConnectionState {
        switch client {
        case .claudeCode:
            // Every Claude Code install materializes ~/.claude.json on first run.
            guard let root = readJSONObject(at: claudeCodeConfigURL) else {
                return .notInstalled(hint: String(localized: "Install Claude Code, run it once, then connect"))
            }
            guard let entry = (root["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .disconnected
            }
            return bridgeEntryState(entry, client: client, bridgePath: bridgePath,
                                    token: token, storedCredential: storedCredential)

        case .geminiCLI:
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path) else {
                return .notInstalled(hint: String(localized: "Install Gemini CLI first (creates ~/.gemini)"))
            }
            guard let root = readJSONObject(at: geminiSettingsURL),
                  let entry = (root["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .disconnected
            }
            return bridgeEntryState(entry, client: client, bridgePath: bridgePath,
                                    token: token, storedCredential: storedCredential)

        case .claudeDesktop:
            guard FileManager.default.fileExists(atPath: applicationsDirectory.appendingPathComponent("Claude.app").path) else {
                return .notInstalled(hint: String(localized: "Install the Claude Desktop app first"))
            }
            guard let root = readJSONObject(at: claudeDesktopConfigURL),
                  let entry = (root["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .disconnected
            }
            return bridgeEntryState(entry, client: client, bridgePath: bridgePath,
                                    token: token, storedCredential: storedCredential)

        case .codexCLI:
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else {
                return .notInstalled(hint: String(localized: "Install Codex CLI or the Codex app first"))
            }
            return tomlBridgeState(configURL: codexConfigURL, client: client,
                                   legacyHeadersField: .httpHeaders, bridgePath: bridgePath,
                                   token: token, storedCredential: storedCredential)

        case .grokCLI:
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path) else {
                return .notInstalled(hint: String(localized: "Install Grok CLI first (creates ~/.grok)"))
            }
            return tomlBridgeState(configURL: grokConfigURL, client: client,
                                   legacyHeadersField: .headers, bridgePath: bridgePath,
                                   token: token, storedCredential: storedCredential)

        case .hermes:
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes").path) else {
                return .notInstalled(hint: String(localized: "Install Hermes first (creates ~/.hermes)"))
            }
            guard let text = try? String(contentsOf: hermesConfigURL, encoding: .utf8),
                  let block = Self.hermesCadenzaBlock(in: text) else {
                return .disconnected
            }
            // url: may be bare or quoted; the bearer line carries the token.
            let matches = (block.contains("url: \(url)") || block.contains("url: \"\(url)\""))
                && block.contains("Bearer \(token)")
            return matches ? .connected : .stale
        }
    }

    private func bridgeEntryState(
        _ entry: [String: Any],
        client: Client,
        bridgePath: String,
        token: String,
        storedCredential: String?
    ) -> ConnectionState {
        let entryMatches = (entry["command"] as? String) == bridgePath
            && (entry["args"] as? [String]) == Self.bridgeArguments(for: client)
        return (entryMatches && storedCredential == token) ? .connected : .stale
    }

    private func tomlBridgeState(
        configURL: URL,
        client: Client,
        legacyHeadersField: TOMLHeaderField,
        bridgePath: String,
        token: String,
        storedCredential: String?
    ) -> ConnectionState {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let section = Self.codexCadenzaSection(in: text, headersField: legacyHeadersField) else {
            return .disconnected
        }
        let values = Self.codexBridgeManagedValues(inSection: section, legacyHeadersField: legacyHeadersField)
        let entryMatches = values.command == bridgePath
            && values.args == Self.bridgeArguments(for: client)
        return (entryMatches && storedCredential == token) ? .connected : .stale
    }

    // MARK: - Connect (idempotent upsert; safe to re-run to refresh the entry)

    func connect(_ client: Client, bridgePath: String, url: String, token: String) async throws {
        do {
            try await connectImplementation(client, bridgePath: bridgePath, url: url, token: token)
        } catch is CancellationError {
            throw CancellationError()
        } catch let connectorError as ConnectorError {
            NSLog(
                "[MCPClientConnector] %@ automatic setup failed: %@",
                client.rawValue,
                String(reflecting: connectorError)
            )
            throw connectorError
        } catch {
            NSLog(
                "[MCPClientConnector] %@ automatic setup failed: %@",
                client.rawValue,
                String(describing: error)
            )
            throw ConnectorError.configurationFailed(String(describing: error))
        }
    }

    private func connectImplementation(_ client: Client, bridgePath: String, url: String, token: String) async throws {
        switch client {
        case .claudeCode:
            try await connectClaudeCode(bridgePath: bridgePath)
        case .geminiCLI:
            try upsertConfigFile(at: geminiSettingsURL, entry: Self.bridgeJSONEntry(bridgePath: bridgePath, client: client))
        case .claudeDesktop:
            try upsertConfigFile(at: claudeDesktopConfigURL, entry: Self.bridgeJSONEntry(bridgePath: bridgePath, client: client))
        case .codexCLI:
            try upsertTOMLBridgeEntry(at: codexConfigURL, client: client,
                                      bridgePath: bridgePath, legacyHeadersField: .httpHeaders)
        case .grokCLI:
            try upsertTOMLBridgeEntry(at: grokConfigURL, client: client,
                                      bridgePath: bridgePath, legacyHeadersField: .headers)
        case .hermes:
            // YAML config.yaml — Hermes reads headers.Authorization (its CLI
            // path only prompts interactively + stashes the token in .env).
            // We text-replace our own `cadenza:` block, preserving every
            // other key and the file's comments.
            let existing = try existingFileContents(at: hermesConfigURL).map { data -> String in
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ConnectorError.configUnreadable(hermesConfigURL.path)
                }
                return text
            }
            let merged = try Self.upsertHermesServerEntry(in: existing, url: url, token: token,
                                                          configPath: hermesConfigURL.path)
            try FileManager.default.createDirectory(at: hermesConfigURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(merged.utf8).write(to: hermesConfigURL, options: .atomic)
        }
    }

    static func bridgeJSONEntry(bridgePath: String, client: Client) -> [String: Any] {
        ["command": bridgePath, "args": bridgeArguments(for: client)]
    }

    private func upsertTOMLBridgeEntry(
        at configURL: URL,
        client: Client,
        bridgePath: String,
        legacyHeadersField: TOMLHeaderField
    ) throws {
        let existing = try existingFileContents(at: configURL).map { data -> String in
            guard let text = String(data: data, encoding: .utf8) else {
                throw ConnectorError.configUnreadable(configURL.path)
            }
            return text
        }
        let merged = try Self.upsertCodexBridgeEntry(
            in: existing,
            bridgePath: bridgePath,
            clientID: client.accessID,
            configPath: configURL.path,
            legacyHeadersField: legacyHeadersField
        )
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(merged.utf8).write(to: configURL, options: .atomic)
    }

    static func userVisibleMessage(for error: Error, locale: Locale? = nil) -> String {
        if let connectorError = error as? ConnectorError {
            return connectorError.localizedMessage(locale: locale)
        }
        return ConnectorError.configurationFailed(String(describing: error))
            .localizedMessage(locale: locale)
    }

    /// nil ⇒ the file genuinely does not exist (safe to create fresh).
    /// A file that EXISTS but cannot be read throws instead — treating an
    /// IO/permission failure as "absent" would rewrite the user's config
    /// from scratch.
    private func existingFileContents(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ConnectorError.configUnreadable(url.path)
        }
    }

    private func connectClaudeCode(bridgePath: String) async throws {
        // Login shell so Homebrew/nvm PATHs resolve from a GUI app context.
        let probe = try await Self.runShell("command -v claude")
        guard probe.status == 0, !probe.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorError.cliNotFound
        }
        // Add first — atomic for the common (not-yet-configured) case. Only
        // when the CLI refuses a DUPLICATE do we remove and re-add; any other
        // failure must not delete a working existing entry.
        let arguments = Self.bridgeArguments(for: .claudeCode).joined(separator: " ")
        let addCommand = "claude mcp add \(Self.serverName) -s user -- \(Self.shellQuoted(bridgePath)) \(arguments)"
        let firstTry = try await Self.runShell(addCommand)
        if firstTry.status == 0 { return }
        guard firstTry.output.localizedCaseInsensitiveContains("already exist") else {
            throw ConnectorError.cliFailed(Self.truncatedCLIOutput(firstTry.output))
        }

        _ = try? await Self.runShell("claude mcp remove \(Self.serverName) -s user")
        let retry = try await Self.runShell(addCommand)
        guard retry.status == 0 else {
            throw ConnectorError.cliFailed(Self.truncatedCLIOutput(retry.output))
        }
    }

    /// Keep CLI failure text short enough for the UI. Bridge entries carry no
    /// secrets, so truncation is the only scrubbing needed.
    static func truncatedCLIOutput(_ output: String) -> String {
        String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - JSON plumbing

    private func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func upsertConfigFile(at url: URL, entry: [String: Any]) throws {
        let existing = try existingFileContents(at: url)
        let merged = try Self.upsertServerEntry(in: existing, configPath: url.path, entry: entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try merged.write(to: url, options: .atomic)
    }

    // MARK: TOML (Codex / Grok)

    /// Legacy managed header fields from the pre-bridge HTTP layout. Codex
    /// used `http_headers`; Grok's documented field was `headers`. The stdio
    /// upsert removes them (inline key or nested table) so a migrated entry
    /// never carries both transports.
    enum TOMLHeaderField: String, Sendable {
        case httpHeaders = "http_headers"
        case headers = "headers"
    }

    private static let codexParentTable = "mcp_servers.\(serverName)"
    private static func tomlHeadersTable(_ field: TOMLHeaderField) -> String {
        "\(codexParentTable).\(field.rawValue)"
    }

    private static func tomlTableHeaderName(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["),
              let close = trimmed.firstIndex(of: "]") else { return nil }
        let after = trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return nil }
        let nameStart = trimmed.index(after: trimmed.startIndex)
        return String(trimmed[nameStart..<close]).trimmingCharacters(in: .whitespaces)
    }

    private static func tomlTableRanges(in text: String, named name: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var matchingStart: String.Index?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let lineBreak = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = lineBreak.map { text.index(after: $0) } ?? text.endIndex
            if let tableName = tomlTableHeaderName(in: text[lineStart..<lineEnd]) {
                if let matchingStart {
                    ranges.append(matchingStart..<lineStart)
                }
                matchingStart = tableName == name ? lineStart : nil
            }
            lineStart = lineEnd
        }
        if let matchingStart {
            ranges.append(matchingStart..<text.endIndex)
        }
        return ranges
    }

    private static func codexHasAmbiguousEquivalent(in text: String) -> Bool {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineBreak = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = lineBreak.map { text.index(after: $0) } ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[[") {
                let arrayName = normalizedTOMLKey(trimmed)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if arrayName == codexParentTable || arrayName.hasPrefix(codexParentTable + ".") {
                    return true
                }
            }
            if let tableName = tomlTableHeaderName(in: line) {
                let normalized = normalizedTOMLKey(tableName)
                if (normalized == codexParentTable || normalized.hasPrefix(codexParentTable + ".")),
                   tableName != normalized {
                    return true
                }
            } else {
                if let key = tomlAssignmentKey(in: trimmed) {
                    let normalized = normalizedTOMLKey(key)
                    if normalized == codexParentTable || normalized.hasPrefix(codexParentTable + ".") {
                        return true
                    }
                }
            }
            lineStart = lineEnd
        }
        return false
    }

    private static func tomlBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func tomlAssignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func normalizedTOMLKey(_ key: String) -> String {
        String(key.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" })
    }

    /// Parses a TOML scalar string value (basic "…" / literal '…'; bare
    /// values are cut before any trailing comment).
    private static func tomlScalarString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            var result = ""
            var escaped = false
            for char in value.dropFirst() {
                if escaped {
                    switch char {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    default: result.append(char)
                    }
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    return result
                } else {
                    result.append(char)
                }
            }
            return nil // unterminated string
        }
        if value.hasPrefix("'") {
            guard let close = value.dropFirst().firstIndex(of: "'") else { return nil }
            return String(value[value.index(after: value.startIndex)..<close])
        }
        let bare = value.split(separator: "#", maxSplits: 1)[0]
        return bare.trimmingCharacters(in: .whitespaces)
    }

    /// Parses a TOML inline array of strings (`["--client", "codex-cli"]`).
    /// nil for anything else: non-string elements, unterminated strings, or
    /// trailing garbage after the closing bracket (a comment is fine).
    static func tomlStringArray(_ raw: String) -> [String]? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), let close = value.lastIndex(of: "]") else { return nil }
        let trailing = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        let inside = value[value.index(after: value.startIndex)..<close]

        var result: [String] = []
        var expectElement = true
        var i = inside.startIndex
        while i < inside.endIndex {
            let char = inside[i]
            if char == " " || char == "\t" || char == "\n" || char == "\r" {
                i = inside.index(after: i)
                continue
            }
            if char == "," {
                guard !expectElement else { return nil }  // leading or doubled comma
                expectElement = true
                i = inside.index(after: i)
                continue
            }
            guard expectElement else { return nil }  // elements without a comma
            if char == "\"" {
                var text = ""
                var escaped = false
                var closed = false
                var j = inside.index(after: i)
                while j < inside.endIndex {
                    let c = inside[j]
                    j = inside.index(after: j)
                    if escaped {
                        switch c {
                        case "n": text.append("\n")
                        case "r": text.append("\r")
                        case "t": text.append("\t")
                        default: text.append(c)
                        }
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        closed = true
                        break
                    } else {
                        text.append(c)
                    }
                }
                guard closed else { return nil }
                result.append(text)
                i = j
            } else if char == "'" {
                let start = inside.index(after: i)
                guard let closeQuote = inside[start...].firstIndex(of: "'") else { return nil }
                result.append(String(inside[start..<closeQuote]))
                i = inside.index(after: closeQuote)
            } else {
                return nil  // non-string element
            }
            expectElement = false
        }
        return result
    }

    private static func tomlStringArrayLiteral(_ values: [String]) -> String {
        "[" + values.map { "\"\(tomlBasicString($0))\"" }.joined(separator: ", ") + "]"
    }

    /// Structural read of the managed bridge entry from the combined cadenza
    /// section, parsed strictly by table context. Any legacy HTTP key
    /// (`url`, the headers field, or its nested table), duplicate keys, or
    /// unparseable values invalidate the read (returns nils → stale):
    /// duplicate TOML keys are illegal rather than last-wins, and a
    /// last-wins read could report a config as connected that a standard
    /// parser rejects, hiding the repair entry point.
    static func codexBridgeManagedValues(
        inSection section: String,
        legacyHeadersField: TOMLHeaderField = .httpHeaders
    ) -> (command: String?, args: [String]?) {
        var inParent = true
        var commands: [String] = []
        var argsValues: [[String]] = []
        var invalid = false

        for rawLine in section.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let table = tomlTableHeaderName(in: Substring(rawLine)) {
                let normalized = normalizedTOMLKey(table)
                if normalized == codexParentTable {
                    inParent = true
                } else {
                    // Any nested table inside our combined section is the
                    // legacy headers table — a shape Connect must repair.
                    inParent = false
                    invalid = true
                }
                continue
            }
            guard inParent, let equals = line.firstIndex(of: "=") else { continue }
            let key = normalizedTOMLKey(String(line[..<equals]))
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "command":
                if let value = tomlScalarString(rawValue) { commands.append(value) } else { invalid = true }
            case "args":
                if let values = tomlStringArray(rawValue) { argsValues.append(values) } else { invalid = true }
            case "url", legacyHeadersField.rawValue:
                invalid = true  // legacy HTTP entry
            default:
                if key.hasPrefix(legacyHeadersField.rawValue + ".") { invalid = true }
            }
        }
        guard !invalid, commands.count == 1, argsValues.count == 1 else { return (nil, nil) }
        return (commands[0], argsValues[0])
    }

    /// Final structural check before any upsert result is written: exactly
    /// one parent table, no legacy headers table, and inside the parent
    /// exactly one parseable `command` and one `args`, with zero legacy
    /// keys — enforced on the output, independent of branch logic.
    static func validateCodexBridgeMergeResult(
        _ text: String,
        configPath: String,
        legacyHeadersField: TOMLHeaderField = .httpHeaders
    ) throws {
        let parents = tomlTableRanges(in: text, named: codexParentTable)
        guard parents.count == 1,
              tomlTableRanges(in: text, named: tomlHeadersTable(legacyHeadersField)).isEmpty else {
            throw ConnectorError.configUnrecognized(configPath)
        }
        var commandCount = 0
        var argsCount = 0
        for line in String(text[parents[0]]).components(separatedBy: .newlines) {
            guard let key = tomlAssignmentKey(in: line) else { continue }
            let normalized = normalizedTOMLKey(key)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch normalized {
            case "command":
                guard tomlScalarString(rawValue) != nil else { throw ConnectorError.configUnrecognized(configPath) }
                commandCount += 1
            case "args":
                guard tomlStringArray(rawValue) != nil else { throw ConnectorError.configUnrecognized(configPath) }
                argsCount += 1
            case "url", legacyHeadersField.rawValue:
                throw ConnectorError.configUnrecognized(configPath)
            default:
                if normalized.hasPrefix(legacyHeadersField.rawValue + ".") {
                    throw ConnectorError.configUnrecognized(configPath)
                }
            }
        }
        guard commandCount == 1, argsCount == 1 else {
            throw ConnectorError.configUnrecognized(configPath)
        }
    }

    private static func updatingCodexBridgeParent(
        _ section: String,
        bridgePath: String,
        clientID: String,
        legacyHeadersField: TOMLHeaderField
    ) -> String {
        let newline = section.contains("\r\n") ? "\r\n" : "\n"
        var lines = section.components(separatedBy: newline)
        guard !lines.isEmpty else { return section }

        let header = lines.removeFirst()
        lines.removeAll { line in
            guard let key = tomlAssignmentKey(in: line) else { return false }
            let normalized = normalizedTOMLKey(key)
            return normalized == "command" || normalized == "args" || normalized == "url"
                || normalized == legacyHeadersField.rawValue
                || normalized.hasPrefix(legacyHeadersField.rawValue + ".")
        }

        let managed = [
            "command = \"\(tomlBasicString(bridgePath))\"",
            "args = \(tomlStringArrayLiteral(["--client", clientID]))",
        ]
        lines.insert(contentsOf: managed, at: 0)
        lines.insert(header, at: 0)
        return lines.joined(separator: newline)
    }

    /// Our own parent table plus its optional (legacy) nested header table.
    /// Ambiguous duplicate tables return nil so detection never reports a
    /// malformed config as connected.
    static func codexCadenzaSectionRange(in text: String) -> Range<String.Index>? {
        let ranges = tomlTableRanges(in: text, named: codexParentTable)
        guard ranges.count == 1 else { return nil }
        return ranges[0]
    }

    static func codexCadenzaSection(
        in text: String,
        headersField: TOMLHeaderField = .httpHeaders
    ) -> String? {
        guard !codexHasAmbiguousEquivalent(in: text) else { return nil }
        guard let parent = codexCadenzaSectionRange(in: text) else { return nil }
        let headers = tomlTableRanges(in: text, named: tomlHeadersTable(headersField))
        guard headers.count <= 1 else { return nil }
        return String(text[parent]) + (headers.first.map { String(text[$0]) } ?? "")
    }

    /// Replace our managed table with the stdio bridge entry while leaving
    /// every unrelated byte intact: unmanaged keys and comments in our table
    /// survive, the legacy HTTP keys (`url`, headers inline or nested table)
    /// are removed, and multiple/equivalent parent tables are rejected before
    /// any file write.
    static func upsertCodexBridgeEntry(
        in existing: String?,
        bridgePath: String,
        clientID: String,
        configPath: String = "~/.codex/config.toml",
        legacyHeadersField: TOMLHeaderField = .httpHeaders
    ) throws -> String {
        let newline = existing?.contains("\r\n") == true ? "\r\n" : "\n"
        let freshSection = """
        [mcp_servers.\(serverName)]
        command = "\(tomlBasicString(bridgePath))"
        args = \(tomlStringArrayLiteral(["--client", clientID]))

        """.replacingOccurrences(of: "\n", with: newline)

        guard var text = existing, !text.isEmpty else {
            try validateCodexBridgeMergeResult(freshSection, configPath: configPath,
                                               legacyHeadersField: legacyHeadersField)
            return freshSection
        }
        guard !codexHasAmbiguousEquivalent(in: text) else {
            throw ConnectorError.configUnrecognized(configPath)
        }

        var parentRanges = tomlTableRanges(in: text, named: codexParentTable)
        let legacyRanges = tomlTableRanges(in: text, named: tomlHeadersTable(legacyHeadersField))
        guard parentRanges.count <= 1, legacyRanges.count <= 1 else {
            throw ConnectorError.configUnrecognized(configPath)
        }
        guard !parentRanges.isEmpty || legacyRanges.isEmpty else {
            throw ConnectorError.configUnrecognized(configPath)
        }

        // The nested legacy header table was ours (Authorization); stdio has
        // no headers, so the whole table goes.
        if let legacyRange = legacyRanges.first {
            text.removeSubrange(legacyRange)
            parentRanges = tomlTableRanges(in: text, named: codexParentTable)
            guard parentRanges.count == 1 else {
                throw ConnectorError.configUnrecognized(configPath)
            }
        }

        if let parentRange = parentRanges.first {
            text.replaceSubrange(
                parentRange,
                with: updatingCodexBridgeParent(
                    String(text[parentRange]),
                    bridgePath: bridgePath,
                    clientID: clientID,
                    legacyHeadersField: legacyHeadersField
                )
            )
            try validateCodexBridgeMergeResult(text, configPath: configPath,
                                               legacyHeadersField: legacyHeadersField)
            return text
        }

        let appended = text + (text.hasSuffix(newline) ? newline : newline + newline) + freshSection
        try validateCodexBridgeMergeResult(appended, configPath: configPath,
                                           legacyHeadersField: legacyHeadersField)
        return appended
    }

    // MARK: YAML (Hermes)

    private static func yamlIndent(_ line: String) -> Int {
        var n = 0
        for ch in line { if ch == " " { n += 1 } else { break } }
        return n
    }

    /// True when a line's indentation uses a tab. YAML forbids tab indentation,
    /// and we can't reason about column math with tabs — so we refuse rather
    /// than risk misindenting the user's config.
    private static func yamlLeadingTab(_ line: String) -> Bool {
        for ch in line {
            if ch == "\t" { return true }
            if ch != " " { return false }
        }
        return false
    }

    /// Blank line or a comment-only line. YAML comments do NOT close a
    /// mapping, so structural scans must skip these, not stop on them.
    private static func yamlIgnorable(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }

    /// The substring after `key:` on a `key: …` line, or nil if the trimmed
    /// line isn't that key at all. Empty / comment-only remainder means a
    /// block mapping (`key:`); anything else is an inline scalar/flow value.
    private static func yamlValueAfterKey(_ line: String, key: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t == "\(key):" || t.hasPrefix("\(key): ") || t.hasPrefix("\(key):\t") || t.hasPrefix("\(key):#") else {
            return nil
        }
        return String(t.dropFirst("\(key):".count)).trimmingCharacters(in: .whitespaces)
    }

    /// `key:` opening a block mapping (no inline value) at exactly `indent`.
    private static func yamlBlockKey(_ line: String, key: String, indent: Int) -> Bool {
        guard yamlIndent(line) == indent, !yamlLeadingTab(line),
              let value = yamlValueAfterKey(line, key: key) else { return false }
        return value.isEmpty || value.hasPrefix("#")
    }

    /// `key: <scalar/flow>` carrying an inline value at exactly `indent` —
    /// a form we cannot safely splice into, so callers refuse it.
    private static func yamlHasInlineValue(_ line: String, key: String, indent: Int) -> Bool {
        guard yamlIndent(line) == indent, !yamlLeadingTab(line),
              let value = yamlValueAfterKey(line, key: key) else { return false }
        return !value.isEmpty && !value.hasPrefix("#")
    }

    /// Locate the `cadenza:` block (its key line through its last child line)
    /// nested under top-level `mcp_servers:`. Returns nil when either key is
    /// absent (caller appends fresh); throws `configUnrecognized` on shapes we
    /// can't edit safely (tab indentation, inline/flow `mcp_servers`/`cadenza`).
    static func hermesCadenzaBlockRange(in lines: [String], configPath: String = "") throws -> (range: Range<Int>, serverIndent: Int, childIndent: Int)? {
        // Inline/flow `mcp_servers: {...}` or `mcp_servers: []` — refuse rather
        // than append a duplicate top-level key (which would be invalid YAML).
        if lines.contains(where: { yamlHasInlineValue($0, key: "mcp_servers", indent: 0) }) {
            throw ConnectorError.configUnrecognized(configPath)
        }
        guard let mcpIdx = lines.firstIndex(where: { yamlBlockKey($0, key: "mcp_servers", indent: 0) }) else {
            return nil
        }
        // mcp_servers block ends at the first top-level (indent 0) line that is
        // neither blank nor a comment.
        var mcpEnd = lines.count
        for i in (mcpIdx + 1)..<lines.count {
            let line = lines[i]
            if yamlIgnorable(line) { continue }
            if yamlLeadingTab(line) { throw ConnectorError.configUnrecognized(configPath) }
            if yamlIndent(line) == 0 { mcpEnd = i; break }
        }
        // Server keys are mcp_servers' DIRECT children; their shared indent is
        // set by the first one. cadenza must sit at THAT indent — a `cadenza:`
        // nested deeper inside some other server is not ours.
        var serverIndent: Int?
        for i in (mcpIdx + 1)..<mcpEnd where !yamlIgnorable(lines[i]) {
            serverIndent = yamlIndent(lines[i])
            break
        }
        guard let serverIndent, serverIndent > 0 else { return nil }  // empty mcp_servers
        var cadIdx: Int?
        for i in (mcpIdx + 1)..<mcpEnd {
            let line = lines[i]
            if yamlIgnorable(line) || yamlIndent(line) != serverIndent { continue }
            if yamlHasInlineValue(line, key: serverName, indent: serverIndent) {
                throw ConnectorError.configUnrecognized(configPath)
            }
            if yamlBlockKey(line, key: serverName, indent: serverIndent) { cadIdx = i; break }
        }
        guard let cadIdx else { return nil }
        // cadenza block ends at the first non-ignorable line at indent <= serverIndent.
        var cadEnd = mcpEnd
        for i in (cadIdx + 1)..<mcpEnd {
            let line = lines[i]
            if yamlIgnorable(line) { continue }
            if yamlIndent(line) <= serverIndent { cadEnd = i; break }
        }
        var childIndent = serverIndent + 2
        if let firstChild = (cadIdx + 1..<cadEnd).first(where: { !yamlIgnorable(lines[$0]) }) {
            childIndent = yamlIndent(lines[firstChild])
            guard childIndent > serverIndent else { throw ConnectorError.configUnrecognized(configPath) }
        }
        return (cadIdx..<cadEnd, serverIndent, childIndent)
    }

    /// Index just past a `key:` block's subtree within `lines`, starting at the
    /// first line AFTER the key. Consumes deeper-indented lines and any blank/
    /// comment lines that are INTERIOR to the subtree (followed by more deep
    /// content), but stops before trailing blanks/comments that separate the
    /// subtree from the next sibling — so a separator comment isn't eaten.
    private static func yamlSkipSubtree(_ lines: [String], from start: Int, parentIndent: Int) -> Int {
        var i = start
        while i < lines.count {
            if yamlIgnorable(lines[i]) {
                var k = i
                while k < lines.count, yamlIgnorable(lines[k]) { k += 1 }
                if k < lines.count, yamlIndent(lines[k]) > parentIndent {
                    i = k  // interior blanks/comments — part of the subtree
                    continue
                }
                break  // trailing separators — leave them for the caller
            }
            if yamlIndent(lines[i]) > parentIndent { i += 1; continue }
            break
        }
        return i
    }

    static func hermesCadenzaBlock(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        // `try?` flattens the Optional return, so a single bind unwraps both
        // the throw and the nil-not-found cases.
        guard let found = try? hermesCadenzaBlockRange(in: lines) else { return nil }
        return lines[found.range].joined(separator: "\n")
    }

    /// Text-level upsert of the `mcp_servers.cadenza` block in Hermes's YAML.
    /// Regenerates the block's `url:` + `headers.Authorization:` while
    /// PRESERVING every other child (timeout, connect_timeout, anything the
    /// user added) and every other byte of the file. Throws
    /// `configUnrecognized` on tab indentation we can't safely edit.
    static func upsertHermesServerEntry(in text: String?, url: String, token: String, configPath: String) throws -> String {
        let bearer = "Bearer \(token)"

        func cadenzaLines(serverIndent: Int, childIndent: Int, preserved: [String]) -> [String] {
            let s = String(repeating: " ", count: serverIndent)
            let c = String(repeating: " ", count: childIndent)
            let cc = String(repeating: " ", count: childIndent + 2)
            return ["\(s)\(serverName):",
                    "\(c)url: \(url)",
                    "\(c)headers:",
                    "\(cc)Authorization: \(bearer)"] + preserved
        }

        // No file yet → a minimal standalone config.
        guard let text, !text.isEmpty else {
            return (["mcp_servers:"] + cadenzaLines(serverIndent: 2, childIndent: 4, preserved: []) + [""])
                .joined(separator: "\n")
        }

        var lines = text.components(separatedBy: "\n")

        // mcp_servers as inline/flow → refuse (range function also guards, but
        // be explicit before the absent-check below).
        if lines.contains(where: { yamlHasInlineValue($0, key: "mcp_servers", indent: 0) }) {
            throw ConnectorError.configUnrecognized(configPath)
        }

        // mcp_servers absent → append a whole block at EOF.
        guard lines.contains(where: { yamlBlockKey($0, key: "mcp_servers", indent: 0) }) else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append("")  // blank separator
            lines.append("mcp_servers:")
            lines.append(contentsOf: cadenzaLines(serverIndent: 2, childIndent: 4, preserved: []))
            lines.append("")  // trailing newline
            return lines.joined(separator: "\n")
        }

        guard let found = try hermesCadenzaBlockRange(in: lines, configPath: configPath) else {
            // mcp_servers exists, no cadenza → insert at end of that block,
            // matching sibling server-key indent (default 2).
            let mcpIdx = lines.firstIndex(where: { yamlBlockKey($0, key: "mcp_servers", indent: 0) })!
            var mcpEnd = lines.count
            var siblingIndent = 2
            var sawSibling = false
            for i in (mcpIdx + 1)..<lines.count {
                let line = lines[i]
                if yamlIgnorable(line) { continue }
                let ind = yamlIndent(line)
                if ind == 0 { mcpEnd = i; break }
                if !sawSibling { siblingIndent = ind; sawSibling = true }
            }
            let insertion = cadenzaLines(serverIndent: siblingIndent, childIndent: siblingIndent + 2, preserved: [])
            lines.insert(contentsOf: insertion, at: mcpEnd)
            return lines.joined(separator: "\n")
        }

        // cadenza exists → preserve children except url and headers(+subtree).
        let childLines = Array(lines[(found.range.lowerBound + 1)..<found.range.upperBound])
        var preserved: [String] = []
        var i = 0
        while i < childLines.count {
            let line = childLines[i]
            if yamlIndent(line) == found.childIndent,
               yamlValueAfterKey(line, key: "url") != nil || yamlValueAfterKey(line, key: "headers") != nil {
                // Drop the key line AND its value subtree. For `headers:` this
                // is the nested Authorization mapping; for `url:` it covers a
                // folded/literal/plain multiline value (`url: >`, `url:` +
                // indented continuation) — we regenerate url either way, so the
                // old value is discarded wholesale rather than left orphaned.
                i = yamlSkipSubtree(childLines, from: i + 1, parentIndent: found.childIndent)
                continue
            }
            preserved.append(line)
            i += 1
        }
        // Preserved children are always appended AFTER our regenerated
        // url/headers, so any trailing blank line stays exactly where it was —
        // the separator before the next block. (Don't trim it; that would
        // collapse the gap before whatever follows mcp_servers.)

        let replacement = cadenzaLines(serverIndent: found.serverIndent, childIndent: found.childIndent, preserved: preserved)
        lines.replaceSubrange(found.range, with: replacement)
        return lines.joined(separator: "\n")
    }

    /// Semantic merge of `mcpServers.cadenza` into a JSON config: every other
    /// key and server entry is preserved (formatting/key order are
    /// JSONSerialization's, not byte-identical). Pure — unit-tested directly.
    /// Refuses to proceed when the existing structure isn't what we expect,
    /// rather than silently replacing user data.
    static func upsertServerEntry(in data: Data?, configPath: String, entry: [String: Any]) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ConnectorError.configNotAnObject(configPath)
            }
            root = parsed
        }
        let servers: [String: Any]
        switch root["mcpServers"] {
        case nil:
            servers = [:]
        case let existing as [String: Any]:
            servers = existing
        default:
            // mcpServers exists but isn't an object — overwriting it with a
            // dictionary would destroy whatever the user had there.
            throw ConnectorError.configNotAnObject(configPath)
        }
        var updated = servers
        updated[serverName] = entry
        root["mcpServers"] = updated
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func runShell(_ command: String) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Single background reader drains to EOF: prevents the child
            // blocking on a full (~64KB) pipe, and resume waits on BOTH
            // termination and reader completion — no torn-output race.
            let buffer = Mutex(Data())
            let readerDone = DispatchGroup()
            readerDone.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                buffer.withLock { $0 = data }
                readerDone.leave()
            }
            process.terminationHandler = { finished in
                readerDone.notify(queue: .global(qos: .utility)) {
                    let data = buffer.withLock { $0 }
                    continuation.resume(returning: (finished.terminationStatus,
                                                    String(data: data, encoding: .utf8) ?? ""))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
