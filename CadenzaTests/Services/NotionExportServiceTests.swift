import Foundation
import Testing
@testable import Cadenza

@MainActor
@Suite("NotionExportService — connect()")
struct NotionExportConnectTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.notion." + UUID().uuidString
        return UserDefaults(suiteName: suiteName)!
    }

    private func signedInAuth(http: FakeAuthHTTP)
            -> (CadenzaAuthService, InMemoryAuthSecretStore) {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try! writeStoredToken(into: store, value: "tok",
                              expiresAt: Date().addingTimeInterval(3600))
        userStore.user = .init(id: "u", email: "a@b", displayName: "A", pictureURL: nil)
        let auth = try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "u"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "u"))
        )
        return (auth, store)
    }

    private func startResponse(attemptID: String = "att-1") -> FakeAuthHTTP.Outcome {
        let body = """
        {
          "attempt_id": "\(attemptID)",
          "authorize_url": "https://api.notion.com/v1/oauth/authorize?client_id=x&state=bound&redirect_uri=https%3A%2F%2Fcadenzapp.test%2Fapi%2Fv1%2Fintegrations%2Fnotion%2Fcallback&response_type=code&owner=user"
        }
        """.data(using: .utf8)!
        let resp = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        return .success(data: body, response: resp)
    }

    @Test func connectHappyPathSetsConnected() async throws {
        let http = FakeAuthHTTP()
        let (auth, _) = signedInAuth(http: http)
        let authorizer = FakeAuthorizationProvider()
        http.enqueue(startResponse(attemptID: "att-1"))
        // /me response after callback success
        http.enqueue(.success(
            data: """
            {"connected":true,"workspace_name":"Andy's WS","bot_id":"bot-1"}
            """.data(using: .utf8)!,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        authorizer.nextResult = .success(URL(string: "com.shuiandy.cadenza://auth/notion/callback?attempt=att-1&status=success")!)

        let notion = NotionExportService(
            cadenzaAuth: auth,
            authorizer: authorizer,
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: makeIsolatedDefaults()
        )
        try await notion.connect()

        #expect(notion.isConnected == true)
        #expect(notion.workspaceName == "Andy's WS")
    }

    @Test func connectCancelledKeepsState() async throws {
        let http = FakeAuthHTTP()
        let (auth, _) = signedInAuth(http: http)
        let authorizer = FakeAuthorizationProvider()
        http.enqueue(startResponse())
        authorizer.nextResult = .failure(AuthError.cancelled)
        let notion = NotionExportService(
            cadenzaAuth: auth, authorizer: authorizer,
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: makeIsolatedDefaults())
        do {
            try await notion.connect()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .cancelled)
        }
        #expect(notion.isConnected == false)
    }

    @Test func connectAttemptMismatchThrowsInvalidCallback() async throws {
        let http = FakeAuthHTTP()
        let (auth, _) = signedInAuth(http: http)
        let authorizer = FakeAuthorizationProvider()
        http.enqueue(startResponse(attemptID: "att-1"))
        authorizer.nextResult = .success(URL(string: "com.shuiandy.cadenza://auth/notion/callback?attempt=att-OTHER&status=success")!)
        let notion = NotionExportService(
            cadenzaAuth: auth, authorizer: authorizer,
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: makeIsolatedDefaults())
        do {
            try await notion.connect()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .invalidCallback)
        }
    }

    @Test func connectStatusErrorPropagates() async throws {
        let http = FakeAuthHTTP()
        let (auth, _) = signedInAuth(http: http)
        let authorizer = FakeAuthorizationProvider()
        http.enqueue(startResponse(attemptID: "att-1"))
        authorizer.nextResult = .success(URL(string: "com.shuiandy.cadenza://auth/notion/callback?attempt=att-1&status=error&reason=user_denied")!)
        let notion = NotionExportService(
            cadenzaAuth: auth, authorizer: authorizer,
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: makeIsolatedDefaults())
        do {
            try await notion.connect()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .authorizationDenied)
        }
    }

    @Test func connectWrongHostThrowsInvalidCallback() async throws {
        let http = FakeAuthHTTP()
        let (auth, _) = signedInAuth(http: http)
        let authorizer = FakeAuthorizationProvider()
        http.enqueue(startResponse(attemptID: "att-1"))
        authorizer.nextResult = .success(URL(string: "com.shuiandy.cadenza://other/notion/callback?attempt=att-1&status=success")!)
        let notion = NotionExportService(
            cadenzaAuth: auth, authorizer: authorizer,
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: makeIsolatedDefaults())
        do {
            try await notion.connect()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .invalidCallback)
        }
    }
}

