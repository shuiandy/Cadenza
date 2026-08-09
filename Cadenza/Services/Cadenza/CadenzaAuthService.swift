import Foundation

/// Handles the Mac app's OAuth (PKCE) login flow against cadenzapp.com.
///
/// Flow (RFC 8252 / OAuth 2.0 for Native Apps + custom URL scheme):
///
///   1. Generate `code_verifier` + SHA-256 `code_challenge` + opaque `state`.
///   2. Invoke `AuthorizationProvider.authorize(_:)` (production:
///      `OAuthCoordinator` using `ASWebAuthenticationSession`), which opens
///      the browser to `https://cadenzapp.com/api/v1/auth/desktop/start?...`.
///      The backend sets a transient cookie containing (state, challenge,
///      redirect_uri) and 302s into Google's OIDC consent.
///   3. After Google, the backend 302s the browser to the custom-scheme
///      redirect `com.shuiandy.cadenza://auth/cadenza/callback?code=&state=`.
///      The OS delivers this URL back to the app.
///   4. We validate the callback (scheme, host, path, error param), extract
///      `code` + `state`, and verify `state` matches.
///   5. POST `{ code, code_verifier, redirect_uri }` to `/auth/desktop/exchange`.
///      The backend validates the verifier, mints a session row, and returns
///      a Bearer token + user info.
///   6. Token + user are atomically persisted (Keychain + UserDefaults).
///      The token is sent on every subsequent backend call as `Authorization: Bearer`.
///
/// The class also exposes `request(path:method:body:)` — the canonical
/// helper for any other Mac-side service that needs to call the backend.
@Observable @MainActor
final class CadenzaAuthService {
    // MARK: - Session state

