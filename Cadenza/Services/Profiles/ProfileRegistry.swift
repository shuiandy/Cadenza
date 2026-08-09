import Foundation
import os

/// One profile entry in the registry (spec §4.1, schema version 1).
/// The M1 migration produces the first `standard` profile; the session
/// migrations bind it and establish the permanent system Local, and the
/// login flow may create further account profiles. The bound-account,
/// lock, and disposition fields are live session state — the registry is
/// the single durable authority for all of them.
struct Profile: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case system
        case standard
    }

    struct AudioDirectory: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case appManaged
            case userSelected
        }

        /// Security-scoped bookmark for user-chosen directories; nil for the
        /// default location, which is re-derived by path.
        var bookmark: Data?
        /// Absolute path recorded for diagnostics and default-location
        /// re-derivation; the bookmark wins when both exist.
        var path: String
        var kind: Kind
    }

    struct BoundAccount: Codable, Sendable, Equatable {
        var userID: String
        var originKey: String
        var issuerOrigin: String
        var apiBaseURL: String
        var displayEmail: String
        var displayName: String
        var boundAt: Date
    }

    var id: UUID
    var kind: Kind
    var name: String
    var colorHex: String?
    var createdAt: Date
    var lastActiveAt: Date
    var audioDirectory: AudioDirectory
    var boundAccount: BoundAccount?
    var lockOnSignOut: Bool
    var isLocked: Bool
    /// One-time materialization boundary, kept in the registry so it lives
    /// in a different failure domain than the store itself: a migrated
    /// profile commits as true; a fresh profile starts false and flips to
    /// true atomically right after its container is first created and
    /// before anything can write user data. Only an explicit false permits
    /// a missing store to materialize — losing the whole profile directory
    /// halts the boot instead of silently recreating an empty database.
    var storeMaterialized: Bool

    enum SessionDisposition: String, Codable, Sendable {
        case active
        case explicitlySignedOut
        /// Durable record that the session's token was invalidated (401 or
        /// local expiry handling): the profile presents `.expired` even if
        /// a stale token value survives in the Keychain slot, so a failed
        /// slot cleanup can never resurrect a dead session. Cleared back
        /// to `active` by a successful re-login.
        case tokenInvalidated
    }

    var sessionDisposition: SessionDisposition
    /// Creation provenance for transfer eligibility (spec §6.4, INV-19):
    /// the binding transaction that created this profile row, stamped in
    /// phase A and never set by any other path. Cleared once the profile
    /// materializes its store or a transfer targeting it resolves —
    /// eligibility is one-shot, so an emptied or rebuilt profile can
    /// never present as freshly created again. Nil for migrated, system,
    /// and legacy rows.
    var createdByBindingTransactionID: UUID? = nil
}

/// Two-phase-commit intermediate state for account binding (spec §5.6).
/// Present only while a binding is mid-flight; boot recovery either
/// completes or rolls it back.
struct PendingBinding: Codable, Sendable, Equatable {
    /// Tags this transaction's side effects: the store rows marked in
    /// phase B2 carry it, so a rollback removes exactly this transaction's
    /// marks and nothing that legitimately existed before.
    var transactionID: UUID
    var profileID: UUID
    var userID: String
    var originKey: String
    /// Issuer identity captured at phase A so a crash recovery can rebuild
    /// the boundAccount at phase C — the originKey hash alone cannot be
    /// reversed into an origin.
    var issuerOrigin: String
    var apiBaseURL: String
    /// SHA-256 hex of the token value phase B writes into the Keychain
    /// slot — irreversible ownership evidence. Recovery, commit, and
    /// rollback verify the slot's current value against it; a mismatch is
    /// a foreign token that must never be committed or removed. Nil for a
    /// tokenless binding (migrating a session whose token was already
    /// lost, INV-3): the slot is then expected to stay empty.
    var tokenDigest: String?
    /// True when phase A created the target profile in the same atomic
    /// commit — rollback then removes the still-inert profile again, so a
    /// crash can never leave an unowned empty profile behind.
    var createdProfile: Bool
    var startedAt: Date

