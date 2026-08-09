import Foundation
import SwiftData

/// Result of a B2 marking pass. The transaction commits only when the
/// whole row set is provably stamped by this transaction:
/// `newlyMarked + previouslyMarked == total`.
struct HistoricalMarkResult: Equatable, Sendable {
    let newlyMarked: Int
    let previouslyMarked: Int
    let total: Int

    var coversAllRows: Bool { newlyMarked + previouslyMarked == total }
}

enum HistoricalMarkingError: Error, Equatable {
    /// A row already carries a different transaction's mark. Marks from a
    /// rolled-back transaction are always cleared by its recovery, so a
    /// foreign mark is unclassifiable state — never silently absorbed.
    case foreignMark(existing: UUID)
}

/// Marks and unmarks the awaiting-historical-consent rows of a profile
/// store (§5.6 phase B2). Synchronous seam used by boot recovery and the
/// M2 migration, which run before any regular container is open.
protocol HistoricalConsentMarking {
    /// Idempotently stamps every unmarked recording with the transaction
    /// ID. Rows already stamped by the same transaction count as
    /// previously marked; a foreign mark throws.
    func markAll(storeURL: URL, transactionID: UUID) throws -> HistoricalMarkResult
    /// Removes exactly the marks carrying the transaction ID.
    func clearMarks(storeURL: URL, transactionID: UUID) throws -> Int
}

/// Direct-container implementation for code paths where the profile's
/// regular container is not open (boot recovery, M2). Never creates a
/// store: callers gate on classified presence first.
struct SwiftDataHistoricalConsentMarker: HistoricalConsentMarking {
    func markAll(storeURL: URL, transactionID: UUID) throws -> HistoricalMarkResult {
        try withContext(storeURL) { context in
            let rows = try context.fetch(FetchDescriptor<Recording>())
            var newlyMarked = 0
            var previouslyMarked = 0
            for row in rows {
                switch row.awaitingHistoricalConsentBindingID {
                case nil:
                    row.awaitingHistoricalConsentBindingID = transactionID
                    newlyMarked += 1
                case transactionID:
                    previouslyMarked += 1
                case .some(let foreign):
                    throw HistoricalMarkingError.foreignMark(existing: foreign)
                }
            }
            if newlyMarked > 0 { try context.save() }
            return HistoricalMarkResult(
                newlyMarked: newlyMarked, previouslyMarked: previouslyMarked, total: rows.count
            )
        }
    }

    func clearMarks(storeURL: URL, transactionID: UUID) throws -> Int {
        try withContext(storeURL) { context in
            let rows = try context.fetch(FetchDescriptor<Recording>())
            var cleared = 0
            for row in rows where row.awaitingHistoricalConsentBindingID == transactionID {
                row.awaitingHistoricalConsentBindingID = nil
                cleared += 1
            }
            if cleared > 0 { try context.save() }
            return cleared
        }
    }

    private func withContext<T>(_ storeURL: URL, _ body: (ModelContext) throws -> T) throws -> T {
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        return try body(context)
    }
}

/// Two-phase account binding (§5.6, INV-14): A records the intent in the
/// registry, B writes the session artifacts, B2 stamps the historical row
/// set, C commits the bound account and clears the intent. Every durable
/// step is atomic; a crash at any point leaves a state the boot recovery
/// resolves to fully-bound or fully-rolled-back — no observable
/// half-binding.
///
/// Phase C sets `sessionDisposition = .active` per §5.5/§5.6; switching
/// `activeProfileID` to the bound profile is the separate relaunch step
/// (§7) owned by the login flow, never by this transaction.
@MainActor
enum ProfileBindingTransaction {
    /// Template for a profile phase A creates atomically together with
    /// the pending record — creation is owned by the transaction, never a
    /// standalone commit.
    struct NewProfileTemplate {
        let name: String
        let audioDirectory: Profile.AudioDirectory
    }

