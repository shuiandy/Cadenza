import Foundation
import Testing

@testable import Cadenza

// MARK: - Origin normalization (§5.2, INV-7)

struct IssuerOriginTests {
    @Test func normalizesCaseAndMakesDefaultPortExplicit() throws {
        let https = try IssuerOrigin(url: URL(string: "HTTPS://Cadenzapp.COM/api/v1")!)
        #expect(https.normalized == "https://cadenzapp.com:443")

        let http = try IssuerOrigin(url: URL(string: "http://LOCALHOST/x?q=1#f")!)
        #expect(http.normalized == "http://localhost:80")
    }

    @Test func preservesExplicitNonDefaultPort() throws {
        let origin = try IssuerOrigin(url: URL(string: "https://self.host:8443/api")!)
        #expect(origin.normalized == "https://self.host:8443")
    }

    @Test func explicitDefaultPortEqualsImplicit() throws {
        let implicit = try IssuerOrigin(url: URL(string: "https://cadenzapp.com/api/v1")!)
        let explicit = try IssuerOrigin(url: URL(string: "https://cadenzapp.com:443/")!)
        #expect(implicit == explicit)
        #expect(implicit.originKey == explicit.originKey)
    }

    @Test func stripsPathQueryFragmentAndCredentials() throws {
        let origin = try IssuerOrigin(
            url: URL(string: "https://user:pw@host.example:9000/deep/path?a=b#c")!
        )
        #expect(origin.normalized == "https://host.example:9000")
    }

    @Test func bracketsIPv6Hosts() throws {
        let origin = try IssuerOrigin(url: URL(string: "https://[::1]:8443/api")!)
        #expect(origin.normalized == "https://[::1]:8443")
        // The canonical form must itself re-normalize to the same value.
        let again = try IssuerOrigin(validating: origin.normalized)
        #expect(again == origin)
    }

    @Test func rejectsNonHTTPSchemes() {
        for raw in ["ftp://host", "file:///tmp/x", "com.shuiandy.cadenza://auth"] {
            #expect(throws: IssuerOrigin.NormalizationError.self) {
                _ = try IssuerOrigin(url: URL(string: raw)!)
            }
        }
    }

    @Test func rejectsMissingHost() {
        #expect(throws: IssuerOrigin.NormalizationError.missingHost) {
            _ = try IssuerOrigin(url: URL(string: "https:///path")!)
        }
    }

    @Test func rejectsMalformedStoredStrings() {
        for raw in ["", "not a url", "cadenzapp.com"] {
            #expect(throws: IssuerOrigin.NormalizationError.self) {
                _ = try IssuerOrigin(validating: raw)
            }
        }
    }

    @Test func normalizedFormRoundTripsThroughValidation() throws {
        let origin = try IssuerOrigin(url: URL(string: "https://cadenzapp.com/api/v1")!)
        let revalidated = try IssuerOrigin(validating: origin.normalized)
        #expect(revalidated == origin)
    }

    @Test func originKeyIsSixteenLowercaseHexAndStable() throws {
        let origin = try IssuerOrigin(url: URL(string: "https://cadenzapp.com/api/v1")!)
        let key = origin.originKey
        #expect(key.count == 16)
        #expect(key.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
        #expect(key == origin.originKey)

        let other = try IssuerOrigin(url: URL(string: "https://other.example/api")!)
        #expect(other.originKey != key)
    }

    @Test func coversOnlyExactOriginMatches() throws {
        let origin = try IssuerOrigin(url: URL(string: "https://cadenzapp.com/api/v1")!)
        #expect(origin.covers(requestURL: URL(string: "https://cadenzapp.com/api/v1/me")!))
        #expect(origin.covers(requestURL: URL(string: "HTTPS://CADENZAPP.COM:443/other")!))
        #expect(!origin.covers(requestURL: URL(string: "http://cadenzapp.com/api/v1")!))
        #expect(!origin.covers(requestURL: URL(string: "https://cadenzapp.com:8443/api")!))
        #expect(!origin.covers(requestURL: URL(string: "https://evil.example/api/v1")!))
        #expect(!origin.covers(requestURL: URL(fileURLWithPath: "/tmp/x")))
    }
}