    init(
        transactionID: UUID,
        profileID: UUID,
        userID: String,
        originKey: String,
        issuerOrigin: String,
        apiBaseURL: String,
        tokenDigest: String?,
        createdProfile: Bool = false,
        startedAt: Date
    ) {
        self.transactionID = transactionID
        self.profileID = profileID
        self.userID = userID
        self.originKey = originKey
        self.issuerOrigin = issuerOrigin
        self.apiBaseURL = apiBaseURL
        self.tokenDigest = tokenDigest
        self.createdProfile = createdProfile
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case transactionID, profileID, userID, originKey
        case issuerOrigin, apiBaseURL, tokenDigest, createdProfile, startedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionID = try container.decode(UUID.self, forKey: .transactionID)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        userID = try container.decode(String.self, forKey: .userID)
        originKey = try container.decode(String.self, forKey: .originKey)
        issuerOrigin = try container.decode(String.self, forKey: .issuerOrigin)
        apiBaseURL = try container.decode(String.self, forKey: .apiBaseURL)
        tokenDigest = try container.decodeIfPresent(String.self, forKey: .tokenDigest)
        createdProfile = try container.decodeIfPresent(Bool.self, forKey: .createdProfile)
            ?? false
        startedAt = try container.decode(Date.self, forKey: .startedAt)
    }
}

/// Durable intent and checkpoint record for a whole-store transfer
/// (spec §6.4, INV-19). Present only between initiation and the relaunch
/// transfer mode's commit or refusal. Strictly decoded: an unknown mode,
/// state, or version fails the registry load, and the boot halts rather
/// than guessing.
struct PendingTransfer: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable {
        case copy
        case move
    }

    /// Ordered durable checkpoints; recovery resumes from the recorded
    /// state. `initiated` is written by the initiating flow before the
    /// relaunch; the later states belong to the transfer executor.
    enum State: String, Codable, Sendable, CaseIterable {
        case initiated
        case sourceSnapshotted
        case staged
        case targetVerified
        case placed
        /// Move only: the replacement empty Local store is built and
        /// verified before any source-side cleanup.
        case localRebuilt
    }

    /// Frozen full-row snapshot of one side, captured at initiation and
    /// re-proven in transfer mode before any work: a side that drifted
    /// refuses or halts, never proceeds against the changed profile.
    /// Comparison runs over the deterministic registry encoding of the
    /// complete row, so every field — current and future — participates
    /// byte-exactly; synthesized equality (canonical-equivalence String
    /// comparison) is never used for the proof.
    struct ProfileEvidence: Codable, Sendable, Equatable {
        var profile: Profile

        init(profile: Profile) {
            self.profile = profile
        }

        func matches(_ other: Profile) -> Bool {
            let encoder = ProfileRegistryCoding.makeEncoder()
            guard let lhs = try? encoder.encode(profile),
                  let rhs = try? encoder.encode(other) else {
                return false
            }
            return lhs == rhs
        }
    }

    var version: Int
    var transactionID: UUID
    var placementClaimToken: UUID
    var sourceProfileID: UUID
    var targetProfileID: UUID
    var mode: Mode
    var state: State
    var startedAt: Date
    var sourceEvidence: ProfileEvidence
    var targetEvidence: ProfileEvidence
    /// Executor checkpoint payloads, nil until their state is reached.
    /// Ownership and resume decisions run on these recorded proofs, never
    /// on timestamps or directory heuristics.
    var snapshotReceipt: SnapshotReceipt?
    var sourceStoreEvidence: SourceEvidence?
    var sourceContentDigest: String?
    var audioPlan: TransferAudioPlan?
    /// Logical digest of the staged store after the reference rewrite;
    /// the receipt's pre-rewrite proofs cannot cover the mutated target.
    var targetContentDigest: String?
    /// Exact bytes of the staged store after the rewrite, for placement
    /// and resume confirmation.
    var stagedStoreSHA256: String?
    /// Move-only raw proofs for the final replacement candidate.
    var replacementContentDigest: String?
    var replacementStoreSHA256: String?
}

/// Every audio byte the transfer moves and every reference it rewrites,
/// recorded at staging time: per-file exact source identity and bytes,
/// plus the per-row field rewrites the staged store received. Copy,
/// confirm, verification, and cleanup decisions all run on this plan.
struct TransferAudioPlan: Codable, Sendable, Equatable {
    enum Field: String, Codable, Sendable, CaseIterable {
        case audioFile
        case segmentsDirectory
    }

    /// One physical file to place. The entry carries no absolute source
    /// path: the source location is re-derived at use time from the
    /// frozen profile root plus the verified snapshot row, and the entry
    /// only identifies which row and which tree child it belongs to —
    /// the persisted plan is evidence, never path authority.
    struct File: Codable, Sendable, Equatable {
        var recordingID: UUID
        var field: Field
        /// nil for the referenced file itself; the tree-relative child
        /// path for a file inside a segments directory.
        var childRelativePath: String?
        var size: Int64
        var sha256: String
        /// Ownership recorded from the source row — the move-side
        /// cleanup evidence, re-checked against the snapshot row before
        /// any deletion. Target rows always own their fresh copies.
        var sourceOwnership: AudioFileOwnership
    }