    struct Request {
        let profileID: UUID
        let userID: String
        let origin: IssuerOrigin
        let apiBaseURL: String
        let user: SessionUser
        /// Nil binds without a token (M2 for a session whose token was
        /// already lost): the profile presents `.expired` after commit and
        /// the slot is expected to stay empty (INV-3).
        let tokenRaw: String?
        /// Non-nil creates the target profile inside phase A.
        var create: NewProfileTemplate?
        /// Runtime source-authority precondition, proven inside phase
        /// A's fresh load (a coordinator pre-read cannot close the race
        /// with a concurrent switch). Nil is the migration mode — M2
        /// runs before any runtime instance owns a source profile.
        var sourceAuthority: SourceAuthority?

        init(
            profileID: UUID,
            userID: String,
            origin: IssuerOrigin,
            apiBaseURL: String,
            user: SessionUser,
            tokenRaw: String?,
            create: NewProfileTemplate? = nil,
            sourceAuthority: SourceAuthority? = nil
        ) {
            self.profileID = profileID
            self.userID = userID
            self.origin = origin
            self.apiBaseURL = apiBaseURL
            self.user = user
            self.tokenRaw = tokenRaw
            self.create = create
            self.sourceAuthority = sourceAuthority
        }
    }

    /// Snapshot of the process's active profile at authorization time.
    /// Phase A refuses when the fresh registry no longer matches: same
    /// active ID, same kind, still unlocked, and the bound account still
    /// nil or the same byte-exact frozen tuple. For bind-current the
    /// source is the target itself; for create it is whichever profile
    /// this process runs as — a bound standard profile may create
    /// another account profile.
    struct SourceAuthority {
        let profileID: UUID
        let kind: Profile.Kind
        let boundAccount: Profile.BoundAccount?

        init(profile: Profile) {
            self.profileID = profile.id
            self.kind = profile.kind
            self.boundAccount = profile.boundAccount
        }
    }

    struct Dependencies {
        let registry: ProfileRegistryProviding
        let secretStore: AuthSecretStore
        let sessionUserStore: (UUID) -> SessionUserStoring
        let marker: HistoricalConsentMarking
        let storeURL: (UUID) -> URL
        /// Classified presence probe: true present, false definite absent,
        /// throws on anything unclassifiable.
        let storePresence: (URL) throws -> Bool
        let now: () -> Date
    }

    /// Runtime B2 route for a binding whose target store is open as the
    /// regular container: marking must go through that container, not a
    /// second one on the same file.
    struct ActiveStoreMarking {
        let markAll: (UUID) async throws -> HistoricalMarkResult
        let clearMarks: (UUID) async throws -> Int
    }

    enum BindingError: Error, Equatable {
        case profileMissing
        case systemProfileCannotBind
        case profileAlreadyBound
        case accountAlreadyBoundElsewhere(UUID)
        case anotherOperationInFlight
        case identityMismatch
        /// The token slot or session-user file this transaction would
        /// write already exists — it belongs to no recorded transaction,
        /// so the binding refuses to overwrite or later delete it.
        case foreignSessionArtifact(String)
        case inconsistentState(String)
        /// Phase A's fresh document no longer matches the runtime source
        /// snapshot: another instance switched, rebound, or locked the
        /// source profile, so this process's authority is lost — the
        /// runtime must halt, not merely refuse.
        case sourceAuthorityLost(String)
        /// A commit attempt failed and a re-read could not prove whether
        /// it persisted; nothing is rolled back — boot recovery resolves.
        case commitIndeterminate(String)
    }

    private static func encodedFingerprint(_ document: ProfileRegistryDocument) -> Data? {
        try? ProfileRegistryCoding.makeEncoder().encode(document)
    }

