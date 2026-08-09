import Foundation

// MARK: - Public types

struct NotionDatabaseInfo: Equatable, Sendable {
    let id: String
    let title: String
    let url: URL?
}

struct NotionExportRequest: Sendable {
    enum Block: Encodable, Sendable {
        case heading2(String)
        case paragraph(String)

        private enum CodingKeys: String, CodingKey { case type, text }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .heading2(let text):
                try container.encode("heading_2", forKey: .type)
                try container.encode(text, forKey: .text)
            case .paragraph(let text):
                try container.encode("paragraph", forKey: .type)
                try container.encode(text, forKey: .text)
            }
        }
    }

    enum PropertyValue: Encodable, Sendable {
        case string(String)
        case date(Date)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .date(let d): try container.encode(ISO8601DateFormatter().string(from: d))
            }
        }
    }

    let databaseID: String
    let properties: [String: PropertyValue]
    let blocks: [Block]
}

struct NotionExportResult: Sendable {
    let pageID: String
    let url: URL?
}

private struct NotionExportPayload: Encodable {
    let databaseID: String
    let properties: [String: NotionExportRequest.PropertyValue]
    let blocks: [NotionExportRequest.Block]

    init(request: NotionExportRequest) {
        self.databaseID = request.databaseID
        self.properties = request.properties
        self.blocks = request.blocks
    }

    private enum CodingKeys: String, CodingKey { case databaseID = "database_id", properties, blocks }
}

// MARK: - Service

@Observable @MainActor
final class NotionExportService {
    var isExporting = false
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var workspaceName = ""
    private(set) var lastError: AuthError?
    private(set) var needsForcedReconnect = false

    private let cadenzaAuth: CadenzaAuthService
    private let authorizer: AuthorizationProvider
    private let legacyTokenStore: AuthSecretStore  // for forced-reconnect cleanup (F3)

    private let defaults: UserDefaults
    /// Scoped-key resolver, injected so tests pin the mapping explicitly.
    private let preferenceKey: (String) -> String
    private var workspaceNameKey: String { preferenceKey("notion.workspaceName") }
    private var connectedKey: String { preferenceKey("notion.connected") }

    /// Legacy keychain key from pre-vault builds. Forced-reconnect path
    /// (Task F3) detects this on launch and deletes it after reconnect.
    private let legacyTokenKey = "oauth.tokens.notion"

    var databaseID: String {
        get { defaults.string(forKey: preferenceKey("notion.databaseID")) ?? "" }
        set { defaults.set(newValue, forKey: preferenceKey("notion.databaseID")) }
    }

    init(cadenzaAuth: CadenzaAuthService,
         authorizer: AuthorizationProvider = OAuthCoordinator.shared,
         legacyTokenStore: AuthSecretStore = KeychainAuthSecretStore(),
         defaults: UserDefaults = .standard,
         preferenceKey: @escaping (String) -> String = ActiveProfileDefaults.key) {
        self.cadenzaAuth = cadenzaAuth
        self.authorizer = authorizer
        self.legacyTokenStore = legacyTokenStore
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.workspaceName = defaults.string(forKey: workspaceNameKey) ?? ""
        self.isConnected = defaults.bool(forKey: connectedKey)
        Self.purgeLegacyCredentials()
    }

    // MARK: - OAuth Flow (server-side vault)

    func connect() async throws {
        guard cadenzaAuth.isSignedIn else { throw AuthError.unknown }
        guard !isConnecting else { throw AuthError.alreadyInProgress }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }
        let entryFingerprint = cadenzaAuth.currentUser?.id