    enum SessionState: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn
        case expired
    }

    // MARK: - Public API types

    struct SignedInUser: Codable, Equatable, Sendable {
        let id: String
        let email: String
        let displayName: String
        /// Picture URL; `nil` if the backend didn't supply one.
        /// Field name matches the Codable synthesised key (`pictureURL`).
        /// The exchange-response transform in `signIn()` maps server's
        /// `picture` string to a `URL` before constructing this struct.
        let pictureURL: URL?
    }

    // MARK: - Observable state

    private(set) var sessionState: SessionState = .signedOut
    private(set) var currentUser: SignedInUser?
    private(set) var lastError: AuthError?
    var onSessionChanged: ((SessionState, SignedInUser?) -> Void)?

    /// Set by `CadenzaApp` so legacy callers passing `openURL` keep working
    /// during this phase; new code should rely on `OAuthCoordinator` instead.
    var openURLHandler: (@Sendable (URL) -> Void)?

    /// Computed from observable stored fields — no keychain reads, no
    /// `@ViewBuilder` nesting hazards.
    var isSignedIn: Bool { sessionState == .signedIn && currentUser != nil }
    var isConnecting: Bool { sessionState == .signingIn }

    /// Legacy `String?` surface kept so existing views (`IntegrationsSettingsView`)
    /// compile without changes during D1. E-phase tasks will migrate views to
    /// `lastError` / `AuthErrorBanner` and remove this shim.
    var error: String? { lastError?.errorDescription }

    // MARK: - Profile identity (INV-5)

    /// The profile this service is bound to for its whole lifetime — one
    /// service per process, created only after the active ProfileContext
    /// is resolved (§5.3). Switching profiles relaunches the app.
    struct SessionProfile: Equatable, Sendable {
        let profileID: UUID
        let boundAccount: Profile.BoundAccount?
        let sessionDisposition: Profile.SessionDisposition

        init(
            profileID: UUID,
            boundAccount: Profile.BoundAccount?,
            sessionDisposition: Profile.SessionDisposition
        ) {
            self.profileID = profileID
            self.boundAccount = boundAccount
            self.sessionDisposition = sessionDisposition
        }

        init(profile: Profile) {
            self.init(
                profileID: profile.id,
                boundAccount: profile.boundAccount,
                sessionDisposition: profile.sessionDisposition
            )
        }

        /// Unbound in-memory identity for TestHost and previews: derives
        /// `.signedOut`, owns no token slot, and can never issue requests.
        static func ephemeralUnbound() -> SessionProfile {
            SessionProfile(profileID: UUID(), boundAccount: nil, sessionDisposition: .active)
        }
    }

    /// Fully-classified durable session evidence, resolved by the
    /// throwing factory before the service exists. The init consumes this
    /// snapshot and performs no store reads of its own, so every boot
    /// distinction — valid / expired / definitely absent / unknown-or-
    /// corrupt — is decided in one classified place and unknowns halt the
    /// live boot instead of being guessed into a state.
    struct SessionSnapshot: Equatable {
        enum TokenEvidence: Equatable {
            case valid(StoredToken)
            case expired(StoredToken)
            /// Definite absence (classified not-found), never an error
            /// collapsed into nil.
            case absent
        }

        let token: TokenEvidence
        /// Identity-verified session-user record, or nil for definite
        /// absence. Mismatched or unreadable records never reach here —
        /// the factory throws.
        let user: SessionUser?

        static let empty = SessionSnapshot(token: .absent, user: nil)
    }

    enum SessionEvidenceError: Error {
        /// A boundAccount whose issuer or origin key fails validation is
        /// corrupt binding state — never treated as unbound.
        case invalidBinding
        /// A bound service must hold the registry handle: session
        /// disposition writes are part of its transactional contract.
        case registryRequired
        case tokenUnreadable(String)
        case tokenCorrupt
        case userUnreadable(String)
        /// Every legal path through binding, M2, sign-out, and session
        /// refresh leaves a session-user record on a bound profile; its
        /// definite absence is a torn artifact set.
        case sessionUserMissing
        /// The session-user record names a different account than the
        /// profile's binding — corrupt binding artifacts, never adopted.
        case identityMismatch
    }

    /// Classified read of the profile's durable session artifacts.
    /// Definite token absence is data; a missing session-user on a bound
    /// profile is not — no legal state produces it. Anything unreadable
    /// or inconsistent throws so the live boot halts rather than
    /// presenting a guessed session state.
    static func loadSessionSnapshot(
        sessionProfile: SessionProfile,
        secretStore: AuthSecretStore,
        sessionUserStore: SessionUserStoring
    ) throws -> SessionSnapshot {
        guard let bound = sessionProfile.boundAccount else {
            return .empty
        }
        guard let origin = try? IssuerOrigin(validating: bound.issuerOrigin),
              origin.originKey == bound.originKey else {
            throw SessionEvidenceError.invalidBinding
        }
        let account = SessionTokenKey.account(
            profileID: sessionProfile.profileID, originKey: origin.originKey
        )
        let raw: String?
        do {
            raw = try secretStore.getClassified(account)
        } catch {
            throw SessionEvidenceError.tokenUnreadable(String(describing: error))
        }
        let token: SessionSnapshot.TokenEvidence
        if let raw {
            // An empty string is not a representable token value — it is a
            // corrupt slot, not an absent one.
            guard !raw.isEmpty,
                  let data = Data(base64Encoded: raw),
                  let stored = try? JSONDecoder().decode(StoredToken.self, from: data) else {
                throw SessionEvidenceError.tokenCorrupt
            }
            token = stored.expiresAt.timeIntervalSinceNow > 60 ? .valid(stored) : .expired(stored)
        } else {
            token = .absent
        }

        let user: SessionUser?
        do {
            user = try sessionUserStore.load()
        } catch {
            throw SessionEvidenceError.userUnreadable(String(describing: error))
        }
        guard let user else {
            throw SessionEvidenceError.sessionUserMissing
        }
        guard AccountIdentity.matches(user.userID, bound.userID) else {
            throw SessionEvidenceError.identityMismatch
        }
        return SessionSnapshot(token: token, user: user)
    }

    /// The single construction path for a profile-bound service (§5.3):
    /// classify the durable evidence, then build the service from the
    /// snapshot. Throws on unknown-or-corrupt evidence — the caller halts
    /// the boot. The raw initializer is private so no code can inject a
    /// fabricated snapshot around this classification.
    static func bootstrapped(
        sessionProfile: SessionProfile,
        http: AuthHTTP = URLSession.shared,
        authorizer: AuthorizationProvider = OAuthCoordinator.shared,
        secretStore: AuthSecretStore,
        sessionUserStore: SessionUserStoring,
        registry: ProfileRegistryProviding? = nil,
        newLoginBackend: @escaping () throws -> CadenzaBackendConfig.Resolved = {
            try CadenzaBackendConfig.resolveForNewLogin()
        }
    ) throws -> CadenzaAuthService {
        if sessionProfile.boundAccount != nil, registry == nil {
            throw SessionEvidenceError.registryRequired
        }
        let snapshot = try loadSessionSnapshot(
            sessionProfile: sessionProfile,
            secretStore: secretStore,
            sessionUserStore: sessionUserStore
        )
        return CadenzaAuthService(
            sessionProfile: sessionProfile,
            snapshot: snapshot,
            http: http,
            authorizer: authorizer,
            secretStore: secretStore,
            sessionUserStore: sessionUserStore,
            registry: registry,
            newLoginBackend: newLoginBackend
        )
    }

    /// Request-incapable unbound service for TestHost, previews, and the
    /// pre-commit legacy fallback: no token slot, no registry, in-memory
    /// stores only.
    static func ephemeral() -> CadenzaAuthService {
        CadenzaAuthService(
            sessionProfile: .ephemeralUnbound(),
            snapshot: .empty,
            secretStore: EphemeralAuthSecretStore(),
            sessionUserStore: EphemeralSessionUserStore(),
            registry: nil
        )
    }

    // MARK: - Private DI dependencies

    private let sessionProfile: SessionProfile

    /// The frozen binding identity, for callers that scope per-account state
    /// to it. Read-only and no wider than the identity itself.
    struct BoundIdentity: Equatable, Sendable {
        let profileID: UUID
        let account: Profile.BoundAccount
    }

    var boundIdentity: BoundIdentity? {
        sessionProfile.boundAccount.map {
            BoundIdentity(profileID: sessionProfile.profileID, account: $0)
        }
    }
    /// Parsed issuer + base URL of the bound account; nil while unbound.
    /// Every request is pinned to this origin (INV-7).
    private let boundBackend: CadenzaBackendConfig.Resolved?
    /// Keychain account of this profile's token slot (§5.2); nil while
    /// unbound — there is no token slot until a binding fixes the issuer.
    private let tokenAccount: String?
    private let http: AuthHTTP
    private let authorizer: AuthorizationProvider
    private let secretStore: AuthSecretStore
    private let sessionUserStore: SessionUserStoring
    /// Backend a NEW login targets (§5.4); consulted only while unbound.
    private let newLoginBackend: () throws -> CadenzaBackendConfig.Resolved
    /// Registry handle for durable session-disposition writes (401 expiry
    /// and re-login restore); nil only for the ephemeral unbound service —
    /// the factory refuses a bound profile without it.
    private let registry: ProfileRegistryProviding?
    /// The classified in-memory token — the single runtime source. Set
    /// from the boot snapshot and on successful persists; never re-read
    /// from the Keychain through a nonclassified path.
    private var activeToken: StoredToken?
    /// Tracks the durable disposition as this process last successfully
    /// wrote it; starts at the boot snapshot's value.
    private var currentDisposition: Profile.SessionDisposition

    /// Guard against concurrent expireSession calls (401s from the network).
    private var expireSessionInFlight = false