@MainActor
@Suite("NotionExportService — proxy calls")
struct NotionExportProxyTests {
    private func setup(authorizer: FakeAuthorizationProvider = FakeAuthorizationProvider())
            -> (NotionExportService, FakeAuthHTTP, CadenzaAuthService) {
        let http = FakeAuthHTTP()
        let store = InMemoryAuthSecretStore()
        try! writeStoredToken(into: store, value: "tok",
                              expiresAt: Date().addingTimeInterval(3600))
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u", email: "a@b", displayName: "A", pictureURL: nil)
        let auth = try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "u"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "u"))
        )
        let suiteName = "test.notion." + UUID().uuidString
        let notion = NotionExportService(
            cadenzaAuth: auth,
            authorizer: authorizer,
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: UserDefaults(suiteName: suiteName)!
        )
        return (notion, http, auth)
    }

    @Test func fetchDatabasesParsesProxyResponse() async throws {
        let (notion, http, _) = setup()
        let body = """
        {
          "databases": [
            {"id":"db-1","title":"Meetings","icon":null,"url":"https://notion.so/db1"},
            {"id":"db-2","title":"Notes","icon":null,"url":"https://notion.so/db2"}
          ],
          "has_more": false,
          "next_cursor": null
        }
        """.data(using: .utf8)!
        http.enqueue(.success(data: body,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))

        let dbs = try await notion.fetchDatabases()
        #expect(dbs.count == 2)
        #expect(dbs[0].id == "db-1")
        #expect(dbs[1].title == "Notes")
    }

    @Test func fetchDatabasesIntegrationReauthDisconnects() async throws {
        let (notion, http, _) = setup()
        let body = """
        {"code":"integration_reauth_required","integration":"notion"}
        """.data(using: .utf8)!
        http.enqueue(.success(data: body,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 409,
                                      httpVersion: nil, headerFields: nil)!))
        notion.markConnectedForTests()

        do {
            _ = try await notion.fetchDatabases()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .integrationReauthRequired(provider: "notion"))
        }
        #expect(notion.isConnected == false)
    }

    @Test func exportPageSendsIdempotencyKey() async throws {
        let (notion, http, _) = setup()
        let body = """
        {"page_id":"p-1","url":"https://notion.so/p1"}
        """.data(using: .utf8)!
        http.enqueue(.success(data: body,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        let key = UUID().uuidString
        let req = NotionExportRequest(
            databaseID: "db-1",
            properties: ["Title": .string("Standup")],
            blocks: [.heading2("Summary"), .paragraph("...")]
        )
        let result = try await notion.exportPage(req, idempotencyKey: key)
        #expect(result.pageID == "p-1")
        let request = http.requests.first!
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key)
    }

    @Test func exportPageRetriedWithSameKeyHitsBackendOnce() async throws {
        // Simulate: backend returns identical 200 body for replay.
        let (notion, http, _) = setup()
        let body = """
        {"page_id":"p-1","url":"https://notion.so/p1"}
        """.data(using: .utf8)!
        let resp = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        http.enqueue(.success(data: body, response: resp))
        http.enqueue(.success(data: body, response: resp))

        let key = UUID().uuidString
        let req = NotionExportRequest(databaseID: "db-1", properties: [:], blocks: [])
        let r1 = try await notion.exportPage(req, idempotencyKey: key)
        let r2 = try await notion.exportPage(req, idempotencyKey: key)
        #expect(r1.pageID == r2.pageID)
        #expect(http.requests.count == 2)
        #expect(http.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Idempotency-Key") == key
        })
    }
}