    /// Classified registry save shared by phases A and C: a thrown save is
    /// re-read and compared byte-for-byte (the deterministic encoder keeps
    /// NFC/NFD spellings distinct). Exact intended returns success, exact
    /// old rethrows the original error (retryable), anything else is
    /// commit-indeterminate.
    private static func classifiedSave(
        old: ProfileRegistryDocument,
        intended: ProfileRegistryDocument,
        registry: ProfileRegistryProviding
    ) throws {
        do {
            try registry.save(intended)
            return
        } catch let saveError {
            guard let oldBytes = encodedFingerprint(old),
                  let intendedBytes = encodedFingerprint(intended) else {
                throw BindingError.commitIndeterminate("registry shape unencodable")
            }
            let reread: ProfileRegistryDocument
            do {
                reread = try registry.load()
            } catch {
                throw BindingError.commitIndeterminate(
                    "registry unreadable after failed save: \(error)"
                )
            }
            guard let rereadBytes = encodedFingerprint(reread) else {
                throw BindingError.commitIndeterminate("reread shape unencodable")
            }
            if rereadBytes == intendedBytes { return }
            if rereadBytes == oldBytes { throw saveError }
            throw BindingError.commitIndeterminate(
                "registry in an unexpected shape after failed save"
            )
        }
    }

    private enum TokenSlotState: Equatable {
        case owned
        case absent
        case foreign
    }

    /// Verifies the token slot's current value against the pending
    /// record's digest. Begin-time absence only proves the slot started
    /// empty; every later phase re-proves the slot still holds this
    /// transaction's write — or, for a tokenless binding, that it stayed
    /// empty. Throws when the Keychain cannot be read — unknown, fail
    /// closed.
    private static func classifyTokenSlot(
        pending: PendingBinding,
        dependencies: Dependencies
    ) throws -> TokenSlotState {
        let account = SessionTokenKey.account(
            profileID: pending.profileID, originKey: pending.originKey
        )
        let raw = try dependencies.secretStore.getClassified(account)
        guard let expected = pending.tokenDigest else {
            return (raw?.isEmpty ?? true) ? .owned : .foreign
        }
        guard let raw, !raw.isEmpty else { return .absent }
        return SessionTokenDigest.digest(of: raw) == expected ? .owned : .foreign
    }

    nonisolated static func classifiedStorePresence(
        fileOperations: FileOperations
    ) -> (URL) throws -> Bool {
        { url in
            do {
                try requireRegularFile(at: url, fileOperations: fileOperations)
                return true
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return false
            }
        }
    }

    // MARK: - Forward paths

    /// Login-flow entry point: the target is either the profile whose
    /// container is open (`activeStore` routes B2 through it) or a fresh
    /// unmaterialized profile (no rows to mark). On failure after phase A
    /// a rollback is attempted; if the rollback itself fails, the pending
    /// record stays for boot recovery.
    static func run(
        request: Request,
        dependencies: Dependencies,
        activeStore: ActiveStoreMarking
    ) async throws -> ProfileRegistryDocument {
        let (document, index, pending) = try begin(request: request, dependencies: dependencies)
        let profile = document.profiles[index]
        do {
            try writeSessionArtifacts(
                pending: pending, user: request.user, tokenRaw: request.tokenRaw,
                dependencies: dependencies
            )
            if profile.storeMaterialized {
                let result = try await activeStore.markAll(pending.transactionID)
                guard result.coversAllRows else {
                    throw BindingError.inconsistentState(
                        "marking left rows uncovered: \(result)"
                    )
                }
            } else {
                try assertNoOrphanStore(profile: profile, dependencies: dependencies)
            }
        } catch {
            try await rollbackOrEscalate(
                pending: pending, dependencies: dependencies, activeStore: activeStore
            )
            throw error
        }
        // Post-phase-A contract: this entry may return only success, an
        // error after a proven complete rollback, or commit-indeterminate
        // (recovery required, runtime halts). Unreadable or foreign token
        // evidence deliberately retains the pending record and takes the
        // last route.
        let slot: TokenSlotState
        do {
            slot = try classifyTokenSlot(pending: pending, dependencies: dependencies)
        } catch {
            throw BindingError.commitIndeterminate(
                "token slot unreadable after phase B: \(error)"
            )
        }
        switch slot {
        case .owned:
            break
        case .absent:
            try await rollbackOrEscalate(
                pending: pending, dependencies: dependencies, activeStore: activeStore
            )
            throw BindingError.inconsistentState("token slot lost before commit")
        case .foreign:
            throw BindingError.commitIndeterminate("token slot holds a foreign value")
        }
        do {
            return try commit(pending: pending, user: request.user, dependencies: dependencies)
        } catch let error as BindingError {
            if case .commitIndeterminate = error { throw error }
            try await rollbackOrEscalate(
                pending: pending, dependencies: dependencies, activeStore: activeStore
            )
            throw error
        } catch {
            // The classified commit proved the old shape — pending stands
            // and a rollback is licensed.
            try await rollbackOrEscalate(
                pending: pending, dependencies: dependencies, activeStore: activeStore
            )
            throw error
        }
    }