#if DEBUG
    /// Isolation assertion seam: whether this instance holds the ephemeral
    /// storage pair. Type checks, not type names — renames stay
    /// compile-checked.
    enum AuthStorageBackingForTesting: Equatable {
        case ephemeral
        case persistent
    }

    var authStorageBackingForTesting:
        (secretStore: AuthStorageBackingForTesting, userStore: AuthStorageBackingForTesting) {
        (
            secretStore is EphemeralAuthSecretStore ? .ephemeral : .persistent,
            sessionUserStore is EphemeralSessionUserStore ? .ephemeral : .persistent
        )
    }
#endif

    // MARK: - Init

    private init(sessionProfile: SessionProfile,
                 snapshot: SessionSnapshot,
                 http: AuthHTTP = URLSession.shared,
                 authorizer: AuthorizationProvider = OAuthCoordinator.shared,
                 secretStore: AuthSecretStore,
                 sessionUserStore: SessionUserStoring,
                 registry: ProfileRegistryProviding?,
                 newLoginBackend: @escaping () throws -> CadenzaBackendConfig.Resolved = {
                     try CadenzaBackendConfig.resolveForNewLogin()
                 }) {
        self.sessionProfile = sessionProfile
        self.http = http
        self.authorizer = authorizer
        self.secretStore = secretStore
        self.sessionUserStore = sessionUserStore
        self.registry = registry
        self.newLoginBackend = newLoginBackend
        self.currentDisposition = sessionProfile.sessionDisposition

        if let bound = sessionProfile.boundAccount,
           let origin = try? IssuerOrigin(validating: bound.issuerOrigin),
           origin.originKey == bound.originKey,
           let base = URL(string: bound.apiBaseURL),
           origin.covers(requestURL: base) {
            self.boundBackend = CadenzaBackendConfig.Resolved(origin: origin, apiBaseURL: base)
            self.tokenAccount = SessionTokenKey.account(
                profileID: sessionProfile.profileID, originKey: origin.originKey
            )
        } else {
            // Registry validation makes a bound-but-unparseable account
            // unreachable; if it ever appears, the service degrades to a
            // request-incapable signed-out state instead of guessing an
            // origin for the token.
            if sessionProfile.boundAccount != nil {
                NSLog("[CadenzaAuth] bound account failed origin validation; requests disabled")
            }
            self.boundBackend = nil
            self.tokenAccount = nil
        }

        // Durable-state derivation (§4.1, INV-3) from the classified
        // snapshot only: an explicit sign-out or a recorded token
        // invalidation are the non-active dispositions; under `.active` a
        // missing or expired token presents as `.expired` and never locks
        // anything. The factory guarantees a bound snapshot carries an
        // identity-verified user record.
        let sessionUsable: Bool
        if case .valid = snapshot.token {
            sessionUsable = true
        } else {
            sessionUsable = false
        }
        let derived = ProfileSessionDerivation.authState(
            boundAccount: boundBackend != nil ? sessionProfile.boundAccount : nil,
            sessionDisposition: sessionProfile.sessionDisposition,
            tokenPresent: sessionUsable
        )
        switch derived {
        case .signedIn:
            self.sessionState = .signedIn
            self.currentUser = snapshot.user.map(SignedInUser.init(sessionUser:))
            if case .valid(let stored) = snapshot.token {
                self.activeToken = stored
            }
        case .expired:
            self.sessionState = .expired
            // Drive the AuthErrorBanner on cold start. expireSession() does
            // this when triggered at runtime; init must mirror it for the
            // "quit while signed in → token expired by next launch" path.
            self.lastError = .sessionExpired
        case .signedOut, .signingIn:
            self.sessionState = .signedOut
        }
    }

    // MARK: - Token persistence

    /// The current classified token, exposed for state inspection. The
    /// runtime never re-reads the Keychain through a nonclassified path —
    /// this memory copy, set from the boot snapshot and successful
    /// persists, is the single runtime source.
    func loadStoredToken() -> StoredToken? {
        activeToken
    }

    /// Wire encoding of a token value for a per-profile Keychain slot —
    /// the format `loadSessionSnapshot` classifies and M2 migrates.
    static func encodeTokenValue(_ token: StoredToken) throws -> String {
        try JSONEncoder().encode(token).base64EncodedString()
    }

    /// Serializes into the profile's Keychain slot (base64-encoded JSON).
    ///
    /// Uses the default `JSONEncoder` date strategy
    /// (seconds-since-reference-date): the wire format inside the slot is
    /// unchanged from the pre-profile service, and M2 moves the value
    /// verbatim, so migrated sessions read back without conversion.
    /// Throws if encoding or keychain write fails, and always for an
    /// unbound profile — there is no slot to write. Callers are
    /// responsible for the rollback story.
    func storeToken(_ token: StoredToken) throws {
        guard let tokenAccount else {
            throw AuthError.localPersistenceFailed("no bound token slot")
        }
        let data = try JSONEncoder().encode(token)
        try secretStore.set(data.base64EncodedString(), for: tokenAccount)
    }

    // MARK: - Public API

    private static let redirectURI = "com.shuiandy.cadenza://auth/cadenza/callback"

    /// Restores the session of this already-bound profile (unlock or
    /// expired-token re-login): PKCE against the bound issuer, then a hard
    /// identity check — the `/me` identity must equal the bound account's
    /// userID (§6.2, INV-4) or nothing is written. New logins that may
    /// bind or create profiles go through `authorizeForBinding` and the
    /// profile login flow (§5.5) instead.
    ///
    /// Throws `AuthError` on any failure. Guarantees that no partial write is
    /// left behind: if either the token store or the user store fails after the
    /// other has already succeeded, `persistSession` rolls back the completed
    /// write before re-throwing.
    func signIn() async throws {
        guard sessionState != .signingIn else { throw AuthError.alreadyInProgress }
        guard let backend = boundBackend, let bound = sessionProfile.boundAccount else {
            throw AuthError.bindingFlowRequired
        }
        let entryState = sessionState  // .signedOut, .signedIn, or .expired
        sessionState = .signingIn
        lastError = nil
        do {
            let (token, user) = try await performAuthorization(backend: backend)
            guard AccountIdentity.matches(user.id, bound.userID) else {
                throw AuthError.accountMismatch
            }
            // Artifacts first, under the entry disposition: while the
            // registry still says invalidated/signed-out, neither the new
            // pair nor a rolled-back stale token can be used, so any
            // failure or crash here is safe. The `.active` disposition is
            // the commit point and comes last.
            try persistSession(token: token, user: user)
            do {
                try writeSessionDisposition(.active)
            } catch {
                // The fresh pair stays durably in place — retryable and
                // inert under the non-active disposition. Nothing is
                // rolled back (restoring a stale token under a later
                // successful activation would resurrect a dead session);
                // in memory the entry view is restored and nothing is
                // published as signed-in.
                activeToken = nil
                throw AuthError.localPersistenceFailed(
                    "session disposition commit failed: \(error)"
                )
            }

            currentUser = user
            sessionState = .signedIn
            publishSessionChange()
        } catch {
            // Revert to the state we entered with — preserves `.expired` if the
            // user was re-signing-in from an expired session and failed.
            sessionState = currentUser != nil ? .signedIn : entryState
            let classified = AuthError.classify(error)
            lastError = classified
            NSLog("[CadenzaAuth] sign in failed: %@", String(describing: classified) as NSString)
            // Throw the original error to preserve call-stack debugging info; the
            // classified version lives in `lastError` for UI consumption.
            throw error
        }
    }

    /// Memory-only authorization for the profile login flow (§5.5): runs
    /// PKCE against the bound issuer (unlock path) or the configured
    /// new-login backend (unbound path) and returns the token and identity
    /// without persisting anything — binding decides what, if anything,
    /// gets written, through the two-phase transaction.
    struct AuthorizationResult {
        let token: StoredToken
        let user: SignedInUser
        let backend: CadenzaBackendConfig.Resolved
    }

    /// Memory-only PKCE authorization for the login/binding flow. An
    /// explicit `backend` pins the dance to that exact issuer and base —
    /// the target-profile unlock path passes the locked profile's frozen
    /// backend, which need not match this service's own; without it a
    /// bound service authorizes against its bound backend and an unbound
    /// one against the configured new-login backend.
    func authorizeForBinding(
        backend targetBackend: CadenzaBackendConfig.Resolved? = nil
    ) async throws -> AuthorizationResult {
        guard sessionState != .signingIn else { throw AuthError.alreadyInProgress }
        let backend: CadenzaBackendConfig.Resolved
        if let targetBackend {
            backend = targetBackend
        } else if let boundBackend {
            backend = boundBackend
        } else {
            backend = try newLoginBackend()
        }
        let entryState = sessionState
        sessionState = .signingIn
        lastError = nil
        do {
            let (token, user) = try await performAuthorization(backend: backend)
            sessionState = entryState
            return AuthorizationResult(token: token, user: user, backend: backend)
        } catch {
            sessionState = entryState
            let classified = AuthError.classify(error)
            lastError = classified
            NSLog(
                "[CadenzaAuth] authorization failed: %@",
                String(describing: classified) as NSString
            )
            throw error
        }
    }

    /// Shared PKCE core: browser dance + code exchange against the given
    /// backend. Pure with respect to session state — callers own
    /// persistence and state transitions.
    private func performAuthorization(
        backend: CadenzaBackendConfig.Resolved
    ) async throws -> (StoredToken, SignedInUser) {
        let codeVerifier = PKCE.generateVerifier()
        let codeChallenge = PKCE.challenge(forVerifier: codeVerifier)
        let state = PKCE.generateVerifier()
        let redirectURI = Self.redirectURI

        var components = URLComponents(
            url: backend.apiBaseURL.appendingPathComponent("auth/desktop/start"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else {
            throw AuthError.invalidCallback
        }

        let callbackURL = try await authorizer.authorize(authorizeURL)
        try validateCallback(callbackURL)
        let parsed = try parseCallback(callbackURL)
        guard parsed.state == state else { throw AuthError.stateMismatch }

        let response = try await postExchange(code: parsed.code,
                                              codeVerifier: codeVerifier,
                                              redirectURI: redirectURI,
                                              baseURL: backend.apiBaseURL)

        let user = SignedInUser(
            id: response.user.id,
            email: response.user.email,
            displayName: response.user.displayName,
            pictureURL: response.user.picture.flatMap(URL.init(string:))
        )
        let token = StoredToken(value: response.token,
                                expiresAt: Date(timeIntervalSince1970: response.expiresAt))
        return (token, user)
    }

    /// Idempotent. Once `.signedIn`, calling this transitions to `.expired` and
    /// drops the access token; subsequent calls (after the state moved) are no-ops
    /// via the `sessionState == .signedIn` guard. The `expireSessionInFlight`
    /// flag is belt-and-suspenders against synchronous re-entrancy from
    /// `@Observable` observers reacting to the mutations below — true
    /// `await`-driven concurrent calls cannot interleave on `@MainActor`.
    /// Keeps the user JSON so the next launch reads as `.expired`, not `.signedOut`.
    func expireSession() {
        guard !expireSessionInFlight, sessionState == .signedIn else { return }
        expireSessionInFlight = true
        defer { expireSessionInFlight = false }

        // The expiry is recoverable only when at least one durable fact
        // records it: the registry disposition, an emptied token slot, or
        // a slot overwritten with an already-expired value. If every write
        // fails, the state is reported as an explicit cleanup failure —
        // never claimed durable.
        var durablyRecorded = false
        do {
            try writeSessionDisposition(.tokenInvalidated)
            durablyRecorded = true
        } catch {
            NSLog(
                "[CadenzaAuth] disposition write failed: %@",
                String(describing: error) as NSString
            )
        }

        let retained = activeToken
        activeToken = nil
        if let tokenAccount {
            do {
                try secretStore.remove(tokenAccount)
                durablyRecorded = true
            } catch {
                NSLog(
                    "[CadenzaAuth] expired-token removal failed: %@",
                    String(describing: error) as NSString
                )
                do {
                    try storeToken(
                        StoredToken(value: retained?.value ?? "invalidated",
                                    expiresAt: .distantPast)
                    )
                    durablyRecorded = true
                } catch {
                    NSLog(
                        "[CadenzaAuth] durable expiry write failed: %@",
                        String(describing: error) as NSString
                    )
                }
            }
        }
        currentUser = nil
        sessionState = .expired
        lastError = durablyRecorded ? .sessionExpired : .sessionCleanupFailed
        publishSessionChange()
        NSLog("[CadenzaAuth] state → .expired (durable: %d)", durablyRecorded ? 1 : 0)
        // Do NOT call backend revoke — server already considers this session invalid.
    }

    /// Clears `lastError` if it's an `.integrationReauthRequired(provider:)`
    /// matching the given provider. Used after a service successfully
    /// reconnects so the per-row "Reconnect …" banner stops rendering.
    func clearIntegrationReauth(for provider: String) {
        if case .integrationReauthRequired(let p) = lastError, p == provider {
            lastError = nil
        }
    }

    /// Revokes the backend session row (best-effort) and clears the local
    /// token as a classifiable durable operation: removal, or a provable
    /// already-expired overwrite. Returns whether the credential at rest
    /// was durably invalidated — callers must not proceed with a
    /// "signed out" transition on false, because a live credential would
    /// remain while claiming successful cleanup.
    ///
    /// The session-user file is deliberately kept (§6.1): the profile
    /// stays bound and a lock screen shows whose profile this is. The
    /// durable sign-out disposition, lock flag, and switch back to Local
    /// are registry writes owned by the sign-out orchestration, not by
    /// this service.
    @discardableResult
    func signOut() -> Bool {
        pendingRevokeTask = nil
        let token = currentToken()
        activeToken = nil
        var durablyCleared = tokenAccount == nil
        if let tokenAccount {
            do {
                try secretStore.remove(tokenAccount)
                durablyCleared = true
            } catch {
                NSLog(
                    "[CadenzaAuth] sign-out token removal failed: %@",
                    String(describing: error) as NSString
                )
                do {
                    try storeToken(
                        StoredToken(value: token ?? "invalidated", expiresAt: .distantPast)
                    )
                    durablyCleared = true
                } catch {
                    NSLog(
                        "[CadenzaAuth] sign-out expiry overwrite failed: %@",
                        String(describing: error) as NSString
                    )
                }
            }
        }
        currentUser = nil
        sessionState = .signedOut
        lastError = durablyCleared ? nil : .sessionCleanupFailed
        publishSessionChange()
        NSLog("[CadenzaAuth] state → .signedOut (durable: %d)", durablyCleared ? 1 : 0)
        if let token, let backend = boundBackend,
           // Endpoint matches the existing pre-rebuild service. Do NOT change
           // unless the backend prerequisite explicitly adds a new endpoint.
           let request = try? Self.makeBearerRequest(
               path: "auth/desktop/sign-out", method: "POST",
               token: token, backend: backend
           ) {
            // `Task { ... }` (not `.detached`) inherits `@MainActor`, so we can
            // safely capture `http` (a `@MainActor` protocol existential) without
            // a Sendable-capture warning. `http.data(for:)` is a `@MainActor`
            // requirement; the underlying URLSession network IO runs off-main,
            // but the call and its continuation remain on `@MainActor`.
            pendingRevokeTask = Task { [http] in
                _ = try? await http.data(for: request)
            }
        }
        return durablyCleared
    }

    /// Best-effort backend revoke fired by `signOut`; the sign-out
    /// orchestration awaits it within a bound before relaunching.
    private(set) var pendingRevokeTask: Task<Void, Never>?

    /// The single path from bearer token to outbound request: builds the
    /// URL from the bound base and enforces INV-7 — the token goes only to
    /// the origin that issued it. A violation is programmer error in debug
    /// and a refused request in release.
    static func makeBearerRequest(
        path: String,
        method: String,
        token: String,
        backend: CadenzaBackendConfig.Resolved
    ) throws -> URLRequest {
        let url = backend.apiBaseURL.appendingPathComponent(path)
        guard backend.origin.covers(requestURL: url) else {
            assertionFailure("request URL escapes the bound issuer origin")
            throw CadenzaAPIError.notSignedIn
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Returns the current Bearer token string, or `nil` if signed out or
    /// within 60 seconds of expiry. Use this for outbound request headers.
    func currentToken() -> String? {
        guard let stored = activeToken else { return nil }
        // 60-second skew like our Zoom logic.
        if stored.expiresAt.timeIntervalSinceNow < 60 { return nil }
        return stored.value
    }

    /// Canonical authenticated request helper. All Mac-side services that hit
    /// `cadenzapp.com` go through this method. Centralizes 401 handling
    /// (drops session via `expireSession()` except for the exchange path,
    /// where 401 means "wrong PKCE/code", not "session expired") and surfaces
    /// the backend's standard error envelope (spec §6.5) as a typed error.
    @discardableResult
    func request(path: String,
                 method: String = "GET",
                 body: Data? = nil,
                 headers: [String: String] = [:]) async throws -> Data {
        let (data, _) = try await requestResponse(
            path: path,
            method: method,
            body: body,
            contentType: body == nil ? nil : "application/json",
            headers: headers
        )
        return data
    }

    @discardableResult
    func requestResponse(path: String,
                         method: String = "GET",
                         body: Data? = nil,
                         contentType: String? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        // Only a coherent signed-in session issues requests: a torn
        // artifact set (valid-looking token, missing user record) boots as
        // `.expired` and must never see its bearer used.
        guard sessionState == .signedIn else {
            throw CadenzaAPIError.notSignedIn
        }
        guard let token = currentToken() else {
            // Local token cleared or expired (60s skew). If the in-memory state
            // still thinks we're signed in, surface the expiry so the UI flips
            // to "Sign in again" instead of silently throwing on every call.
            if sessionState == .signedIn { expireSession() }
            throw CadenzaAPIError.notSignedIn
        }
        guard let backend = boundBackend else {
            // A token with no bound backend cannot exist; refuse rather
            // than guess a destination for the bearer.
            throw CadenzaAPIError.notSignedIn
        }
        var urlRequest = try Self.makeBearerRequest(
            path: path, method: method, token: token, backend: backend
        )
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let classified = AuthError.classify(error)
            NSLog(
                "[CadenzaAuth] request failed for %@: %@",
                path,
                String(describing: error)
            )
            throw classified
        }
        guard let httpResp = response as? HTTPURLResponse else {
            throw AuthError.unknown
        }

        if httpResp.statusCode == 401 {
            // The exchange endpoint can return 401 for "wrong PKCE/code", which
            // is a sign-in failure, not a stale-session signal — never demote
            // the session here. Every other path means the bearer is dead.
            if path != "auth/desktop/exchange" {
                expireSession()
            }
            throw CadenzaAPIError.unauthorized
        }

        // Try to decode the standard error envelope (spec §6.5) on any non-2xx.
        // We must check status first; otherwise a 200 response that happens to
        // have a `code` field would be mistaken for an error.
        if !(200..<300).contains(httpResp.statusCode),
           let envelope = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) {
            if envelope.code == "integration_reauth_required" {
                let provider = envelope.integration ?? "unknown"
                // Only surface in UI if the session is still active; signOut()
                // during the in-flight request would otherwise leave the next
                // launch with a stale reauth error.
                if sessionState == .signedIn {
                    lastError = .integrationReauthRequired(provider: provider)
                }
                throw AuthError.integrationReauthRequired(provider: provider)
            }
            throw CadenzaAPIError.backend(envelope: envelope, status: httpResp.statusCode)
        }

        guard (200..<300).contains(httpResp.statusCode) else {
            throw AuthError.server(status: httpResp.statusCode)
        }
        return (data, httpResp)
    }

    private func publishSessionChange() {
        onSessionChanged?(sessionState, currentUser)
    }

    /// Writes this profile's session disposition into the registry — the
    /// durable authority the boot derivation reads. Throwing: callers own
    /// what a failure means for their transaction; success updates the
    /// tracked disposition so later logic never reasons from the stale
    /// boot-time value.
    private func writeSessionDisposition(_ disposition: Profile.SessionDisposition) throws {
        guard let registry else {
            throw SessionEvidenceError.registryRequired
        }
        let document = try registry.load()
        guard let index = document.profiles.firstIndex(where: {
            $0.id == sessionProfile.profileID
        }) else {
            throw DispositionWriteError.authorityLost("session profile missing from registry")
        }
        // Fresh authority proof, matching the root and lock writers: a
        // stale process after a switch or rebind must not flip a
        // disposition on a profile that is no longer its own.
        guard document.activeProfileID == sessionProfile.profileID else {
            throw DispositionWriteError.authorityLost("profile no longer active")
        }
        guard !document.profiles[index].isLocked else {
            throw DispositionWriteError.authorityLost("profile is locked")
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            throw DispositionWriteError.authorityLost("operation in flight")
        }
        guard AccountIdentity.boundTupleMatches(
            document.profiles[index].boundAccount, sessionProfile.boundAccount
        ) else {
            throw DispositionWriteError.authorityLost("profile rebound to a different account")
        }
        let freshDisposition = document.profiles[index].sessionDisposition
        if freshDisposition == disposition {
            // The registry already records the target — idempotent.
            currentDisposition = disposition
            return
        }
        // A fresh value that matches neither the target nor this
        // service's tracked state is another instance's transition
        // (sign-out, invalidation) and must not be overwritten.
        guard freshDisposition == currentDisposition else {
            throw DispositionWriteError.authorityLost("disposition changed behind this process")
        }
        do {
            var intended = document
            intended.profiles[index].sessionDisposition = disposition
            // Classified save: a committed disposition must never be
            // reported as failed.
            switch ProfileSwitchCoordinator.classifiedSave(
                old: document, intended: intended, registry: registry
            ) {
            case .committed:
                break
            case .notCommitted(let detail):
                throw DispositionWriteError.notCommitted(detail)
            case .indeterminate(let detail):
                throw DispositionWriteError.indeterminate(detail)
            }
        }
        currentDisposition = disposition
    }

    /// Disposition write failures: `notCommitted` provably left the
    /// old shape (retryable), `indeterminate` has unknown durable state,
    /// `authorityLost` refused before writing. Only a proven commit
    /// reports success.
    enum DispositionWriteError: Error {
        case notCommitted(String)
        case indeterminate(String)
        case authorityLost(String)
    }

    // MARK: - Persistence

    /// Persists token + user atomically for in-process readers (both stores
    /// are `@MainActor`-isolated, so no other Swift code can interleave reads
    /// between the two writes). A crash between the two leaves a fresh
    /// token beside the previous user record of the same account — the
    /// boot factory verifies identity, so the pair stays coherent; only a
    /// record of a different account would halt the boot.
    /// Throws `AuthError.localPersistenceFailed` on any failure; rollback is
    /// best-effort and logged on failure. On success the in-memory token
    /// is updated — the runtime single source.
    private func persistSession(token: StoredToken, user: SignedInUser) throws {
        guard let tokenAccount else {
            throw AuthError.localPersistenceFailed("no bound token slot")
        }
        // Classified prior reads precede any write: an unreadable slot or
        // record means the rollback baseline cannot be established, so
        // nothing is written at all — unknown is never treated as absent
        // and then deleted by the rollback.
        let priorTokenRaw: String?
        do {
            priorTokenRaw = try secretStore.getClassified(tokenAccount)
        } catch {
            throw AuthError.localPersistenceFailed(
                "token slot unreadable before write: \(error)"
            )
        }
        let priorUser: SessionUser?
        do {
            priorUser = try sessionUserStore.load()
        } catch {
            throw AuthError.localPersistenceFailed(
                "session user unreadable before write: \(error)"
            )
        }

        func restore() {
            do {
                if let priorTokenRaw {
                    try secretStore.set(priorTokenRaw, for: tokenAccount)
                } else {
                    try secretStore.remove(tokenAccount)
                }
            } catch {
                // Best-effort rollback. Keychain may end up with a stale token
                // entry; signOut() will clear it on next call. Logged so an
                // observer can spot it in Console.
                NSLog("[CadenzaAuth] persistSession rollback (token) failed: %@",
                      String(describing: error) as NSString)
            }
            do {
                if let priorUser {
                    try sessionUserStore.save(priorUser)
                } else {
                    try sessionUserStore.remove()
                }
            } catch {
                NSLog("[CadenzaAuth] persistSession rollback (user) failed: %@",
                      String(describing: error) as NSString)
            }
        }

        do {
            try storeToken(token)
        } catch {
            restore()
            throw AuthError.localPersistenceFailed(String(describing: error))
        }
        do {
            try sessionUserStore.save(user.sessionUserRecord())
        } catch {
            restore()
            throw AuthError.localPersistenceFailed(String(describing: error))
        }
        activeToken = token
    }

    // MARK: - Callback parsing

    private struct CallbackPayload {
        let code: String
        let state: String
    }

    /// Validates the structural invariants of the callback URL (scheme, host,
    /// path) and checks for an `error=access_denied` query parameter.
    /// Throws `AuthError.invalidCallback` or `AuthError.authorizationDenied`.
    private func validateCallback(_ url: URL) throws {
        guard url.scheme == "com.shuiandy.cadenza" else { throw AuthError.invalidCallback }
        guard url.host == "auth" else { throw AuthError.invalidCallback }
        guard url.path == "/cadenza/callback" else { throw AuthError.invalidCallback }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.first(where: { $0.name == "error" })?.value == "access_denied" {
            throw AuthError.authorizationDenied
        }
    }

    /// Extracts `code` and `state` from a validated callback URL.
    /// Throws `AuthError.invalidCallback` if either parameter is absent.
    private func parseCallback(_ url: URL) throws -> CallbackPayload {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else {
            throw AuthError.invalidCallback
        }
        return CallbackPayload(code: code, state: state)
    }

    // MARK: - Exchange

    /// Wire format returned by `/auth/desktop/exchange`.
    /// `expiresAt` is a Unix epoch integer from the server; the caller converts
    /// it to `Date(timeIntervalSince1970:)` for `StoredToken`.
    private struct ExchangeResponse: Decodable {
        let token: String
        let expiresAt: TimeInterval
        let user: User

        struct User: Decodable {
            let id: String
            let email: String
            let displayName: String
            let picture: String?

            private enum CodingKeys: String, CodingKey {
                case id, email, displayName = "display_name", picture
            }
        }

        private enum CodingKeys: String, CodingKey {
            case token, expiresAt = "expires_at", user
        }
    }

    /// POSTs the authorization code + PKCE verifier to the exchange endpoint.
    /// Uses the injected `http` dependency (not `URLSession.shared`) so tests
    /// can provide canned responses. Throws `AuthError.server` on non-2xx or
    /// `AuthError.decoding` on a malformed response body.
    private func postExchange(code: String,
                              codeVerifier: String,
                              redirectURI: String,
                              baseURL: URL) async throws -> ExchangeResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/desktop/exchange"))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["code": code, "code_verifier": codeVerifier, "redirect_uri": redirectURI]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await http.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else { throw AuthError.unknown }
        guard (200..<300).contains(httpResp.statusCode) else {
            throw AuthError.server(status: httpResp.statusCode)
        }
        do {
            return try JSONDecoder().decode(ExchangeResponse.self, from: data)
        } catch {
            throw AuthError.decoding(String(describing: error))
        }
    }
}

