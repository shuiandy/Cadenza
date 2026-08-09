import Foundation
import Testing
import os
@testable import Cadenza

/// Session-user store fake keeping the pre-profile test surface
/// (`user` / `failNextSaveWith`) while conforming to the per-profile
/// `SessionUserStoring` seam. Lock-based so it satisfies `Sendable`
/// without `@unchecked`.
final class InMemoryUserStore: SessionUserStoring, Sendable {
    private struct State {
        var user: CadenzaAuthService.SignedInUser?
        var failNextSave = false
        var failNextLoad = false
    }

    struct InjectedFailure: Error {}

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var user: CadenzaAuthService.SignedInUser? {
        get { state.withLock { $0.user } }
        set { state.withLock { $0.user = newValue } }
    }

    var failNextSaveWith: Error? {
        get { state.withLock { $0.failNextSave } ? InjectedFailure() : nil }
        set { state.withLock { $0.failNextSave = newValue != nil } }
    }

    func failNextLoad() {
        state.withLock { $0.failNextLoad = true }
    }

    func load() throws -> SessionUser? {
        let (record, fail) = state.withLock { current in
            let fail = current.failNextLoad
            current.failNextLoad = false
            return (current.user, fail)
        }
        if fail { throw InjectedFailure() }
        return record?.sessionUserRecord()
    }

    func save(_ record: SessionUser) throws {
        let fail = state.withLock { current in
            let fail = current.failNextSave
            current.failNextSave = false
            return fail
        }
        if fail { throw InjectedFailure() }
        state.withLock { $0.user = CadenzaAuthService.SignedInUser(sessionUser: record) }
    }

    func remove() throws {
        state.withLock { $0.user = nil }
    }
}

/// Tests write tokens through `InMemoryAuthSecretStore` using the same
/// base64-JSON wire format the real `CadenzaAuthService.storeToken` uses,
/// so the round trip exercises the production decoder. Uses default
/// `JSONEncoder` date encoding (seconds-since-reference-date) — same wire
/// format M2 migrates verbatim, keeping migrated sessions valid.
@MainActor
func writeStoredToken(into store: InMemoryAuthSecretStore,
                      value: String,
                      expiresAt: Date,
                      account: String = AuthTestProfile.tokenAccount()) throws {
    let token = StoredToken(value: value, expiresAt: expiresAt)
    let data = try JSONEncoder().encode(token)
    try store.set(data.base64EncodedString(), for: account)
}

/// Registry document matching the canonical bound test profile — bound
/// services require the registry handle for disposition writes.
@MainActor
func makeAuthRegistryDocument(
    userID: String = "u1",
    disposition: Profile.SessionDisposition = .active,
    baseURL: String = AuthTestProfile.baseURLString
) -> ProfileRegistryDocument {
    let bound = AuthTestProfile.bound(
        userID: userID, disposition: disposition, baseURL: baseURL
    )
    let profile = Profile(
        id: bound.profileID,
        kind: .standard,
        name: "P",
        colorHex: nil,
        createdAt: Date(timeIntervalSince1970: 1_785_628_800),
        lastActiveAt: Date(timeIntervalSince1970: 1_785_628_800),
        audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
        boundAccount: bound.boundAccount,
        lockOnSignOut: false,
        isLocked: false,
        storeMaterialized: true,
        sessionDisposition: disposition
    )
    return ProfileRegistryDocument(
        version: 1, activeProfileID: profile.id, profiles: [profile]
    )
}

@MainActor
private func makeBoundService(
    userID: String = "u1",
    disposition: Profile.SessionDisposition = .active,
    http: FakeAuthHTTP = FakeAuthHTTP(),
    authorizer: FakeAuthorizationProvider = FakeAuthorizationProvider(),
    store: InMemoryAuthSecretStore = InMemoryAuthSecretStore(),
    userStore: InMemoryUserStore = InMemoryUserStore(),
    registry: ProfileRegistryProviding? = nil,
    seedUser: Bool = true
) throws -> CadenzaAuthService {
    if seedUser, userStore.user == nil {
        userStore.user = .init(id: userID, email: "a@b.com", displayName: "Andy", pictureURL: nil)
    }
    return try CadenzaAuthService.bootstrapped(
        sessionProfile: AuthTestProfile.bound(userID: userID, disposition: disposition),
        http: http,
        authorizer: authorizer,
        secretStore: store,
        sessionUserStore: userStore,
        registry: registry ?? ScriptedRegistry(
            document: makeAuthRegistryDocument(userID: userID, disposition: disposition)
        )
    )
}

@MainActor
private func makeUnboundService(
    http: FakeAuthHTTP = FakeAuthHTTP(),
    authorizer: FakeAuthorizationProvider = FakeAuthorizationProvider()
) throws -> CadenzaAuthService {
    try CadenzaAuthService.bootstrapped(
        sessionProfile: .ephemeralUnbound(),
        http: http,
        authorizer: authorizer,
        secretStore: InMemoryAuthSecretStore(),
        sessionUserStore: InMemoryUserStore()
    )
}

@Suite("CadenzaAuthService — boot derivation (classified snapshot)")
struct CadenzaAuthServiceInitTests {
    @MainActor
    @Test func unboundProfileBootsSignedOut() throws {
        let service = try makeUnboundService()
        #expect(service.sessionState == .signedOut)
        #expect(service.isSignedIn == false)
        #expect(service.currentUser == nil)
    }