@MainActor
@Suite("NotionExportService — forced reconnect")
struct NotionExportForcedReconnectTests {
    private func setup(authorizer: FakeAuthorizationProvider = FakeAuthorizationProvider())
            -> (NotionExportService, FakeAuthHTTP, InMemoryAuthSecretStore) {
        let http = FakeAuthHTTP()
        let store = InMemoryAuthSecretStore()
        try! writeStoredToken(into: store, value: "tok",
                              expiresAt: Date().addingTimeInterval(3600))
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u", email: "a@b", displayName: "A", pictureURL: nil)
        let auth = try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "u"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "u"))
        )
        let legacy = InMemoryAuthSecretStore()
        let suiteName = "test.notion." + UUID().uuidString
        let notion = NotionExportService(
            cadenzaAuth: auth,
            authorizer: authorizer,
            legacyTokenStore: legacy,
            defaults: UserDefaults(suiteName: suiteName)!
        )
        return (notion, http, legacy)
    }

    @Test func detectForcedReconnectSetsFlagWhenLegacyTokenAndMeReturnsNotConnected() async throws {
        let (notion, http, legacy) = setup()
        try legacy.set("legacy-tok", for: "oauth.tokens.notion")
        let body = """
        {"code":"not_connected"}
        """.data(using: .utf8)!
        http.enqueue(.success(data: body,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 404,
                                      httpVersion: nil, headerFields: nil)!))

        await notion.detectForcedReconnect()
        #expect(notion.needsForcedReconnect == true)
    }

    @Test func detectForcedReconnectNoLegacyTokenIsNoop() async throws {
        let (notion, _, _) = setup()
        await notion.detectForcedReconnect()
        #expect(notion.needsForcedReconnect == false)
    }

    @Test func successfulConnectClearsLegacyToken() async throws {
        let authorizer = FakeAuthorizationProvider()
        let (notion, http, legacy) = setup(authorizer: authorizer)
        try legacy.set("legacy-tok", for: "oauth.tokens.notion")

        // Pretend forced-reconnect was detected on launch.
        notion.markForcedReconnectForTests()

        // Drive successful connect.
        http.enqueue(.success(
            data: """
            {"attempt_id":"att-1","authorize_url":"https://api.notion.com/v1/oauth/authorize"}
            """.data(using: .utf8)!,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        http.enqueue(.success(
            data: """
            {"connected":true,"workspace_name":"WS","bot_id":"b"}
            """.data(using: .utf8)!,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        authorizer.nextResult = .success(URL(string: "com.shuiandy.cadenza://auth/notion/callback?attempt=att-1&status=success")!)

        try await notion.connect()
        #expect(legacy.get("oauth.tokens.notion") == nil)
        #expect(notion.needsForcedReconnect == false)
    }
}

@MainActor
@Suite("NotionExportService: transcript speakers")
struct NotionExportTranscriptSpeakerTests {
    private func setup() -> (NotionExportService, FakeAuthHTTP) {
        let http = FakeAuthHTTP()
        let store = InMemoryAuthSecretStore()
        try! writeStoredToken(into: store, value: "tok",
                              expiresAt: Date().addingTimeInterval(3600))
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u", email: "a@b", displayName: "A", pictureURL: nil)
        let auth = try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "u"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "u"))
        )
        let suiteName = "test.notion." + UUID().uuidString
        let notion = NotionExportService(
            cadenzaAuth: auth,
            authorizer: FakeAuthorizationProvider(),
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: UserDefaults(suiteName: suiteName)!
        )
        notion.databaseID = "db-1"
        http.enqueue(.success(
            data: #"{"page_id":"p-1","url":"https://notion.so/p1"}"#.data(using: .utf8)!,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        return (notion, http)
    }

    private func makeDetail(
        entries: [(TimeInterval, String, String?)],
        mappings: [SpeakerLabelMappingDTO] = [],
        suggestions: [SpeakerLabelSuggestionDTO] = []
    ) -> RecordingDetailDTO {
        let date = Date(timeIntervalSince1970: 1_785_628_800)
        let segments = entries.map { start, text, speaker in
            TranscriptEntryDTO(id: UUID(), startTime: start, endTime: start + 4,
                               text: text, speaker: speaker)
        }
        return RecordingDetailDTO(
            id: UUID(),
            title: "Garden club planning",
            startDate: date,
            endDate: date.addingTimeInterval(600),
            duration: 600,
            meetingApp: nil,
            meetingURL: nil,
            language: "en",
            tags: [],
            meetingType: nil,
            lastAccessedDate: nil,
            folderID: nil,
            audioFile: nil,
            linkedCalendarEventID: nil,
            transcript: TranscriptDTO(
                id: UUID(),
                fullText: segments.map(\.text).joined(separator: " "),
                segments: segments,
                detectedLanguage: "en",
                createdAt: date
            ),
            summary: nil,
            speakerMappings: mappings,
            speakerSuggestions: suggestions
        )
    }

    /// Paragraph texts from the single export-page request body.
    private func paragraphs(in http: FakeAuthHTTP) throws -> [String] {
        let body = try #require(http.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let blocks = try #require(json["blocks"] as? [[String: Any]])
        return blocks.compactMap { block in
            block["type"] as? String == "paragraph" ? block["text"] as? String : nil
        }
    }

    @Test func renamedSpeakersUseTheMappedName() async throws {
        let (notion, http) = setup()
        let detail = makeDetail(
            entries: [
                (0, "Seed order is in.", "SPEAKER_00"),
                (75, "Great, thanks.", "SPEAKER_01"),
            ],
            mappings: [
                SpeakerLabelMappingDTO(rawLabel: "SPEAKER_00", profileID: UUID(),
                                       profileName: "Wren Halloway"),
                SpeakerLabelMappingDTO(rawLabel: "SPEAKER_01", profileID: UUID(),
                                       profileName: "Ossian Pike"),
            ]
        )

        try await notion.exportRecording(detail)

        #expect(try paragraphs(in: http) == [
            "[00:00] Wren Halloway: Seed order is in.",
            "[01:15] Ossian Pike: Great, thanks.",
        ])
    }

    @Test func unmappedProviderTokensBecomeFriendlyNames() async throws {
        let (notion, http) = setup()
        let detail = makeDetail(entries: [
            (0, "Morning.", "SPEAKER_00"),
            (5, "Hi there.", "B"),
        ])

        try await notion.exportRecording(detail)

        let first = SpeakerLabelFormatter.displayName(forRawLabel: "SPEAKER_00")
        let second = SpeakerLabelFormatter.displayName(forRawLabel: "B")
        #expect(first != "SPEAKER_00")
        #expect(second != "B")
        #expect(try paragraphs(in: http) == [
            "[00:00] \(first): Morning.",
            "[00:05] \(second): Hi there.",
        ])
    }

    @Test func paddedLabelsMatchMappingsAndBlankLabelsDrop() async throws {
        let (notion, http) = setup()
        let detail = makeDetail(
            entries: [
                (0, "Padded.", "  SPEAKER_02 \n"),
                (2, "Blank.", "   "),
                (4, "Missing.", nil),
            ],
            mappings: [
                SpeakerLabelMappingDTO(rawLabel: "SPEAKER_02", profileID: UUID(),
                                       profileName: "Juno Marsh"),
            ]
        )

        try await notion.exportRecording(detail)

        #expect(try paragraphs(in: http) == [
            "[00:00] Juno Marsh: Padded.",
            "[00:02] Blank.",
            "[00:04] Missing.",
        ])
    }

    @Test func speakerSuggestionsDoNotLeakIntoExport() async throws {
        let (notion, http) = setup()
        let detail = makeDetail(
            entries: [(0, "Who is this?", "SPEAKER_00")],
            suggestions: [
                SpeakerLabelSuggestionDTO(rawLabel: "SPEAKER_00", profileID: UUID(),
                                          profileName: "Thea Quill", score: 0.91,
                                          strategy: "voiceprint"),
            ]
        )

        try await notion.exportRecording(detail)

        let lines = try paragraphs(in: http)
        let fallback = SpeakerLabelFormatter.displayName(forRawLabel: "SPEAKER_00")
        #expect(lines == ["[00:00] \(fallback): Who is this?"])
        #expect(!lines.joined().contains("Thea Quill"))
    }

    // Gemini recordings transcribed before ingest mapped its wire labels
    // store spk:0, spk:1, …: zero-based, so spk:0 is Speaker 1. A rename
    // is keyed on the stored label and still wins.
    @Test func storedGeminiLabelsExportAsSpeakerNumbers() async throws {
        let (notion, http) = setup()
        let detail = makeDetail(
            entries: [
                (0, "Seed order is in.", "spk:0"),
                (5, "Great, thanks.", "spk:1"),
                (9, "Bulbs next week.", "spk:2"),
            ],
            mappings: [
                SpeakerLabelMappingDTO(rawLabel: "spk:1", profileID: UUID(),
                                       profileName: "Ossian Pike"),
            ]
        )

        try await notion.exportRecording(detail)

        let first = SpeakerLabelFormatter.displayName(forRawLabel: "Speaker 1")
        let third = SpeakerLabelFormatter.displayName(forRawLabel: "Speaker 3")
        #expect(try paragraphs(in: http) == [
            "[00:00] \(first): Seed order is in.",
            "[00:05] Ossian Pike: Great, thanks.",
            "[00:09] \(third): Bulbs next week.",
        ])
    }
}
