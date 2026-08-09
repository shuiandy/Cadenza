import Foundation
import Synchronization

/// Detects external MCP clients and writes their configuration in one click.
///
/// Detection is purely filesystem-based (no shell calls — fast and testable):
/// a client counts as installed when its config root exists. Connecting:
/// - Claude Code goes through the official `claude mcp add` CLI (its
///   ~/.claude.json is a live state file other processes write to; the CLI
///   is the supported mutation path).
/// - Gemini CLI / Claude Desktop get a semantic JSON merge: parse, upsert
///   `mcpServers.cadenza`, rewrite. Every other key/value is preserved
///   (formatting and key order are JSONSerialization's).
/// - Codex / Hermes are TOML / YAML: no Swift stdlib parser, so we do a
///   text-level replacement of ONLY our own `cadenza` block, refusing
///   (throwing) on any structure we don't recognize so we never corrupt the
///   user's hand-tuned config. On refusal the UI shows a copyable snippet.
struct MCPClientConnector: Sendable {
    enum Client: String, CaseIterable, Identifiable, Sendable {
        case claudeCode = "Claude Code"
        case geminiCLI = "Gemini CLI"
        case claudeDesktop = "Claude Desktop"
        case codexCLI = "Codex (GPT)"
        case hermes = "Hermes"
        var id: String { rawValue }
        var accessID: String {
            switch self {
            case .claudeCode: "claude-code"
            case .geminiCLI: "gemini-cli"
            case .claudeDesktop: "claude-desktop"
            case .codexCLI: "codex-cli"
            case .hermes: "hermes"
            }
        }
    }

    enum ConnectionState: Equatable, Sendable {
        case notInstalled(hint: String)
        case disconnected
        case connected
        /// Configured, but with a token/URL that no longer matches ours
        /// (e.g. after a token reset or port change).
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
    var hermesConfigURL: URL { home.appendingPathComponent(".hermes/config.yaml") }

    // MARK: - Detection

