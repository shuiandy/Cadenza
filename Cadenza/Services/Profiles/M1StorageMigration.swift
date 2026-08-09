import Foundation
import SwiftData

enum M1MigrationError: Error {
    case concurrentMigration
    case journalUnreadable(String)
    case sourceProbeFailed(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case snapshotMismatch(String)
    case chatHistoryEntryRejected(String)
    case verificationFailed(String)
    case sourceEvidenceChanged(String)
    case stagedMutationFailed(String)
}

/// M1: move the store (and chat history) of the single inherited data set
/// into `Profiles/<id>/` and establish the registry (spec §6.5, §9).
///
/// State machine — every mutation of the staged copy happens before
/// `targetVerified`; the registry write is the commit point:
///
///     started → snapshotVerified → staged → targetVerified
///             → registryCommitted → done
///
/// Failure before the registry write leaves the source untouched and boots
/// the legacy path. Once the registry is written the target is the
/// authority: boot MUST open the profile store, no later failure may
/// surface as a pre-commit outcome, and the source stays behind as a
/// retained duplicate until the retire step completes.
/// Auth state (tokens, session user file, Keychain) is never read or
/// touched by any step.
struct M1StorageMigration {

    struct Dependencies {
        let paths: ProfilePaths
        let registry: any ProfileRegistryProviding
        let fileOperations: any FileOperations
        let backupDriver: any SQLiteBackupDriver
        /// Inherited audio root; spec §10.3 rewrites are proven against it
        /// lexically. Snapshotted once for the whole run.
        /// Lazy: evaluated only on a pre-commit migration path. A
        /// registry-present boot must never resolve the legacy global
        /// storage keys these read.
        let audioRoot: () -> URL
        /// Mirror of the operative audio-directory state for the registry.
        let audioDirectoryState: () -> Profile.AudioDirectory
        let scopedDefaults: ProfileScopedDefaults
        let now: @Sendable () -> Date
    }

    enum Outcome: Equatable {
        /// Migration ran to completion (or was already complete); boot the
        /// profile store.
        case completed(profileID: UUID)
        /// Fresh install: registry and empty profile directory created, no
        /// source existed.
        case freshInstall(profileID: UUID)
        /// Registry committed but the source retire step is pending; the
        /// profile store is the authority, retire resumes next launch.
        case committedPendingRetire(profileID: UUID)
        /// Failure before the commit point: source untouched, caller boots
        /// the legacy path.
        case failedPreCommit(reason: String)
        /// A commit exists (journal at or past the commit point) but the
        /// authority cannot be established safely — the boot must stop
        /// visibly; a legacy boot here would be a second authority.
        case halted(reason: String)
    }

    /// Disk headroom demanded beyond two copies of the source trio.
    static let requiredDiskSlack: Int64 = 512 * 1024 * 1024

    let dependencies: Dependencies

    private var paths: ProfilePaths { dependencies.paths }
    private var fileOperations: any FileOperations { dependencies.fileOperations }

    /// Runs with the registry definitively absent. Absence of the registry
    /// is NOT proof that no commit ever happened — the journal and the
    /// on-disk residue of a commit are consulted first, and only their
    /// combined, classified absence licenses the legacy/fresh paths. Any
    /// state that cannot be classified (unreadable journal, unprobeable
    /// migration directory, lock contention while evidence may exist)
    /// halts: booting legacy beside a possibly committed target would be a
    /// second authority.
    func run() -> Outcome {
        let journalStore = MigrationJournalStore(paths: paths, fileOperations: fileOperations)

        // Evidence phase: classify the migration directory before touching
        // anything. A definitively absent directory means no journal can
        // exist; anything unclassifiable halts.
        let directoryExists: Bool
        do {
            let attributes = try fileOperations.attributesOfItem(at: paths.migrationDirectory)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return .halted(reason: "migration location is not a directory")
            }
            directoryExists = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            directoryExists = false
        } catch {
            return .halted(
                reason: "migration directory unprobeable: \(String(describing: error))"
            )
        }

        if directoryExists {
            // The journal may exist: take the lock before reading it, and
            // treat contention as unknown evidence — another process may be
            // mid-commit.
            guard let lock = MigrationFileLock(
                url: paths.migrationDirectory.appendingPathComponent("lock")
            ) else {
                return .halted(reason: "migration lock unavailable")
            }
            defer { lock.unlock() }
            return runWithLockedEvidence(journalStore: journalStore)
        }

        // No migration directory: the journal is definitively absent. The
        // remaining commit evidence is on-disk residue.
        if let residue = committedResidueProblem() {
            return .halted(reason: residue)
        }
        // Positive proof of never-committed. Operational failures from
        // here are genuine pre-commit failures.
        do {
            try fileOperations.createDirectory(at: paths.migrationDirectory)
        } catch {
            return .failedPreCommit(reason: "migration directory: \(error.localizedDescription)")
        }
        guard let lock = MigrationFileLock(
            url: paths.migrationDirectory.appendingPathComponent("lock")
        ) else {
            return .halted(reason: "migration lock unavailable")
        }
        defer { lock.unlock() }
        return runWithLockedEvidence(journalStore: journalStore)
    }