    @MainActor
    @Test func boundWithFreshTokenAndUserIsSignedIn() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        let service = try makeBoundService(store: store, userStore: userStore)

        #expect(service.sessionState == .signedIn)
        #expect(service.isSignedIn == true)
        #expect(service.currentUser?.email == "a@b.com")
    }

    @MainActor
    @Test func boundWithTokenExpiringInUnder60sIsExpired() throws {
        let store = InMemoryAuthSecretStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(45))
        let service = try makeBoundService(store: store)

        #expect(service.sessionState == .expired)
        #expect(service.isSignedIn == false)
        #expect(service.lastError == .sessionExpired)
    }

    @MainActor
    @Test func boundWithoutTokenIsExpiredNeverSignedOut() throws {
        let service = try makeBoundService()
        #expect(service.sessionState == .expired)
        #expect(service.lastError == .sessionExpired)
    }

    @MainActor
    @Test func explicitSignOutDispositionBootsSignedOut() throws {
        let store = InMemoryAuthSecretStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        let service = try makeBoundService(disposition: .explicitlySignedOut, store: store)
        #expect(service.sessionState == .signedOut)
    }

    @MainActor
    @Test func tokenInvalidatedDispositionBeatsSurvivingValidToken() throws {
        // Resurrection guard: a future-expiry token that survived a failed
        // slot cleanup must not boot signed-in once the durable
        // disposition says the session was invalidated.
        let store = InMemoryAuthSecretStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(86400))
        let service = try makeBoundService(disposition: .tokenInvalidated, store: store)
        #expect(service.sessionState == .expired)
    }

    @MainActor
    @Test func corruptTokenSlotThrowsInsteadOfBootingAState() throws {
        let store = InMemoryAuthSecretStore()
        try store.set("not-base64-json", for: AuthTestProfile.tokenAccount())
        #expect(throws: (any Error).self) {
            _ = try makeBoundService(store: store)
        }
    }

    @MainActor
    @Test func emptyStringTokenSlotIsCorruptNotAbsent() throws {
        let store = InMemoryAuthSecretStore()
        try store.set("", for: AuthTestProfile.tokenAccount())
        // The ephemeral fake stores empty strings verbatim; the classified
        // factory must refuse them rather than reading them as absent.
        if store.get(AuthTestProfile.tokenAccount()) != nil {
            #expect(throws: (any Error).self) {
                _ = try makeBoundService(store: store)
            }
        }
    }

    @MainActor
    @Test func unreadableKeychainThrows() throws {
        let store = ThrowingSecretStore()
        store.failClassifiedReads = true
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u1", email: "a@b.com", displayName: "A", pictureURL: nil)
        #expect(throws: (any Error).self) {
            _ = try CadenzaAuthService.bootstrapped(
                sessionProfile: AuthTestProfile.bound(),
                http: FakeAuthHTTP(),
                authorizer: FakeAuthorizationProvider(),
                secretStore: store,
                sessionUserStore: userStore
            )
        }
    }

    @MainActor
    @Test func missingSessionUserOnBoundProfileThrowsTornArtifacts() throws {
        for tokenState in ["valid", "expired", "absent"] {
            let store = InMemoryAuthSecretStore()
            if tokenState == "valid" {
                try writeStoredToken(into: store, value: "tok",
                                     expiresAt: Date().addingTimeInterval(3600))
            } else if tokenState == "expired" {
                try writeStoredToken(into: store, value: "tok",
                                     expiresAt: Date().addingTimeInterval(-3600))
            }
            #expect(throws: (any Error).self, "token \(tokenState)") {
                _ = try makeBoundService(store: store, seedUser: false)
            }
        }
    }

    @MainActor
    @Test func mismatchedSessionUserIdentityThrows() throws {
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "someone-else", email: "x@y", displayName: "X", pictureURL: nil)
        #expect(throws: (any Error).self) {
            _ = try makeBoundService(userID: "u1", userStore: userStore, seedUser: false)
        }
    }

    @MainActor
    @Test func unreadableSessionUserThrows() throws {
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u1", email: "a@b.com", displayName: "A", pictureURL: nil)
        userStore.failNextLoad()
        #expect(throws: (any Error).self) {
            _ = try makeBoundService(userStore: userStore, seedUser: false)
        }
    }

    @MainActor
    @Test func invalidBoundAccountThrowsInvalidBindingNotUnbound() throws {
        let origin = AuthTestProfile.origin()
        let profile = CadenzaAuthService.SessionProfile(
            profileID: AuthTestProfile.profileID,
            boundAccount: Profile.BoundAccount(
                userID: "u1",
                originKey: "0000000000000000",
                issuerOrigin: origin.normalized,
                apiBaseURL: AuthTestProfile.baseURLString,
                displayEmail: "a@b.com",
                displayName: "Andy",
                boundAt: Date(timeIntervalSince1970: 1_785_628_800)
            ),
            sessionDisposition: .active
        )
        #expect(throws: (any Error).self) {
            _ = try CadenzaAuthService.bootstrapped(
                sessionProfile: profile,
                http: FakeAuthHTTP(),
                authorizer: FakeAuthorizationProvider(),
                secretStore: InMemoryAuthSecretStore(),
                sessionUserStore: InMemoryUserStore()
            )
        }
    }
}