        do {
            let startResponse = try await fetchStartAttempt()
            let callbackURL = try await authorizer.authorize(startResponse.authorizeURL)
            try validateNotionCallback(callbackURL, expectedAttempt: startResponse.attemptID)

            // refreshConnectionStatus() owns the success-path state mutation.
            // It writes isConnected=true + defaults on `connected:true` and
            // throws on `connected:false`.
            try await refreshConnectionStatus()

            if sessionStillCurrent(entryFingerprint) {
                // Clear any lingering per-integration reauth banner now that
                // the vault row is confirmed live.
                cadenzaAuth.clearIntegrationReauth(for: "notion")

                // F3: clean up the legacy keychain token now that the vault row is live.
                if needsForcedReconnect {
                    try? legacyTokenStore.remove(legacyTokenKey)
                    needsForcedReconnect = false
                }
            }
        } catch {
            // Don't unconditionally clear isConnected — that would falsely
            // demote a previously-connected user on a transient network blip
            // during forced reconnect. refreshConnectionStatus() already
            // clears state for the cases that prove the vault is invalid
            // (integrationReauthRequired, connected:false). Other errors
            // (network, decoding, attempt mismatch) preserve prior state.
            let classified = AuthError.classify(error)
            if sessionStillCurrent(entryFingerprint) {
                lastError = classified
            }
            NSLog("[NotionExport] connect failed: %@", String(describing: classified) as NSString)
            throw error
        }
    }

    func disconnect() {
        isConnected = false
        workspaceName = ""
        defaults.set(false, forKey: connectedKey)
        defaults.removeObject(forKey: workspaceNameKey)
        // Backend keeps the vault row until Cadenza signs out; future
        // /integrations/notion/disconnect endpoint will clear it eagerly.
    }

    // MARK: - Export

    /// Renders a time on an exported page: `H:MM:SS` past an hour, `MM:SS` below.
    ///
    /// Shared by the Duration property and the transcript timestamps because
    /// they sit on the same page and a reader compares them. They used to be
    /// formatted separately, and the timestamps had no hour component at all —
    /// so a segment an hour into a meeting read `[65:00]` beside a Duration of
    /// `1:12:30`, two different clocks in one document.
    static func exportClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// Exports a recording via the server-side proxy. Loses block fidelity vs
    /// the pre-vault implementation: bulleted_list_item / to_do / heading_1 /
    /// toggleable blocks are flattened to paragraph/heading2. Tracked as an
    /// accepted regression for Phase 1; richer block support is a separate
    /// scope decision.
    func exportRecording(_ recording: RecordingDetailDTO) async throws {
        guard !databaseID.isEmpty else {
            throw ExportError.notionDatabaseNotSelected
        }

        isExporting = true
        defer { isExporting = false }

        var properties: [String: NotionExportRequest.PropertyValue] = [
            "Name": .string(recording.title),
            "Date": .date(recording.startDate),
        ]
        properties["Duration"] = .string(Self.exportClock(recording.duration))
        if !recording.tags.isEmpty {
            properties["Tags"] = .string(recording.tags.joined(separator: ", "))
        }

        var blocks: [NotionExportRequest.Block] = []
        if let transcript = recording.transcript, !transcript.fullText.isEmpty {
            blocks.append(.heading2("Full Transcript"))
            if transcript.segments.isEmpty {
                blocks.append(.paragraph(transcript.fullText))
            } else {
                for entry in transcript.segments {
                    let timestamp = Self.exportClock(entry.startTime)
                    let speaker = entry.speaker.map { "\($0): " } ?? ""
                    blocks.append(.paragraph("[\(timestamp)] \(speaker)\(entry.text)"))
                }
            }
        }
        if let summary = recording.summary {
            if !summary.overview.isEmpty {
                blocks.append(.heading2("Overview"))
                blocks.append(.paragraph(summary.overview))
            }
            if !summary.keyPoints.isEmpty {
                blocks.append(.heading2("Key Points"))
                for point in summary.keyPoints { blocks.append(.paragraph("• \(point)")) }
            }
            if !summary.actionItems.isEmpty {
                blocks.append(.heading2("Action Items"))
                for item in summary.actionItems {
                    let text = item.assignee.map { "\(item.task) (@\($0))" } ?? item.task
                    blocks.append(.paragraph("☐ \(text)"))
                }
            }
            if !summary.decisions.isEmpty {
                blocks.append(.heading2("Decisions"))
                for decision in summary.decisions { blocks.append(.paragraph("• \(decision)")) }
            }
            if !summary.yourTasks.isEmpty {
                blocks.append(.heading2("Your Tasks"))
                for task in summary.yourTasks { blocks.append(.paragraph("• \(task)")) }
            }
            if !summary.followUps.isEmpty {
                blocks.append(.heading2("Follow-ups"))
                for followUp in summary.followUps { blocks.append(.paragraph("• \(followUp)")) }
            }
        }

        let req = NotionExportRequest(databaseID: databaseID,
                                      properties: properties, blocks: blocks)
        _ = try await exportPage(req, idempotencyKey: recording.id.uuidString)
    }

    // MARK: - Private helpers

    private struct StartResponse {
        let attemptID: String
        let authorizeURL: URL
    }

    private func fetchStartAttempt() async throws -> StartResponse {
        let data = try await cadenzaAuth.request(
            path: "integrations/notion/start", method: "POST", body: Data("{}".utf8))
        struct Raw: Decodable {
            let attemptId: String
            let authorizeUrl: String
            private enum CodingKeys: String, CodingKey {
                case attemptId = "attempt_id", authorizeUrl = "authorize_url"
            }
        }
        let raw: Raw
        raw = try decodeProxyResponse(Raw.self, from: data, operation: "start")
        guard let url = URL(string: raw.authorizeUrl) else { throw AuthError.invalidCallback }
        return StartResponse(attemptID: raw.attemptId, authorizeURL: url)
    }

    private func validateNotionCallback(_ url: URL, expectedAttempt: String) throws {
        guard url.scheme == "com.shuiandy.cadenza" else { throw AuthError.invalidCallback }
        guard url.host == "auth" else { throw AuthError.invalidCallback }
        guard url.path == "/notion/callback" else { throw AuthError.invalidCallback }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "attempt" })?.value == expectedAttempt else {
            throw AuthError.invalidCallback
        }
        guard let status = items.first(where: { $0.name == "status" })?.value else {
            throw AuthError.invalidCallback
        }
        if status == "error" {
            let reason = items.first(where: { $0.name == "reason" })?.value ?? ""
            if reason == "user_denied" || reason == "access_denied" {
                throw AuthError.authorizationDenied
            }
            throw AuthError.unknown
        }
        guard status == "success" else { throw AuthError.invalidCallback }
    }

    /// Lightweight `/me` call to confirm vault row + populate workspace name.
    func refreshConnectionStatus() async throws {
        let entryFingerprint = cadenzaAuth.currentUser?.id
        let data: Data
        do {
            data = try await cadenzaAuth.request(
                path: "integrations/notion/me", method: "GET", body: nil)
        } catch let err as AuthError where err == .integrationReauthRequired(provider: "notion") {
            if sessionStillCurrent(entryFingerprint) {
                isConnected = false
                defaults.set(false, forKey: connectedKey)
            }
            throw err
        }
        struct Raw: Decodable {
            let connected: Bool
            let workspaceName: String?
            let workspaceIcon: String?
            let botId: String?
            private enum CodingKeys: String, CodingKey {
                case connected, workspaceName = "workspace_name",
                     workspaceIcon = "workspace_icon", botId = "bot_id"
            }
        }
        let raw: Raw
        raw = try decodeProxyResponse(Raw.self, from: data, operation: "connection status")

        guard sessionStillCurrent(entryFingerprint) else {
            // Sign-out happened during /me — drop the response.
            return
        }

        if raw.connected {
            isConnected = true
            workspaceName = raw.workspaceName ?? ""
            defaults.set(true, forKey: connectedKey)
            defaults.set(workspaceName, forKey: workspaceNameKey)
        } else {
            // Backend says callback succeeded but vault row is empty — likely a
            // race or partial failure on the server. Throw so the caller can
            // surface it via lastError instead of silently appearing connected.
            isConnected = false
            defaults.set(false, forKey: connectedKey)
            throw AuthError.unknown
        }
    }

    // MARK: - Forced reconnect (F3)

    /// Spec §5.6: legacy users have a Notion token in keychain from pre-vault
    /// builds. On launch (or after sign-in), call this to surface the
    /// "Reconnect Notion to Cadenza Cloud" UI.
    func detectForcedReconnect() async {
        guard cadenzaAuth.isSignedIn else {
            needsForcedReconnect = false
            return
        }
        guard legacyTokenStore.get(legacyTokenKey) != nil else {
            needsForcedReconnect = false
            return
        }
        let entryFingerprint = cadenzaAuth.currentUser?.id
        do {
            let data = try await cadenzaAuth.request(
                path: "integrations/notion/me", method: "GET", body: nil)
            guard sessionStillCurrent(entryFingerprint) else { return }
            struct Raw: Decodable { let connected: Bool? }
            if let raw = try? JSONDecoder().decode(Raw.self, from: data),
               raw.connected == true {
                // Already vault-backed — clean up the stale legacy token.
                try? legacyTokenStore.remove(legacyTokenKey)
                needsForcedReconnect = false
            } else {
                needsForcedReconnect = true
            }
        } catch CadenzaAPIError.backend(let envelope, let status)
                    where status == 404 && envelope.code == "not_connected" {
            guard sessionStillCurrent(entryFingerprint) else { return }
            needsForcedReconnect = true
        } catch {
            // Network or other failure: don't pin the user into a banner; revisit later.
            guard sessionStillCurrent(entryFingerprint) else { return }
            needsForcedReconnect = false
            NSLog("[NotionExport] detectForcedReconnect inconclusive: %@",
                  String(describing: AuthError.classify(error)) as NSString)
        }
    }

    // MARK: - Legacy cleanup

    /// Removes the BYO client_id / client_secret state used by Cadenza < 0.2.
    /// Idempotent and silent — runs once per service init.
    private static func purgeLegacyCredentials() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "notion.clientID") != nil {
            defaults.removeObject(forKey: "notion.clientID")
        }
        try? KeychainManager.shared.remove("notion.clientSecret")
        if defaults.object(forKey: "notion.clientSecret") != nil {
            defaults.removeObject(forKey: "notion.clientSecret")
        }
    }
}