// MARK: - Token key + auth state derivation (§5.1/§5.2, INV-3)

struct ProfileSessionDerivationTests {
    private func boundAccount() -> Profile.BoundAccount {
        Profile.BoundAccount(
            userID: "user-1",
            originKey: "0123456789abcdef",
            issuerOrigin: "https://cadenzapp.com:443",
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "a@example.com",
            displayName: "A",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
    }

    @Test func tokenAccountFormatMatchesSpec() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let account = SessionTokenKey.account(profileID: id, originKey: "00ff00ff00ff00ff")
        #expect(account == "cadenza.session.token.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.00ff00ff00ff00ff")
    }

    @Test func unboundProfileIsSignedOutRegardlessOfToken() {
        for tokenPresent in [true, false] {
            let state = ProfileSessionDerivation.authState(
                boundAccount: nil, sessionDisposition: .active, tokenPresent: tokenPresent
            )
            #expect(state == .signedOut)
        }
    }

    @Test func explicitSignOutWinsOverTokenPresence() {
        for tokenPresent in [true, false] {
            let state = ProfileSessionDerivation.authState(
                boundAccount: boundAccount(),
                sessionDisposition: .explicitlySignedOut,
                tokenPresent: tokenPresent
            )
            #expect(state == .signedOut)
        }
    }

    @Test func activeWithTokenIsSignedIn() {
        let state = ProfileSessionDerivation.authState(
            boundAccount: boundAccount(), sessionDisposition: .active, tokenPresent: true
        )
        #expect(state == .signedIn)
    }

    @Test func activeWithoutTokenIsExpiredNeverSignedOut() {
        let state = ProfileSessionDerivation.authState(
            boundAccount: boundAccount(), sessionDisposition: .active, tokenPresent: false
        )
        #expect(state == .expired)
    }
}

// MARK: - Session user file store

struct FileSessionUserStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-user-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(in dir: URL) -> FileSessionUserStore {
        FileSessionUserStore(
            url: dir.appendingPathComponent("session-user.json"),
            fileOperations: LiveFileOperations()
        )
    }

    private var sampleUser: SessionUser {
        SessionUser(
            userID: "user-42",
            email: "u@example.com",
            displayName: "U",
            pictureURL: URL(string: "https://cadenzapp.com/avatar.png")
        )
    }

    @Test func roundTripsAndUsesRestrictivePermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        try store.save(sampleUser)
        #expect(try store.load() == sampleUser)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("session-user.json").path
        )
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test func absentFileLoadsAsDefiniteNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try makeStore(in: dir).load() == nil)
    }

    @Test func malformedContentThrowsInsteadOfReadingAsAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session-user.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try makeStore(in: dir).load()
        }
    }

    @Test func emptyUserIDIsRejectedOnLoadAndSave() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let invalid = SessionUser(userID: "  ", email: "e", displayName: "d", pictureURL: nil)

        #expect(throws: SessionUser.ValidationError.emptyUserID) {
            try store.save(invalid)
        }
        let url = dir.appendingPathComponent("session-user.json")
        try Data(#"{"userID":"","email":"e","displayName":"d"}"#.utf8).write(to: url)
        #expect(throws: SessionUser.ValidationError.emptyUserID) {
            _ = try store.load()
        }
    }

    @Test func symlinkedFileIsRefused() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("elsewhere.json")
        let encoder = JSONEncoder()
        try encoder.encode(sampleUser).write(to: real)
        let link = dir.appendingPathComponent("session-user.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(throws: (any Error).self) {
            _ = try makeStore(in: dir).load()
        }
    }

    @Test func removeIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        try store.save(sampleUser)
        try store.remove()
        #expect(try store.load() == nil)
        try store.remove()
    }

    @Test func ephemeralStoreNeverTouchesDisk() throws {
        let store = EphemeralSessionUserStore()
        #expect(try store.load() == nil)
        try store.save(sampleUser)
        #expect(try store.load() == sampleUser)
        try store.remove()
        #expect(try store.load() == nil)
    }
}

