import CryptoKit
import Foundation
import os

/// Server-issued account IDs are opaque byte strings: identity and
/// ownership comparisons use exact UTF-8 bytes, never Swift's
/// canonical-equivalence String equality, so canonically equal but
/// byte-distinct IDs (NFC vs NFD spellings) can never bind, unlock, or
/// clean up each other's artifacts.
enum AccountIdentity {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Collision-free set key for uniqueness checks: hashed containers
    /// collapse canonically equal strings, so the key carries the exact
    /// bytes in hex.
    static func byteKey(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Byte-exact comparison of the complete frozen bound-account
    /// security tuple (userID, originKey, issuerOrigin, apiBaseURL);
    /// display fields are not identity. Nil matches only nil.
    static func boundTupleMatches(
        _ lhs: Profile.BoundAccount?, _ rhs: Profile.BoundAccount?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let fresh?, let expected?):
            return matches(fresh.userID, expected.userID)
                && matches(fresh.originKey, expected.originKey)
                && matches(fresh.issuerOrigin, expected.issuerOrigin)
                && matches(fresh.apiBaseURL, expected.apiBaseURL)
        default:
            return false
        }
    }

    /// Canonical-representation-safe component for embedding an opaque
    /// server ID in a derived storage key. Nonempty ASCII IDs without a
    /// colon keep their raw spelling exactly, so every deployed sync row
    /// and preference key stays reachable; anything else gets the tagged
    /// UTF-8 hex form. Byte-distinct IDs can never alias: raw components
    /// are colon-free, so the "u8x:" namespace is unreachable for them,
    /// and tagged components are the injective hex of the exact bytes.
    /// Empty IDs (forbidden by registry validation) fail closed into the
    /// tag rather than yielding a usable bare key.
    static func keyComponent(_ value: String) -> String {
        let isSafeASCII = !value.isEmpty && value.utf8.allSatisfy { byte in
            byte < 0x80 && byte != UInt8(ascii: ":")
        }
        if isSafeASCII {
            return value
        }
        return "u8x:" + byteKey(value)
    }
}

/// Per-profile session identity persisted at `Profiles/<id>/session-user.json`
/// (spec §5.1). Non-secret display data only; the token lives in the Keychain
/// under a per-(profile, origin) account (§5.2).
struct SessionUser: Codable, Equatable, Sendable {
    let userID: String
    let email: String
    let displayName: String
    let pictureURL: URL?
    /// Durable ownership evidence for the binding two-phase commit: while a
    /// binding is mid-flight this carries the writing transaction's ID, so
    /// a rollback can prove the file is its own artifact before deleting
    /// it. Retained after commit as provenance; correctness never depends
    /// on it once the pending record is cleared, so later session
    /// refreshes may rewrite the file without it.
    let bindingTransactionID: UUID?

    init(
        userID: String,
        email: String,
        displayName: String,
        pictureURL: URL?,
        bindingTransactionID: UUID? = nil
    ) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.bindingTransactionID = bindingTransactionID
    }

    enum ValidationError: Error, Equatable {
        case emptyUserID
    }

    func validate() throws {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyUserID
        }
    }
}

/// Keychain account naming for per-profile session tokens (§5.2). The
/// service name stays `com.shuiandy.Cadenza`; the account pins the token to
/// both the profile and the issuing origin so a token can never be read for
/// a different backend (INV-7).
enum SessionTokenKey {
    static let legacyGlobalAccount = "cadenza.session.token"

    static func account(profileID: UUID, originKey: String) -> String {
        "cadenza.session.token.\(profileID.uuidString).\(originKey)"
    }
}

/// Irreversible fingerprint of a token value (SHA-256 hex over its UTF-8
/// bytes). The binding transaction records it in the pending record so
/// every later phase can prove the Keychain slot still holds this
/// transaction's write without persisting the token itself.
enum SessionTokenDigest {
    static func digest(of raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Derives the observable auth state from durable facts (§4.1): the
/// registry's session disposition distinguishes an explicit sign-out from a
/// lost/expired token, so a missing token on an active session presents as
/// `.expired` — never as signed-out, and never locks the profile (INV-3).
/// `.signingIn` is a transient in-memory state owned by the login flow.
enum ProfileSessionDerivation {
    static func authState(
        boundAccount: Profile.BoundAccount?,
        sessionDisposition: Profile.SessionDisposition,
        tokenPresent: Bool
    ) -> CadenzaAuthService.SessionState {
        guard boundAccount != nil else { return .signedOut }
        switch sessionDisposition {
        case .explicitlySignedOut:
            return .signedOut
        case .tokenInvalidated:
            // Durable expiry record wins over whatever the Keychain slot
            // still holds — a failed cleanup never resurrects a session.
            return .expired
        case .active:
            return tokenPresent ? .signedIn : .expired
        }
    }
}

/// Persistence seam for the per-profile session user. `load()` returns nil
/// only on definite absence; malformed content or unclassifiable probe
/// errors throw so callers never mistake unknown for signed-out.
protocol SessionUserStoring: Sendable {
    func load() throws -> SessionUser?
    func save(_ user: SessionUser) throws
    func remove() throws
}

/// File-backed store for `Profiles/<id>/session-user.json`. Writes are
/// atomic (0600, fsync'd rename); reads refuse symlinks and non-regular
/// files.
struct FileSessionUserStore: SessionUserStoring {
    let url: URL
    let fileOperations: FileOperations

    func load() throws -> SessionUser? {
        do {
            try requireRegularFile(at: url, fileOperations: fileOperations)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let data = try fileOperations.read(from: url)
        let user = try JSONDecoder().decode(SessionUser.self, from: data)
        try user.validate()
        return user
    }

    func save(_ user: SessionUser) throws {
        try user.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(user)
        try fileOperations.atomicReplace(data, at: url)
    }

    func remove() throws {
        do {
            try fileOperations.removeItem(at: url)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Definite absence — removal is idempotent. Anything else
            // (permissions, unknown IO) propagates.
        }
    }
}

/// In-memory store for TestHost (INV-8) — no real profile directory is ever
/// touched by tests.
final class EphemeralSessionUserStore: SessionUserStoring, Sendable {
    private let lock = OSAllocatedUnfairLock<SessionUser?>(initialState: nil)

    func load() throws -> SessionUser? {
        lock.withLock { $0 }
    }

    func save(_ user: SessionUser) throws {
        try user.validate()
        lock.withLock { $0 = user }
    }

    func remove() throws {
        lock.withLock { $0 = nil }
    }
}