// MARK: - Proxy API

extension NotionExportService {
    /// `POST /integrations/notion/databases/search`
    func fetchDatabases(query: String? = nil) async throws -> [NotionDatabaseInfo] {
        var payload: [String: Any] = ["page_size": 50]
        if let query, !query.isEmpty { payload["query"] = query }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await callProxy(path: "integrations/notion/databases/search",
                                       method: "POST", body: body)
        struct Raw: Decodable {
            let databases: [Item]
            struct Item: Decodable { let id: String; let title: String; let url: String? }
        }
        let raw: Raw
        raw = try decodeProxyResponse(Raw.self, from: data, operation: "database search")
        return raw.databases.map {
            NotionDatabaseInfo(id: $0.id, title: $0.title, url: $0.url.flatMap(URL.init(string:)))
        }
    }

    /// `POST /integrations/notion/container-page` — creates the workspace-level
    /// "Cadenza" page if the user doesn't already have one.
    func createContainerPage(title: String) async throws -> NotionDatabaseInfo {
        let body = try JSONSerialization.data(withJSONObject: ["title": title])
        let data = try await callProxy(path: "integrations/notion/container-page",
                                       method: "POST", body: body)
        struct Raw: Decodable {
            let pageId: String
            let url: String?
            private enum CodingKeys: String, CodingKey { case pageId = "page_id", url }
        }
        let raw = try decodeProxyResponse(Raw.self, from: data, operation: "container page")
        return NotionDatabaseInfo(id: raw.pageId, title: title,
                                  url: raw.url.flatMap(URL.init(string:)))
    }