    /// Migration entry point (M2): runs the same phases synchronously with
    /// the direct-container marker — no regular container is open yet.
    static func runSync(
        request: Request,
        dependencies: Dependencies
    ) throws -> ProfileRegistryDocument {
        let (document, index, pending) = try begin(request: request, dependencies: dependencies)
        do {
            try writeSessionArtifacts(
                pending: pending, user: request.user, tokenRaw: request.tokenRaw,
                dependencies: dependencies
            )
            try markHistorical(
                profile: document.profiles[index], pending: pending, dependencies: dependencies
            )
        } catch {
            try syncRollbackOrEscalate(pending: pending, dependencies: dependencies)
            throw error
        }
        let slot: TokenSlotState
        do {
            slot = try classifyTokenSlot(pending: pending, dependencies: dependencies)
        } catch {
            throw BindingError.commitIndeterminate(
                "token slot unreadable after phase B: \(error)"
            )
        }
        switch slot {
        case .owned:
            break
        case .absent:
            try syncRollbackOrEscalate(pending: pending, dependencies: dependencies)
            throw BindingError.inconsistentState("token slot lost before commit")
        case .foreign:
            throw BindingError.commitIndeterminate("token slot holds a foreign value")
        }
        do {
            return try commit(pending: pending, user: request.user, dependencies: dependencies)
        } catch let error as BindingError {
            if case .commitIndeterminate = error { throw error }
            try syncRollbackOrEscalate(pending: pending, dependencies: dependencies)
            throw error
        } catch {
            try syncRollbackOrEscalate(pending: pending, dependencies: dependencies)
            throw error
        }
    }

    // MARK: - Boot recovery (§5.6)

    enum RecoveryOutcome: Equatable {
        case noPending
        case completed(profileID: UUID)
        case rolledBack(profileID: UUID)
        /// Evidence about the pending transaction could not be classified;
        /// the boot must halt rather than guess between commit and
        /// rollback.
        case halted(String)
    }

    static func recover(
        document: ProfileRegistryDocument,
        dependencies: Dependencies
    ) -> RecoveryOutcome {
        guard let pending = document.pendingBinding else { return .noPending }
        guard let index = document.profiles.firstIndex(where: { $0.id == pending.profileID })
        else {
            return .halted("pending binding references unknown profile")
        }

        let slot: TokenSlotState
        do {
            slot = try classifyTokenSlot(pending: pending, dependencies: dependencies)
        } catch {
            return .halted("token slot unreadable: \(error)")
        }
        if slot == .foreign {
            return .halted("token slot holds a foreign value")
        }

        // Atomic writes mean the session-user file is either absent or a
        // complete artifact of some writer; malformed content is external
        // interference, not a crash window — unclassifiable, so halt.
        let user: SessionUser?
        do {
            user = try dependencies.sessionUserStore(pending.profileID).load()
        } catch {
            return .halted("session user unreadable: \(error)")
        }

        let complete = slot == .owned
            && user.map { AccountIdentity.matches($0.userID, pending.userID) } == true
            && user?.bindingTransactionID == pending.transactionID

        if complete, let user {
            do {
                try markHistorical(
                    profile: document.profiles[index], pending: pending,
                    dependencies: dependencies
                )
                _ = try commit(pending: pending, user: user, dependencies: dependencies)
                return .completed(profileID: pending.profileID)
            } catch {
                // The artifact set is complete, so the transaction is
                // committable — never roll it back because one attempt
                // failed. Halt and retry on the next boot.
                return .halted("binding completion failed: \(error)")
            }
        }

        do {
            try rollback(pending: pending, dependencies: dependencies)
            return .rolledBack(profileID: pending.profileID)
        } catch {
            return .halted("binding rollback failed: \(error)")
        }
    }