    /// One directory to materialize at the target. Trees are described
    /// completely — the root, every nested directory (including empty
    /// ones), and every file — so placement never derives structure
    /// from the filesystem at copy time.
    struct DirectoryEntry: Codable, Sendable, Equatable {
        var recordingID: UUID
        var field: Field
        /// nil for the tree root itself; the tree-relative path for a
        /// nested directory.
        var childRelativePath: String?
    }

    struct Rewrite: Codable, Sendable, Equatable {
        var recordingID: UUID
        var field: Field
        /// Exact stored reference value before the rewrite.
        var sourceReference: String
        /// Exact stored reference value after the rewrite. Always the
        /// transaction-owned target namespace path, re-derived and
        /// checked at every use.
        var destinationReference: String
    }

    var files: [File]
    var directories: [DirectoryEntry]
    var rewrites: [Rewrite]
}

/// The registry document persisted at `profiles.json`. The pending fields
/// serialize as explicit JSON `null` when empty — the on-disk document
/// always carries both keys, so "no pending operation" is a recorded state
/// rather than an absent field (spec §4.1 sample document).
struct ProfileRegistryDocument: Codable, Sendable, Equatable {
    var version: Int
    var activeProfileID: UUID
    var pendingBinding: PendingBinding?
    var pendingTransfer: PendingTransfer?
    var profiles: [Profile]

    static let currentVersion = 1

    init(
        version: Int,
        activeProfileID: UUID,
        pendingBinding: PendingBinding? = nil,
        pendingTransfer: PendingTransfer? = nil,
        profiles: [Profile]
    ) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.pendingBinding = pendingBinding
        self.pendingTransfer = pendingTransfer
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case activeProfileID
        case pendingBinding
        case pendingTransfer
        case profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        activeProfileID = try container.decode(UUID.self, forKey: .activeProfileID)
        pendingBinding = try container.decodeIfPresent(PendingBinding.self, forKey: .pendingBinding)
        pendingTransfer = try container.decodeIfPresent(
            PendingTransfer.self, forKey: .pendingTransfer
        )
        profiles = try container.decode([Profile].self, forKey: .profiles)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(activeProfileID, forKey: .activeProfileID)
        if let pendingBinding {
            try container.encode(pendingBinding, forKey: .pendingBinding)
        } else {
            try container.encodeNil(forKey: .pendingBinding)
        }
        if let pendingTransfer {
            try container.encode(pendingTransfer, forKey: .pendingTransfer)
        } else {
            try container.encodeNil(forKey: .pendingTransfer)
        }
        try container.encode(profiles, forKey: .profiles)
    }
}

enum ProfileRegistryError: Error, Equatable {
    case malformedDocument(String)
    case unsupportedVersion(Int)
    case invariantViolated(String)
}