// MARK: - signIn tests

@Suite("CadenzaAuthService — signIn (bound re-login)")
struct CadenzaAuthServiceSignInTests {
    /// Reads `state` from the authorize URL the service built and synthesises
    /// a callback URL that matches it. Used by tests that want to drive the
    /// full sign-in path without the state-mismatch hazard.
    private func matchingCallback(host: String = "auth",
                                  path: String = "/cadenza/callback",
                                  code: String = "abc",
                                  authorizeURL: URL) -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "state" })!.value!
        return URL(string: "com.shuiandy.cadenza://\(host)\(path)?code=\(code)&state=\(state)")!
    }

    private func exchangeOK(userID: String = "u1") -> FakeAuthHTTP.Outcome {
        let exchangeJSON = """
        {
          "token": "tok-123",
          "expires_at": \(Int(Date().addingTimeInterval(86400).timeIntervalSince1970)),
          "user": {
            "id": "\(userID)",
            "email": "andy@example.com",
            "display_name": "Andy",
            "picture": "https://lh3.googleusercontent.com/a/x"
          }
        }
        """.data(using: .utf8)!
        let httpResp = HTTPURLResponse(url: URL(string: "https://x")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        return .success(data: exchangeJSON, response: httpResp)
    }

    @MainActor
    @Test func happyPathSignsInPersistsAndRestoresDisposition() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(exchangeOK())
        // Bound profile whose token expired: the classic re-login entry.
        let registry = ScriptedRegistry(
            document: makeAuthRegistryDocument(disposition: .tokenInvalidated)
        )
        let service = try makeBoundService(
            disposition: .tokenInvalidated,
            http: http, authorizer: authorizer, store: store, userStore: userStore,
            registry: registry
        )
        #expect(service.sessionState == .expired)

        try await service.signIn()
        #expect(service.sessionState == .signedIn)
        #expect(service.currentUser?.email == "andy@example.com")
        #expect(service.currentUser?.pictureURL?.absoluteString
                == "https://lh3.googleusercontent.com/a/x")
        #expect(service.loadStoredToken()?.value == "tok-123")
        #expect(store.get(AuthTestProfile.tokenAccount()) != nil)
        #expect(userStore.user?.id == "u1")
        // Durable disposition restored to active for the next boot.
        #expect(try registry.load().profiles.first?.sessionDisposition == .active)
    }

    @MainActor
    @Test func staleTokenPlusUserSaveFailureNeverActivates() async throws {
        // Resurrection variant: the invalidated session's stale token
        // survived a failed cleanup; the re-login writes a fresh token but
        // the user-record write fails, rolling the slot back to the stale
        // value. Because the disposition commit never ran, the stale token
        // stays durably blocked.
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "stale-tok",
                             expiresAt: Date().addingTimeInterval(86400))
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(exchangeOK())
        let registry = ScriptedRegistry(
            document: makeAuthRegistryDocument(disposition: .tokenInvalidated)
        )
        let service = try makeBoundService(
            disposition: .tokenInvalidated,
            http: http, authorizer: authorizer, store: store, userStore: userStore,
            registry: registry
        )
        #expect(service.sessionState == .expired)
        userStore.failNextSaveWith = InMemoryUserStore.InjectedFailure()

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .localPersistenceFailed = err { /* ok */ } else {
                Issue.record("expected .localPersistenceFailed, got \(err)")
            }
        }
        #expect(service.sessionState == .expired)
        #expect(try registry.load().profiles.first?.sessionDisposition == .tokenInvalidated)

        let relaunched = try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(disposition: .tokenInvalidated),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )
        #expect(relaunched.sessionState == .expired)
    }

    @MainActor
    @Test func dispositionCommitFailureKeepsFreshPairInertAndUnpublished() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(exchangeOK())
        let registry = ScriptedRegistry(
            document: makeAuthRegistryDocument(disposition: .tokenInvalidated)
        )
        let service = try makeBoundService(
            disposition: .tokenInvalidated,
            http: http, authorizer: authorizer, store: store, userStore: userStore,
            registry: registry
        )
        registry.configure { $0.failSaveAt = [1] }

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .localPersistenceFailed = err { /* ok */ } else {
                Issue.record("expected .localPersistenceFailed, got \(err)")
            }
        }
        // Not published; the fresh pair is durably in place but inert
        // under the uncommitted disposition.
        #expect(service.sessionState == .expired)
        #expect(service.loadStoredToken() == nil)
        #expect(store.get(AuthTestProfile.tokenAccount()) != nil)
        #expect(userStore.user?.email == "andy@example.com")
        #expect(try registry.load().profiles.first?.sessionDisposition == .tokenInvalidated)

        let relaunched = try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(disposition: .tokenInvalidated),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )
        #expect(relaunched.sessionState == .expired)
    }

    @MainActor
    @Test func unboundProfileSignInThrowsBindingFlowRequired() async throws {
        let service = try makeUnboundService()
        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .bindingFlowRequired)
        }
        #expect(service.sessionState == .signedOut)
    }

    @MainActor
    @Test func identityMismatchRejectsWithoutPersisting() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(exchangeOK(userID: "someone-else"))
        let service = try makeBoundService(
            http: http, authorizer: authorizer, store: store, userStore: userStore
        )

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .accountMismatch)
        }
        #expect(service.sessionState == .expired)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
        #expect(userStore.user?.id == "u1")
    }

    @MainActor
    @Test func cancelledByUserSurfacesCancelled() async throws {
        let authorizer = FakeAuthorizationProvider()
        authorizer.nextResult = .failure(AuthError.cancelled)
        let service = try makeBoundService(authorizer: authorizer)
        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .cancelled)
        }
        #expect(service.sessionState == .expired)
        #expect(service.lastError == .cancelled)
    }

    @MainActor
    @Test func providerErrorAccessDeniedClassifiesAuthorizationDenied() async throws {
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { _ in
            URL(string: "com.shuiandy.cadenza://auth/cadenza/callback?error=access_denied&state=anything")!
        }
        let service = try makeBoundService(authorizer: authorizer)
        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .authorizationDenied)
        }
    }

    @MainActor
    @Test func wrongCallbackHostThrowsInvalidCallback() async throws {
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { _ in
            URL(string: "com.shuiandy.cadenza://other/cadenza/callback?code=x&state=y")!
        }
        let service = try makeBoundService(authorizer: authorizer)
        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .invalidCallback)
        }
    }

    @MainActor
    @Test func missingCodeThrowsInvalidCallback() async throws {
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { _ in
            URL(string: "com.shuiandy.cadenza://auth/cadenza/callback?state=y")!
        }
        let service = try makeBoundService(authorizer: authorizer)
        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .invalidCallback)
        }
    }

    @MainActor
    @Test func mismatchedStateThrowsStateMismatch() async throws {
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { _ in
            URL(string: "com.shuiandy.cadenza://auth/cadenza/callback?code=x&state=tampered")!
        }
        let service = try makeBoundService(authorizer: authorizer)
        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .stateMismatch)
        }
    }

    @MainActor
    @Test func exchangeServerErrorClassifiesServerNotPartialWrite() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(.success(data: Data(),
            response: HTTPURLResponse(url: URL(string: "https://x")!,
                                      statusCode: 500, httpVersion: nil, headerFields: nil)!))
        let service = try makeBoundService(
            http: http, authorizer: authorizer, store: store, userStore: userStore
        )

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .server(status: 500))
        }
        #expect(service.loadStoredToken() == nil)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
        #expect(service.sessionState == .expired)
    }

    @MainActor
    @Test func exchangeMalformedJSONClassifiesDecoding() async throws {
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(.success(data: Data("{not-json".utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        let service = try makeBoundService(http: http, authorizer: authorizer)

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .decoding = err { /* ok */ } else {
                Issue.record("expected .decoding, got \(err)")
            }
        }
        #expect(service.sessionState == .expired)
    }

    @MainActor
    @Test func authorizerTimeoutSurfacesCallbackTimeout() async throws {
        let authorizer = FakeAuthorizationProvider()
        authorizer.nextResult = .failure(AuthError.callbackTimeout)
        let service = try makeBoundService(authorizer: authorizer)

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .callbackTimeout)
        }
        #expect(service.sessionState == .expired)
        #expect(service.lastError == .callbackTimeout)
    }

    @MainActor
    @Test func storeUserFailureRollsBackToken() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(exchangeOK())
        let service = try makeBoundService(
            http: http, authorizer: authorizer, store: store, userStore: userStore
        )
        userStore.failNextSaveWith = InMemoryUserStore.InjectedFailure()

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .localPersistenceFailed = err { /* ok */ } else {
                Issue.record("expected .localPersistenceFailed, got \(err)")
            }
        }
        #expect(service.loadStoredToken() == nil) // rolled back
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
        #expect(userStore.user?.id == "u1") // prior record restored
        #expect(service.sessionState == .expired)
    }

    @MainActor
    @Test func tokenStoreFailureLeavesEverythingClean() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in matchingCallback(authorizeURL: url) }
        http.enqueue(exchangeOK())
        let service = try makeBoundService(
            http: http, authorizer: authorizer, store: store, userStore: userStore
        )
        store.failNextWriteWith = NSError(domain: "test", code: 2)

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .localPersistenceFailed = err { /* ok */ } else {
                Issue.record("expected .localPersistenceFailed, got \(err)")
            }
        }
        #expect(service.loadStoredToken() == nil)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
        #expect(service.sessionState == .expired)
    }

    @MainActor
    @Test func reentrantCallThrowsAlreadyInProgress() async throws {
        let authorizer = FakeAuthorizationProvider()
        // Hold the first call open until we release it via this continuation.
        var unblockFirst: CheckedContinuation<URL, Error>?
        authorizer.onAuthorize = { _ in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                unblockFirst = cont
            }
        }
        let service = try makeBoundService(authorizer: authorizer)

        async let first: Void = service.signIn()
        // Yield so .signingIn flips.
        for _ in 0..<20 where service.sessionState != .signingIn {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(service.sessionState == .signingIn)

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .alreadyInProgress)
        }

        // Release the held first call so the test exits cleanly.
        unblockFirst?.resume(throwing: AuthError.cancelled)
        _ = try? await first
    }
}