    private func runWithLockedEvidence(journalStore: MigrationJournalStore) -> Outcome {
        // An unreadable journal is unknown commit evidence, never absence.
        let journal: MigrationJournalDocument?
        do {
            journal = try journalStore.load()
        } catch {
            return .halted(reason: "journal unreadable: \(String(describing: error))")
        }
        // A journal at or past the commit point is a durable commit
        // record: the target is the authority, the registry must be
        // re-established as a durable artifact over a validated target,
        // and no failure may fall back to legacy (spec §9.2).
        if let record = journal?.m1 {
            switch record.state {
            case .done:
                guard validateCommittedTarget(record: record, requireExactDigest: false) else {
                    return .halted(reason: "journal complete but target failed validation")
                }
                do {
                    try recommitRegistry(profileID: record.profileID)
                } catch {
                    return .halted(
                        reason: "registry re-establishment failed: \(String(describing: error))"
                    )
                }
                return .completed(profileID: record.profileID)
            case .registryCommitted:
                guard validateCommittedTarget(record: record, requireExactDigest: true) else {
                    return .halted(reason: "committed journal but target failed validation")
                }
                do {
                    try recommitRegistry(profileID: record.profileID)
                } catch {
                    return .halted(
                        reason: "registry re-establishment failed: \(String(describing: error))"
                    )
                }
                return resumeRetire(record: record, journalStore: journalStore)
            case .started, .snapshotVerified, .staged, .targetVerified:
                discardPreCommitLeftovers(profileID: record.profileID)
            }
        } else {
            // Journal definitively absent under the lock: residue is the
            // last line of commit evidence.
            if let residue = committedResidueProblem() {
                return .halted(reason: residue)
            }
        }

        do {
            return try runFromScratch(journalStore: journalStore)
        } catch {
            return .failedPreCommit(reason: String(describing: error))
        }
    }