// MARK: - Token wire format

/// Token wire format: `value` is the bearer string; `expiresAt` is a
/// `Date` encoded with default `JSONEncoder` strategy (seconds since
/// Apple's reference date — 2001-01-01). Persisted as base64 of this
/// struct's JSON. Wire format matches the existing pre-rebuild service.
struct StoredToken: Codable, Equatable, Sendable {
    let value: String
    let expiresAt: Date
}

// MARK: - Session-user record mapping

/// The display identity round-trips between the observable `SignedInUser`
/// and the per-profile `session-user.json` record. The global defaults
/// record that predated profiles is read only by the M2 migration, which
/// retires it.
extension CadenzaAuthService.SignedInUser {
    init(sessionUser: SessionUser) {
        self.init(
            id: sessionUser.userID,
            email: sessionUser.email,
            displayName: sessionUser.displayName,
            pictureURL: sessionUser.pictureURL
        )
    }

    /// Post-commit session refreshes do not carry binding provenance; the
    /// transaction ID matters only while a pending binding exists.
    func sessionUserRecord() -> SessionUser {
        SessionUser(
            userID: id,
            email: email,
            displayName: displayName,
            pictureURL: pictureURL,
            bindingTransactionID: nil
        )
    }
}

// MARK: - API errors

struct BackendErrorEnvelope: Decodable, Equatable, Sendable {
    let code: String
    let message: String?
    let integration: String?
    let upstreamStatus: Int?
    let retryAfter: Int?