@MainActor
@Suite("CadenzaAuthService — expireSession / signOut")
struct CadenzaAuthServiceLifecycleTests {
    @Test func expireSessionRecordsDurableDispositionAndClearsToken() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        let registry = ScriptedRegistry(document: makeAuthRegistryDocument())
        let service = try makeBoundService(
            store: store, userStore: userStore, registry: registry
        )
        #expect(service.sessionState == .signedIn)

        service.expireSession()

        #expect(service.sessionState == .expired)
        #expect(service.currentUser == nil)
        #expect(service.lastError == .sessionExpired)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
        #expect(userStore.user != nil)  // user record survives (INV-3)
        // Registry carries the durable invalidation for the next boot.
        #expect(try registry.load().profiles.first?.sessionDisposition == .tokenInvalidated)
    }

    @Test func expireSessionSurvivesTokenRemovalFailureDurably() throws {
        // Future-expiry token + failing removal: without the durable
        // disposition, the next boot would resurrect `.signedIn`.
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(86400))
        let registry = ScriptedRegistry(document: makeAuthRegistryDocument())
        let service = try makeBoundService(
            store: store, userStore: userStore, registry: registry
        )
        #expect(service.sessionState == .signedIn)
        store.failAllRemoves = true
        store.failNextWriteWith = NSError(domain: "test", code: 9)

        service.expireSession()
        #expect(service.sessionState == .expired)
        // Slot cleanup failed — the surviving token still has a future
        // expiry, but the registry disposition is durable...
        #expect(store.get(AuthTestProfile.tokenAccount()) != nil)
        let disposition = try registry.load().profiles.first?.sessionDisposition
        #expect(disposition == .tokenInvalidated)

        // ...so a relaunch derives `.expired`, not `.signedIn`.
        var document = try registry.load()
        document.profiles[0].sessionDisposition = disposition ?? .active
        let relaunched = try CadenzaAuthService.bootstrapped(
            sessionProfile: .init(profile: document.profiles[0]),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )
        #expect(relaunched.sessionState == .expired)
    }

    @Test func expireSessionRegistryFailureWithSuccessfulRemovalStaysSafe() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(86400))
        let registry = ScriptedRegistry(document: makeAuthRegistryDocument())
        let service = try makeBoundService(
            store: store, userStore: userStore, registry: registry
        )
        registry.configure { $0.failSaveAt = [1] }

        service.expireSession()
        #expect(service.sessionState == .expired)
        // The emptied slot is the durable fact; the state is recoverable.
        #expect(service.lastError == .sessionExpired)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)

        let relaunched = try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )
        #expect(relaunched.sessionState == .expired)
    }

    @Test func expireSessionWithEveryDurableWriteFailingSurfacesExplicitError() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(86400))
        let registry = ScriptedRegistry(document: makeAuthRegistryDocument())
        let service = try makeBoundService(
            store: store, userStore: userStore, registry: registry
        )
        registry.configure { $0.failSaveAt = [1] }
        store.failAllRemoves = true
        store.failNextWriteWith = NSError(domain: "test", code: 9)

        service.expireSession()
        // Nothing durable recorded the expiry — explicitly reported, never
        // claimed recoverable.
        #expect(service.sessionState == .expired)
        #expect(service.lastError == .sessionCleanupFailed)
        #expect(store.get(AuthTestProfile.tokenAccount()) != nil)
        #expect(try registry.load().profiles.first?.sessionDisposition == .active)
    }

    @Test func expireSessionWhileSignedOutIsNoop() throws {
        let service = try makeUnboundService()
        #expect(service.sessionState == .signedOut)
        service.expireSession()
        #expect(service.sessionState == .signedOut)
        #expect(service.lastError == nil)
    }

    @Test func signOutClearsTokenButKeepsSessionUserRecord() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        let service = try makeBoundService(store: store, userStore: userStore)

        service.signOut()

        #expect(service.sessionState == .signedOut)
        #expect(service.currentUser == nil)
        #expect(service.lastError == nil)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
        // §6.1: the record stays so a locked profile can show whose it is;
        // the durable disposition/lock writes belong to the sign-out
        // orchestration, not this service.
        #expect(userStore.user != nil)
    }
}

