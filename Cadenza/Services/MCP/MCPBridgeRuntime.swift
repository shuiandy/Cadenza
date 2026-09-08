import Foundation

/// Filesystem contract between the app's MCP server and the `cadenza-mcp`
/// stdio bridge. Compiled into BOTH targets: the app writes these files, the
/// bridge reads them.
///
/// Layout under `~/Library/Application Support/Cadenza/mcp/`:
/// - `endpoint.json` — the server's current loopback URL, rewritten every
///   time the listener comes up. The bridge re-reads it on every reconnect
///   attempt, so a port change never invalidates client configs.
/// - `credentials/<client-id>.token` — one per-client bearer token, written
///   on Connect and removed on Revoke. Client configs carry only the bridge
///   command, never a secret, so a dotfiles repo can't leak a token and a
///   token reset doesn't require touching any client config.
///
/// Files are 0600 and directories 0700: readable by the user's processes
/// only — the same trust boundary the previous tokens-in-client-config
/// layout already had, minus the copies scattered across other tools' files.
struct MCPBridgeRuntime: Sendable {
    enum RuntimeError: Error, Equatable {
        case invalidClientID(String)
        case writeFailed(String)
    }

    /// Payload of `endpoint.json`. Versioned so the bridge can keep reading
    /// files written by newer apps.
    struct Endpoint: Codable, Sendable, Equatable {
        let version: Int
        let url: String
    }

    let root: URL

    static let endpointFileName = "endpoint.json"
    static let credentialsDirectoryName = "credentials"
    static let endpointVersion = 1
    /// Where the bridge probes when no endpoint file exists yet (fresh
    /// install, or the app has never started its server on this machine).
    static let fallbackServerURL = "http://127.0.0.1:8585/mcp"

    static func standard() -> MCPBridgeRuntime {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return MCPBridgeRuntime(
            root: base
                .appendingPathComponent("Cadenza", isDirectory: true)
                .appendingPathComponent("mcp", isDirectory: true)
        )
    }

    var endpointFileURL: URL { root.appendingPathComponent(Self.endpointFileName) }

    var credentialsDirectoryURL: URL {
        root.appendingPathComponent(Self.credentialsDirectoryName, isDirectory: true)
    }

    func credentialFileURL(for clientID: String) throws -> URL {
        guard Self.isValidClientID(clientID) else { throw RuntimeError.invalidClientID(clientID) }
        return credentialsDirectoryURL.appendingPathComponent("\(clientID).token")
    }

    // MARK: - Endpoint

    func writeEndpoint(url serverURL: String) throws {
        let payload = Endpoint(version: Self.endpointVersion, url: serverURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try ensureDirectory(root)
        try writeProtected(data, to: endpointFileURL)
    }

    /// nil when the file is absent or unreadable — callers fall back to
    /// `fallbackServerURL`.
    func readEndpointURL() -> String? {
        guard let data = try? Data(contentsOf: endpointFileURL),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
              !endpoint.url.isEmpty else { return nil }
        return endpoint.url
    }

    // MARK: - Per-client credentials

    func writeCredential(_ token: String, for clientID: String) throws {
        let destination = try credentialFileURL(for: clientID)
        try ensureDirectory(root)
        try ensureDirectory(credentialsDirectoryURL)
        try writeProtected(Data(token.utf8), to: destination)
    }

    func credential(for clientID: String) -> String? {
        guard let url = try? credentialFileURL(for: clientID),
              let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func removeCredential(for clientID: String) throws {
        let url = try credentialFileURL(for: clientID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Plumbing

    /// Path-safe client IDs only: the ID becomes a file name, so anything
    /// outside the access store's normalized alphabet is refused.
    static func isValidClientID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { char in
            char.isASCII && (char.isLowercase || char.isNumber || char == "-" || char == "_")
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// 0600 from the first byte: the payload lands in a same-directory temp
    /// file created with final permissions, then replaces the destination —
    /// a reader can never observe a half-written or world-readable file.
    private func writeProtected(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw RuntimeError.writeFailed(destination.path)
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