extension ProfileRegistryDocument {
    /// Structural invariants enforced on every load and save: a document
    /// violating them is treated as corrupt, never partially honored.
    func validate() throws {
        guard version >= 1 else {
            throw ProfileRegistryError.unsupportedVersion(version)
        }
        guard version <= Self.currentVersion else {
            throw ProfileRegistryError.unsupportedVersion(version)
        }
        guard !profiles.isEmpty else {
            throw ProfileRegistryError.invariantViolated("no profiles")
        }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw ProfileRegistryError.invariantViolated("duplicate profile ids")
        }
        guard profiles.contains(where: { $0.id == activeProfileID }) else {
            throw ProfileRegistryError.invariantViolated("active profile missing")
        }
        for profile in profiles where profile.audioDirectory.path.isEmpty {
            throw ProfileRegistryError.invariantViolated("empty audio directory path")
        }
        guard profiles.filter({ $0.kind == .system }).count <= 1 else {
            throw ProfileRegistryError.invariantViolated("multiple system profiles")
        }
        for profile in profiles where profile.kind == .system {
            guard profile.boundAccount == nil else {
                throw ProfileRegistryError.invariantViolated("system profile is bound")
            }
            guard !profile.isLocked else {
                throw ProfileRegistryError.invariantViolated("system profile is locked")
            }
        }
        var boundIdentities: Set<String> = []
        for profile in profiles where profile.kind == .system {
            guard profile.createdByBindingTransactionID == nil else {
                throw ProfileRegistryError.invariantViolated(
                    "system profile cannot carry creation provenance"
                )
            }
        }
        // Creation provenance is one-shot phase-A output: it may exist
        // only on an unmaterialized standard profile, and only inside
        // the two legal windows — mid-transaction (a matching created
        // pending binding) or the post-creation bound window.
        for profile in profiles {
            guard let provenance = profile.createdByBindingTransactionID else { continue }
            guard profile.kind == .standard, !profile.storeMaterialized else {
                throw ProfileRegistryError.invariantViolated(
                    "creation provenance on a materialized or non-standard profile"
                )
            }
            let midTransaction = pendingBinding.map {
                $0.createdProfile && $0.profileID == profile.id
                    && $0.transactionID == provenance
            } ?? false
            guard midTransaction || profile.boundAccount != nil else {
                throw ProfileRegistryError.invariantViolated(
                    "creation provenance outside its legal windows"
                )
            }
        }
        for profile in profiles {
            guard let bound = profile.boundAccount else { continue }
            guard !bound.userID.isEmpty else {
                throw ProfileRegistryError.invariantViolated("bound account missing userID")
            }
            guard let origin = try? IssuerOrigin(validating: bound.issuerOrigin),
                  origin.originKey == bound.originKey else {
                throw ProfileRegistryError.invariantViolated(
                    "bound account origin does not match its origin key"
                )
            }
            guard let base = URL(string: bound.apiBaseURL), origin.covers(requestURL: base) else {
                throw ProfileRegistryError.invariantViolated(
                    "bound account base URL is outside its issuer origin"
                )
            }
            // Byte-keyed: hashed String uniqueness would collapse
            // canonically equal but byte-distinct user IDs.
            let identity = "\(bound.originKey)#\(AccountIdentity.byteKey(bound.userID))"
            guard boundIdentities.insert(identity).inserted else {
                throw ProfileRegistryError.invariantViolated(
                    "one account bound to multiple profiles"
                )
            }
        }
        if let binding = pendingBinding {
            guard let target = profiles.first(where: { $0.id == binding.profileID }) else {
                throw ProfileRegistryError.invariantViolated(
                    "pending binding references unknown profile"
                )
            }
            guard target.kind != .system else {
                throw ProfileRegistryError.invariantViolated(
                    "pending binding targets the system profile"
                )
            }
            guard target.boundAccount == nil else {
                throw ProfileRegistryError.invariantViolated(
                    "pending binding targets an already-bound profile"
                )
            }
            guard !binding.userID.isEmpty, !binding.originKey.isEmpty else {
                throw ProfileRegistryError.invariantViolated("pending binding missing identity")
            }
            if let digest = binding.tokenDigest {
                guard digest.count == 64,
                      digest.allSatisfy({
                          $0.isHexDigit && (!$0.isLetter || $0.isLowercase)
                      }) else {
                    throw ProfileRegistryError.invariantViolated(
                        "pending binding token digest malformed"
                    )
                }
            }
            guard let origin = try? IssuerOrigin(validating: binding.issuerOrigin),
                  origin.originKey == binding.originKey else {
                throw ProfileRegistryError.invariantViolated(
                    "pending binding origin does not match its origin key"
                )
            }
            guard let base = URL(string: binding.apiBaseURL),
                  origin.covers(requestURL: base) else {
                throw ProfileRegistryError.invariantViolated(
                    "pending binding base URL is outside its issuer origin"
                )
            }
            if binding.createdProfile {
                guard activeProfileID != binding.profileID else {
                    throw ProfileRegistryError.invariantViolated(
                        "transaction-created profile cannot be active while pending"
                    )
                }
                guard !target.storeMaterialized else {
                    throw ProfileRegistryError.invariantViolated(
                        "transaction-created profile cannot be materialized while pending"
                    )
                }
                guard target.createdByBindingTransactionID == binding.transactionID else {
                    throw ProfileRegistryError.invariantViolated(
                        "transaction-created profile missing its creation provenance"
                    )
                }
            }
        }
        if pendingBinding != nil, pendingTransfer != nil {
            throw ProfileRegistryError.invariantViolated(
                "binding and transfer cannot both be pending"
            )
        }
        if let transfer = pendingTransfer {
            // Writer basics only: every legal writer guarantees these and
            // no legitimate later mutation can break them. The transfer
            // semantics (frozen evidence match, checkpoint legality,
            // target freshness) are classified on the trusted document by
            // the boot interception — a semantic mismatch must halt there,
            // never turn the registry "unreadable" and route into the M1
            // journal rebuild, which would destroy later authority.
            guard transfer.version == 1 else {
                throw ProfileRegistryError.invariantViolated(
                    "unsupported pending transfer version"
                )
            }
            guard transfer.sourceProfileID != transfer.targetProfileID else {
                throw ProfileRegistryError.invariantViolated("transfer source equals target")
            }
        }
    }
}