@MainActor
@Suite("CadenzaAuthService — request() 401 / 409 routing")
struct CadenzaAuthServiceRequestTests {
    private func signedInService(http: FakeAuthHTTP)
            throws -> (CadenzaAuthService, InMemoryAuthSecretStore, InMemoryUserStore) {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        let service = try makeBoundService(http: http, store: store, userStore: userStore)
        return (service, store, userStore)
    }

    private func unauthorizedResponse(url: String = "https://x") -> FakeAuthHTTP.Outcome {
        let resp = HTTPURLResponse(url: URL(string: url)!, statusCode: 401,
                                   httpVersion: nil, headerFields: nil)!
        return .success(data: Data(), response: resp)
    }

    @Test func unauthorizedOnProxyPathExpiresSession() async throws {
        let http = FakeAuthHTTP()
        let (service, store, _) = try signedInService(http: http)
        http.enqueue(unauthorizedResponse())

        do {
            _ = try await service.request(path: "integrations/notion/databases/search",
                                          method: "POST", body: Data())
            Issue.record("expected throw")
        } catch { /* ignore */ }

        #expect(service.sessionState == .expired)
        #expect(store.get(AuthTestProfile.tokenAccount()) == nil)
    }

    @Test func requestsTargetTheBoundIssuerOriginOnly() async throws {
        let http = FakeAuthHTTP()
        let (service, _, _) = try signedInService(http: http)
        http.enqueue(.success(data: Data("{}".utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!))
        _ = try await service.request(path: "recordings", method: "GET", body: nil)
        let sent = try #require(http.requests.first?.url)
        #expect(AuthTestProfile.origin().covers(requestURL: sent))
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func unauthorizedOnExchangePathDoesNotExpire() async throws {
        let http = FakeAuthHTTP()
        let (service, _, _) = try signedInService(http: http)
        http.enqueue(unauthorizedResponse())

        do {
            _ = try await service.request(path: "auth/desktop/exchange",
                                          method: "POST", body: Data())
            Issue.record("expected throw")
        } catch { /* ignore */ }

        #expect(service.sessionState == .signedIn)  // unchanged
        #expect(service.loadStoredToken()?.value == "tok")  // token intact
    }

    @Test func concurrentUnauthorizedsTriggerSingleStateTransition() async throws {
        let http = FakeAuthHTTP()
        let (service, _, _) = try signedInService(http: http)
        http.enqueue(unauthorizedResponse())
        http.enqueue(unauthorizedResponse())

        async let a: () = {
            _ = try? await service.request(path: "integrations/notion/me",
                                           method: "GET", body: nil)
        }()
        async let b: () = {
            _ = try? await service.request(path: "integrations/notion/databases/search",
                                           method: "POST", body: Data())
        }()
        _ = await (a, b)

        #expect(service.sessionState == .expired)
    }

    @Test func conflictWithIntegrationReauthRequiredEnvelopeThrowsTypedError() async throws {
        let http = FakeAuthHTTP()
        let (service, _, _) = try signedInService(http: http)
        let body = """
        { "code": "integration_reauth_required", "message": "Reconnect Notion", "integration": "notion" }
        """.data(using: .utf8)!
        let resp = HTTPURLResponse(url: URL(string: "https://x")!,
                                   statusCode: 409, httpVersion: nil, headerFields: nil)!
        http.enqueue(.success(data: body, response: resp))

        do {
            _ = try await service.request(path: "integrations/notion/databases/search",
                                          method: "POST", body: Data())
            Issue.record("expected throw")
        } catch let err as AuthError {
            #expect(err == .integrationReauthRequired(provider: "notion"))
        }
        #expect(service.sessionState == .signedIn)  // Cadenza session intact
    }

    // MARK: - Local-expiry flips session to .expired

    @Test func expiredLocalTokenTransitionsToExpiredOnRequest() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        // Just over the 60s skew: valid at boot, expired shortly after.
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(61.0))
        let service = try makeBoundService(store: store, userStore: userStore)
        #expect(service.sessionState == .signedIn)

        try await Task.sleep(for: .seconds(1.3))

        do {
            _ = try await service.request(path: "x", method: "GET", body: nil)
            Issue.record("expected throw")
        } catch { /* notSignedIn expected */ }
        #expect(service.sessionState == .expired)
    }

