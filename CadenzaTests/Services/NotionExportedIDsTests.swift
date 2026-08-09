import Foundation
import Testing
@testable import Cadenza

@MainActor
@Suite("NotionExportService — fetchExportedRecordingIDs")
struct NotionExportedIDsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.notion." + UUID().uuidString)!
    }

    private func signedInAuth(http: FakeAuthHTTP) -> CadenzaAuthService {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try! writeStoredToken(into: store, value: "tok",
                              expiresAt: Date().addingTimeInterval(3600))
        userStore.user = .init(id: "u", email: "a@b", displayName: "A", pictureURL: nil)
        return try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "u"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "u")))
    }

    private func makeService(http: FakeAuthHTTP) -> NotionExportService {
        NotionExportService(
            cadenzaAuth: signedInAuth(http: http),
            authorizer: FakeAuthorizationProvider(),
            legacyTokenStore: InMemoryAuthSecretStore(),
            defaults: makeIsolatedDefaults())
    }

    private func ok(_ json: String) -> FakeAuthHTTP.Outcome {
        .success(data: json.data(using: .utf8)!,
                 response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!)
    }

    @Test func parsesIDsAndIgnoresMalformed() async throws {
        let http = FakeAuthHTTP()
        let a = UUID(), b = UUID()
        http.enqueue(ok("""
        {"recording_ids": ["\(a.uuidString)", "not-a-uuid", "\(b.uuidString)"]}
        """))
        let service = makeService(http: http)

        let ids = try await service.fetchExportedRecordingIDs()
        #expect(ids == [a, b])

        // GET、正确路径
        let request = http.requests.last!
        #expect(request.httpMethod == "GET")
        #expect(request.url!.path.hasSuffix("integrations/notion/exported-ids"))
    }

    @Test func emptyListParses() async throws {
        let http = FakeAuthHTTP()
        http.enqueue(ok(#"{"recording_ids": []}"#))
        let service = makeService(http: http)
        let ids = try await service.fetchExportedRecordingIDs()
        #expect(ids.isEmpty)
    }

    @Test func malformedBodyThrowsDecoding() async {
        let http = FakeAuthHTTP()
        http.enqueue(ok(#"{"unexpected": true}"#))
        let service = makeService(http: http)
        do {
            _ = try await service.fetchExportedRecordingIDs()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .decoding = err {
                // expected
            } else {
                Issue.record("expected .decoding, got \(err)")
            }
        } catch {
            Issue.record("expected AuthError.decoding, got \(error)")
        }
    }

    @Test func serverErrorPropagates() async {
        let http = FakeAuthHTTP()
        http.enqueue(.success(
            data: Data("{}".utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 404,
                                      httpVersion: nil, headerFields: nil)!))
        let service = makeService(http: http)
        do {
            _ = try await service.fetchExportedRecordingIDs()
            Issue.record("expected throw on 404")
        } catch {
            // Backend without the endpoint must surface as an error —
            // bulk export shows it instead of silently pushing everything.
        }
    }
}
