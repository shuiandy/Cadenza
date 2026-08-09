import Foundation
import Testing
@testable import Cadenza

@Suite("AuthFakes")
struct AuthFakesTests {
    @MainActor
    @Test func inMemorySecretStoreRoundTrips() throws {
        let store = InMemoryAuthSecretStore()
        try store.set("hunter2", for: "key")
        #expect(store.get("key") == "hunter2")
        try store.remove("key")
        #expect(store.get("key") == nil)
    }

    @MainActor
    @Test func fakeAuthHTTPReturnsCannedResponse() async throws {
        let http = FakeAuthHTTP()
        let url = URL(string: "https://example.com")!
        http.enqueue(.success(data: Data("hello".utf8),
                              response: HTTPURLResponse(url: url, statusCode: 200,
                                                       httpVersion: nil, headerFields: nil)!))
        let (data, response) = try await http.data(for: URLRequest(url: url))
        #expect(String(data: data, encoding: .utf8) == "hello")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @MainActor
    @Test func fakeAuthorizationProviderReturnsCannedURL() async throws {
        let provider = FakeAuthorizationProvider()
        let canned = URL(string: "com.shuiandy.cadenza://auth/cadenza/callback?code=abc&state=xyz")!
        provider.nextResult = .success(canned)
        let result = try await provider.authorize(URL(string: "https://cadenzapp.com/auth/desktop/start")!)
        #expect(result == canned)
    }
}