    // MARK: - Backend error description must not leak envelope.message

    @Test func backendErrorDescriptionDoesNotLeakEnvelopeMessage() {
        let envelope = BackendErrorEnvelope(
            code: "rate_limited", message: "Too many requests for user 12345",
            integration: nil, upstreamStatus: nil, retryAfter: 60)
        let err = CadenzaAPIError.backend(envelope: envelope, status: 429)
        let rendered = "\(err)"
        #expect(!rendered.contains("Too many requests"))
        #expect(!rendered.contains("12345"))
        #expect(rendered.contains("rate_limited"))
        #expect(rendered.contains("429"))
    }

    // MARK: - Signed-out session does not mutate lastError on 409

    @Test func signedOutSessionDoesNotMutateLastErrorOn409() async throws {
        // An unbound (signed-out) service refuses before any HTTP happens.
        let service = try makeUnboundService()
        #expect(service.sessionState == .signedOut)
        do {
            _ = try await service.request(path: "integrations/notion/me",
                                          method: "GET", body: nil)
            Issue.record("expected throw")
        } catch { /* notSignedIn — request never reaches HTTP */ }
        #expect(service.lastError == nil)
    }
}

@MainActor
@Suite("CadenzaAuthService — clearIntegrationReauth")
struct CadenzaAuthServiceClearReauthTests {
    private func signedInService(http: FakeAuthHTTP) throws -> CadenzaAuthService {
        let store = InMemoryAuthSecretStore()
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        return try makeBoundService(http: http, store: store)
    }

    @Test func clearIntegrationReauthAfter409DropsMatchingProvider() async throws {
        let http = FakeAuthHTTP()
        let service = try signedInService(http: http)
        // Drive a 409 to populate lastError = .integrationReauthRequired(provider: "notion").
        let body = """
        {"code":"integration_reauth_required","integration":"notion"}
        """.data(using: .utf8)!
        http.enqueue(.success(data: body,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 409,
                                      httpVersion: nil, headerFields: nil)!))
        do {
            _ = try await service.request(path: "integrations/notion/me",
                                          method: "GET", body: nil)
            Issue.record("expected throw")
        } catch { /* ignore */ }
        #expect(service.lastError == .integrationReauthRequired(provider: "notion"))