    /// On-disk residue that proves (or may prove) a past commit when both
    /// the registry and the journal are gone: any entry under the Profiles
    /// directory — including one that merely looks empty; guessing that a
    /// profile directory holds nothing worth keeping is how user data gets
    /// silently orphaned — and any retired source artifact. Only
    /// definitively absent evidence returns nil; unprobeable states are
    /// reasons to halt.
    private func committedResidueProblem() -> String? {
        // Profiles/<id>/ residue.
        do {
            let attributes = try fileOperations.attributesOfItem(at: paths.profilesDirectory)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return "profiles location is not a directory"
            }
            let entries: [URL]
            do {
                entries = try fileOperations.contentsOfDirectory(at: paths.profilesDirectory)
            } catch {
                return "profiles directory unlistable: \(String(describing: error))"
            }
            if let entry = entries.first {
                return "profile residue present without registry or journal: \(entry.lastPathComponent)"
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Definitively no profile residue.
        } catch {
            return "profiles directory unprobeable: \(String(describing: error))"
        }

        // Retired-source residue beside either whitelisted source location.
        for (directory, prefix) in [
            (paths.root, "Cadenza.store.migrated-"),
            (paths.preLegacyStoreURL.deletingLastPathComponent(), "default.store.migrated-"),
        ] {
            let entries: [URL]
            do {
                entries = try fileOperations.contentsOfDirectory(at: directory)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                return "retired-artifact scan failed: \(String(describing: error))"
            }
            if let retired = entries.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) {
                return "retired source present without registry or journal: \(retired.lastPathComponent)"
            }
        }
        return nil
    }

    /// Converges a migration whose registry is committed but whose journal
    /// never reached `done` — including the crash window between the
    /// registry write and the `registryCommitted` journal write, where the
    /// journal understates reality. Only the retire step runs; staging and
    /// the profile directory are never touched. No-op unless the journal
    /// record matches the committed active profile.
    func resumeRetireAfterCommit(activeProfileID: UUID) {
        do {
            try fileOperations.createDirectory(at: paths.migrationDirectory)
        } catch {
            return
        }
        guard let lock = MigrationFileLock(
            url: paths.migrationDirectory.appendingPathComponent("lock")
        ) else { return }
        defer { lock.unlock() }

        let journalStore = MigrationJournalStore(paths: paths, fileOperations: fileOperations)
        let journal: MigrationJournalDocument?
        do {
            journal = try journalStore.load()
        } catch {
            NSLog("[M1Migration] retire skipped, journal unreadable: %@", String(describing: error))
            return
        }
        guard var record = journal?.m1,
              record.profileID == activeProfileID,
              record.state != .done else { return }
        record.state = .registryCommitted
        _ = resumeRetire(record: record, journalStore: journalStore)
    }

    /// Re-establishes the registry for an already-validated committed
    /// target (unreadable-registry recovery). Callers must have passed
    /// `validateCommittedTarget` first.
    func recommitRegistry(profileID: UUID) throws {
        dependencies.scopedDefaults.copyGlobalValues(to: profileID)
        try commitRegistry(profileID: profileID, storeMaterialized: true)
    }

    /// Target validation gate used before any registry re-establishment or
    /// source retirement on a resumed launch. The profile store must exist
    /// as a regular file whose full logical digest is computable (a
    /// complete, readable database); with `requireExactDigest` it must
    /// equal the digest recorded after the staged mutations — which binds
    /// every entity and field, counted or not. Anything else fails closed.
    /// The exact check applies wherever the target should still be the
    /// untouched migration product; a target that has served as the live
    /// store since (journal already `done`) is validated for integrity
    /// only, because its content legitimately evolves.
    func validateCommittedTarget(
        record: MigrationJournalDocument.M1Record, requireExactDigest: Bool
    ) -> Bool {
        // Without a readable registry, materialization state cannot be
        // known, so nothing is guessed from the journal shape: a
        // fresh-install record's store must exist and be readable like any
        // other — a missing target halts at the caller rather than being
        // recreated empty.
        if record.isFreshInstallShape {
            let storeURL = paths.storeURL(record.profileID)
            switch probePresence(of: storeURL) {
            case .regularFile:
                break
            case .absent, .rejected, .unknown:
                NSLog("[M1Migration] fresh-profile store not a readable regular file")
                return false
            }
            do {
                _ = try SQLiteLogicalDigest.digest(of: storeURL)
                return true
            } catch {
                NSLog(
                    "[M1Migration] fresh-profile store unreadable: %@",
                    String(describing: error)
                )
                return false
            }
        }
        let storeURL = paths.storeURL(record.profileID)
        switch probePresence(of: storeURL) {
        case .regularFile:
            break
        case .absent, .rejected, .unknown:
            NSLog("[M1Migration] target validation: store not a readable regular file")
            return false
        }
        let digest: String
        do {
            digest = try SQLiteLogicalDigest.digest(of: storeURL)
        } catch {
            NSLog("[M1Migration] target validation failed: %@", String(describing: error))
            return false
        }
        if requireExactDigest {
            guard let expected = record.targetContentDigest, digest == expected else {
                NSLog("[M1Migration] target validation: content digest mismatch")
                return false
            }
        }
        return true
    }

    // MARK: - Full pipeline

    private func runFromScratch(journalStore: MigrationJournalStore) throws -> Outcome {
        let profileID = UUID()

        guard let sourceTrio = try locateSource() else {
            return try establishFreshInstall(profileID: profileID, journalStore: journalStore)
        }

        try preflightDiskSpace(for: sourceTrio)

        // Freeze the source for the whole migration window: BEGIN
        // IMMEDIATE held until the retire decision. An active writer fails
        // the acquisition; the lock dies with the process on crash.
        let lease = try SourceFreezeLease.acquire(
            storeURL: sourceTrio.base, fileOperations: fileOperations
        )
        var leaseReleased = false
        defer { if !leaseReleased { lease.release() } }

        // Evidence about the live source, captured under the lease and
        // re-verified before commit and before the in-window retire.
        let evidence = try SourceEvidence.capture(
            source: sourceTrio, fileOperations: fileOperations
        )

        var record = MigrationJournalDocument.M1Record(
            state: .started,
            profileID: profileID,
            sourceStorePath: sourceTrio.base.path,
            receipt: nil,
            sourceEvidence: evidence,
            rewrittenReferenceCount: nil,
            retainedLegacyCount: nil
        )
        // The logical content digest is frozen by the lease, so it can be
        // captured now and persisted with every journal state — a crash in
        // any later window still leaves the resumed retire its evidence.
        record.sourceContentDigest = try SQLiteLogicalDigest.digest(of: sourceTrio.base)
        try saveJournal(record, to: journalStore)

        // 1. Verified snapshot (INV-9): the artifact, not the live trio, is
        // what every later step consumes.
        let receipt = try StoreSnapshotter.performVerifiedSnapshot(
            source: sourceTrio,
            into: paths.migrationDirectory.appendingPathComponent("snapshots", isDirectory: true),
            label: "m1",
            fileOperations: fileOperations,
            backupDriver: dependencies.backupDriver
        )
        record.state = .snapshotVerified
        record.receipt = receipt
        try saveJournal(record, to: journalStore)

        // 2. Stage: copy the artifact, then apply every mutation to the
        // staged copy (schema migration, ownership backfill, spec §10.3
        // reference rewrite, chat history).
        let stagingDirectory = paths.stagingDirectory(profileID: profileID)
        if fileOperations.fileExists(at: stagingDirectory) {
            try fileOperations.removeItem(at: stagingDirectory)
        }
        try fileOperations.createDirectory(at: stagingDirectory)
        let stagedStoreURL = stagingDirectory.appendingPathComponent("Cadenza.store")
        let artifactURL = receipt.directory.appendingPathComponent("Cadenza.store")
        try fileOperations.copyItem(at: artifactURL, to: stagedStoreURL)
        guard let artifactRecord = receipt.files.first(where: { $0.name == "Cadenza.store" }),
              try fileOperations.sha256(of: stagedStoreURL) == artifactRecord.sha256 else {
            throw M1MigrationError.snapshotMismatch("staged copy hash differs from receipt")
        }

        let rewriteCounts = try applyStagedMutations(storeURL: stagedStoreURL)
        try copyChatHistory(into: stagingDirectory)

        record.state = .staged
        record.rewrittenReferenceCount = rewriteCounts.rewritten
        record.retainedLegacyCount = rewriteCounts.retainedLegacy
        // The target digest covers the ENTIRE staged database after all
        // mutations — later gates compare against it, so uncounted
        // entities and count-preserving field changes are both bound.
        record.targetContentDigest = try SQLiteLogicalDigest.digest(of: stagedStoreURL)
        try saveJournal(record, to: journalStore)

        // 3. Verify the staged store after ALL mutations.
        try verifyStoreContent(
            storeURL: stagedStoreURL,
            receipt: receipt,
            expectedRetainedLegacy: rewriteCounts.retainedLegacy,
            expectedContentDigest: record.targetContentDigest
        )
        record.state = .targetVerified
        try saveJournal(record, to: journalStore)

        // 4. Place: same-volume atomic rename into Profiles/<id>/.
        try fileOperations.createDirectory(at: paths.profilesDirectory)
        let profileDirectory = paths.profileDirectory(profileID)
        if fileOperations.fileExists(at: profileDirectory) {
            // Pre-commit leftovers from an interrupted attempt are
            // disposable — nothing references them yet.
            try fileOperations.removeItem(at: profileDirectory)
        }
        try fileOperations.moveItemExclusively(staging: stagingDirectory, final: profileDirectory)

        // 5. Commit. The source must still match its evidence — direct
        // file tampering during the window aborts with the registry
        // unwritten (still a pre-commit failure).
        switch evidence.check(for: sourceTrio, fileOperations: fileOperations) {
        case .holds:
            break
        case .changed(let detail), .unverifiable(let detail):
            throw M1MigrationError.sourceEvidenceChanged(detail)
        }
        // The defaults mapping precedes the registry write: it is
        // idempotent, so a crash between the two re-copies on retry, and
        // the commit point never exists without the mapping.
        dependencies.scopedDefaults.copyGlobalValues(to: profileID)
        try commitRegistry(profileID: profileID, storeMaterialized: true)

        // The registry is written: the target is the authority from here
        // on and no failure below may surface as pre-commit — a legacy
        // boot beside a committed registry would mean double authority for
        // one session. The bootstrap converges an understated journal on
        // the next launch.
        record.state = .registryCommitted
        do {
            try saveJournal(record, to: journalStore)
        } catch {
            NSLog(
                "[M1Migration] journal commit-write failed: %@", String(describing: error)
            )
            return .committedPendingRetire(profileID: profileID)
        }

        let retired = retireSourceInWindow(
            trio: sourceTrio,
            evidence: evidence,
            lease: lease,
            record: &record,
            journalStore: journalStore
        )
        guard retired else {
            return .committedPendingRetire(profileID: profileID)
        }
        // The retire helper closes the lease before renaming the base.
        // Releasing again is harmless; stale original-name sidecars are
        // removed only after the base is definitively absent.
        lease.release()
        leaseReleased = true
        sweepStaleSourceSidecars(forRetiredBase: sourceTrio.base)
        record.state = .done
        do {
            try saveJournal(record, to: journalStore)
        } catch {
            // Retire happened; a failed journal write only means the next
            // launch re-runs a retire that finds nothing left to rename.
            NSLog("[M1Migration] journal done-write failed: %@", String(describing: error))
        }
        return .completed(profileID: profileID)
    }

    // MARK: - Steps

    /// Classified presence probe: only a definite not-found counts as
    /// absent. A symlink or unexpected node type is rejected, and any
    /// other metadata failure (permissions, IO) is unknown — callers must
    /// fail closed on both instead of mistaking an unreadable store for a
    /// missing one.
    private enum PresenceProbe {
        case regularFile
        case absent
        case rejected(String)
        case unknown(String)
    }

    private func probePresence(of url: URL) -> PresenceProbe {
        do {
            let attributes = try fileOperations.attributesOfItem(at: url)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .rejected(url.lastPathComponent)
            }
            return .regularFile
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .unknown(String(describing: error))
        }
    }

    /// The migration source comes ONLY from this whitelist — the current
    /// store location, then the pre-Cadenza `default.store` for
    /// skip-version upgrades (INV-16). Journal-recorded paths are never
    /// dereferenced; they serve as consistency hints at most. Only a
    /// definite not-found continues the search: an unreadable or
    /// non-regular candidate aborts, because treating it as absent would
    /// commit a fresh empty profile over existing data.
    private func locateSource() throws -> StoreTrioURL? {
        for candidate in [paths.legacyStoreURL, paths.preLegacyStoreURL] {
            switch probePresence(of: candidate) {
            case .regularFile:
                return StoreTrioURL(base: candidate)
            case .absent:
                continue
            case .rejected(let name):
                throw M1MigrationError.sourceProbeFailed("not a regular file: \(name)")
            case .unknown(let detail):
                throw M1MigrationError.sourceProbeFailed(detail)
            }
        }
        return nil
    }

    private func establishFreshInstall(
        profileID: UUID, journalStore: MigrationJournalStore
    ) throws -> Outcome {
        let profileDirectory = paths.profileDirectory(profileID)
        try fileOperations.createDirectory(at: profileDirectory)
        try fileOperations.createDirectory(at: paths.chatHistoryDirectory(profileID))
        dependencies.scopedDefaults.copyGlobalValues(to: profileID)
        try commitRegistry(profileID: profileID, storeMaterialized: false)
        // Committed: a failed journal write must not demote the boot to
        // legacy; the record converges on the next launch.
        let record = MigrationJournalDocument.M1Record(
            state: .done,
            profileID: profileID,
            sourceStorePath: "",
            receipt: nil,
            sourceEvidence: nil,
            rewrittenReferenceCount: 0,
            retainedLegacyCount: 0
        )
        do {
            try saveJournal(record, to: journalStore)
        } catch {
            NSLog(
                "[M1Migration] fresh-install journal write failed: %@",
                String(describing: error)
            )
        }
        return .freshInstall(profileID: profileID)
    }

    private func preflightDiskSpace(for trio: StoreTrioURL) throws {
        var trioBytes: Int64 = 0
        // The base is required; sidecars count when definitely present,
        // and an unprobeable sidecar aborts rather than undercounting the
        // space the migration needs.
        for (file, required) in [(trio.base, true), (trio.wal, false), (trio.shm, false)] {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileOperations.attributesOfItem(at: file)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !required {
                continue
            } catch {
                throw M1MigrationError.sourceProbeFailed(String(describing: error))
            }
            guard let size = attributes[.size] as? Int64 else {
                throw M1MigrationError.verificationFailed("source size unreadable")
            }
            trioBytes += size
        }
        let required = trioBytes * 2 + Self.requiredDiskSlack
        let available = try fileOperations.availableCapacity(at: paths.root)
        guard available >= required else {
            throw M1MigrationError.insufficientDiskSpace(required: required, available: available)
        }
    }

    private struct RewriteCounts: Equatable {
        var rewritten: Int
        var retainedLegacy: Int
    }

    /// All staged-store mutations in one transaction: schema migration
    /// happens on open (additive ownership column), then ownership backfill
    /// and the spec §10.3 legacy-to-relative rewrite, saved once. Any
    /// failure rolls back and the staging copy is discarded by the caller.
    private func applyStagedMutations(storeURL: URL) throws -> RewriteCounts {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: RecordingsStore.schema,
                configurations: ModelConfiguration(url: storeURL)
            )
        } catch {
            throw M1MigrationError.stagedMutationFailed(
                "staged open: \(error.localizedDescription)"
            )
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let resolver = ProfileStorageResolver(root: dependencies.audioRoot())
        var counts = RewriteCounts(rewritten: 0, retainedLegacy: 0)
        do {
            let recordings = try context.fetch(FetchDescriptor<Recording>())
            for recording in recordings {
                if recording.audioFileOwnership == nil {
                    recording.audioFileOwnership = AudioFileOwnership.unknownLegacy.rawValue
                }
                recording.audioFileReference = try rewrite(
                    recording.audioFileReference, resolver: resolver, counts: &counts
                )
                recording.segmentsDirectoryReference = try rewrite(
                    recording.segmentsDirectoryReference, resolver: resolver, counts: &counts
                )
            }
            try context.save()
        } catch {
            context.rollback()
            throw M1MigrationError.stagedMutationFailed(String(describing: error))
        }
        return counts
    }

    /// Spec §10.3: a legacy absolute reference is rewritten to relative
    /// only when its lexical subpath under the inherited root is provable
    /// AND the resulting relative reference resolves under the strict
    /// rules. A classified resolution rejection retains the stored value
    /// by design; any other error aborts the staged transaction.
    private func rewrite(
        _ reference: AudioFileReference?,
        resolver: ProfileStorageResolver,
        counts: inout RewriteCounts
    ) throws -> AudioFileReference? {
        guard case .legacyAbsolute(let path) = reference else { return reference }
        let url = URL(fileURLWithPath: path)
        guard let subpath = resolver.lexicalSubpath(of: url) else {
            counts.retainedLegacy += 1
            return reference
        }
        do {
            _ = try resolver.resolveAudio(.relative(subpath))
        } catch let error as ProfileStorageResolver.ResolutionError {
            NSLog(
                "[M1Migration] reference kept legacy (%@): %@",
                String(describing: error), path
            )
            counts.retainedLegacy += 1
            return reference
        }
        counts.rewritten += 1
        return .relative(subpath)
    }

    /// Chat history is copied (never moved) with per-file content
    /// verification; the source directory stays for rollback. Only a
    /// definite not-found skips the copy — a directory whose metadata
    /// cannot be read may hold data, and committing without it would lose
    /// it silently. Only regular files are legitimate entries.
    private func copyChatHistory(into stagingDirectory: URL) throws {
        let source = paths.legacyChatHistoryDirectory
        let target = stagingDirectory.appendingPathComponent("ChatHistory", isDirectory: true)
        try fileOperations.createDirectory(at: target)
        do {
            let attributes = try fileOperations.attributesOfItem(at: source)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw M1MigrationError.chatHistoryEntryRejected(source.lastPathComponent)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch let error as M1MigrationError {
            throw error
        } catch {
            throw M1MigrationError.chatHistoryEntryRejected(
                "unprobeable: \(String(describing: error))"
            )
        }
        for entry in try fileOperations.contentsOfDirectory(at: source) {
            let attributes = try fileOperations.attributesOfItem(at: entry)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw M1MigrationError.chatHistoryEntryRejected(entry.lastPathComponent)
            }
            let destination = target.appendingPathComponent(entry.lastPathComponent)
            try fileOperations.copyItem(at: entry, to: destination)
            guard try fileOperations.sha256(of: entry)
                == fileOperations.sha256(of: destination) else {
                throw M1MigrationError.chatHistoryEntryRejected(entry.lastPathComponent)
            }
        }
    }

    /// Content gate for the staged store: entity counts must match the
    /// receipt, the ownership backfill must be complete, the legacy-row
    /// bookkeeping must reproduce, and the full logical digest must equal
    /// the one just recorded.
    private func verifyStoreContent(
        storeURL: URL,
        receipt: SnapshotReceipt,
        expectedRetainedLegacy: Int?,
        expectedContentDigest: String?
    ) throws {
        if let expectedContentDigest {
            let digest = try SQLiteLogicalDigest.digest(of: storeURL)
            guard digest == expectedContentDigest else {
                throw M1MigrationError.verificationFailed("staged content digest mismatch")
            }
        }
        let counts = try StoreSnapshotter.readEntityCounts(storeURL: storeURL)
        guard counts == receipt.entityCounts else {
            throw M1MigrationError.verificationFailed(
                "entity counts \(counts) != receipt \(receipt.entityCounts)"
            )
        }
        let configuration = ModelConfiguration(url: storeURL, allowsSave: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: RecordingsStore.schema, configurations: configuration
            )
        } catch {
            throw M1MigrationError.verificationFailed(error.localizedDescription)
        }
        let context = ModelContext(container)
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        var remainingLegacy = 0
        var missingOwnership = 0
        for recording in recordings {
            if recording.audioFileOwnership == nil { missingOwnership += 1 }
            if case .legacyAbsolute = recording.audioFileReference { remainingLegacy += 1 }
            if case .legacyAbsolute = recording.segmentsDirectoryReference { remainingLegacy += 1 }
        }
        guard missingOwnership == 0 else {
            throw M1MigrationError.verificationFailed("\(missingOwnership) rows without ownership")
        }
        if let expectedRetainedLegacy {
            guard remainingLegacy == expectedRetainedLegacy else {
                throw M1MigrationError.verificationFailed(
                    "legacy rows \(remainingLegacy) != recorded \(expectedRetainedLegacy)"
                )
            }
        }
    }

    private func commitRegistry(profileID: UUID, storeMaterialized: Bool) throws {
        let now = dependencies.now()
        let profile = Profile(
            id: profileID,
            kind: .standard,
            name: "Cadenza",
            colorHex: nil,
            createdAt: now,
            lastActiveAt: now,
            audioDirectory: dependencies.audioDirectoryState(),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: storeMaterialized,
            sessionDisposition: .active
        )
        let document = ProfileRegistryDocument(
            version: ProfileRegistryDocument.currentVersion,
            activeProfileID: profileID,
            profiles: [profile]
        )
        try dependencies.registry.save(document)
    }

    // MARK: - Retire

    /// In-window retire: physical evidence must still hold, then the
    /// checkpoint-digest-rename protocol runs under the held lease. Any
    /// deviation keeps the source duplicate untouched.
    private func retireSourceInWindow(
        trio: StoreTrioURL,
        evidence: SourceEvidence,
        lease: SourceFreezeLease,
        record: inout MigrationJournalDocument.M1Record,
        journalStore: MigrationJournalStore
    ) -> Bool {
        switch evidence.check(for: trio, fileOperations: fileOperations) {
        case .holds:
            break
        case .changed(let detail):
            NSLog("[M1Migration] source changed during window (%@); keeping duplicate", detail)
            return false
        case .unverifiable(let detail):
            NSLog("[M1Migration] source unverifiable (%@); keeping duplicate", detail)
            return false
        }
        return checkpointVerifyAndRename(
            trio: trio, lease: lease, record: &record, journalStore: journalStore
        )
    }

    /// Resume the retire step on a later launch. The physical evidence is
    /// invalid across a lease release (checkpoints rewrite the base), so
    /// the decision uses the logical content digest captured at commit
    /// time: identical content retires; any difference — a real write
    /// between launches — keeps the duplicate permanently.
    private func resumeRetire(
        record: MigrationJournalDocument.M1Record,
        journalStore: MigrationJournalStore
    ) -> Outcome {
        var record = record
        switch resumeSource(hint: record.sourceStorePath) {
        case .failClosed(let reason):
            NSLog("[M1Migration] retire deferred (%@); keeping state", reason)
            return .committedPendingRetire(profileID: record.profileID)
        case .present(let trio):
            guard record.sourceContentDigest != nil else {
                NSLog("[M1Migration] no content digest recorded; keeping duplicate")
                return .committedPendingRetire(profileID: record.profileID)
            }
            guard validateCommittedTarget(record: record, requireExactDigest: true) else {
                return .committedPendingRetire(profileID: record.profileID)
            }
            guard let lease = try? SourceFreezeLease.acquire(
                storeURL: trio.base, fileOperations: fileOperations
            ) else {
                return .committedPendingRetire(profileID: record.profileID)
            }
            defer { lease.release() }
            guard checkpointVerifyAndRename(
                trio: trio, lease: lease, record: &record, journalStore: journalStore
            ) else {
                return .committedPendingRetire(profileID: record.profileID)
            }
            lease.release()
            sweepStaleSourceSidecars(forRetiredBase: trio.base)
        case .alreadyRetired(let base):
            guard validateCommittedTarget(record: record, requireExactDigest: true) else {
                return .committedPendingRetire(profileID: record.profileID)
            }
            guard verifyRetiredStore(sourceBase: base, record: record) else {
                return .committedPendingRetire(profileID: record.profileID)
            }
            sweepStaleSourceSidecars(forRetiredBase: base)
        }
        record.state = .done
        do {
            try saveJournal(record, to: journalStore)
        } catch {
            NSLog("[M1Migration] journal done-write failed: %@", String(describing: error))
        }
        return .completed(profileID: record.profileID)
    }

    private enum ResumeSourceState {
        case present(StoreTrioURL)
        case alreadyRetired(base: URL)
        case failClosed(String)
    }

    /// Source selection for a resumed retire: the journal hint must
    /// literally equal one of the whitelisted paths, and only that exact
    /// candidate is ever considered. A hint outside the whitelist, or a
    /// probe that cannot prove presence or absence, fails closed — the
    /// resume never switches to a different file, even one with identical
    /// content.
    private func resumeSource(hint: String) -> ResumeSourceState {
        let approved = [paths.legacyStoreURL, paths.preLegacyStoreURL]
        guard let candidate = approved.first(where: { $0.path == hint }) else {
            return .failClosed("journal source hint is not a whitelisted path")
        }
        switch probePresence(of: candidate) {
        case .regularFile:
            return .present(StoreTrioURL(base: candidate))
        case .absent:
            return .alreadyRetired(base: candidate)
        case .rejected(let name):
            return .failClosed("source not a regular file: \(name)")
        case .unknown(let detail):
            return .failClosed("source probe failed: \(detail)")
        }
    }

    /// Shared retire tail, entered under a held lease:
    /// 1. `prepareForRetire` folds every WAL frame into the base and
    ///    switches it to rollback-journal mode: the base becomes a single
    ///    self-contained file that read-only consumers can open, and the
    ///    renames cannot split content between differently-named files.
    /// 2. The logical digest must equal the recorded one — this also
    ///    covers the lock hand-off instants inside the preparation.
    /// 3. The lease closes before the BASE rename so SQLite never observes
    ///    its own open vnode move. Boot remains serialized by the migration
    ///    lock, and later verification still binds the retired content.
    private func checkpointVerifyAndRename(
        trio: StoreTrioURL,
        lease: SourceFreezeLease,
        record: inout MigrationJournalDocument.M1Record,
        journalStore: MigrationJournalStore
    ) -> Bool {
        guard let expectedDigest = record.sourceContentDigest else {
            NSLog("[M1Migration] no content digest recorded; keeping duplicate")
            return false
        }
        do {
            try lease.prepareForRetire()
        } catch {
            NSLog(
                "[M1Migration] retire preparation failed (%@); keeping duplicate",
                String(describing: error)
            )
            return false
        }
        let currentDigest: String
        do {
            currentDigest = try SQLiteLogicalDigest.digest(of: trio.base)
        } catch {
            NSLog(
                "[M1Migration] source digest unavailable (%@); keeping duplicate",
                String(describing: error)
            )
            return false
        }
        guard currentDigest == expectedDigest else {
            NSLog("[M1Migration] source content changed since commit; keeping duplicate")
            return false
        }
        lease.release()
        return renameRetiredTrio(trio, record: &record, journalStore: journalStore)
    }

    /// Best-effort removal of content-free source sidecars once the base
    /// is retired. Only a DEFINITE not-found of the base authorizes the
    /// sweep — an unreadable base may still be a live database whose WAL
    /// must never be deleted — and each sidecar must itself prove to be a
    /// regular file.
    private func sweepStaleSourceSidecars(forRetiredBase base: URL) {
        switch probePresence(of: base) {
        case .absent:
            break
        case .regularFile, .rejected, .unknown:
            NSLog("[M1Migration] sidecar sweep skipped: base state not definitively absent")
            return
        }
        let trio = StoreTrioURL(base: base)
        for sidecar in [trio.wal, trio.shm] {
            switch probePresence(of: sidecar) {
            case .regularFile:
                do {
                    try fileOperations.removeItem(at: sidecar)
                } catch {
                    NSLog(
                        "[M1Migration] sidecar sweep failed for %@: %@",
                        sidecar.lastPathComponent, String(describing: error)
                    )
                }
            case .absent:
                continue
            case .rejected(let name):
                NSLog("[M1Migration] sidecar sweep kept non-regular node %@", name)
            case .unknown(let detail):
                NSLog("[M1Migration] sidecar sweep kept unprobeable node: %@", detail)
            }
        }
    }

    /// Retired-base rename. The generation is chosen against occupied
    /// names and persisted in the journal BEFORE the rename, so a resumed
    /// attempt reuses it; with the recorded generation, a target occupied
    /// while the source still exists can only be a foreign file — the
    /// rename is exclusive and any error stops fail-safe. After the base
    /// rename the content-free source sidecars are removed best-effort.
    private func renameRetiredTrio(
        _ trio: StoreTrioURL,
        record: inout MigrationJournalDocument.M1Record,
        journalStore: MigrationJournalStore
    ) -> Bool {
        let generation: Int
        if let recorded = record.retireGeneration {
            generation = recorded
        } else {
            guard let free = chooseFreeGeneration(for: trio) else {
                NSLog("[M1Migration] no free retire generation; keeping duplicate")
                return false
            }
            generation = free
            record.retireGeneration = generation
            do {
                try saveJournal(record, to: journalStore)
            } catch {
                NSLog(
                    "[M1Migration] retire-generation journal write failed: %@",
                    String(describing: error)
                )
                return false
            }
        }
        let retired = retiredBaseURL(for: trio, generation: generation)
        do {
            try fileOperations.moveItemExclusively(staging: trio.base, final: retired)
        } catch {
            NSLog(
                "[M1Migration] retire rename failed for %@: %@",
                trio.base.lastPathComponent, String(describing: error)
            )
            return false
        }
        return verifyRetiredStore(sourceBase: trio.base, record: record)
    }

    private func verifyRetiredStore(
        sourceBase: URL, record: MigrationJournalDocument.M1Record
    ) -> Bool {
        guard let generation = record.retireGeneration,
              let expectedDigest = record.sourceContentDigest else {
            NSLog("[M1Migration] retired store proof missing")
            return false
        }
        let retired = retiredBaseURL(
            for: StoreTrioURL(base: sourceBase), generation: generation
        )
        do {
            try requireRegularFile(at: retired, fileOperations: fileOperations)
            guard try SQLiteLogicalDigest.digest(of: retired) == expectedDigest else {
                NSLog("[M1Migration] retired store content mismatch")
                return false
            }
            return true
        } catch {
            NSLog(
                "[M1Migration] retired store verification failed: %@",
                String(describing: error)
            )
            return false
        }
    }

    private func retiredBaseURL(for trio: StoreTrioURL, generation: Int) -> URL {
        URL(fileURLWithPath: trio.base.path + ".migrated-\(generation)")
    }

    /// A generation whose retired-base name is unoccupied.
    private func chooseFreeGeneration(for trio: StoreTrioURL) -> Int? {
        let base = Int(dependencies.now().timeIntervalSince1970)
        for offset in 0..<100 {
            let candidate = base + offset
            if !fileOperations.fileExists(at: retiredBaseURL(for: trio, generation: candidate)) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func saveJournal(
        _ record: MigrationJournalDocument.M1Record, to store: MigrationJournalStore
    ) throws {
        try store.save(MigrationJournalDocument(
            version: MigrationJournalDocument.currentVersion, m1: record
        ))
    }

    /// Pre-commit leftovers (staging tree, unplaced or placed-but-uncommitted
    /// profile directory) are disposable; failures here only waste disk.
    private func discardPreCommitLeftovers(profileID: UUID) {
        for leftover in [
            paths.stagingDirectory(profileID: profileID),
            paths.profileDirectory(profileID),
        ] where fileOperations.fileExists(at: leftover) {
            do {
                try fileOperations.removeItem(at: leftover)
            } catch {
                NSLog(
                    "[M1Migration] leftover cleanup failed for %@: %@",
                    leftover.lastPathComponent, String(describing: error)
                )
            }
        }
    }
}

/// `flock(LOCK_EX | LOCK_NB)` over a lock file: exclusive across processes,
/// released automatically when the descriptor dies with the process.
final class MigrationFileLock {
    private var fd: Int32

    init?(url: URL) {
        fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
    }

    func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        unlock()
    }
}