// MARK: - Active profile resolution (§5.3, INV-1)

struct ActiveProfileResolutionTests {
    private func makeProfile(
        id: UUID = UUID(),
        kind: Profile.Kind = .standard,
        name: String = "P",
        isLocked: Bool = false
    ) -> Profile {
        Profile(
            id: id,
            kind: kind,
            name: name,
            colorHex: nil,
            createdAt: Date(timeIntervalSince1970: 1_785_628_800),
            lastActiveAt: Date(timeIntervalSince1970: 1_785_628_900),
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: isLocked,
            storeMaterialized: true,
            sessionDisposition: .active
        )
    }

    @Test func unlockedActiveProfileResolvesDirectly() {
        let active = makeProfile()
        let local = makeProfile(kind: .system, name: "Local")
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: active.id, profiles: [local, active]
        )
        #expect(ActiveProfileResolution.resolve(document: document) == .active(active))
    }

    @Test func lockedActiveProfileFallsBackToLocal() {
        let locked = makeProfile(isLocked: true)
        let local = makeProfile(kind: .system, name: "Local")
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: locked.id, profiles: [local, locked]
        )
        guard case .fallbackToLocal(let resolved, _) =
            ActiveProfileResolution.resolve(document: document) else {
            Issue.record("expected fallback to Local")
            return
        }
        #expect(resolved == local)
    }

    @Test func missingActiveProfileFallsBackToLocal() {
        let local = makeProfile(kind: .system, name: "Local")
        let other = makeProfile()
        var document = ProfileRegistryDocument(
            version: 1, activeProfileID: other.id, profiles: [local, other]
        )
        document.activeProfileID = UUID()
        guard case .fallbackToLocal(let resolved, _) =
            ActiveProfileResolution.resolve(document: document) else {
            Issue.record("expected fallback to Local")
            return
        }
        #expect(resolved == local)
    }

    @Test func noSystemLocalIsUnresolvable() {
        let locked = makeProfile(isLocked: true)
        var document = ProfileRegistryDocument(
            version: 1, activeProfileID: locked.id, profiles: [locked]
        )
        document.activeProfileID = locked.id
        guard case .unresolvable = ActiveProfileResolution.resolve(document: document) else {
            Issue.record("expected unresolvable")
            return
        }
    }

    @Test func lockedSystemLocalIsUnresolvableNotGuessed() {
        // The registry validator forbids persisting a locked system profile;
        // resolution still refuses to run as one if it ever observes it.
        let locked = makeProfile(isLocked: true)
        let localLocked = makeProfile(kind: .system, name: "Local", isLocked: true)
        var document = ProfileRegistryDocument(
            version: 1, activeProfileID: locked.id, profiles: [localLocked, locked]
        )
        document.activeProfileID = locked.id
        guard case .unresolvable = ActiveProfileResolution.resolve(document: document) else {
            Issue.record("expected unresolvable")
            return
        }
    }
}

// MARK: - ProfileContext token slot