        // Now clear with the matching provider — should drop to nil.
        service.clearIntegrationReauth(for: "notion")
        #expect(service.lastError == nil)
    }

    @Test func clearIntegrationReauthIgnoresMismatchedProvider() async throws {
        let http = FakeAuthHTTP()
        let service = try signedInService(http: http)
        let body = """
        {"code":"integration_reauth_required","integration":"notion"}
        """.data(using: .utf8)!
        http.enqueue(.success(data: body,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 409,
                                      httpVersion: nil, headerFields: nil)!))
        do {
            _ = try await service.request(path: "integrations/notion/me",
                                          method: "GET", body: nil)
            Issue.record("expected throw")
        } catch {}

        // Mismatched provider — should leave lastError untouched.
        service.clearIntegrationReauth(for: "google_calendar")
        #expect(service.lastError == .integrationReauthRequired(provider: "notion"))
    }
}

// MARK: - Construction seal

@Suite("CadenzaAuthService — construction seal")
struct CadenzaAuthServiceConstructionSealTests {
    /// The live startup must build the auth service exclusively through
    /// the classified `bootstrapped` factory; no production call site may
    /// construct AppState without injecting it.
    @Test func liveStartupUsesBootstrappedFactoryOnly() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let appFile = repoRoot.appendingPathComponent("Cadenza/App/CadenzaApp.swift")
        let contents = try String(contentsOf: appFile, encoding: .utf8)
        #expect(contents.contains("CadenzaAuthService.bootstrapped("))
        #expect(!contents.contains("AppState()"))
        #expect(!contents.contains("CadenzaAuthService(sessionProfile:"))

        let appStateFile = repoRoot.appendingPathComponent("Cadenza/App/AppState.swift")
        let appState = try String(contentsOf: appStateFile, encoding: .utf8)
        #expect(appState.contains("precondition("))
    }
}

// MARK: - Classified disposition writes and fresh authority