    /// `POST /integrations/notion/databases`
    func createDatabase(parentPageID: String, title: String) async throws -> NotionDatabaseInfo {
        let body = try JSONSerialization.data(withJSONObject: [
            "parent_page_id": parentPageID,
            "title": title,
        ])
        let data = try await callProxy(path: "integrations/notion/databases",
                                       method: "POST", body: body)
        struct Raw: Decodable {
            let databaseId: String
            let title: String
            let url: String?
            private enum CodingKeys: String, CodingKey { case databaseId = "database_id", title, url }
        }
        let raw = try decodeProxyResponse(Raw.self, from: data, operation: "database creation")
        return NotionDatabaseInfo(id: raw.databaseId, title: raw.title,
                                  url: raw.url.flatMap(URL.init(string:)))
    }

    /// `POST /integrations/notion/export-page` with `Idempotency-Key`.
    func exportPage(_ request: NotionExportRequest, idempotencyKey: String) async throws -> NotionExportResult {
        let body: Data
        do {
            body = try JSONEncoder().encode(NotionExportPayload(request: request))
        } catch {
            NSLog("[NotionExport] request encoding failed: %@", String(describing: error))
            throw AuthError.decoding(String(describing: error))
        }
        let data = try await callProxy(path: "integrations/notion/export-page",
                                       method: "POST", body: body,
                                       extraHeaders: ["Idempotency-Key": idempotencyKey])
        struct Raw: Decodable {
            let pageId: String
            let url: String?
            private enum CodingKeys: String, CodingKey { case pageId = "page_id", url }
        }
        let raw = try decodeProxyResponse(Raw.self, from: data, operation: "page export")
        return NotionExportResult(pageID: raw.pageId, url: raw.url.flatMap(URL.init(string:)))
    }

