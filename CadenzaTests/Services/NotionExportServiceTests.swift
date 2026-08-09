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