@Suite("CadenzaAuthService — disposition authority")
struct CadenzaAuthDispositionAuthorityTests {
    @MainActor
    private func reloginService(
        registry: ScriptedRegistry,
        store: InMemoryAuthSecretStore = InMemoryAuthSecretStore(),
        userStore: InMemoryUserStore = InMemoryUserStore(),
        http: FakeAuthHTTP,
        authorizer: FakeAuthorizationProvider
    ) throws -> CadenzaAuthService {
        if userStore.user == nil {
            userStore.user = .init(id: "u1", email: "a@b.com", displayName: "Andy", pictureURL: nil)
        }
        return try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(disposition: .tokenInvalidated),
            http: http,
            authorizer: authorizer,
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )
    }

    @MainActor
    private func makeRelogin(
        registry: ScriptedRegistry
    ) throws -> (CadenzaAuthService, InMemoryAuthSecretStore) {
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first(where: { $0.name == "state" })!.value!
            return URL(
                string: "com.shuiandy.cadenza://auth/cadenza/callback?code=abc&state=\(state)"
            )!
        }
        let exchangeJSON = """
        {
          "token": "tok-123",
          "expires_at": \(Int(Date().addingTimeInterval(86400).timeIntervalSince1970)),
          "user": { "id": "u1", "email": "a@b.com", "display_name": "Andy", "picture": null }
        }
        """
        http.enqueue(.success(
            data: Data(exchangeJSON.utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!
        ))
        let store = InMemoryAuthSecretStore()
        let service = try reloginService(
            registry: registry, store: store, http: http, authorizer: authorizer
        )
        return (service, store)
    }

    /// The disposition save landed before throwing: classification
    /// proves the commit and the sign-in publishes — never reported as
    /// failed with a live active registry row.
    @MainActor
    @Test func dispositionSaveThatActuallyPersistedPublishes() async throws {
        let registry = ScriptedRegistry(
            document: makeAuthRegistryDocument(disposition: .tokenInvalidated)
        )
        let (service, _) = try makeRelogin(registry: registry)
        registry.configure { $0.persistThenThrowAt = [1] }

        try await service.signIn()
        #expect(service.sessionState == .signedIn)
        #expect(try registry.load().profiles.first?.sessionDisposition == .active)
    }

    /// A third-shape disposition save stays unpublished.
    @MainActor
    @Test func dispositionThirdShapeSaveStaysUnpublished() async throws {
        let registry = ScriptedRegistry(
            document: makeAuthRegistryDocument(disposition: .tokenInvalidated)
        )
        let (service, _) = try makeRelogin(registry: registry)
        registry.configure { $0.thirdShapeOnSaveAt = [1] }

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .localPersistenceFailed = err {
                // Unclassifiable disposition commit stays unpublished.
            } else {
                Issue.record("expected localPersistenceFailed, got \(err)")
            }
        } catch {
            Issue.record("expected AuthError, got \(error)")
        }
        #expect(service.sessionState == .expired)
    }

    /// Fresh-authority matrix: a stale service must not flip a
    /// disposition on a profile that is inactive, locked, mid-operation,
    /// rebound, or already transitioned by another instance.
    @MainActor
    @Test(arguments: ["inactive", "locked", "pending", "rebound", "drift"])
    func staleAuthorityRefusesDispositionWrite(mode: String) async throws {
        var document = makeAuthRegistryDocument(disposition: .tokenInvalidated)
        switch mode {
        case "inactive":
            var other = document.profiles[0]
            other.id = UUID()
            other.name = "Other"
            other.boundAccount = nil
            document.profiles.append(other)
            document.activeProfileID = other.id
        case "locked":
            // Still the active profile: exercises the locked-active
            // guard, not the inactive one.
            document.profiles[0].isLocked = true
        case "pending":
            var standard = document.profiles[0]
            standard.id = UUID()
            standard.name = "T"
            standard.boundAccount = nil
            standard.storeMaterialized = false
            document.profiles.append(standard)
            let origin = AuthTestProfile.origin()
            document.pendingBinding = PendingBinding(
                transactionID: UUID(),
                profileID: standard.id,
                userID: "u9",
                originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: AuthTestProfile.baseURLString,
                tokenDigest: SessionTokenDigest.digest(of: "raw"),
                createdProfile: false,
                startedAt: Date(timeIntervalSince1970: 1_785_628_800)
            )
        case "rebound":
            document.profiles[0].boundAccount?.userID = "use\u{0301}r-x"
        case "drift":
            document.profiles[0].sessionDisposition = .explicitlySignedOut
        default:
            Issue.record("unknown mode \(mode)")
            return
        }
        try document.validate()
        let registry = ScriptedRegistry(document: document)
        let (service, _) = try makeRelogin(registry: registry)

        do {
            try await service.signIn()
            Issue.record("expected throw")
        } catch let err as AuthError {
            if case .localPersistenceFailed = err {
                // The refused disposition write surfaces here.
            } else {
                Issue.record("expected localPersistenceFailed, got \(err)")
            }
        } catch {
            Issue.record("expected AuthError, got \(error)")
        }
        // The concurrent instance's registry state stands untouched: the
        // refusal happened at the fresh load, before any save.
        #expect(registry.saveCount == 0)
        let after = try registry.load()
        #expect(after.profiles.first?.sessionDisposition != .active)
    }

    /// Registry disposition write that persisted despite throwing counts
    /// as the durable expiry record even when every Keychain cleanup
    /// fails.
    @MainActor
    @Test func expireSessionPersistThenThrowCountsDurable() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u1", email: "a@b.com", displayName: "Andy", pictureURL: nil)
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(86400))
        let registry = ScriptedRegistry(document: makeAuthRegistryDocument())
        let service = try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )
        #expect(service.sessionState == .signedIn)
        registry.configure { $0.persistThenThrowAt = [1] }
        store.failAllRemoves = true
        store.failNextWriteWith = NSError(domain: "test", code: 9)

        service.expireSession()
        #expect(service.sessionState == .expired)
        // Durable through the committed registry write; never
        // sessionCleanupFailed.
        #expect(service.lastError == .sessionExpired)
        #expect(try registry.load().profiles.first?.sessionDisposition == .tokenInvalidated)
    }

    /// Snapshot identity is byte-exact: a canonically equivalent
    /// session-user record is a different account and halts the boot.
    @MainActor
    @Test func snapshotRefusesCanonicallyEquivalentUserRecord() throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        // Valid token in the expected slot, so the walk reaches the
        // identity comparison instead of exiting on token evidence.
        try writeStoredToken(into: store, value: "tok",
                             expiresAt: Date().addingTimeInterval(3600))
        userStore.user = .init(
            id: "use\u{0301}r-1", email: "a@b.com", displayName: "Andy", pictureURL: nil
        )
        do {
            _ = try CadenzaAuthService.loadSessionSnapshot(
                sessionProfile: AuthTestProfile.bound(userID: "us\u{00E9}r-1"),
                secretStore: store,
                sessionUserStore: userStore
            )
            Issue.record("expected throw")
        } catch CadenzaAuthService.SessionEvidenceError.identityMismatch {
            // Byte-distinct identity refused.
        } catch {
            Issue.record("expected identityMismatch, got \(error)")
        }
    }
}

// MARK: - Stable-ID identity (INV-4)

@Suite("CadenzaAuthService — stable userID identity")
struct CadenzaAuthStableIdentityTests {
    /// Identity is the stable userID, never the email: a changed email
    /// on re-login is display data and must not refuse the session.
    @MainActor
    @Test func reloginAcceptsChangedEmailForSameUserID() async throws {
        let store = InMemoryAuthSecretStore()
        let userStore = InMemoryUserStore()
        userStore.user = .init(id: "u1", email: "old@example.com", displayName: "Andy", pictureURL: nil)
        let http = FakeAuthHTTP()
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first(where: { $0.name == "state" })!.value!
            return URL(
                string: "com.shuiandy.cadenza://auth/cadenza/callback?code=abc&state=\(state)"
            )!
        }
        let exchangeJSON = """
        {
          "token": "tok-123",
          "expires_at": \(Int(Date().addingTimeInterval(86400).timeIntervalSince1970)),
          "user": { "id": "u1", "email": "new@example.com", "display_name": "Andy", "picture": null }
        }
        """
        http.enqueue(.success(
            data: Data(exchangeJSON.utf8),
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!
        ))
        let registry = ScriptedRegistry(
            document: makeAuthRegistryDocument(disposition: .tokenInvalidated)
        )
        let service = try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(disposition: .tokenInvalidated),
            http: http,
            authorizer: authorizer,
            secretStore: store,
            sessionUserStore: userStore,
            registry: registry
        )

        try await service.signIn()
        #expect(service.sessionState == .signedIn)
        #expect(service.currentUser?.id == "u1")
        #expect(service.currentUser?.email == "new@example.com")
    }
}