    func detect(_ client: Client, url: String, token: String) -> ConnectionState {
        let bearer = "Bearer \(token)"
        switch client {
        case .claudeCode:
            // Every Claude Code install materializes ~/.claude.json on first run.
            guard let root = readJSONObject(at: claudeCodeConfigURL) else {
                return .notInstalled(hint: String(localized: "Install Claude Code, run it once, then connect"))
            }
            guard let entry = (root["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .disconnected
            }
            let headers = entry["headers"] as? [String: Any]
            let matches = (entry["url"] as? String) == url
                && (headers?["Authorization"] as? String) == bearer
            return matches ? .connected : .stale

        case .geminiCLI:
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path) else {
                return .notInstalled(hint: String(localized: "Install Gemini CLI first (creates ~/.gemini)"))
            }
            guard let root = readJSONObject(at: geminiSettingsURL),
                  let entry = (root["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .disconnected
            }
            let headers = entry["headers"] as? [String: Any]
            let matches = (entry["httpUrl"] as? String) == url
                && (headers?["Authorization"] as? String) == bearer
            return matches ? .connected : .stale

        case .claudeDesktop:
            guard FileManager.default.fileExists(atPath: applicationsDirectory.appendingPathComponent("Claude.app").path) else {
                return .notInstalled(hint: String(localized: "Install the Claude Desktop app first"))
            }
            guard let root = readJSONObject(at: claudeDesktopConfigURL),
                  let entry = (root["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any] else {
                return .disconnected
            }
            let args = entry["args"] as? [String] ?? []
            let env = entry["env"] as? [String: Any]
            let matches = args.contains(url) && (env?["AUTH_HEADER"] as? String) == bearer
            return matches ? .connected : .stale

        case .codexCLI:
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else {
                return .notInstalled(hint: String(localized: "Install Codex CLI or the Codex app first"))
            }
            guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8),
                  let section = Self.codexCadenzaSection(in: text) else {
                return .disconnected
            }
            // Compare parsed values, not text: Codex rewrites config.toml
            // through its own serializer (spacing, quotes, inline vs nested),
            // so format matching would misreport cosmetic rewrites as stale.
            let values = Self.codexManagedValues(inSection: section)
            return (values.url == url && values.token == token) ? .connected : .stale

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

    // MARK: - Connect (idempotent upsert; safe to re-run to refresh token)

    func connect(_ client: Client, url: String, token: String) async throws {
        do {
            try await connectImplementation(client, url: url, token: token)
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

    private func connectImplementation(_ client: Client, url: String, token: String) async throws {
        switch client {
        case .claudeCode:
            try await connectClaudeCode(url: url, token: token)
        case .geminiCLI:
            try upsertConfigFile(at: geminiSettingsURL, entry: [
                "httpUrl": url,
                "headers": ["Authorization": "Bearer \(token)"],
            ])
        case .claudeDesktop:
            try upsertConfigFile(at: claudeDesktopConfigURL, entry: [
                "command": "npx",
                "args": ["-y", "mcp-remote", url, "--header", "Authorization:${AUTH_HEADER}"],
                "env": ["AUTH_HEADER": "Bearer \(token)"],
            ])
        case .codexCLI:
            // Codex's `mcp add` CLI only takes --bearer-token-env-var (an env
            // indirection the user would have to plumb); config.toml's static
            // `http_headers` is a first-class field (shows in `codex mcp get`)
            // with zero friction — so we upsert our own section textually.
            let existing = try existingFileContents(at: codexConfigURL).map { data -> String in
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ConnectorError.configUnreadable(codexConfigURL.path)
                }
                return text
            }
            let merged = try Self.upsertCodexServerEntry(
                in: existing,
                url: url,
                token: token,
                configPath: codexConfigURL.path
            )
            try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(merged.utf8).write(to: codexConfigURL, options: .atomic)

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

    private func connectClaudeCode(url: String, token: String) async throws {
        // Login shell so Homebrew/nvm PATHs resolve from a GUI app context.
        let probe = try await Self.runShell("command -v claude")
        guard probe.status == 0, !probe.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectorError.cliNotFound
        }
        // Add first — atomic for the common (not-yet-configured) case. Only
        // when the CLI refuses a DUPLICATE do we remove and re-add; any other
        // failure must not delete a working existing entry.
        let addCommand = "claude mcp add --transport http \(Self.serverName) '\(url)' --header 'Authorization: Bearer \(token)' -s user"
        let firstTry = try await Self.runShell(addCommand)
        if firstTry.status == 0 { return }
        guard firstTry.output.localizedCaseInsensitiveContains("already exist") else {
            throw ConnectorError.cliFailed(Self.redactingToken(firstTry.output, token: token))
        }

        _ = try? await Self.runShell("claude mcp remove \(Self.serverName) -s user")
        let retry = try await Self.runShell(addCommand)
        guard retry.status == 0 else {
            throw ConnectorError.cliFailed(Self.redactingToken(retry.output, token: token))
        }
    }

    /// CLI output can echo argv (and with it the bearer token) — scrub it
    /// before the text reaches the UI, and keep the message short.
    static func redactingToken(_ output: String, token: String) -> String {
        let scrubbed = output.replacingOccurrences(of: token, with: "●●●")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(scrubbed.prefix(300))
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

    // MARK: TOML (Codex)

    /// Text-level TOML support for the two Codex representations seen in the
    /// wild: an inline `http_headers = {...}` key and a nested
    /// `[mcp_servers.cadenza.http_headers]` table. Unknown or ambiguous
    /// equivalents are refused so a refresh can never append a duplicate key.
    private static let codexParentTable = "mcp_servers.\(serverName)"
    private static let codexHTTPHeadersTable = "\(codexParentTable).http_headers"

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

    private static func isTOMLAuthorizationAssignment(_ line: String) -> Bool {
        guard let key = tomlAssignmentKey(in: line) else { return false }
        return normalizedTOMLKey(key) == "Authorization"
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

    private static func bearerToken(fromTOMLScalar raw: String) -> String? {
        guard let scalar = tomlScalarString(raw), scalar.hasPrefix("Bearer ") else { return nil }
        return String(scalar.dropFirst("Bearer ".count))
    }

    /// Extracts the bearer token from an inline `{ Authorization = "Bearer …" }`
    /// value; nil for any other shape. Shared by detection and merge validation
    /// so the two never diverge.
    private static func inlineHeaderBearerToken(fromValue rawValue: String) -> String? {
        guard rawValue.hasPrefix("{"), let close = rawValue.lastIndex(of: "}") else { return nil }
        let trailing = rawValue[rawValue.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        let inside = String(rawValue[rawValue.index(after: rawValue.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
        guard !inside.contains(","),
              let innerEquals = inside.firstIndex(of: "="),
              normalizedTOMLKey(String(inside[..<innerEquals])) == "Authorization" else { return nil }
        return bearerToken(
            fromTOMLScalar: String(inside[inside.index(after: innerEquals)...])
                .trimmingCharacters(in: .whitespaces)
        )
    }

    /// Structural read of the managed url + bearer token from the combined
    /// cadenza section, parsed strictly by table context. Duplicate or
    /// misplaced keys invalidate the section (returns nils → stale):
    /// duplicate TOML keys are illegal rather than last-wins, and a
    /// last-wins read could report a config as connected that a standard
    /// parser rejects, hiding the repair entry point.
    static func codexManagedValues(inSection section: String) -> (url: String?, token: String?) {
        enum Context { case parent, headers, other }
        var context: Context = .parent
        var urls: [String] = []
        var tokens: [String] = []
        var invalid = false

        for rawLine in section.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let table = tomlTableHeaderName(in: Substring(rawLine)) {
                let normalized = normalizedTOMLKey(table)
                context = normalized == codexParentTable ? .parent
                    : normalized == codexHTTPHeadersTable ? .headers : .other
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = normalizedTOMLKey(String(line[..<equals]))
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            switch (context, key) {
            case (.parent, "url"):
                if let value = tomlScalarString(rawValue) { urls.append(value) } else { invalid = true }
            case (.parent, "http_headers"):
                if let token = inlineHeaderBearerToken(fromValue: rawValue) {
                    tokens.append(token)
                } else {
                    invalid = true
                }
            case (.headers, "Authorization"):
                if let token = bearerToken(fromTOMLScalar: rawValue) {
                    tokens.append(token)
                } else {
                    invalid = true
                }
            case (.parent, "Authorization"), (.headers, "url"):
                invalid = true // misplaced key
            default:
                break
            }
        }
        guard !invalid, urls.count == 1, tokens.count == 1 else { return (nil, nil) }
        return (urls[0], tokens[0])
    }

    /// Final structural check before any upsert result is written. Inline and
    /// nested headers together (a duplicate key to TOML parsers), duplicate
    /// tables, or an unexpected Authorization count throw configUnrecognized
    /// (fall back to the manual snippet) — enforced on the output,
    /// independent of branch logic.
    static func validateCodexMergeResult(_ text: String, configPath: String) throws {
        let parents = tomlTableRanges(in: text, named: codexParentTable)
        let headers = tomlTableRanges(in: text, named: codexHTTPHeadersTable)
        guard parents.count == 1, headers.count <= 1 else {
            throw ConnectorError.configUnrecognized(configPath)
        }
        let parentSection = String(text[parents[0]])
        let inlineHeaderCount = parentSection.components(separatedBy: .newlines).filter { line in
            guard let key = tomlAssignmentKey(in: line) else { return false }
            return normalizedTOMLKey(key) == "http_headers"
        }.count
        if let headerRange = headers.first {
            guard inlineHeaderCount == 0 else { throw ConnectorError.configUnrecognized(configPath) }
            let authCount = String(text[headerRange]).components(separatedBy: .newlines)
                .filter(isTOMLAuthorizationAssignment).count
            guard authCount == 1 else { throw ConnectorError.configUnrecognized(configPath) }
        } else {
            guard inlineHeaderCount == 1 else { throw ConnectorError.configUnrecognized(configPath) }
            // The inline form must carry exactly one Bearer Authorization.
            let inlineLine = parentSection.components(separatedBy: .newlines).first { line in
                guard let key = tomlAssignmentKey(in: line) else { return false }
                return normalizedTOMLKey(key) == "http_headers"
            }
            guard let inlineLine,
                  let equals = inlineLine.firstIndex(of: "="),
                  inlineHeaderBearerToken(
                      fromValue: String(inlineLine[inlineLine.index(after: equals)...])
                          .trimmingCharacters(in: .whitespaces)
                  ) != nil else {
                throw ConnectorError.configUnrecognized(configPath)
            }
        }
    }

    private static func updatingNestedCodexHeaders(_ section: String, token: String) -> String {
        let newline = section.contains("\r\n") ? "\r\n" : "\n"
        var lines = section.components(separatedBy: newline)
        lines.removeAll(where: isTOMLAuthorizationAssignment)
        let authorization = "Authorization = \"Bearer \(tomlBasicString(token))\""
        lines.insert(authorization, at: min(1, lines.endIndex))
        return lines.joined(separator: newline)
    }

    private static func updatingCodexParent(
        _ section: String,
        url: String,
        token: String,
        usesNestedHeaders: Bool
    ) -> String {
        let newline = section.contains("\r\n") ? "\r\n" : "\n"
        var lines = section.components(separatedBy: newline)
        guard !lines.isEmpty else { return section }

        let header = lines.removeFirst()
        lines.removeAll { line in
            guard let key = tomlAssignmentKey(in: line) else { return false }
            let normalized = normalizedTOMLKey(key)
            return normalized == "url" || normalized == "http_headers"
        }

        var managed = ["url = \"\(tomlBasicString(url))\""]
        if !usesNestedHeaders {
            managed.append("http_headers = { Authorization = \"Bearer \(tomlBasicString(token))\" }")
        }
        lines.insert(contentsOf: managed, at: 0)
        lines.insert(header, at: 0)
        return lines.joined(separator: newline)
    }

    private static func codexParentHasUnsafeHeaders(_ section: String, newline: String) -> Bool {
        section.components(separatedBy: newline).contains { line in
            guard let key = tomlAssignmentKey(in: line) else { return false }
            let normalized = normalizedTOMLKey(key)
            if normalized.hasPrefix("http_headers.") { return true }
            guard normalized == "http_headers",
                  let equals = line.firstIndex(of: "=") else { return false }

            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("{"), let close = value.lastIndex(of: "}") else { return true }
            let trailing = value[value.index(after: close)...]
                .trimmingCharacters(in: .whitespaces)
            guard trailing.isEmpty || trailing.hasPrefix("#") else { return true }

            let inside = value[value.index(after: value.startIndex)..<close]
                .trimmingCharacters(in: .whitespaces)
            guard !inside.contains(","), let innerKey = tomlAssignmentKey(in: inside) else { return true }
            return normalizedTOMLKey(innerKey) != "Authorization"
        }
    }

    /// Our own parent table plus its optional nested HTTP-header table.
    /// Ambiguous duplicate tables return nil so detection never reports a
    /// malformed config as connected.
    static func codexCadenzaSectionRange(in text: String) -> Range<String.Index>? {
        let ranges = tomlTableRanges(in: text, named: codexParentTable)
        guard ranges.count == 1 else { return nil }
        return ranges[0]
    }

    static func codexCadenzaSection(in text: String) -> String? {
        guard !codexHasAmbiguousEquivalent(in: text) else { return nil }
        guard let parent = codexCadenzaSectionRange(in: text) else { return nil }
        let headers = tomlTableRanges(in: text, named: codexHTTPHeadersTable)
        guard headers.count <= 1 else { return nil }
        let parentSection = String(text[parent])
        if !headers.isEmpty {
            let hasParentHeaders = parentSection.components(separatedBy: "\n").contains { line in
                guard let key = tomlAssignmentKey(in: line) else { return false }
                let normalized = normalizedTOMLKey(key)
                return normalized == "http_headers" || normalized.hasPrefix("http_headers.")
            }
            guard !hasParentHeaders else { return nil }
        }
        return parentSection + (headers.first.map { String(text[$0]) } ?? "")
    }

    /// Replace our managed fields while leaving every unrelated byte intact.
    /// Multiple/equivalent parent tables are rejected before any file write.
    static func upsertCodexServerEntry(
        in existing: String?,
        url: String,
        token: String,
        configPath: String = "~/.codex/config.toml"
    ) throws -> String {
        let escapedURL = tomlBasicString(url)
        let escapedToken = tomlBasicString(token)
        let newline = existing?.contains("\r\n") == true ? "\r\n" : "\n"
        let inlineSection = """
        [mcp_servers.\(serverName)]
        url = "\(escapedURL)"
        http_headers = { Authorization = "Bearer \(escapedToken)" }

        """.replacingOccurrences(of: "\n", with: newline)

        guard var text = existing, !text.isEmpty else {
            try validateCodexMergeResult(inlineSection, configPath: configPath)
            return inlineSection
        }
        guard !codexHasAmbiguousEquivalent(in: text) else {
            throw ConnectorError.configUnrecognized(configPath)
        }

        var parentRanges = tomlTableRanges(in: text, named: codexParentTable)
        var headerRanges = tomlTableRanges(in: text, named: codexHTTPHeadersTable)
        guard parentRanges.count <= 1, headerRanges.count <= 1 else {
            throw ConnectorError.configUnrecognized(configPath)
        }
        guard !parentRanges.isEmpty || headerRanges.isEmpty else {
            throw ConnectorError.configUnrecognized(configPath)
        }

        if let headerRange = headerRanges.first {
            let updatedHeaders = updatingNestedCodexHeaders(String(text[headerRange]), token: token)
            text.replaceSubrange(headerRange, with: updatedHeaders)
            parentRanges = tomlTableRanges(in: text, named: codexParentTable)
            guard let parentRange = parentRanges.first else {
                throw ConnectorError.configUnrecognized(configPath)
            }
            let parentSection = String(text[parentRange])
            guard !codexParentHasUnsafeHeaders(parentSection, newline: newline) else {
                throw ConnectorError.configUnrecognized(configPath)
            }
            text.replaceSubrange(
                parentRange,
                with: updatingCodexParent(parentSection, url: url, token: token, usesNestedHeaders: true)
            )
            try validateCodexMergeResult(text, configPath: configPath)
            return text
        }

        if let parentRange = parentRanges.first {
            let parentSection = String(text[parentRange])
            guard !codexParentHasUnsafeHeaders(parentSection, newline: newline) else {
                throw ConnectorError.configUnrecognized(configPath)
            }
            text.replaceSubrange(
                parentRange,
                with: updatingCodexParent(parentSection, url: url, token: token, usesNestedHeaders: false)
            )
            try validateCodexMergeResult(text, configPath: configPath)
            return text
        }
        headerRanges = tomlTableRanges(in: text, named: codexHTTPHeadersTable)
        guard headerRanges.isEmpty else {
            throw ConnectorError.configUnrecognized(configPath)
        }
        let appended = text + (text.hasSuffix(newline) ? newline : newline + newline) + inlineSection
        try validateCodexMergeResult(appended, configPath: configPath)
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