struct ProfileContextTokenTests {
    private func makeProfile(bound: Profile.BoundAccount?) -> Profile {
        Profile(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .standard,
            name: "P",
            colorHex: nil,
            createdAt: Date(timeIntervalSince1970: 1_785_628_800),
            lastActiveAt: Date(timeIntervalSince1970: 1_785_628_900),
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: bound,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
    }

    @Test func boundProfileDerivesTokenAccountFromStoredOrigin() throws {
        let origin = try IssuerOrigin(url: URL(string: "https://cadenzapp.com/api/v1")!)
        let bound = Profile.BoundAccount(
            userID: "u",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "e",
            displayName: "d",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
        let context = ProfileContext(
            profile: makeProfile(bound: bound),
            paths: ProfilePaths(root: URL(fileURLWithPath: "/tmp/profiles-root"))
        )
        #expect(context.tokenAccount ==
            "cadenza.session.token.11111111-2222-3333-4444-555555555555.\(origin.originKey)")
        #expect(context.sessionUserURL.path.hasSuffix(
            "Profiles/11111111-2222-3333-4444-555555555555/session-user.json"))
    }

    @Test func unboundProfileHasNoTokenSlot() {
        let context = ProfileContext(
            profile: makeProfile(bound: nil),
            paths: ProfilePaths(root: URL(fileURLWithPath: "/tmp/profiles-root"))
        )
        #expect(context.tokenAccount == nil)
    }

    @Test func malformedStoredIssuerOriginYieldsNoTokenSlot() {
        let bound = Profile.BoundAccount(
            userID: "u",
            originKey: "0123456789abcdef",
            issuerOrigin: "not a url",
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "e",
            displayName: "d",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
        let context = ProfileContext(
            profile: makeProfile(bound: bound),
            paths: ProfilePaths(root: URL(fileURLWithPath: "/tmp/profiles-root"))
        )
        #expect(context.tokenAccount == nil)
    }
}

// MARK: - Opaque-ID key components

@Suite struct AccountIdentityKeyTests {
    @Test func byteEqualityDistinguishesCanonicallyEquivalentSpellings() {
        let nfc = "us\u{00E9}r-1"
        let nfd = "use\u{0301}r-1"
        #expect(nfc == nfd)
        #expect(!AccountIdentity.matches(nfc, nfd))
        #expect(AccountIdentity.matches(nfc, nfc))
        #expect(AccountIdentity.byteKey(nfc) != AccountIdentity.byteKey(nfd))
    }

    @Test func keyComponentKeepsSafeASCIIAndTagsEverythingElse() {
        // Deployed ASCII IDs keep their raw spelling — existing sync
        // rows and preference keys stay reachable.
        #expect(AccountIdentity.keyComponent("user-1") == "user-1")
        #expect(AccountIdentity.keyComponent("109876543210") == "109876543210")

        // Canonically equivalent spellings produce byte-distinct tagged
        // components.
        let nfc = AccountIdentity.keyComponent("us\u{00E9}r-1")
        let nfd = AccountIdentity.keyComponent("use\u{0301}r-1")
        #expect(nfc.hasPrefix("u8x:"))
        #expect(Array(nfc.utf8) != Array(nfd.utf8))

        // Only the colon (the derived-key delimiter) and non-ASCII
        // escape; every other deployed ASCII spelling stays raw.
        #expect(AccountIdentity.keyComponent("a#b") == "a#b")
        #expect(AccountIdentity.keyComponent("u8xdeadbeef") == "u8xdeadbeef")
        #expect(AccountIdentity.keyComponent("a:b").hasPrefix("u8x:"))
        #expect(AccountIdentity.keyComponent("a:b") != "a:b")
        #expect(AccountIdentity.keyComponent("u8x:deadbeef").hasPrefix("u8x:"))
        #expect(AccountIdentity.keyComponent("u8x:deadbeef") != "u8x:deadbeef")
        // Empty IDs fail closed into the tag, never a usable bare key.
        #expect(AccountIdentity.keyComponent("") == "u8x:")
    }

    @Test func syncKeysAreByteDistinctForCanonicallyEquivalentIDs() {
        let recordingID = UUID()
        let nfcKey = WebSyncRecord.key(userID: "us\u{00E9}r-1", recordingID: recordingID)
        let nfdKey = WebSyncRecord.key(userID: "use\u{0301}r-1", recordingID: recordingID)
        #expect(Array(nfcKey.utf8) != Array(nfdKey.utf8))
        // ASCII IDs keep the deployed key format.
        #expect(WebSyncRecord.key(userID: "user-1", recordingID: recordingID)
            == "user-1:\(recordingID.uuidString.lowercased())")
    }
}