    private enum CodingKeys: String, CodingKey {
        case code, message, integration
        case upstreamStatus = "upstream_status"
        case retryAfter = "retry_after"
    }
}

/// Errors raised by `CadenzaAuthService.request`. Auth-shaped backend
/// errors (`integration_reauth_required`) are mapped to `AuthError`
/// directly; everything else surfaces here as `.backend(...)` so service
/// callers (e.g., NotionExportService) can interpret per-provider codes.
enum CadenzaAPIError: Error, Equatable {
    case notSignedIn
    case unauthorized
    /// Non-auth backend domain error. `code` values per spec §6.5:
    /// `rate_limited`, `notion_validation_error`, `database_missing`,
    /// `upstream_unavailable`, `not_connected`, etc.
    case backend(envelope: BackendErrorEnvelope, status: Int)
}

extension CadenzaAPIError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notSignedIn: return "notSignedIn"
        case .unauthorized: return "unauthorized"
        case .backend(let envelope, let status):
            return "backend(code=\(envelope.code), status=\(status))"
        }
    }
}

/// Human-readable text the UI shows for each enum case. Without this
/// `LocalizedError` conformance, `error.localizedDescription` falls back
/// to the Cocoa default — `"<bundle>.CadenzaAPIError 错误 0"` — because
/// `Error` enums without `CustomNSError` map every case to NSError code
/// 0 and the `.userInfo` dictionary is empty. The legacy export alert
/// surfaced exactly that string and confused at least one user during
/// G2 manual smoke (handoff 2026-05-07). Backend envelope prose is retained
/// only as diagnostic data; the UI localizes the stable code from spec §6.5.
extension CadenzaAPIError: LocalizedError {
    var errorDescription: String? { localizedMessage() }