    /// `GET /integrations/notion/exported-ids` — recording UUIDs the backend
    /// has already exported for this user (the persisted Idempotency-Keys of
    /// every successful export-page, including manual and auto-export).
    /// Backend contract: docs/superpowers/specs/2026-06-12-export-all-transcripts-design.md
    func fetchExportedRecordingIDs() async throws -> Set<UUID> {
        let data = try await callProxy(path: "integrations/notion/exported-ids",
                                       method: "GET", body: nil)
        struct Raw: Decodable {
            let recordingIds: [String]
            private enum CodingKeys: String, CodingKey { case recordingIds = "recording_ids" }
        }
        let raw: Raw
        raw = try decodeProxyResponse(Raw.self, from: data, operation: "exported IDs")
        // Malformed IDs are dropped: re-exporting an already-exported recording
        // is a harmless no-op (export-page is idempotent on recording.id).
        return Set(raw.recordingIds.compactMap(UUID.init))
    }

    /// Returns true iff the Cadenza account that initiated the request is
    /// still signed in. Uses `currentUser.id` as the fingerprint so a
    /// sign-out followed by sign-in to a *different* account during an
    /// in-flight request is correctly detected as a session change. For
    /// Phase 1 (single account) this is functionally equivalent to a
    /// boolean signed-in check; the `id` comparison future-proofs against
    /// multi-account.
    private func sessionStillCurrent(_ entryFingerprint: String?) -> Bool {
        guard let entryFingerprint else { return false }
        return cadenzaAuth.currentUser?.id == entryFingerprint
    }

    private func callProxy(path: String,
                           method: String,
                           body: Data?,
                           extraHeaders: [String: String] = [:]) async throws -> Data {
        let entryFingerprint = cadenzaAuth.currentUser?.id
        do {
            return try await cadenzaAuth.request(path: path, method: method,
                                                 body: body, headers: extraHeaders)
        } catch let err as AuthError where err == .integrationReauthRequired(provider: "notion") {
            if sessionStillCurrent(entryFingerprint) {
                isConnected = false
                defaults.set(false, forKey: connectedKey)
            }
            throw err
        }
    }

    private func decodeProxyResponse<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        operation: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog(
                "[NotionExport] %@ response decoding failed: %@",
                operation,
                String(describing: error)
            )
            throw AuthError.decoding(String(describing: error))
        }
    }

#if DEBUG
    /// Test seam — flips `isConnected` without going through `connect()`.
    func markConnectedForTests() {
        isConnected = true
        defaults.set(true, forKey: connectedKey)
    }

    /// Test seam — sets `needsForcedReconnect` to simulate detected legacy token.
    func markForcedReconnectForTests() { needsForcedReconnect = true }
#endif
}