extension ProfileRegistryDocument {
    /// Save-side validation: everything `validate()` enforces plus the
    /// strict pending-transfer writer invariants. The load path keeps
    /// the lighter rule set on purpose — a semantically drifted transfer
    /// must still load as a trusted document so the boot classification
    /// halts on it, instead of the load failure routing the boot into
    /// the M1 journal rebuild over later authority.
    func validateForSave() throws {
        try validate()
        if let transfer = pendingTransfer,
           let problem = ProfileTransfer.structuralProblem(
               document: self, pending: transfer
           ) {
            throw ProfileRegistryError.invariantViolated(problem)
        }
    }
}

/// Presence of the registry artifact. Only a definite not-found is
/// `absent`; a node whose metadata cannot be read may be a committed
/// registry, so callers must route it to the unreadable-registry recovery,
/// never to a fresh migration.
enum RegistryPresence: Equatable, Sendable {
    case present
    case absent
    case unprobeable(String)
}

/// Registry persistence behind a protocol so ephemeral environments run on
/// an in-memory document and never touch the real registry file.
protocol ProfileRegistryProviding: Sendable {
    func presence() -> RegistryPresence
    func load() throws -> ProfileRegistryDocument
    func save(_ document: ProfileRegistryDocument) throws
}

/// Dates persist as epoch seconds (Double): exact round-trip with no
/// formatter or locale variance. String date formats truncate fractional
/// seconds, so format-then-parse is not idempotent.
enum ProfileRegistryCoding {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Reads and writes `profiles.json`. Writes are atomic (temp file plus
/// `rename(2)` plus parent-directory fsync, INV-14). Decoding tolerates
/// unknown fields so newer documents from a later version still load in
/// older code. All IO goes through the injected `FileOperations` seam.
struct DiskProfileRegistry: ProfileRegistryProviding {
    let registryURL: URL
    let fileOperations: FileOperations

    /// lstat semantics with classified failures: a symlink still counts as
    /// present — the registry's presence marks a committed migration, and
    /// a link must surface as an unreadable registry (load rejects it) —
    /// and a metadata error is `unprobeable`, never absent.
    func presence() -> RegistryPresence {
        do {
            _ = try fileOperations.attributesOfItem(at: registryURL)
            return .present
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .unprobeable(String(describing: error))
        }
    }

    func load() throws -> ProfileRegistryDocument {
        do {
            try requireRegularFile(at: registryURL, fileOperations: fileOperations)
        } catch {
            throw ProfileRegistryError.malformedDocument("not a regular file")
        }
        let data: Data
        do {
            data = try fileOperations.read(from: registryURL)
        } catch {
            throw ProfileRegistryError.malformedDocument(
                "unreadable: \(error.localizedDescription)"
            )
        }
        let document: ProfileRegistryDocument
        do {
            document = try ProfileRegistryCoding.makeDecoder().decode(
                ProfileRegistryDocument.self, from: data
            )
        } catch {
            throw ProfileRegistryError.malformedDocument("undecodable: \(error)")
        }
        try document.validate()
        return document
    }

    /// Atomic write (INV-14): temp sibling with tight permissions, fsync of
    /// the file, `rename(2)`, then fsync of the parent directory so the new
    /// entry itself is durable. A crash leaves the old document or the new
    /// one, never a torn file.
    func save(_ document: ProfileRegistryDocument) throws {
        try document.validateForSave()
        let data = try ProfileRegistryCoding.makeEncoder().encode(document)
        try fileOperations.atomicReplace(data, at: registryURL)
    }
}

/// Registry for ephemeral environments (TestHost, previews): the document
/// lives in memory only, so nothing ever reaches the real profiles.json.
final class InMemoryProfileRegistry: ProfileRegistryProviding, Sendable {
    private let storage = OSAllocatedUnfairLock<ProfileRegistryDocument?>(initialState: nil)

    func presence() -> RegistryPresence {
        storage.withLock { $0 != nil } ? .present : .absent
    }

    func load() throws -> ProfileRegistryDocument {
        guard let document = storage.withLock({ $0 }) else {
            throw ProfileRegistryError.malformedDocument("no in-memory document")
        }
        try document.validate()
        return document
    }

    func save(_ document: ProfileRegistryDocument) throws {
        // Round-trip through the shared coders and the shared validation so
        // in-memory behavior matches disk exactly.
        try document.validateForSave()
        let data = try ProfileRegistryCoding.makeEncoder().encode(document)
        let decoded = try ProfileRegistryCoding.makeDecoder().decode(
            ProfileRegistryDocument.self, from: data
        )
        storage.withLock { $0 = decoded }
    }
}