    func localizedMessage(locale: Locale? = nil) -> String {
        switch self {
        case .notSignedIn:
            return LocalizedBundle.string("Please sign in to Cadenza.", locale: locale)
        case .unauthorized:
            return LocalizedBundle.string(
                "Your session has expired. Please sign in again.",
                locale: locale
            )
        case .backend(let envelope, _):
            // Server-supplied prose is diagnostic data, not UI copy. It can
            // contain schema details, record identifiers, upstream bodies,
            // or English-only text. Map only the stable backend code here.
            let code = envelope.code.trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty {
                return LocalizedBundle.string(
                    "The server returned an unspecified error.",
                    locale: locale
                )
            }
            switch code {
            case "rate_limited":
                if let s = envelope.retryAfter, s > 0 {
                    if s == 1 {
                        return LocalizedBundle.string(
                            "Too many requests. Try again in 1 second.",
                            locale: locale
                        )
                    }
                    return LocalizedBundle.string(
                        "Too many requests. Try again in \(s) seconds.",
                        locale: locale
                    )
                }
                return LocalizedBundle.string(
                    "Too many requests. Please try again later.",
                    locale: locale
                )
            case "notion_validation_error":
                return LocalizedBundle.string("Notion rejected the request.", locale: locale)
            case "database_missing":
                return LocalizedBundle.string(
                    "The Notion database is unavailable. Select it again.",
                    locale: locale
                )
            case "upstream_unavailable":
                return LocalizedBundle.string(
                    "Notion is temporarily unavailable. Please try again later.",
                    locale: locale
                )
            case "not_connected":
                return LocalizedBundle.string("Connect Notion in Settings first.", locale: locale)
            case "vault_required":
                return LocalizedBundle.string(
                    "This account was migrated to the new Notion integration. Reconnect in Settings.",
                    locale: locale
                )
            case "bad_request":
                return LocalizedBundle.string("The request was invalid.", locale: locale)
            case "internal_error":
                return LocalizedBundle.string(
                    "The server encountered an internal error. Please try again later.",
                    locale: locale
                )
            case "integration_reauth_required":
                return LocalizedBundle.string(
                    "The third-party integration needs to be reauthorized.",
                    locale: locale
                )
            default:
                return LocalizedBundle.string("The server returned an error.", locale: locale)
            }
        }
    }
}