    // MARK: - Phase A

    private static func begin(
        request: Request,
        dependencies: Dependencies
    ) throws -> (ProfileRegistryDocument, Int, PendingBinding) {
        guard AccountIdentity.matches(request.user.userID, request.userID) else {
            throw BindingError.identityMismatch
        }
        var document = try dependencies.registry.load()
        let oldShape = document
        if let source = request.sourceAuthority {
            guard document.activeProfileID == source.profileID,
                  let sourceProfile = document.profiles.first(where: {
                      $0.id == source.profileID
                  }),
                  sourceProfile.kind == source.kind,
                  !sourceProfile.isLocked,
                  AccountIdentity.boundTupleMatches(
                      sourceProfile.boundAccount, source.boundAccount
                  ) else {
                throw BindingError.sourceAuthorityLost(
                    "source authority changed behind this process"
                )
            }
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            throw BindingError.anotherOperationInFlight
        }
        let transactionID = UUID()
        if let template = request.create {
            guard !document.profiles.contains(where: { $0.id == request.profileID }) else {
                throw BindingError.inconsistentState("created profile ID already exists")
            }
            document.profiles.append(Profile(
                id: request.profileID,
                kind: .standard,
                name: template.name,
                colorHex: nil,
                createdAt: dependencies.now(),
                lastActiveAt: dependencies.now(),
                audioDirectory: template.audioDirectory,
                boundAccount: nil,
                lockOnSignOut: true,
                isLocked: false,
                storeMaterialized: false,
                sessionDisposition: .active,
                createdByBindingTransactionID: transactionID
            ))
        }
        guard let index = document.profiles.firstIndex(where: { $0.id == request.profileID })
        else {
            throw BindingError.profileMissing
        }
        guard document.profiles[index].kind != .system else {
            throw BindingError.systemProfileCannotBind
        }
        guard document.profiles[index].boundAccount == nil else {
            throw BindingError.profileAlreadyBound
        }
        let originKey = request.origin.originKey
        if let existing = document.profiles.first(where: {
            $0.boundAccount?.originKey == originKey
                && $0.boundAccount.map { AccountIdentity.matches($0.userID, request.userID) } == true
        }) {
            throw BindingError.accountAlreadyBoundElsewhere(existing.id)
        }

        // The slots this transaction will write must be provably empty
        // before phase A: with no recorded transaction owning them, any
        // occupant is foreign and must never be overwritten in B or
        // deleted in a rollback. Unknown reads fail closed.
        let account = SessionTokenKey.account(
            profileID: request.profileID, originKey: originKey
        )
        if try dependencies.secretStore.getClassified(account) != nil {
            throw BindingError.foreignSessionArtifact("token slot occupied")
        }
        if try dependencies.sessionUserStore(request.profileID).load() != nil {
            throw BindingError.foreignSessionArtifact("session-user file exists")
        }

        let pending = PendingBinding(
            transactionID: transactionID,
            profileID: request.profileID,
            userID: request.userID,
            originKey: originKey,
            issuerOrigin: request.origin.normalized,
            apiBaseURL: request.apiBaseURL,
            tokenDigest: request.tokenRaw.map { SessionTokenDigest.digest(of: $0) },
            createdProfile: request.create != nil,
            startedAt: dependencies.now()
        )
        document.pendingBinding = pending
        try classifiedSave(
            old: oldShape, intended: document, registry: dependencies.registry
        )
        return (document, index, pending)
    }

    // MARK: - Phase B / B2

