import Foundation
@testable import Cadenza

/// In-memory `AuthSecretStore` for tests. `@MainActor` to match the
/// protocol's actor isolation; fits the test suite which is also @MainActor.
@MainActor
final class InMemoryAuthSecretStore: AuthSecretStore {
    private var storage: [String: String] = [:]
    var failNextWriteWith: Error?
    var failAllRemoves = false

    struct RemoveFailure: Error {}

    func get(_ key: String) -> String? { storage[key] }

    func getClassified(_ key: String) throws -> String? { storage[key] }

    func set(_ value: String, for key: String) throws {
        if let err = failNextWriteWith {
            failNextWriteWith = nil
            throw err
        }
        storage[key] = value
    }

    func remove(_ key: String) throws {
        if failAllRemoves { throw RemoveFailure() }
        storage.removeValue(forKey: key)
    }
}

/// Canonical bound test identity whose issuer matches the fake backend
/// base URL, so per-profile services in tests exercise the same
/// origin-derivation path as production.
enum AuthTestProfile {
    static let baseURLString = "https://cadenzapp.test/api/v1"
    static let profileID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    static func origin(baseURL: String = baseURLString) -> IssuerOrigin {
        guard let url = URL(string: baseURL), let origin = try? IssuerOrigin(url: url) else {
            fatalError("test base URL must parse")
        }
        return origin
    }

    static func bound(
        userID: String = "u1",
        disposition: Profile.SessionDisposition = .active,
        baseURL: String = baseURLString
    ) -> CadenzaAuthService.SessionProfile {
        let origin = origin(baseURL: baseURL)
        return CadenzaAuthService.SessionProfile(
            profileID: profileID,
            boundAccount: Profile.BoundAccount(
                userID: userID,
                originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: baseURL,
                displayEmail: "a@b.com",
                displayName: "Andy",
                boundAt: Date(timeIntervalSince1970: 1_785_628_800)
            ),
            sessionDisposition: disposition
        )
    }

    static func tokenAccount(baseURL: String = baseURLString) -> String {
        SessionTokenKey.account(
            profileID: profileID, originKey: origin(baseURL: baseURL).originKey
        )
    }

    static func webSyncPreferenceKey(
        _ base: String,
        userID: String = "user-1",
        baseURL: String = baseURLString
    ) -> String {
        WebSyncCoordinator.accountScopedPreferenceKey(
            base: base,
            profileID: profileID,
            originKey: origin(baseURL: baseURL).originKey,
            userID: userID
        )
    }
}

/// Canned-response `AuthHTTP` for tests. `@MainActor`-isolated to match the
/// protocol; plain class with mutable state — no `@unchecked Sendable` needed.
@MainActor
final class FakeAuthHTTP: AuthHTTP {
    enum Outcome {
        case success(data: Data, response: HTTPURLResponse)
        case failure(Error)
    }

    private var queue: [Outcome] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(_ outcome: Outcome) { queue.append(outcome) }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path.hasSuffix("/me/mcp-prefs") == true {
            if let override = mcpPrefsOutcome {
                mcpPrefsOutcome = nil
                requests.append(request)
                switch override {
                case .success(let data, let response): return (data, response)
                case .failure(let error): throw error
                }
            }
            let body = Data(#"{"search_index_enabled":false,"search_index_generation":0,"speaker_identity_enabled":false,"speaker_identity_generation":0,"updated_at":0}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        requests.append(request)
        guard !queue.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch queue.removeFirst() {
        case .success(let data, let response): return (data, response)
        case .failure(let error): throw error
        }
    }

    /// Next `/me/mcp-prefs` uses this instead of the silent default-off body.
    var mcpPrefsOutcome: Outcome?
}

/// `AuthorizationProvider` test fake.
///
/// Two response modes:
///   - `nextResult`: legacy single-fire result (canned URL or error). Tests
///     that don't need to inspect the authorize URL use this.
///   - `onAuthorize`: closure invoked with the actual authorize URL the
///     service built. Tests that need to extract `state` / PKCE values
///     from the authorize URL and synthesise a *matching* callback URL
///     install this closure. The sign-in suite uses it to avoid the
///     "double-fire to capture state" anti-pattern.
///
/// `onAuthorize` takes precedence over `nextResult` when both are set.
@MainActor
final class FakeAuthorizationProvider: AuthorizationProvider {
    enum Result {
        case success(URL)
        case failure(Error)
    }

    var nextResult: Result?
    var onAuthorize: (@MainActor (URL) async throws -> URL)?
    private(set) var receivedURLs: [URL] = []

    func authorize(_ authorizeURL: URL) async throws -> URL {
        receivedURLs.append(authorizeURL)
        if let onAuthorize {
            return try await onAuthorize(authorizeURL)
        }
        guard let result = nextResult else {
            throw AuthError.unknown
        }
        nextResult = nil
        switch result {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }
}
