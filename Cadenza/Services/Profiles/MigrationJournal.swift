import Foundation

/// Persistent record of migration progress (spec §9.2). One document holds
/// the ordered pipeline. The `m1` storage step journals here; the session
/// steps (M2 binding, M3 Local) commit through the registry itself and
/// need no journal entries. Writes are atomic and durable via
/// `FileOperations.atomicReplace`.
struct MigrationJournalDocument: Codable, Sendable, Equatable {
    enum M1State: String, Codable, Sendable, CaseIterable {
        case started
        case snapshotVerified
        case staged
        case targetVerified
        case registryCommitted
        case done
    }

    struct M1Record: Codable, Sendable, Equatable {
        var state: M1State
        var profileID: UUID
        var sourceStorePath: String
        var receipt: SnapshotReceipt?
        /// Captured under the freeze lease before the snapshot; re-verified
        /// before commit and before retire.
        var sourceEvidence: SourceEvidence?
        /// Rewrite bookkeeping recorded at the stage step and re-checked at
        /// verify: relative rewrites performed and legacy rows kept.
        var rewrittenReferenceCount: Int?
        var retainedLegacyCount: Int?
        /// Logical content digest of the source, computed under the freeze
        /// lease. Invariant under WAL checkpoints, so it is the evidence a
        /// resumed retire compares against.
        var sourceContentDigest: String?
        /// Logical content digest of the staged target after ALL staged
        /// mutations. Re-verified before the registry may be re-established
        /// and before any source retirement: count-preserving tampering and
        /// uncounted-entity removal both change it.
        var targetContentDigest: String?
        /// Suffix generation for the retired trio names, chosen once and
        /// persisted before the first rename so a resumed retire reuses it.
        var retireGeneration: Int?
    }

    var version: Int
    var m1: M1Record?

    static let currentVersion = 1
}

extension MigrationJournalDocument {
    /// State-dependent semantic validation, enforced on load AND save: a
    /// record whose required evidence is missing for its state is
    /// corruption, never something to act on.
    func validate() throws {
        guard version >= 1, version <= Self.currentVersion else {
            throw MigrationJournalError.malformed("unsupported version \(version)")
        }
        try m1?.validate()
    }
}

extension MigrationJournalDocument.M1Record {
    /// The one shape a fresh install writes: done, no source, no receipt,
    /// no evidence, no digests, zero counts.
    var isFreshInstallShape: Bool {
        state == .done && sourceStorePath.isEmpty && receipt == nil
            && sourceEvidence == nil && sourceContentDigest == nil
            && targetContentDigest == nil && retireGeneration == nil
            && rewrittenReferenceCount == 0 && retainedLegacyCount == 0
    }

    func validate() throws {
        func requireDigest(_ digest: String?, _ label: String) throws {
            guard let digest, digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                throw MigrationJournalError.malformed("\(label) digest malformed")
            }
        }
        if isFreshInstallShape { return }
        guard !sourceStorePath.isEmpty else {
            throw MigrationJournalError.malformed("migrated record without source path")
        }
        guard sourceEvidence != nil else {
            throw MigrationJournalError.malformed("migrated record without source evidence")
        }
        try requireDigest(sourceContentDigest, "source")
        // Fields may only appear at the states that produce them; a
        // combination the pipeline cannot write is corruption.
        switch state {
        case .started:
            guard receipt == nil else {
                throw MigrationJournalError.malformed("started with receipt")
            }
            fallthrough
        case .snapshotVerified:
            if state == .snapshotVerified, receipt == nil {
                throw MigrationJournalError.malformed("snapshotVerified without receipt")
            }
            guard rewrittenReferenceCount == nil, retainedLegacyCount == nil,
                  targetContentDigest == nil else {
                throw MigrationJournalError.malformed("\(state.rawValue) with staged fields")
            }
            guard retireGeneration == nil else {
                throw MigrationJournalError.malformed("\(state.rawValue) with retire generation")
            }
        case .staged, .targetVerified:
            guard receipt != nil else {
                throw MigrationJournalError.malformed("\(state.rawValue) without receipt")
            }
            guard let rewritten = rewrittenReferenceCount, rewritten >= 0,
                  let retained = retainedLegacyCount, retained >= 0 else {
                throw MigrationJournalError.malformed("\(state.rawValue) without valid counts")
            }
            try requireDigest(targetContentDigest, "target")
            guard retireGeneration == nil else {
                throw MigrationJournalError.malformed("\(state.rawValue) with retire generation")
            }
        case .registryCommitted, .done:
            guard receipt != nil else {
                throw MigrationJournalError.malformed("\(state.rawValue) without receipt")
            }
            guard let rewritten = rewrittenReferenceCount, rewritten >= 0,
                  let retained = retainedLegacyCount, retained >= 0 else {
                throw MigrationJournalError.malformed("\(state.rawValue) without valid counts")
            }
            try requireDigest(targetContentDigest, "target")
            if let generation = retireGeneration, generation < 0 {
                throw MigrationJournalError.malformed("negative retire generation")
            }
        }
    }
}