    private static func writeSessionArtifacts(
        pending: PendingBinding,
        user: SessionUser,
        tokenRaw: String?,
        dependencies: Dependencies
    ) throws {
        if let tokenRaw {
            let account = SessionTokenKey.account(
                profileID: pending.profileID, originKey: pending.originKey
            )
            try dependencies.secretStore.set(tokenRaw, for: account)
        }
        let owned = SessionUser(
            userID: user.userID,
            email: user.email,
            displayName: user.displayName,
            pictureURL: user.pictureURL,
            bindingTransactionID: pending.transactionID
        )
        try dependencies.sessionUserStore(pending.profileID).save(owned)
    }

    private static func markHistorical(
        profile: Profile,
        pending: PendingBinding,
        dependencies: Dependencies
    ) throws {
        if profile.storeMaterialized {
            let url = dependencies.storeURL(profile.id)
            guard try dependencies.storePresence(url) else {
                throw BindingError.inconsistentState("materialized store is missing")
            }
            let result = try dependencies.marker.markAll(
                storeURL: url, transactionID: pending.transactionID
            )
            guard result.coversAllRows else {
                throw BindingError.inconsistentState("marking left rows uncovered: \(result)")
            }
        } else {
            try assertNoOrphanStore(profile: profile, dependencies: dependencies)
        }
    }

    /// A profile that is not marked materialized must have no store file —
    /// one that exists anyway contradicts the materialization boundary and
    /// could hold rows the transaction would silently skip. Fail closed.
    private static func assertNoOrphanStore(
        profile: Profile,
        dependencies: Dependencies
    ) throws {
        if try dependencies.storePresence(dependencies.storeURL(profile.id)) {
            throw BindingError.inconsistentState(
                "store exists but profile is not marked materialized"
            )
        }
    }

    // MARK: - Phase C

    /// Re-reads the registry at the commit point: the pending record must
    /// still be exactly this transaction's and the target must still
    /// satisfy the preconditions — an async B2 yields the main actor, so
    /// the pre-phase-A snapshot can be stale.
    private static func reloadVerified(
        pending: PendingBinding,
        dependencies: Dependencies
    ) throws -> (ProfileRegistryDocument, Int) {
        let document = try dependencies.registry.load()
        guard document.pendingBinding == pending else {
            throw BindingError.inconsistentState("pending binding changed during transaction")
        }
        guard let index = document.profiles.firstIndex(where: { $0.id == pending.profileID })
        else {
            throw BindingError.profileMissing
        }
        let profile = document.profiles[index]
        guard profile.kind != .system, profile.boundAccount == nil else {
            throw BindingError.inconsistentState("target profile changed during transaction")
        }
        return (document, index)
    }

    private static func commit(
        pending: PendingBinding,
        user: SessionUser,
        dependencies: Dependencies
    ) throws -> ProfileRegistryDocument {
        let (document, index) = try reloadVerified(pending: pending, dependencies: dependencies)
        var committed = document
        committed.profiles[index].boundAccount = Profile.BoundAccount(
            userID: pending.userID,
            originKey: pending.originKey,
            issuerOrigin: pending.issuerOrigin,
            apiBaseURL: pending.apiBaseURL,
            displayEmail: user.email,
            displayName: user.displayName,
            boundAt: dependencies.now()
        )
        committed.profiles[index].isLocked = false
        committed.profiles[index].sessionDisposition = .active
        committed.profiles[index].lockOnSignOut = true
        committed.pendingBinding = nil
        try classifiedSave(
            old: document, intended: committed, registry: dependencies.registry
        )
        return committed
    }

    // MARK: - Rollback

    /// Removes exactly this transaction's side effects: its token slot,
    /// its session-user file (ownership proven by the recorded transaction
    /// ID), and the consent marks carrying its transaction ID — never
    /// other sessions or pre-existing state. Re-verifies the pending
    /// record first; a registry that no longer carries it means another
    /// path resolved the transaction and nothing may be deleted.
    private static func rollback(
        pending: PendingBinding,
        dependencies: Dependencies
    ) throws {
        let (document, index) = try reloadVerified(pending: pending, dependencies: dependencies)
        try removeOwnedSessionArtifacts(pending: pending, dependencies: dependencies)
        let url = dependencies.storeURL(document.profiles[index].id)
        if try dependencies.storePresence(url) {
            _ = try dependencies.marker.clearMarks(
                storeURL: url, transactionID: pending.transactionID
            )
        }
        var cleared = document
        cleared.pendingBinding = nil
        try removeCreatedProfileIfInert(
            pending: pending, from: &cleared, dependencies: dependencies
        )
        try classifiedSave(old: document, intended: cleared, registry: dependencies.registry)
    }