enum MigrationJournalError: Error, Equatable {
    case malformed(String)
    case untrustedPath(String)
}

/// Journal IO plus the path-trust rule for resume: recorded paths are hints
/// only — before use they must re-validate as lexically inside the
/// migration directory with no symlinked components. Dates (present and
/// future fields) persist as epoch seconds via the shared profile coders.
struct MigrationJournalStore: Sendable {
    let journalURL: URL
    let migrationDirectory: URL
    let fileOperations: FileOperations

    init(paths: ProfilePaths, fileOperations: FileOperations) {
        self.journalURL = paths.journalURL
        self.migrationDirectory = paths.migrationDirectory
        self.fileOperations = fileOperations
    }

    func load() throws -> MigrationJournalDocument? {
        try rejectSymlinkedMigrationRoot()
        // lstat semantics on the journal itself: a symlink here is an
        // attack or corruption, never a valid state — fail closed rather
        // than follow or silently treat it as absent.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileOperations.attributesOfItem(at: journalURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw MigrationJournalError.malformed("unreadable: \(error.localizedDescription)")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MigrationJournalError.untrustedPath(journalURL.path)
        }
        let data: Data
        do {
            data = try fileOperations.read(from: journalURL)
        } catch {
            throw MigrationJournalError.malformed("unreadable: \(error.localizedDescription)")
        }
        let document: MigrationJournalDocument
        do {
            document = try ProfileRegistryCoding.makeDecoder().decode(
                MigrationJournalDocument.self, from: data
            )
        } catch {
            throw MigrationJournalError.malformed("undecodable: \(error)")
        }
        try document.validate()
        return document
    }

    func save(_ document: MigrationJournalDocument) throws {
        try rejectSymlinkedMigrationRoot()
        try document.validate()
        let data = try ProfileRegistryCoding.makeEncoder().encode(document)
        try fileOperations.atomicReplace(data, at: journalURL)
    }

    /// The migration directory itself must never be a link: everything the
    /// journal trusts is defined lexically relative to it. The probe is
    /// shared with every Migration/ artifact so the trust rule cannot
    /// drift between them.
    private func rejectSymlinkedMigrationRoot() throws {
        do {
            try requireTrustedMigrationRoot(
                at: migrationDirectory, fileOperations: fileOperations
            )
        } catch is FileOperationError {
            throw MigrationJournalError.untrustedPath(migrationDirectory.path)
        } catch {
            throw MigrationJournalError.malformed(
                "migration root unreadable: \(error.localizedDescription)"
            )
        }
    }

    /// A journal-recorded location is only trusted after re-validation:
    /// lexically inside the migration directory, and no component between
    /// the migration root and the target is a symlink. Existing components
    /// are checked with lstat semantics — resolution-based comparison would
    /// miss links on paths whose tail does not exist yet. Missing components
    /// are legitimate (targets not created yet); any other probe failure is
    /// fail-closed.
    func validatedMigrationLocation(_ url: URL) throws -> URL {
        try rejectSymlinkedMigrationRoot()
        let lexical = url.standardizedFileURL.pathComponents
        let rootLexical = migrationDirectory.standardizedFileURL.pathComponents
        guard lexical.count > rootLexical.count,
              Array(lexical.prefix(rootLexical.count)) == rootLexical else {
            throw MigrationJournalError.untrustedPath(url.path)
        }
        var probe = migrationDirectory
        for component in lexical.dropFirst(rootLexical.count) {
            probe = probe.appendingPathComponent(component)
            do {
                let attributes = try fileOperations.attributesOfItem(at: probe)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw MigrationJournalError.untrustedPath(url.path)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch let error as MigrationJournalError {
                throw error
            } catch {
                throw MigrationJournalError.untrustedPath(url.path)
            }
        }
        return url
    }
}