    /// A transaction-created profile leaves with its transaction: removed
    /// in the rollback save once proven still inert (unbound,
    /// unmaterialized, inactive, storeless). Unknown store presence or a
    /// non-inert target throws — the pending record then stays and the
    /// caller escalates; nothing is silently orphaned.
    private static func removeCreatedProfileIfInert(
        pending: PendingBinding,
        from document: inout ProfileRegistryDocument,
        dependencies: Dependencies
    ) throws {
        guard pending.createdProfile else { return }
        guard let index = document.profiles.firstIndex(where: { $0.id == pending.profileID })
        else { return }
        guard document.profiles[index].boundAccount == nil,
              !document.profiles[index].storeMaterialized,
              document.activeProfileID != pending.profileID else {
            throw BindingError.inconsistentState("created profile is no longer inert")
        }
        guard try dependencies.storePresence(dependencies.storeURL(pending.profileID)) == false
        else {
            throw BindingError.inconsistentState("created profile has a store")
        }
        document.profiles.remove(at: index)
    }

    /// Classified sync rollback: a proven-cleared old shape lets the
    /// caller resume with the original error; anything else escalates to
    /// commit-indeterminate — pending state remains durable and the
    /// runtime must halt rather than keep writing the store while
    /// recovery is owed.
    private static func syncRollbackOrEscalate(
        pending: PendingBinding,
        dependencies: Dependencies
    ) throws {
        do {
            try rollback(pending: pending, dependencies: dependencies)
        } catch {
            NSLog("[ProfileBinding] rollback failed: %@", String(describing: error))
            throw BindingError.commitIndeterminate(
                "rollback unproven: \(error)"
            )
        }
    }

    /// Runtime twin: mark-clearing goes through the open container.
    private static func rollbackOrEscalate(
        pending: PendingBinding,
        dependencies: Dependencies,
        activeStore: ActiveStoreMarking
    ) async throws {
        do {
            let (document, index) = try reloadVerified(
                pending: pending, dependencies: dependencies
            )
            try removeOwnedSessionArtifacts(pending: pending, dependencies: dependencies)
            if document.profiles[index].storeMaterialized {
                _ = try await activeStore.clearMarks(pending.transactionID)
            }
            var cleared = document
            cleared.pendingBinding = nil
            try removeCreatedProfileIfInert(
                pending: pending, from: &cleared, dependencies: dependencies
            )
            try classifiedSave(
                old: document, intended: cleared, registry: dependencies.registry
            )
        } catch {
            NSLog("[ProfileBinding] rollback failed: %@", String(describing: error))
            throw BindingError.commitIndeterminate(
                "rollback unproven: \(error)"
            )
        }
    }

    /// Verifies ownership of every artifact before deleting any of them:
    /// the token slot by digest, the session-user file by its recorded
    /// transaction ID. Any unproven artifact aborts with zero deletions.
    private static func removeOwnedSessionArtifacts(
        pending: PendingBinding,
        dependencies: Dependencies
    ) throws {
        let slot = try classifyTokenSlot(pending: pending, dependencies: dependencies)
        guard slot != .foreign else {
            throw BindingError.foreignSessionArtifact("token slot holds a foreign value")
        }
        let store = dependencies.sessionUserStore(pending.profileID)
        let user = try store.load()
        if let user, user.bindingTransactionID != pending.transactionID {
            throw BindingError.foreignSessionArtifact(
                "session-user not owned by this transaction"
            )
        }

        if slot == .owned, pending.tokenDigest != nil {
            let account = SessionTokenKey.account(
                profileID: pending.profileID, originKey: pending.originKey
            )
            try dependencies.secretStore.remove(account)
        }
        if user != nil {
            try store.remove()
        }
    }
}
