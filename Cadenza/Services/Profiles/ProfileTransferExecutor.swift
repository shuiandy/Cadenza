import Foundation
import SwiftData
import os

/// Crash-safe whole-store transfer executor for the dedicated boot path.
/// Resume decisions use persisted proofs and classified registry saves.
enum ProfileTransferExecutor {
    /// Tracks SQLite stores opened through SwiftData in this process.
    /// Tracked paths and sidecars are retained until a later process.
    final class ScratchProcessTracker: Sendable {
        static let shared = ScratchProcessTracker()

        private let opened = OSAllocatedUnfairLock<Set<String>>(initialState: [])

        func markOpened(baseURL: URL) {
            _ = opened.withLock { $0.insert(Self.baseIdentity(of: baseURL)) }
        }

        func containsBase(for entryURL: URL) -> Bool {
            opened.withLock { $0.contains(Self.baseIdentity(of: entryURL)) }
        }

        /// Maps a base path or either of its "-wal"/"-shm" sidecars to
        /// one shared identity, so marking or querying any member of
        /// the trio is equivalent.
        private static func baseIdentity(of url: URL) -> String {
            let path = url.standardizedFileURL.path
            if path.hasSuffix("-wal") { return String(path.dropLast(4)) }
            if path.hasSuffix("-shm") { return String(path.dropLast(4)) }
            return path
        }
    }

    struct Dependencies {
        let paths: ProfilePaths
        let registry: any ProfileRegistryProviding
        let fileOperations: FileOperations
        let backupDriver: SQLiteBackupDriver
        let inspector: any TransferStoreInspecting
        let scratchTracker: ScratchProcessTracker
        let now: () -> Date
    }

    enum Outcome {
        case completed(targetProfileID: UUID)
        case halted(String)
    }

    enum ExecutorError: Error {
        case halt(String)
    }

    static let requiredDiskSlack: Int64 = 512 * 1024 * 1024
    static let audioDiskSlack: Int64 = 64 * 1024 * 1024

    @MainActor
    static func runLive(pending: PendingTransfer) -> Outcome {
        let environment = ProfileEnvironment.current()
        guard case .live = environment else {
            preconditionFailure("transfer executor must never run in the TestHost")
        }
        let fileOperations = LiveFileOperations()
        return run(
            pending: pending,
            dependencies: Dependencies(
                paths: environment.paths,
                registry: DiskProfileRegistry(
                    registryURL: environment.paths.registryURL,
                    fileOperations: fileOperations
                ),
                fileOperations: fileOperations,
                backupDriver: LiveSQLiteBackupDriver(),
                inspector: LiveTransferStoreInspector(fileOperations: fileOperations),
                scratchTracker: ScratchProcessTracker.shared,
                now: { Date() }
            )
        )
    }

    /// Drives the recorded state machine to completion. The passed
    /// record is advisory; every step reloads the registry, proves the
    /// durable record byte-identical to the one it advanced from, and
    /// re-proves the structural shape.
    static func run(
        pending: PendingTransfer, dependencies: Dependencies
    ) -> Outcome {
        do {
            try requireTrustedMigrationRoot(
                at: dependencies.paths.migrationDirectory,
                fileOperations: dependencies.fileOperations
            )
            try dependencies.fileOperations.createDirectory(
                at: dependencies.paths.migrationDirectory
            )
            try requireTrustedMigrationRoot(
                at: dependencies.paths.migrationDirectory,
                fileOperations: dependencies.fileOperations
            )
        } catch {
            return .halted("migration directory unavailable: \(error)")
        }
        guard let lock = MigrationFileLock(
            url: dependencies.paths.migrationDirectory.appendingPathComponent("lock")
        ) else {
            return .halted("transfer lock unavailable")
        }
        defer { lock.unlock() }
        do {
            var current = try reloadAndProve(
                matching: nil, transactionID: pending.transactionID,
                dependencies: dependencies
            )
            sweepLeftoverWorkStores(current, dependencies: dependencies)
            while true {
                switch current.state {
                case .initiated:
                    current = try performSnapshot(current, dependencies: dependencies)
                case .sourceSnapshotted:
                    current = try performStage(current, dependencies: dependencies)
                case .staged:
                    current = try performStagedVerification(
                        current, dependencies: dependencies
                    )
                case .targetVerified:
                    current = try performPlacement(current, dependencies: dependencies)
                case .placed:
                    if current.mode == .copy {
                        try performFinalVerification(current, dependencies: dependencies)
                        try performCommit(current, dependencies: dependencies)
                        return .completed(targetProfileID: current.targetProfileID)
                    }
                    current = try performLocalRebuildPreparation(
                        current, dependencies: dependencies
                    )
                case .localRebuilt:
                    try performRetire(current, dependencies: dependencies)
                    try performFinalVerification(current, dependencies: dependencies)
                    try performCommit(current, dependencies: dependencies)
                    return .completed(targetProfileID: current.targetProfileID)
                }
            }
        } catch ExecutorError.halt(let reason) {
            return .halted(reason)
        } catch {
            return .halted("transfer step failed: \(error)")
        }
    }

    // MARK: - Record proofs

    private static func encodedPending(_ pending: PendingTransfer) throws -> Data {
        do {
            return try ProfileRegistryCoding.makeEncoder().encode(pending)
        } catch {
            throw ExecutorError.halt("pending record unencodable: \(error)")
        }
    }

    /// Fresh load; the durable record must be byte-identical to the one
    /// this run last observed (when given) and structurally sound.
    private static func reloadAndProve(
        matching expected: PendingTransfer?,
        transactionID: UUID,
        dependencies: Dependencies
    ) throws -> PendingTransfer {
        let document: ProfileRegistryDocument
        do {
            document = try dependencies.registry.load()
        } catch {
            throw ExecutorError.halt("registry unreadable during transfer: \(error)")
        }
        guard let pending = document.pendingTransfer else {
            throw ExecutorError.halt("pending transfer disappeared during execution")
        }
        guard pending.transactionID == transactionID else {
            throw ExecutorError.halt("pending transfer exchanged during execution")
        }
        if let expected {
            guard try encodedPending(pending) == encodedPending(expected) else {
                throw ExecutorError.halt("pending transfer drifted during execution")
            }
        }
        if let problem = ProfileTransfer.structuralProblem(
            document: document, pending: pending
        ) {
            throw ExecutorError.halt(problem)
        }
        return pending
    }

    /// One classified checkpoint write: the durable record must still be
    /// byte-identical to the record this step advanced from, then the
    /// mutation commits through old/intended/third classification.
    private static func saveCheckpoint(
        old: PendingTransfer,
        mutated: PendingTransfer,
        dependencies: Dependencies
    ) throws -> PendingTransfer {
        let document: ProfileRegistryDocument
        do {
            document = try dependencies.registry.load()
        } catch {
            throw ExecutorError.halt("registry unreadable at checkpoint: \(error)")
        }
        guard let disk = document.pendingTransfer,
              try encodedPending(disk) == encodedPending(old) else {
            throw ExecutorError.halt("pending transfer drifted at checkpoint")
        }
        var intended = document
        intended.pendingTransfer = mutated
        switch ProfileSwitchCoordinator.classifiedSave(
            old: document, intended: intended, registry: dependencies.registry
        ) {
        case .committed:
            return mutated
        case .notCommitted(let detail):
            throw ExecutorError.halt("checkpoint not recorded: \(detail)")
        case .indeterminate(let detail):
            throw ExecutorError.halt("checkpoint indeterminate: \(detail)")
        }
    }

    // MARK: - Trusted derived paths

    private static func sourceTrio(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) -> StoreTrioURL {
        StoreTrioURL(base: dependencies.paths.storeURL(pending.sourceProfileID))
    }

    private static func snapshotRootDirectory(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) -> URL {
        dependencies.paths.migrationDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(
                "transfer-\(pending.transactionID.uuidString)", isDirectory: true
            )
    }

    /// The persisted receipt is evidence, never a path source: every
    /// artifact location is re-derived from the trusted paths, and the
    /// receipt must name exactly the derived location.
    private static func snapshotArtifactURL(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> URL {
        guard let receipt = pending.snapshotReceipt else {
            throw ExecutorError.halt("checkpoint payload missing receipt")
        }
        let root = snapshotRootDirectory(pending, dependencies: dependencies)
        let recorded = receipt.directory.standardizedFileURL
        guard recorded.deletingLastPathComponent().path == root.standardizedFileURL.path,
              UUID(uuidString: recorded.lastPathComponent) != nil else {
            throw ExecutorError.halt("receipt names a foreign snapshot directory")
        }
        try requireTrustedMigrationDirectory(
            recorded, mustExist: true, dependencies: dependencies
        )
        let legalNames = ["Cadenza.store", "Cadenza.store-wal", "Cadenza.store-shm"]
        for file in receipt.files where !legalNames.contains(file.name) {
            throw ExecutorError.halt("receipt names a foreign file: \(file.name)")
        }
        let names = receipt.files.map(\.name)
        guard names.filter({ $0 == "Cadenza.store" }).count == 1,
              Set(names).count == names.count else {
            throw ExecutorError.halt("receipt file inventory is ambiguous")
        }
        return recorded.appendingPathComponent("Cadenza.store")
    }

    private static func stagedStoreURL(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) -> URL {
        dependencies.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        ).appendingPathComponent("Cadenza.store")
    }

    private static func stagedVerificationStoreURL(
        _ pending: PendingTransfer, nonce: UUID, dependencies: Dependencies
    ) -> URL {
        dependencies.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        ).appendingPathComponent("Cadenza.store.verify-\(nonce.uuidString)")
    }

    private static func replacementStoreURL(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) -> URL {
        let base = dependencies.paths.storeURL(pending.sourceProfileID)
        return URL(
            fileURLWithPath: base.path + ".replacement-\(pending.transactionID.uuidString)"
        )
    }

    private static func replacementVerificationStoreURL(
        _ pending: PendingTransfer, nonce: UUID, dependencies: Dependencies
    ) -> URL {
        URL(fileURLWithPath: replacementStoreURL(
            pending, dependencies: dependencies
        ).path + ".verify-\(nonce.uuidString)")
    }

    private static func retiredStoreURL(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) -> URL {
        let base = dependencies.paths.storeURL(pending.sourceProfileID)
        return URL(
            fileURLWithPath: base.path + ".transferred-\(pending.transactionID.uuidString)"
        )
    }

    private static func targetProfileMarker(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) -> URL {
        ProfileTransfer.placementMarkerURL(
            inDirectory: dependencies.paths.profileDirectory(pending.targetProfileID),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
    }

    private static func requireOrClaimPlacementMarker(
        at url: URL,
        pending: PendingTransfer,
        kind: TransferPlacementClaim.Kind,
        operations: FileOperations
    ) throws {
        do {
            switch try ProfileTransfer.placementMarkerPresence(
                at: url, pending: pending, kind: kind, fileOperations: operations
            ) {
            case .matching:
                return
            case .absent:
                break
            }
        } catch {
            throw ExecutorError.halt("placement marker claim mismatch: \(error)")
        }
        do {
            try operations.createFileExclusively(
                ProfileTransfer.placementMarkerPayload(pending, kind: kind), at: url
            )
        } catch FileOperationError.createFailed(let code) where code == EEXIST {
            do {
                try ProfileTransfer.requireMatchingPlacementMarker(
                    at: url, pending: pending, kind: kind,
                    fileOperations: operations
                )
            } catch {
                throw ExecutorError.halt("placement marker claim mismatch: \(error)")
            }
        } catch {
            throw ExecutorError.halt("placement marker claim failed: \(error)")
        }
    }

    // MARK: - Audio roots

    /// Resolves a frozen audio root, honoring a recorded security-scoped
    /// bookmark for user-selected directories. The resolved location
    /// must match the frozen lexical path exactly; drift fails closed.
    private static func withAudioRootAccess<T>(
        of profile: Profile, _ body: (URL) throws -> T
    ) throws -> T {
        do {
            return try ProfileTransfer.withAudioRootAccess(of: profile, body)
        } catch let error as ExecutorError {
            throw error
        } catch ProfileTransfer.AudioRootAccessError.pathDrift {
            throw ExecutorError.halt("audio root moved since the transfer froze it")
        } catch {
            throw ExecutorError.halt("audio root bookmark unresolvable: \(error)")
        }
    }

    // MARK: - initiated → sourceSnapshotted

    private static func performSnapshot(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> PendingTransfer {
        let trio = sourceTrio(pending, dependencies: dependencies)
        try preflightStoreDiskSpace(for: trio, dependencies: dependencies)
        let lease: SourceFreezeLease
        do {
            lease = try SourceFreezeLease.acquire(
                storeURL: trio.base, fileOperations: dependencies.fileOperations
            )
        } catch {
            throw ExecutorError.halt("source freeze unavailable: \(error)")
        }
        defer { lease.release() }
        let evidence: SourceEvidence
        do {
            evidence = try SourceEvidence.capture(
                source: trio, fileOperations: dependencies.fileOperations
            )
        } catch {
            throw ExecutorError.halt("source evidence capture failed: \(error)")
        }
        let digest: String
        do {
            digest = try SQLiteLogicalDigest.digest(of: trio.base)
        } catch {
            throw ExecutorError.halt("source digest failed: \(error)")
        }
        let receipt: SnapshotReceipt
        do {
            try requireTrustedMigrationDirectory(
                snapshotRootDirectory(pending, dependencies: dependencies),
                mustExist: false,
                dependencies: dependencies
            )
            try ensureTrustedDirectory(
                snapshotRootDirectory(pending, dependencies: dependencies),
                operations: dependencies.fileOperations
            )
            receipt = try StoreSnapshotter.performVerifiedSnapshot(
                source: trio,
                into: snapshotRootDirectory(pending, dependencies: dependencies),
                label: UUID().uuidString,
                fileOperations: dependencies.fileOperations,
                backupDriver: dependencies.backupDriver
            )
        } catch {
            throw ExecutorError.halt("source snapshot failed: \(error)")
        }
        var mutated = pending
        mutated.state = .sourceSnapshotted
        mutated.snapshotReceipt = receipt
        mutated.sourceStoreEvidence = evidence
        mutated.sourceContentDigest = digest
        return try saveCheckpoint(old: pending, mutated: mutated, dependencies: dependencies)
    }

    /// Store-side capacity: snapshot artifact, staged copy, and the move
    /// replacement all live near the store volume.
    private static func preflightStoreDiskSpace(
        for trio: StoreTrioURL, dependencies: Dependencies
    ) throws {
        var trioBytes: Int64 = 0
        for (file, required) in [(trio.base, true), (trio.wal, false), (trio.shm, false)] {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try dependencies.fileOperations.attributesOfItem(at: file)
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile && !required {
                continue
            } catch {
                throw ExecutorError.halt("source probe failed: \(error)")
            }
            guard let size = attributes[.size] as? Int64, size >= 0 else {
                throw ExecutorError.halt("source size unreadable")
            }
            let (sum, overflow) = trioBytes.addingReportingOverflow(size)
            guard !overflow else {
                throw ExecutorError.halt("source size total overflow")
            }
            trioBytes = sum
        }
        let (threeCopies, multiplicationOverflow) = trioBytes.multipliedReportingOverflow(
            by: 3
        )
        let (required, additionOverflow) = threeCopies.addingReportingOverflow(
            requiredDiskSlack
        )
        guard !multiplicationOverflow, !additionOverflow else {
            throw ExecutorError.halt("store capacity requirement overflow")
        }
        let available: Int64
        do {
            available = try dependencies.fileOperations.availableCapacity(
                at: dependencies.paths.root
            )
        } catch {
            throw ExecutorError.halt("capacity probe failed: \(error)")
        }
        guard available >= required else {
            throw ExecutorError.halt(
                "insufficient disk space: need \(required), have \(available)"
            )
        }
    }

    // MARK: - sourceSnapshotted → staged

    private static func performStage(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> PendingTransfer {
        let (_, sourceDigest) = try requireRecordedEvidence(
            pending, dependencies: dependencies
        )
        guard let receipt = pending.snapshotReceipt else {
            throw ExecutorError.halt("checkpoint payload missing receipt")
        }
        let operations = dependencies.fileOperations
        let artifact = try snapshotArtifactURL(pending, dependencies: dependencies)
        let staging = dependencies.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        )
        try requireTrustedMigrationDirectory(
            staging, mustExist: false, dependencies: dependencies
        )
        try ensureTrustedDirectory(staging, operations: operations)
        let stagedStore = stagedStoreURL(pending, dependencies: dependencies)
        let source = pending.sourceEvidence.profile

        let stagedPresence = try regularFilePresence(
            at: stagedStore, operations: operations
        )
        try removePreparedStoreSidecars(for: stagedStore, operations: operations)
        if stagedPresence == .present {
            // Final staged artifacts are never opened through SwiftData.
            try operations.removeItem(at: stagedStore)
        }
        let workStore = staging.appendingPathComponent(
            "Cadenza.store.work-\(UUID().uuidString)"
        )
        try requireRegularFile(at: artifact, fileOperations: operations)
        try operations.copyItem(at: artifact, to: workStore)
        guard let artifactRecord = receipt.files.first(where: { $0.name == "Cadenza.store" }),
              try operations.sha256(of: workStore) == artifactRecord.sha256 else {
            throw ExecutorError.halt("staged copy hash differs from receipt")
        }
        guard try stagedDigest(of: workStore) == sourceDigest else {
            throw ExecutorError.halt("snapshot content differs from frozen source")
        }

        let plan = try withAudioRootAccess(of: source) { sourceRoot in
            try buildAudioPlan(
                artifact: artifact, sourceRoot: sourceRoot,
                transactionID: pending.transactionID,
                dependencies: dependencies
            )
        }
        try preflightAudioDiskSpace(
            plan: plan, target: pending.targetEvidence.profile, dependencies: dependencies
        )
        try applyStagedRewrites(
            plan: plan, workURL: workStore, finalURL: stagedStore,
            receipt: receipt, pending: pending,
            dependencies: dependencies
        )
        return try finishStaging(
            pending, plan: plan, stagedStore: stagedStore, dependencies: dependencies
        )
    }

    private static func finishStaging(
        _ pending: PendingTransfer,
        plan: TransferAudioPlan,
        stagedStore: URL,
        dependencies: Dependencies
    ) throws -> PendingTransfer {
        var mutated = pending
        mutated.state = .staged
        mutated.audioPlan = plan
        try requireStoreSidecarsAbsent(
            for: stagedStore, operations: dependencies.fileOperations
        )
        mutated.targetContentDigest = try stagedDigest(of: stagedStore)
        mutated.stagedStoreSHA256 = try dependencies.fileOperations.sha256(of: stagedStore)
        return try saveCheckpoint(old: pending, mutated: mutated, dependencies: dependencies)
    }

    private static func stagedDigest(of url: URL) throws -> String {
        do {
            return try SQLiteLogicalDigest.digest(of: url)
        } catch {
            throw ExecutorError.halt("staged digest failed: \(error)")
        }
    }

    private static func requireRecordedEvidence(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> (SourceEvidence, String) {
        guard let evidence = pending.sourceStoreEvidence,
              let digest = pending.sourceContentDigest else {
            throw ExecutorError.halt("checkpoint payload missing source proofs")
        }
        switch evidence.check(
            for: sourceTrio(pending, dependencies: dependencies),
            fileOperations: dependencies.fileOperations
        ) {
        case .holds:
            return (evidence, digest)
        case .changed(let detail):
            throw ExecutorError.halt("source evidence changed: \(detail)")
        case .unverifiable(let detail):
            throw ExecutorError.halt("source evidence unverifiable: \(detail)")
        }
    }

    /// A recording's audio columns as frozen in the verified snapshot
    /// artifact. Copy and cleanup re-read these rows at use time and
    /// halt on any divergence from the persisted plan — the registry
    /// record alone never directs a filesystem mutation.
    private struct SnapshotAudioRow {
        let audioFile: AudioFileReference?
        let segments: AudioFileReference?
        let ownership: AudioFileOwnership
    }

    private static func readSnapshotRows(
        artifact: URL, dependencies: Dependencies
    ) throws -> [(id: UUID, row: SnapshotAudioRow)] {
        let operations = dependencies.fileOperations
        return try autoreleasepool {
            dependencies.scratchTracker.markOpened(baseURL: artifact)
            operations.noteStoreOpen(at: artifact)
            let configuration = ModelConfiguration(url: artifact, allowsSave: false)
            let container: ModelContainer
            do {
                container = try ModelContainer(
                    for: RecordingsStore.schema, configurations: [configuration]
                )
            } catch {
                throw ExecutorError.halt("snapshot artifact unreadable: \(error)")
            }
            let context = ModelContext(container)
            do {
                return try context.fetch(FetchDescriptor<Recording>()).map {
                    ($0.id, SnapshotAudioRow(
                        audioFile: $0.audioFileReference,
                        segments: $0.segmentsDirectoryReference,
                        ownership: $0.ownership
                    ))
                }
            } catch {
                throw ExecutorError.halt("snapshot rows unreadable: \(error)")
            }
        }
    }

    private static func snapshotRowIndex(
        artifact: URL, dependencies: Dependencies
    ) throws -> [UUID: SnapshotAudioRow] {
        var index: [UUID: SnapshotAudioRow] = [:]
        for (id, row) in try readSnapshotRows(artifact: artifact, dependencies: dependencies) {
            guard index[id] == nil else {
                throw ExecutorError.halt("snapshot recording ID duplicated: \(id)")
            }
            index[id] = row
        }
        return index
    }

    private static func rowReference(
        _ row: SnapshotAudioRow, field: TransferAudioPlan.Field
    ) -> AudioFileReference? {
        switch field {
        case .audioFile: row.audioFile
        case .segmentsDirectory: row.segments
        }
    }

    /// Re-derives the source location for one rewrite from the verified
    /// snapshot row and the frozen source root, proving the persisted
    /// plan entry matches the row and the transaction namespace before
    /// any copy or deletion uses it.
    private static func verifiedSourceBase(
        rewrite: TransferAudioPlan.Rewrite,
        rowIndex: [UUID: SnapshotAudioRow],
        sourceRoot: URL,
        transactionID: UUID
    ) throws -> (url: URL, ownership: AudioFileOwnership) {
        guard let row = rowIndex[rewrite.recordingID] else {
            throw ExecutorError.halt(
                "plan names a recording missing from the snapshot: \(rewrite.recordingID)"
            )
        }
        guard let reference = rowReference(row, field: rewrite.field),
              AccountIdentity.matches(reference.storageValue, rewrite.sourceReference) else {
            throw ExecutorError.halt(
                "plan reference does not match the verified snapshot row: \(rewrite.recordingID)"
            )
        }
        let derived = ProfileTransfer.audioDestinationRelativePath(
            transactionID: transactionID,
            recordingID: rewrite.recordingID,
            field: rewrite.field,
            sourceReference: rewrite.sourceReference,
            childRelativePath: nil
        )
        guard AccountIdentity.matches(rewrite.destinationReference, derived) else {
            throw ExecutorError.halt(
                "plan destination is not the transaction namespace: \(rewrite.recordingID)"
            )
        }
        let url: URL
        switch reference {
        case .relative(let path):
            url = try resolveRelative(path, resolver: ProfileStorageResolver(root: sourceRoot))
        case .legacyAbsolute(let path):
            url = URL(fileURLWithPath: path)
        }
        return (url, row.ownership)
    }

    /// Containment-checked child resolution: the child must be a safe
    /// relative path and the result must stay inside the base tree.
    private static func containedChildURL(
        base: URL, child: String
    ) throws -> URL {
        guard ProfileTransfer.isSafeRelativePathComponents(child) else {
            throw ExecutorError.halt("unsafe tree child path: \(child)")
        }
        let url = base.appendingPathComponent(child)
        let basePath = base.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(basePath + "/") else {
            throw ExecutorError.halt("tree child escapes its tree: \(child)")
        }
        return url
    }

    /// The executor re-validates the manifest immediately before any
    /// filesystem mutation it directs, independent of the load-side and
    /// save-side validation.
    private static func requireValidPlan(
        _ plan: TransferAudioPlan, transactionID: UUID
    ) throws {
        if let problem = ProfileTransfer.planProblem(plan, transactionID: transactionID) {
            throw ExecutorError.halt("audio plan invalid: \(problem)")
        }
    }

    /// Completeness against the verified snapshot: every non-nil
    /// reference of every row has exactly its byte-exact rewrite, and no
    /// rewrite exists without its row. A thinned or emptied manifest can
    /// never skip placement or cleanup.
    private static func requireCompletePlan(
        _ plan: TransferAudioPlan,
        rowIndex: [UUID: SnapshotAudioRow],
        transactionID: UUID
    ) throws {
        try requireValidPlan(plan, transactionID: transactionID)
        var expected = Set<Data>()
        for (id, row) in rowIndex {
            for field in TransferAudioPlan.Field.allCases {
                guard let reference = rowReference(row, field: field) else { continue }
                expected.insert(Data(
                    "\(id.uuidString)/\(field.rawValue)/\(reference.storageValue)".utf8
                ))
            }
        }
        var seen = Set<Data>()
        for rewrite in plan.rewrites {
            let key = Data(
                "\(rewrite.recordingID.uuidString)/\(rewrite.field.rawValue)/\(rewrite.sourceReference)".utf8
            )
            guard expected.contains(key) else {
                throw ExecutorError.halt(
                    "plan rewrite without a snapshot row: \(rewrite.recordingID)"
                )
            }
            seen.insert(key)
        }
        guard seen.count == expected.count else {
            throw ExecutorError.halt("plan does not cover every snapshot reference")
        }
    }

    /// The strongest placement proof: the manifest is rebuilt from the
    /// verified snapshot artifact and the frozen source root, and must
    /// encode byte-for-byte identical to the persisted plan. Missing,
    /// extra, or altered files, directories, children, and hashes are
    /// all one mismatch.
    private static func requireSourceConsistentPlan(
        _ plan: TransferAudioPlan,
        pending: PendingTransfer,
        artifact: URL,
        dependencies: Dependencies
    ) throws {
        let rebuilt = try withAudioRootAccess(of: pending.sourceEvidence.profile) { root in
            try buildAudioPlan(
                artifact: artifact, sourceRoot: root,
                transactionID: pending.transactionID,
                dependencies: dependencies
            )
        }
        let encoder = ProfileRegistryCoding.makeEncoder()
        guard try encoder.encode(rebuilt) == encoder.encode(plan) else {
            throw ExecutorError.halt("audio plan does not match the frozen source")
        }
    }

    /// No source path may overlap the transaction namespace, including
    /// through an in-root symlink alias.
    private static func requireOutsideNamespace(
        _ url: URL, namespaceRoot: URL
    ) throws {
        let namespacePath = namespaceRoot.resolvingSymlinksInPath().path
        let sourcePath = url.resolvingSymlinksInPath().path
        if sourcePath == namespacePath
            || sourcePath.hasPrefix(namespacePath + "/")
            || namespacePath.hasPrefix(sourcePath + "/") {
            throw ExecutorError.halt("source path overlaps the transaction namespace")
        }
    }

    private static func targetNamespaceRoot(
        _ pending: PendingTransfer, targetRoot: URL
    ) -> URL {
        targetRoot.appendingPathComponent(
            "transfers/\(pending.transactionID.uuidString)", isDirectory: true
        )
    }

    /// Proves source and destination separation before placement creates
    /// either ownership markers or final artifacts.
    private static func requirePlanDisjoint(
        _ plan: TransferAudioPlan,
        rowIndex: [UUID: SnapshotAudioRow],
        pending: PendingTransfer
    ) throws {
        try withAudioRootAccess(of: pending.sourceEvidence.profile) { sourceRoot in
            try withAudioRootAccess(of: pending.targetEvidence.profile) { targetRoot in
                let namespaceRoot = targetNamespaceRoot(pending, targetRoot: targetRoot)
                for rewrite in plan.rewrites {
                    let base = try verifiedSourceBase(
                        rewrite: rewrite,
                        rowIndex: rowIndex,
                        sourceRoot: sourceRoot,
                        transactionID: pending.transactionID
                    )
                    try requireOutsideNamespace(base.url, namespaceRoot: namespaceRoot)
                    for file in planFiles(of: plan, matching: rewrite) {
                        try requireOutsideNamespace(
                            try sourceFileURL(base: base, file: file),
                            namespaceRoot: namespaceRoot
                        )
                    }
                }
            }
        }
    }

    private static func sourceFileURL(
        base: (url: URL, ownership: AudioFileOwnership),
        file: TransferAudioPlan.File
    ) throws -> URL {
        guard let child = file.childRelativePath else { return base.url }
        return try containedChildURL(base: base.url, child: child)
    }

    private static func planFiles(
        of plan: TransferAudioPlan, matching rewrite: TransferAudioPlan.Rewrite
    ) -> [TransferAudioPlan.File] {
        plan.files.filter {
            $0.recordingID == rewrite.recordingID && $0.field == rewrite.field
        }
    }

    /// Builds the audio manifest from the snapshot rows: every referenced
    /// file — relative or legacy absolute, single file or tree — copies
    /// into the transaction-owned target namespace and gets a rewrite.
    /// Identity is byte-exact throughout; canonical- or case-equivalent
    /// destination collisions fail closed.
    private static func buildAudioPlan(
        artifact: URL,
        sourceRoot: URL,
        transactionID: UUID,
        dependencies: Dependencies
    ) throws -> TransferAudioPlan {
        let operations = dependencies.fileOperations
        let rows = try readSnapshotRows(artifact: artifact, dependencies: dependencies)
            .sorted {
                Array($0.id.uuidString.utf8)
                    .lexicographicallyPrecedes(Array($1.id.uuidString.utf8))
            }
        let resolver = ProfileStorageResolver(root: sourceRoot)
        var files: [TransferAudioPlan.File] = []
        var directories: [TransferAudioPlan.DirectoryEntry] = []
        var rewrites: [TransferAudioPlan.Rewrite] = []

        func appendFile(
            recordingID: UUID,
            field: TransferAudioPlan.Field,
            childRelativePath: String?,
            sourceURL: URL,
            ownership: AudioFileOwnership
        ) throws {
            do {
                try requireRegularFile(at: sourceURL, fileOperations: operations)
            } catch {
                throw ExecutorError.halt(
                    "audio file missing or untrusted: \(sourceURL.lastPathComponent)"
                )
            }
            let attributes = try operations.attributesOfItem(at: sourceURL)
            guard let size = attributes[.size] as? Int64 else {
                throw ExecutorError.halt("audio size unreadable: \(sourceURL.path)")
            }
            files.append(TransferAudioPlan.File(
                recordingID: recordingID,
                field: field,
                childRelativePath: childRelativePath,
                size: size,
                sha256: try operations.sha256(of: sourceURL),
                sourceOwnership: ownership
            ))
        }

        func appendTree(
            recordingID: UUID,
            field: TransferAudioPlan.Field,
            treeURL: URL,
            childPrefix: String?,
            ownership: AudioFileOwnership
        ) throws {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try operations.attributesOfItem(at: treeURL)
            } catch {
                throw ExecutorError.halt(
                    "segments directory missing: \(treeURL.lastPathComponent)"
                )
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ExecutorError.halt(
                    "segments path is not a directory: \(treeURL.lastPathComponent)"
                )
            }
            let entries = try operations.contentsOfDirectory(at: treeURL).sorted {
                Array($0.lastPathComponent.utf8)
                    .lexicographicallyPrecedes(Array($1.lastPathComponent.utf8))
            }
            for entry in entries {
                let child = childPrefix.map { $0 + "/" + entry.lastPathComponent }
                    ?? entry.lastPathComponent
                let childAttributes = try operations.attributesOfItem(at: entry)
                switch childAttributes[.type] as? FileAttributeType {
                case .typeRegular:
                    try appendFile(
                        recordingID: recordingID, field: field,
                        childRelativePath: child, sourceURL: entry,
                        ownership: ownership
                    )
                case .typeDirectory:
                    directories.append(TransferAudioPlan.DirectoryEntry(
                        recordingID: recordingID, field: field,
                        childRelativePath: child
                    ))
                    try appendTree(
                        recordingID: recordingID, field: field,
                        treeURL: entry, childPrefix: child, ownership: ownership
                    )
                default:
                    throw ExecutorError.halt("untrusted segments entry: \(child)")
                }
            }
        }

        for (id, row) in rows {
            for field in TransferAudioPlan.Field.allCases {
                guard let reference = rowReference(row, field: field) else { continue }
                let destination = ProfileTransfer.audioDestinationRelativePath(
                    transactionID: transactionID,
                    recordingID: id,
                    field: field,
                    sourceReference: reference.storageValue,
                    childRelativePath: nil
                )
                let sourceURL: URL
                switch reference {
                case .relative(let path):
                    sourceURL = try resolveRelative(path, resolver: resolver)
                case .legacyAbsolute(let path):
                    sourceURL = URL(
                        fileURLWithPath: path,
                        isDirectory: field == .segmentsDirectory
                    )
                }
                switch field {
                case .audioFile:
                    try appendFile(
                        recordingID: id, field: field, childRelativePath: nil,
                        sourceURL: sourceURL, ownership: row.ownership
                    )
                case .segmentsDirectory:
                    directories.append(TransferAudioPlan.DirectoryEntry(
                        recordingID: id, field: field, childRelativePath: nil
                    ))
                    try appendTree(
                        recordingID: id, field: field, treeURL: sourceURL,
                        childPrefix: nil, ownership: row.ownership
                    )
                }
                rewrites.append(TransferAudioPlan.Rewrite(
                    recordingID: id,
                    field: field,
                    sourceReference: reference.storageValue,
                    destinationReference: destination
                ))
            }
        }

        let plan = TransferAudioPlan(
            files: files, directories: directories, rewrites: rewrites
        )
        // The freshly built manifest passes the same structural validator
        // every load and boot applies — a builder defect fails here, not
        // at a later placement.
        if let problem = ProfileTransfer.planProblem(plan, transactionID: transactionID) {
            throw ExecutorError.halt("audio plan invalid: \(problem)")
        }
        return plan
    }

    private static func resolveRelative(
        _ path: String, resolver: ProfileStorageResolver
    ) throws -> URL {
        do {
            return try resolver.resolveAudio(.relative(path))
        } catch {
            throw ExecutorError.halt("audio reference unresolvable: \(path)")
        }
    }

    /// Audio-side capacity on the target root's own volume, which may
    /// differ from the store volume for user-selected roots.
    private static func preflightAudioDiskSpace(
        plan: TransferAudioPlan, target: Profile, dependencies: Dependencies
    ) throws {
        var audioBytes: Int64 = 0
        for file in plan.files {
            let (sum, overflow) = audioBytes.addingReportingOverflow(file.size)
            guard !overflow else {
                throw ExecutorError.halt("audio size total overflow")
            }
            audioBytes = sum
        }
        guard audioBytes > 0 else { return }
        let available = try withAudioRootAccess(of: target) { targetRoot in
            var probe = targetRoot
            while !dependencies.fileOperations.fileExists(at: probe),
                  probe.pathComponents.count > 1 {
                probe = probe.deletingLastPathComponent()
            }
            do {
                return try dependencies.fileOperations.availableCapacity(at: probe)
            } catch {
                throw ExecutorError.halt("audio capacity probe failed: \(error)")
            }
        }
        let (required, overflow) = audioBytes.addingReportingOverflow(audioDiskSlack)
        guard !overflow else {
            throw ExecutorError.halt("audio capacity requirement overflow")
        }
        guard available >= required else {
            throw ExecutorError.halt(
                "insufficient audio disk space: need \(required), have \(available)"
            )
        }
    }

    /// Rewrites every planned reference in the staged store and marks the
    /// rewritten rows app-created — the target's files are fresh bytes
    /// Cadenza writes. Post-mutation the rewrite set is re-verified
    /// row by row.
    private static func applyStagedRewrites(
        plan: TransferAudioPlan,
        workURL: URL,
        finalURL: URL,
        receipt: SnapshotReceipt,
        pending: PendingTransfer,
        dependencies: Dependencies
    ) throws {
        let operations = dependencies.fileOperations
        dependencies.scratchTracker.markOpened(baseURL: workURL)
        operations.noteStoreOpen(at: workURL)
        let configuration = ModelConfiguration(url: workURL)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: RecordingsStore.schema, configurations: [configuration]
            )
        } catch {
            throw ExecutorError.halt("staged store unopenable: \(error)")
        }
        // The engine stays alive until after the backup below: an idle
        // open connection is benign to the online backup, whereas an
        // asynchronous close can hold a transient exclusive lock.
        defer { withExtendedLifetime(container) {} }
        do {
            let context = ModelContext(container)
            let recordings: [Recording]
            do {
                recordings = try context.fetch(FetchDescriptor<Recording>())
            } catch {
                throw ExecutorError.halt("staged rows unreadable: \(error)")
            }
            var byID: [UUID: Recording] = [:]
            for recording in recordings { byID[recording.id] = recording }
            // Every transferred row is historical data of the target's
            // binding: the consent gate keys on this marker, and rows
            // arriving by transfer never passed the binding-time stamp
            // (the target store was empty then). Rows without audio
            // references are stamped too.
            guard let consentBindingID =
                pending.targetEvidence.profile.createdByBindingTransactionID else {
                throw ExecutorError.halt("target evidence missing creation provenance")
            }
            for recording in recordings {
                recording.awaitingHistoricalConsentBindingID = consentBindingID
            }
            for rewrite in plan.rewrites {
                guard let recording = byID[rewrite.recordingID] else {
                    throw ExecutorError.halt("rewrite row missing: \(rewrite.recordingID)")
                }
                let derived = ProfileTransfer.audioDestinationRelativePath(
                    transactionID: pending.transactionID,
                    recordingID: rewrite.recordingID,
                    field: rewrite.field,
                    sourceReference: rewrite.sourceReference,
                    childRelativePath: nil
                )
                guard AccountIdentity.matches(rewrite.destinationReference, derived) else {
                    throw ExecutorError.halt(
                        "rewrite destination is not the transaction namespace: \(rewrite.recordingID)"
                    )
                }
                switch rewrite.field {
                case .audioFile:
                    guard recording.audioFilePath.map({
                        AccountIdentity.matches($0, rewrite.sourceReference)
                    }) == true else {
                        throw ExecutorError.halt(
                            "rewrite source drifted: \(rewrite.recordingID)"
                        )
                    }
                    recording.audioFilePath = rewrite.destinationReference
                case .segmentsDirectory:
                    guard recording.audioSegmentsDirectory.map({
                        AccountIdentity.matches($0, rewrite.sourceReference)
                    }) == true else {
                        throw ExecutorError.halt(
                            "rewrite source drifted: \(rewrite.recordingID)"
                        )
                    }
                    recording.audioSegmentsDirectory = rewrite.destinationReference
                }
                recording.ownership = .appCreated
            }
            do {
                try context.save()
            } catch {
                throw ExecutorError.halt("staged rewrite save failed: \(error)")
            }
        }
        let verificationURL = stagedVerificationStoreURL(
            pending, nonce: UUID(), dependencies: dependencies
        )
        do {
            try dependencies.backupDriver.consistentBackup(
                source: workURL, destination: verificationURL
            )
        } catch {
            throw ExecutorError.halt("staged verification fold failed: \(error)")
        }
        try verifyRewrites(
            plan: plan, storeURL: verificationURL, placementURL: finalURL,
            receipt: receipt, pending: pending, dependencies: dependencies
        )
    }

    /// Best-effort removal of untracked regular scratch files.
    private static func sweepPrefixedScratch(
        in directory: URL,
        namePrefix: String,
        tracker: ScratchProcessTracker,
        operations: FileOperations
    ) {
        guard let entries = trustedDirectoryEntries(
            at: directory, operations: operations
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(namePrefix) {
            guard !tracker.containsBase(for: entry) else { continue }
            guard (try? requireRegularFile(at: entry, fileOperations: operations)) != nil
            else { continue }
            try? operations.removeItem(at: entry)
        }
    }

    /// Sweeps prior-process work stores without touching paths opened here.
    private static func sweepLeftoverWorkStores(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) {
        let operations = dependencies.fileOperations
        let tracker = dependencies.scratchTracker
        let staging = dependencies.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        )
        if (try? requireTrustedMigrationDirectory(
            staging, mustExist: false, dependencies: dependencies
        )) != nil {
            sweepPrefixedScratch(
                in: staging, namePrefix: "Cadenza.store.work-",
                tracker: tracker, operations: operations
            )
            sweepPrefixedScratch(
                in: staging, namePrefix: "Cadenza.store.verify-",
                tracker: tracker, operations: operations
            )
        }
        let replacement = replacementStoreURL(pending, dependencies: dependencies)
        sweepPrefixedScratch(
            in: replacement.deletingLastPathComponent(),
            namePrefix: replacement.lastPathComponent + ".work-",
            tracker: tracker, operations: operations
        )
        sweepPrefixedScratch(
            in: replacement.deletingLastPathComponent(),
            namePrefix: replacement.lastPathComponent + ".verify-",
            tracker: tracker, operations: operations
        )
    }

    /// Removes transaction scratch from earlier processes. The current
    /// pending transaction and every store opened in this process remain
    /// untouched.
    static func sweepPriorProcessScratch(
        document: ProfileRegistryDocument,
        paths: ProfilePaths,
        fileOperations: FileOperations,
        scratchTracker: ScratchProcessTracker
    ) {
        do {
            try requireTrustedMigrationRoot(
                at: paths.migrationDirectory, fileOperations: fileOperations
            )
            let attributes = try fileOperations.attributesOfItem(
                at: paths.migrationDirectory
            )
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return
            }
        } catch {
            return
        }
        guard let lock = MigrationFileLock(
            url: paths.migrationDirectory.appendingPathComponent("lock")
        ) else { return }
        defer { lock.unlock() }

        let activeTransactionID = document.pendingTransfer?.transactionID
        sweepStaleTransferStaging(
            root: paths.migrationDirectory.appendingPathComponent(
                "transfer-staging", isDirectory: true
            ),
            activeTransactionID: activeTransactionID,
            tracker: scratchTracker,
            operations: fileOperations
        )
        sweepStaleTransferSnapshots(
            root: paths.migrationDirectory.appendingPathComponent(
                "snapshots", isDirectory: true
            ),
            activeTransactionID: activeTransactionID,
            tracker: scratchTracker,
            operations: fileOperations
        )
        for profile in document.profiles {
            sweepStaleReplacementScratch(
                in: paths.profileDirectory(profile.id),
                activeTransactionID: activeTransactionID,
                tracker: scratchTracker,
                operations: fileOperations
            )
        }
    }

    private static func sweepStaleTransferStaging(
        root: URL,
        activeTransactionID: UUID?,
        tracker: ScratchProcessTracker,
        operations: FileOperations
    ) {
        guard let transactionDirectories = trustedDirectoryEntries(
            at: root, operations: operations
        ) else { return }
        for directory in transactionDirectories {
            guard let transactionID = UUID(uuidString: directory.lastPathComponent),
                  transactionID != activeTransactionID,
                  let entries = trustedDirectoryEntries(
                    at: directory, operations: operations
                  ) else { continue }
            for entry in entries where isTransferStagingScratch(entry.lastPathComponent) {
                removeUntrackedScratch(
                    entry, tracker: tracker, operations: operations
                )
            }
        }
    }

    private static func sweepStaleTransferSnapshots(
        root: URL,
        activeTransactionID: UUID?,
        tracker: ScratchProcessTracker,
        operations: FileOperations
    ) {
        guard let transactionDirectories = trustedDirectoryEntries(
            at: root, operations: operations
        ) else { return }
        for transactionDirectory in transactionDirectories {
            let name = transactionDirectory.lastPathComponent
            guard name.hasPrefix("transfer-"),
                  let transactionID = UUID(
                    uuidString: String(name.dropFirst("transfer-".count))
                  ),
                  transactionID != activeTransactionID,
                  let artifacts = trustedDirectoryEntries(
                    at: transactionDirectory, operations: operations
                  ) else { continue }
            for artifact in artifacts {
                guard UUID(uuidString: artifact.lastPathComponent) != nil,
                      let entries = trustedDirectoryEntries(
                        at: artifact, operations: operations
                      ) else { continue }
                for entry in entries where isStoreTrioMember(entry.lastPathComponent) {
                    removeUntrackedScratch(
                        entry, tracker: tracker, operations: operations
                    )
                }
            }
        }
    }

    private static func sweepStaleReplacementScratch(
        in profileDirectory: URL,
        activeTransactionID: UUID?,
        tracker: ScratchProcessTracker,
        operations: FileOperations
    ) {
        guard let entries = trustedDirectoryEntries(
            at: profileDirectory, operations: operations
        ) else { return }
        for entry in entries {
            guard let transactionID = replacementScratchTransactionID(
                entry.lastPathComponent
            ), transactionID != activeTransactionID else { continue }
            removeUntrackedScratch(entry, tracker: tracker, operations: operations)
        }
    }

    private static func trustedDirectoryEntries(
        at directory: URL, operations: FileOperations
    ) -> [URL]? {
        guard let attributes = try? operations.attributesOfItem(at: directory),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return nil
        }
        return try? operations.contentsOfDirectory(at: directory)
    }

    private static func removeUntrackedScratch(
        _ entry: URL,
        tracker: ScratchProcessTracker,
        operations: FileOperations
    ) {
        guard !tracker.containsBase(for: entry),
              (try? requireRegularFile(at: entry, fileOperations: operations)) != nil else {
            return
        }
        try? operations.removeItem(at: entry)
    }

    private static func isTransferStagingScratch(_ name: String) -> Bool {
        let base = scratchBaseName(name)
        if base == "Cadenza.store" { return true }
        for prefix in ["Cadenza.store.work-", "Cadenza.store.verify-"]
        where base.hasPrefix(prefix) {
            return UUID(uuidString: String(base.dropFirst(prefix.count))) != nil
        }
        return false
    }

    private static func isStoreTrioMember(_ name: String) -> Bool {
        scratchBaseName(name) == "Cadenza.store"
    }

    private static func replacementScratchTransactionID(_ name: String) -> UUID? {
        let prefix = "Cadenza.store.replacement-"
        let base = scratchBaseName(name)
        guard base.hasPrefix(prefix) else { return nil }
        let remainder = String(base.dropFirst(prefix.count))
        for separator in [".work-", ".verify-"] {
            guard let range = remainder.range(of: separator) else { continue }
            let transaction = String(remainder[..<range.lowerBound])
            let nonce = String(remainder[range.upperBound...])
            guard UUID(uuidString: transaction) != nil,
                  UUID(uuidString: nonce) != nil else { continue }
            return UUID(uuidString: transaction)
        }
        return nil
    }

    private static func scratchBaseName(_ name: String) -> String {
        if name.hasSuffix("-wal") { return String(name.dropLast(4)) }
        if name.hasSuffix("-shm") { return String(name.dropLast(4)) }
        return name
    }

    private static func verifyRewrites(
        plan: TransferAudioPlan,
        storeURL: URL,
        placementURL: URL,
        receipt: SnapshotReceipt,
        pending: PendingTransfer,
        dependencies: Dependencies
    ) throws {
        dependencies.scratchTracker.markOpened(baseURL: storeURL)
        dependencies.fileOperations.noteStoreOpen(at: storeURL)
        let configuration = ModelConfiguration(url: storeURL, allowsSave: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: RecordingsStore.schema, configurations: [configuration]
            )
        } catch {
            throw ExecutorError.halt("staged store unopenable after rewrite: \(error)")
        }
        defer { withExtendedLifetime(container) {} }
        let counts: [String: Int]
        do {
            counts = try StoreSnapshotter.readEntityCounts(container: container)
        } catch {
            throw ExecutorError.halt("staged store unreadable after rewrite: \(error)")
        }
        guard counts == receipt.entityCounts else {
            throw ExecutorError.halt("staged entity counts drifted during rewrite")
        }
        let context = ModelContext(container)
        let recordings: [Recording]
        do {
            recordings = try context.fetch(FetchDescriptor<Recording>())
        } catch {
            throw ExecutorError.halt("staged rows unreadable after rewrite: \(error)")
        }
        var byID: [UUID: Recording] = [:]
        for recording in recordings { byID[recording.id] = recording }
        guard let consentBindingID =
            pending.targetEvidence.profile.createdByBindingTransactionID else {
            throw ExecutorError.halt("target evidence missing creation provenance")
        }
        for recording in recordings {
            guard recording.awaitingHistoricalConsentBindingID == consentBindingID else {
                throw ExecutorError.halt(
                    "transferred row missing its consent marker: \(recording.id)"
                )
            }
        }
        for rewrite in plan.rewrites {
            guard let recording = byID[rewrite.recordingID] else {
                throw ExecutorError.halt("rewritten row missing: \(rewrite.recordingID)")
            }
            let stored = rewrite.field == .audioFile
                ? recording.audioFilePath : recording.audioSegmentsDirectory
            guard stored.map({
                AccountIdentity.matches($0, rewrite.destinationReference)
            }) == true else {
                throw ExecutorError.halt("rewrite unverified: \(rewrite.recordingID)")
            }
            guard recording.ownership == .appCreated else {
                throw ExecutorError.halt(
                    "rewritten row ownership unverified: \(rewrite.recordingID)"
                )
            }
        }
        do {
            try dependencies.backupDriver.consistentBackup(
                source: storeURL, destination: placementURL
            )
        } catch {
            throw ExecutorError.halt("staged placement fold failed: \(error)")
        }
    }

    // MARK: - staged → targetVerified

    private static func performStagedVerification(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> PendingTransfer {
        _ = try requireRecordedEvidence(pending, dependencies: dependencies)
        let staged = stagedStoreURL(pending, dependencies: dependencies)
        try requireTrustedMigrationDirectory(
            staged.deletingLastPathComponent(), mustExist: true,
            dependencies: dependencies
        )
        try verifyRawStagedStore(
            at: staged, pending: pending, dependencies: dependencies
        )
        var mutated = pending
        mutated.state = .targetVerified
        return try saveCheckpoint(old: pending, mutated: mutated, dependencies: dependencies)
    }

    private static func verifyRawStagedStore(
        at url: URL, pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        guard let expectedSHA = pending.stagedStoreSHA256,
              let expectedDigest = pending.targetContentDigest else {
            throw ExecutorError.halt("checkpoint payload missing target proofs")
        }
        let operations = dependencies.fileOperations
        try requireRegularFile(at: url, fileOperations: operations)
        guard try operations.sha256(of: url) == expectedSHA else {
            throw ExecutorError.halt("store bytes differ from staged record")
        }
        guard try stagedDigest(of: url) == expectedDigest else {
            throw ExecutorError.halt("store content digest differs from staged record")
        }
        try requireStoreSidecarsAbsent(for: url, operations: operations)
    }

    // MARK: - targetVerified → placed

    private static func performPlacement(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> PendingTransfer {
        _ = try requireRecordedEvidence(pending, dependencies: dependencies)
        guard let plan = pending.audioPlan else {
            throw ExecutorError.halt("checkpoint payload missing audio plan")
        }
        // The full manifest proof precedes every placement write: shape,
        // completeness against the snapshot rows, and byte-identity with
        // a rebuild from the frozen source.
        let artifact = try snapshotArtifactURL(pending, dependencies: dependencies)
        let rowIndex = try snapshotRowIndex(artifact: artifact, dependencies: dependencies)
        try requireCompletePlan(
            plan, rowIndex: rowIndex, transactionID: pending.transactionID
        )
        try requireSourceConsistentPlan(
            plan, pending: pending, artifact: artifact, dependencies: dependencies
        )
        try requirePlanDisjoint(plan, rowIndex: rowIndex, pending: pending)
        let operations = dependencies.fileOperations
        let targetStore = dependencies.paths.storeURL(pending.targetProfileID)
        let profileDirectory = dependencies.paths.profileDirectory(pending.targetProfileID)
        try ensureTrustedDirectory(profileDirectory, operations: operations)
        let staged = stagedStoreURL(pending, dependencies: dependencies)
        try requireTrustedMigrationDirectory(
            staged.deletingLastPathComponent(), mustExist: true,
            dependencies: dependencies
        )
        let targetPresence = try regularFilePresence(
            at: targetStore, operations: operations
        )
        let targetAlreadyPlaced: Bool
        if targetPresence == .present {
            targetAlreadyPlaced = try rawStoreMatchesStagedProof(
                at: targetStore, pending: pending, dependencies: dependencies
            )
        } else {
            targetAlreadyPlaced = false
        }
        if !targetAlreadyPlaced {
            try requireEmptyTransferTarget(pending, dependencies: dependencies)
        }
        // The ownership markers precede every artifact write. A fresh
        // audio claim may only adopt a namespace that does not exist.
        let profileMarker = targetProfileMarker(pending, dependencies: dependencies)
        let profileMarkerPresence = try placementMarkerPresenceOrHalt(
            at: profileMarker, pending: pending, kind: .profileStore,
            operations: operations
        )
        try withAudioRootAccess(of: pending.targetEvidence.profile) { targetRoot in
            try ensureTrustedDirectory(targetRoot, operations: operations)
            let audioMarker = ProfileTransfer.placementMarkerURL(
                inDirectory: targetRoot, transactionID: pending.transactionID,
                kind: .audioRoot
            )
            let audioMarkerPresence = try placementMarkerPresenceOrHalt(
                at: audioMarker, pending: pending, kind: .audioRoot,
                operations: operations
            )
            if audioMarkerPresence == .absent {
                try requireUnoccupiedAudioNamespace(
                    targetNamespaceRoot(pending, targetRoot: targetRoot),
                    operations: operations
                )
            }
            if targetAlreadyPlaced && profileMarkerPresence != .matching {
                throw ExecutorError.halt(
                    "placed target store lacks its ownership claim"
                )
            }
            try requireOrClaimPlacementMarker(
                at: profileMarker, pending: pending, kind: .profileStore,
                operations: operations
            )
            try requireOrClaimPlacementMarker(
                at: audioMarker,
                pending: pending,
                kind: .audioRoot,
                operations: operations
            )
        }
        if targetAlreadyPlaced {
            try verifyRawStagedStore(
                at: targetStore, pending: pending, dependencies: dependencies
            )
            try verifyEmptySwapResidueIfPresent(
                at: staged, dependencies: dependencies
            )
        } else if targetPresence == .present {
            guard try regularFilePresence(
                at: staged, operations: operations
            ) == .present else {
                throw ExecutorError.halt("staged store missing before placement")
            }
            try verifyRawStagedStore(
                at: staged, pending: pending, dependencies: dependencies
            )
            try prepareEmptyTargetForSwap(
                targetStore: targetStore,
                stagedStore: staged,
                pending: pending,
                dependencies: dependencies
            )
        } else {
            guard try regularFilePresence(
                at: staged, operations: operations
            ) == .present else {
                throw ExecutorError.halt("staged store missing before placement")
            }
            try operations.moveItemExclusively(staging: staged, final: targetStore)
            try verifyRawStagedStore(
                at: targetStore, pending: pending, dependencies: dependencies
            )
        }
        try copyAudio(
            plan: plan, rowIndex: rowIndex, pending: pending,
            dependencies: dependencies
        )
        var mutated = pending
        mutated.state = .placed
        let checkpoint = try saveCheckpoint(
            old: pending, mutated: mutated, dependencies: dependencies
        )
        discardEmptySwapResidueIfPresent(at: staged, dependencies: dependencies)
        return checkpoint
    }

    private static func placementMarkerPresenceOrHalt(
        at url: URL,
        pending: PendingTransfer,
        kind: TransferPlacementClaim.Kind,
        operations: FileOperations
    ) throws -> ProfileTransfer.PlacementMarkerPresence {
        do {
            return try ProfileTransfer.placementMarkerPresence(
                at: url, pending: pending, kind: kind,
                fileOperations: operations
            )
        } catch {
            throw ExecutorError.halt("placement marker claim mismatch: \(error)")
        }
    }

    private static func requireUnoccupiedAudioNamespace(
        _ url: URL, operations: FileOperations
    ) throws {
        do {
            _ = try operations.attributesOfItem(at: url)
            throw ExecutorError.halt("audio namespace occupied before ownership claim")
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch let error as ExecutorError {
            throw error
        } catch {
            throw ExecutorError.halt("audio namespace unprobeable before claim: \(error)")
        }
    }

    private static func rawStoreMatchesStagedProof(
        at url: URL,
        pending: PendingTransfer,
        dependencies: Dependencies
    ) throws -> Bool {
        guard let expectedSHA = pending.stagedStoreSHA256,
              let expectedDigest = pending.targetContentDigest else {
            throw ExecutorError.halt("checkpoint payload missing target proofs")
        }
        let operations = dependencies.fileOperations
        try requireRegularFile(at: url, fileOperations: operations)
        guard try operations.sha256(of: url) == expectedSHA else { return false }
        guard try stagedDigest(of: url) == expectedDigest else {
            throw ExecutorError.halt("store content digest differs from staged record")
        }
        try requireStoreSidecarsAbsent(for: url, operations: operations)
        return true
    }

    private static func requireEmptyTransferTarget(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        try ProfileTransfer.requireEmptyTargetStore(
            targetID: pending.targetProfileID,
            dependencies: .init(
                registry: dependencies.registry,
                storeURL: { dependencies.paths.storeURL($0) },
                inspector: dependencies.inspector,
                fileOperations: dependencies.fileOperations,
                now: dependencies.now
            )
        )
    }

    private static func prepareEmptyTargetForSwap(
        targetStore: URL,
        stagedStore: URL,
        pending: PendingTransfer,
        dependencies: Dependencies
    ) throws {
        let operations = dependencies.fileOperations
        let lease: SourceFreezeLease
        do {
            lease = try SourceFreezeLease.acquire(
                storeURL: targetStore, fileOperations: operations
            )
        } catch {
            throw ExecutorError.halt("empty target freeze unavailable: \(error)")
        }
        defer { lease.release() }
        do {
            try lease.prepareForRetire()
        } catch {
            throw ExecutorError.halt("empty target preparation failed: \(error)")
        }
        try requireEmptyTransferTarget(pending, dependencies: dependencies)
        lease.release()
        try removePreparedStoreSidecars(for: targetStore, operations: operations)
        try requireEmptyTransferTarget(pending, dependencies: dependencies)
        try operations.swapItems(at: targetStore, with: stagedStore)
        try verifyRawStagedStore(
            at: targetStore, pending: pending, dependencies: dependencies
        )
        try verifyEmptyStore(at: stagedStore, dependencies: dependencies)
        try requireStoreSidecarsAbsent(for: stagedStore, operations: operations)
    }

    private static func verifyEmptySwapResidueIfPresent(
        at url: URL, dependencies: Dependencies
    ) throws {
        guard try regularFilePresence(
            at: url, operations: dependencies.fileOperations
        ) == .present else { return }
        try verifyEmptyStore(at: url, dependencies: dependencies)
        try requireStoreSidecarsAbsent(
            for: url, operations: dependencies.fileOperations
        )
    }

    private static func discardEmptySwapResidueIfPresent(
        at url: URL, dependencies: Dependencies
    ) {
        do {
            try verifyEmptySwapResidueIfPresent(at: url, dependencies: dependencies)
            if try regularFilePresence(
                at: url, operations: dependencies.fileOperations
            ) == .present {
                try dependencies.fileOperations.removeItem(at: url)
            }
        } catch {
            NSLog(
                "[ProfileTransfer] retaining empty-target swap residue: %@",
                String(describing: error)
            )
        }
    }

    private static func copyAudio(
        plan: TransferAudioPlan,
        rowIndex: [UUID: SnapshotAudioRow],
        pending: PendingTransfer,
        dependencies: Dependencies
    ) throws {
        try requireCompletePlan(
            plan, rowIndex: rowIndex, transactionID: pending.transactionID
        )
        let operations = dependencies.fileOperations
        try withAudioRootAccess(of: pending.sourceEvidence.profile) { sourceRoot in
            try withAudioRootAccess(of: pending.targetEvidence.profile) { targetRoot in
                let namespaceRoot = targetNamespaceRoot(pending, targetRoot: targetRoot)
                let targetResolver = ProfileStorageResolver(root: targetRoot)
                try ensureTrustedDirectory(targetRoot, operations: operations)
                let audioMarker = ProfileTransfer.placementMarkerURL(
                    inDirectory: targetRoot, transactionID: pending.transactionID,
                    kind: .audioRoot
                )
                try requireOrClaimPlacementMarker(
                    at: audioMarker, pending: pending, kind: .audioRoot,
                    operations: operations
                )
                for rewrite in plan.rewrites {
                    let base = try verifiedSourceBase(
                        rewrite: rewrite, rowIndex: rowIndex,
                        sourceRoot: sourceRoot,
                        transactionID: pending.transactionID
                    )
                    // Tree structure comes entirely from the manifest:
                    // the root and every nested directory, empty ones
                    // included.
                    for directory in plan.directories
                    where directory.recordingID == rewrite.recordingID
                        && directory.field == rewrite.field {
                        let relative = directory.childRelativePath.map {
                            rewrite.destinationReference + "/" + $0
                        } ?? rewrite.destinationReference
                        let destination = try resolveTargetRelative(
                            relative, resolver: targetResolver
                        )
                        try ensureTrustedDirectory(destination, operations: operations)
                    }
                    try requireOutsideNamespace(base.url, namespaceRoot: namespaceRoot)
                    for file in planFiles(of: plan, matching: rewrite) {
                        guard file.sourceOwnership == base.ownership else {
                            throw ExecutorError.halt(
                                "plan ownership does not match the snapshot row: \(file.recordingID)"
                            )
                        }
                        let sourceURL = try sourceFileURL(base: base, file: file)
                        try requireOutsideNamespace(sourceURL, namespaceRoot: namespaceRoot)
                        let destinationRelative = ProfileTransfer.audioDestinationRelativePath(
                            transactionID: pending.transactionID,
                            recordingID: rewrite.recordingID,
                            field: rewrite.field,
                            sourceReference: rewrite.sourceReference,
                            childRelativePath: file.childRelativePath
                        )
                        let destination = try resolveTargetRelative(
                            destinationRelative, resolver: targetResolver
                        )
                        let partial = try resolveTargetRelative(
                            ProfileTransfer.audioPartialRelativePath(
                                for: destinationRelative
                            ),
                            resolver: targetResolver
                        )
                        try ensureTrustedDirectory(
                            destination.deletingLastPathComponent(), operations: operations
                        )
                        if try regularFilePresence(
                            at: destination, operations: operations
                        ) == .present {
                            try requireRegularFile(at: destination, fileOperations: operations)
                            guard try operations.sha256(of: destination) == file.sha256 else {
                                throw ExecutorError.halt(
                                    "foreign audio at target: \(destinationRelative)"
                                )
                            }
                            try removeOwnedAudioPartialIfPresent(
                                at: partial, operations: operations
                            )
                            continue
                        }
                        try removeOwnedAudioPartialIfPresent(
                            at: partial, operations: operations
                        )
                        try requireRegularFile(at: sourceURL, fileOperations: operations)
                        guard try operations.sha256(of: sourceURL) == file.sha256 else {
                            throw ExecutorError.halt(
                                "source audio changed since manifest: \(destinationRelative)"
                            )
                        }
                        do {
                            try operations.copyItem(at: sourceURL, to: partial)
                        } catch {
                            throw ExecutorError.halt(
                                "audio copy failed: \(destinationRelative): \(error)"
                            )
                        }
                        let attributes = try operations.attributesOfItem(at: partial)
                        guard attributes[.type] as? FileAttributeType == .typeRegular,
                              attributes[.size] as? Int64 == file.size,
                              try operations.sha256(of: partial) == file.sha256 else {
                            throw ExecutorError.halt(
                                "copied audio failed verification: \(destinationRelative)"
                            )
                        }
                        do {
                            try operations.moveItemExclusively(
                                staging: partial, final: destination
                            )
                        } catch {
                            throw ExecutorError.halt(
                                "audio placement failed: \(destinationRelative): \(error)"
                            )
                        }
                    }
                }
            }
        }
    }

    private static func removeOwnedAudioPartialIfPresent(
        at url: URL, operations: FileOperations
    ) throws {
        guard try regularFilePresence(at: url, operations: operations) == .present else {
            return
        }
        try operations.removeItem(at: url)
    }

    private static func resolveTargetRelative(
        _ path: String, resolver: ProfileStorageResolver
    ) throws -> URL {
        do {
            return try resolver.resolveAudio(.relative(path))
        } catch {
            throw ExecutorError.halt("target audio path unresolvable: \(path)")
        }
    }

    private static func ensureTrustedDirectory(
        _ url: URL, operations: FileOperations
    ) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try operations.attributesOfItem(at: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            try ensureTrustedDirectory(url.deletingLastPathComponent(), operations: operations)
            try operations.createDirectory(at: url)
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ExecutorError.halt("directory untrusted: \(url.lastPathComponent)")
        }
    }

    private static func requireTrustedMigrationDirectory(
        _ url: URL,
        mustExist: Bool,
        dependencies: Dependencies
    ) throws {
        do {
            _ = try MigrationJournalStore(
                paths: dependencies.paths,
                fileOperations: dependencies.fileOperations
            ).validatedMigrationLocation(url)
        } catch {
            throw ExecutorError.halt("migration scratch path untrusted: \(error)")
        }
        guard mustExist else { return }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try dependencies.fileOperations.attributesOfItem(at: url)
        } catch {
            throw ExecutorError.halt("migration scratch directory unavailable: \(error)")
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ExecutorError.halt("migration scratch directory untrusted")
        }
    }

    private enum RegularFilePresence: Equatable {
        case absent
        case present
    }

    private static func regularFilePresence(
        at url: URL, operations: FileOperations
    ) throws -> RegularFilePresence {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try operations.attributesOfItem(at: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            throw ExecutorError.halt(
                "file probe failed for \(url.lastPathComponent): \(error)"
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ExecutorError.halt("expected regular file: \(url.lastPathComponent)")
        }
        return .present
    }

    private static func requireStoreSidecarsAbsent(
        for base: URL, operations: FileOperations
    ) throws {
        let trio = StoreTrioURL(base: base)
        for sidecar in [trio.wal, trio.shm] {
            guard try regularFilePresence(
                at: sidecar, operations: operations
            ) == .absent else {
                throw ExecutorError.halt(
                    "unexpected store sidecar: \(sidecar.path)"
                )
            }
        }
    }

    private static func removePreparedStoreSidecars(
        for base: URL, operations: FileOperations
    ) throws {
        let trio = StoreTrioURL(base: base)
        for sidecar in [trio.wal, trio.shm] {
            if try regularFilePresence(
                at: sidecar, operations: operations
            ) == .present {
                try operations.removeItem(at: sidecar)
            }
        }
        try requireStoreSidecarsAbsent(for: base, operations: operations)
    }

    // MARK: - placed → localRebuilt (move)

    private static func performLocalRebuildPreparation(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws -> PendingTransfer {
        // The target side is proven in full before the move sequence
        // starts: a target that degraded after placement must halt while
        // the source is still authoritative and untouched.
        try verifyPlacedTargetSide(
            pending, context: "before local rebuild", dependencies: dependencies
        )
        _ = try requireRecordedEvidence(pending, dependencies: dependencies)
        let operations = dependencies.fileOperations
        let replacement = replacementStoreURL(pending, dependencies: dependencies)
        let replacementPresence = try regularFilePresence(
            at: replacement, operations: operations
        )
        try removePreparedStoreSidecars(for: replacement, operations: operations)
        if replacementPresence == .present {
            // Final replacement candidates are never opened through SwiftData.
            try operations.removeItem(at: replacement)
        }
        try buildEmptyStore(
            at: replacement, pending: pending, dependencies: dependencies
        )
        var mutated = pending
        try requireStoreSidecarsAbsent(for: replacement, operations: operations)
        mutated.replacementStoreSHA256 = try operations.sha256(of: replacement)
        mutated.replacementContentDigest = try stagedDigest(of: replacement)
        mutated.state = .localRebuilt
        return try saveCheckpoint(old: pending, mutated: mutated, dependencies: dependencies)
    }

    private static func buildEmptyStore(
        at url: URL, pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        let operations = dependencies.fileOperations
        let work = URL(fileURLWithPath: url.path + ".work-\(UUID().uuidString)")
        let verification = replacementVerificationStoreURL(
            pending, nonce: UUID(), dependencies: dependencies
        )
        dependencies.scratchTracker.markOpened(baseURL: work)
        operations.noteStoreOpen(at: work)
        let container: ModelContainer
        do {
            let configuration = ModelConfiguration(url: work)
            container = try ModelContainer(
                for: RecordingsStore.schema, configurations: [configuration]
            )
        } catch {
            throw ExecutorError.halt("replacement store creation failed: \(error)")
        }
        defer { withExtendedLifetime(container) {} }
        do {
            try dependencies.backupDriver.consistentBackup(
                source: work, destination: verification
            )
        } catch {
            throw ExecutorError.halt("replacement verification fold failed: \(error)")
        }
        dependencies.scratchTracker.markOpened(baseURL: verification)
        operations.noteStoreOpen(at: verification)
        let verificationContainer: ModelContainer
        do {
            let configuration = ModelConfiguration(url: verification, allowsSave: false)
            verificationContainer = try ModelContainer(
                for: RecordingsStore.schema, configurations: [configuration]
            )
        } catch {
            throw ExecutorError.halt("replacement verification open failed: \(error)")
        }
        defer { withExtendedLifetime(verificationContainer) {} }
        let counts: [String: Int]
        do {
            counts = try StoreSnapshotter.readEntityCounts(container: verificationContainer)
        } catch {
            throw ExecutorError.halt("replacement verification failed: \(error)")
        }
        for entity in ProfileTransfer.inspectedEntityNames {
            guard counts[entity] == 0 else {
                throw ExecutorError.halt("replacement store not empty: \(entity)")
            }
        }
        do {
            try dependencies.backupDriver.consistentBackup(
                source: verification, destination: url
            )
        } catch {
            throw ExecutorError.halt("replacement placement fold failed: \(error)")
        }
    }

    @discardableResult
    private static func verifyEmptyStore(
        at url: URL, dependencies: Dependencies
    ) throws -> Bool {
        let counts: [String: Int]?
        do {
            counts = try dependencies.inspector.entityCounts(at: url)
        } catch {
            throw ExecutorError.halt("empty store unreadable: \(error)")
        }
        guard let counts else {
            throw ExecutorError.halt("empty store absent")
        }
        for entity in ProfileTransfer.inspectedEntityNames {
            guard counts[entity] == 0 else {
                throw ExecutorError.halt("store not empty: \(entity)")
            }
        }
        return true
    }

    private static func verifyRawReplacementStore(
        at url: URL, pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        try verifyRawReplacementStoreContent(
            at: url, pending: pending, dependencies: dependencies
        )
        try requireStoreSidecarsAbsent(
            for: url, operations: dependencies.fileOperations
        )
    }

    private static func verifyRawReplacementStoreContent(
        at url: URL, pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        guard let expectedSHA = pending.replacementStoreSHA256,
              let expectedDigest = pending.replacementContentDigest else {
            throw ExecutorError.halt("rebuild checkpoint replacement payload missing")
        }
        let operations = dependencies.fileOperations
        try requireRegularFile(at: url, fileOperations: operations)
        guard try operations.sha256(of: url) == expectedSHA else {
            throw ExecutorError.halt("replacement store bytes differ from checkpoint")
        }
        guard try stagedDigest(of: url) == expectedDigest else {
            throw ExecutorError.halt("replacement store content differs from checkpoint")
        }
    }

    // MARK: - localRebuilt → retired (move)

    /// Swap-based retirement: the canonical Local store path always
    /// resolves to an openable database. Ordering — atomic content swap
    /// (base becomes the verified empty store, the transaction-keyed
    /// replacement path holds the old store) → transaction-keyed rename
    /// of the old store to its retired name → ownership-verified audio
    /// cleanup through the trash. Every resume branch is proven by the
    /// recorded logical digest, never by path presence alone.
    private static func performRetire(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        guard let sourceDigest = pending.sourceContentDigest,
              pending.replacementStoreSHA256 != nil,
              pending.replacementContentDigest != nil,
              let plan = pending.audioPlan else {
            throw ExecutorError.halt("rebuild checkpoint payload missing")
        }
        try verifyPlacedTargetSide(
            pending, context: "before source retirement", dependencies: dependencies
        )
        let operations = dependencies.fileOperations
        let sourceBase = dependencies.paths.storeURL(pending.sourceProfileID)
        let replacement = replacementStoreURL(pending, dependencies: dependencies)
        let retired = retiredStoreURL(pending, dependencies: dependencies)

        if try regularFilePresence(at: retired, operations: operations) == .present {
            guard try SQLiteLogicalDigest.digest(of: retired) == sourceDigest else {
                throw ExecutorError.halt("retired store is not this transaction's")
            }
            try verifyRawReplacementStore(
                at: sourceBase, pending: pending, dependencies: dependencies
            )
        } else {
            let replacementPresence = try regularFilePresence(
                at: replacement, operations: operations
            )
            if replacementPresence == .present,
               (try? verifyRawReplacementStoreContent(
                at: sourceBase, pending: pending, dependencies: dependencies
               )) != nil {
                guard try SQLiteLogicalDigest.digest(of: replacement) == sourceDigest else {
                    throw ExecutorError.halt("swapped-out store is not this transaction's")
                }
                try removePreparedStoreSidecars(for: sourceBase, operations: operations)
                try verifyRawReplacementStore(
                    at: sourceBase, pending: pending, dependencies: dependencies
                )
                try operations.moveItemExclusively(staging: replacement, final: retired)
                try verifyEmptyStore(at: sourceBase, dependencies: dependencies)
                try cleanupSourceAudio(
                    plan: plan, pending: pending, dependencies: dependencies
                )
                return
            }
            // Normal path: the base still holds the original source.
            let lease: SourceFreezeLease
            do {
                lease = try SourceFreezeLease.acquire(
                    storeURL: sourceBase, fileOperations: operations
                )
            } catch {
                throw ExecutorError.halt("retire freeze unavailable: \(error)")
            }
            defer { lease.release() }
            do {
                try lease.prepareForRetire()
            } catch {
                throw ExecutorError.halt("retire preparation failed: \(error)")
            }
            guard try SQLiteLogicalDigest.digest(of: sourceBase) == sourceDigest else {
                // Real writes landed after the snapshot: the placed
                // target is stale and must not become the authority.
                throw ExecutorError.halt("source changed since snapshot; transfer stale")
            }
            guard replacementPresence == .present else {
                throw ExecutorError.halt("replacement store missing before swap")
            }
            try verifyRawReplacementStore(
                at: replacement, pending: pending, dependencies: dependencies
            )
            lease.release()
            try operations.swapItems(at: sourceBase, with: replacement)
            try removePreparedStoreSidecars(for: sourceBase, operations: operations)
            try verifyRawReplacementStore(
                at: sourceBase, pending: pending, dependencies: dependencies
            )
            guard try SQLiteLogicalDigest.digest(of: replacement) == sourceDigest else {
                throw ExecutorError.halt("swapped-out store changed before retirement")
            }
            try operations.moveItemExclusively(staging: replacement, final: retired)
        }

        try verifyEmptyStore(at: sourceBase, dependencies: dependencies)
        try cleanupSourceAudio(plan: plan, pending: pending, dependencies: dependencies)
    }

    /// Move-side cleanup: only rows the verified snapshot records as
    /// app-created, only when the current bytes still match the plan,
    /// and only through the recoverable trash. A non-app-created alias
    /// protects every reference to the same source identity. Every rewrite
    /// is proven before deletion; trash-side failures retain the file.
    private static func cleanupSourceAudio(
        plan: TransferAudioPlan,
        pending: PendingTransfer,
        dependencies: Dependencies
    ) throws {
        let operations = dependencies.fileOperations
        let artifact = try snapshotArtifactURL(pending, dependencies: dependencies)
        let rowIndex = try snapshotRowIndex(artifact: artifact, dependencies: dependencies)
        try requireCompletePlan(
            plan, rowIndex: rowIndex, transactionID: pending.transactionID
        )
        try withAudioRootAccess(of: pending.targetEvidence.profile) { targetRoot in
            let targetNamespace = targetNamespaceRoot(
                pending, targetRoot: targetRoot
            )
            try withAudioRootAccess(of: pending.sourceEvidence.profile) { sourceRoot in
                var candidates: [(
                    url: URL,
                    file: TransferAudioPlan.File,
                    pathKey: Data,
                    fileIdentity: Data?
                )] = []
                var protectedPathKeys = Set<Data>()
                var protectedFileIdentities = Set<Data>()
                var identityUnverifiable = false
                for rewrite in plan.rewrites {
                    let base = try verifiedSourceBase(
                        rewrite: rewrite, rowIndex: rowIndex,
                        sourceRoot: sourceRoot,
                        transactionID: pending.transactionID
                    )
                    for file in planFiles(of: plan, matching: rewrite) {
                        guard file.sourceOwnership == base.ownership else {
                            throw ExecutorError.halt(
                                "plan ownership does not match the snapshot row: \(file.recordingID)"
                            )
                        }
                        let url = try sourceFileURL(base: base, file: file)
                        try requireOutsideNamespace(url, namespaceRoot: targetNamespace)
                        let pathKey = conservativeSourcePathKey(url)
                        let fileIdentity: Data?
                        do {
                            switch try regularFilePresence(at: url, operations: operations) {
                            case .absent:
                                fileIdentity = nil
                            case .present:
                                let attributes = try operations.attributesOfItem(at: url)
                                fileIdentity = sourceFileIdentity(attributes)
                            }
                        } catch {
                            identityUnverifiable = true
                            fileIdentity = nil
                        }
                        candidates.append((url, file, pathKey, fileIdentity))
                        if base.ownership != .appCreated {
                            protectedPathKeys.insert(pathKey)
                            if let fileIdentity {
                                protectedFileIdentities.insert(fileIdentity)
                            }
                        }
                    }
                }
                if identityUnverifiable {
                    NSLog("[ProfileTransfer] retaining source audio: identity unavailable")
                    return
                }
                var processedPaths = Set<Data>()
                for candidate in candidates {
                    let url = candidate.url
                    let file = candidate.file
                    guard file.sourceOwnership == .appCreated,
                          !protectedPathKeys.contains(candidate.pathKey),
                          candidate.fileIdentity.map({
                              !protectedFileIdentities.contains($0)
                          }) ?? true else {
                        continue
                    }
                    let exactPath = Data(url.standardizedFileURL.path.utf8)
                    guard processedPaths.insert(exactPath).inserted else { continue }
                    guard operations.fileExists(at: url) else { continue }
                    guard (try? requireRegularFile(at: url, fileOperations: operations))
                        != nil,
                        (try? operations.sha256(of: url)) == file.sha256 else {
                        NSLog(
                            "[ProfileTransfer] retaining changed source audio: %@",
                            url.lastPathComponent
                        )
                        continue
                    }
                    do {
                        try operations.trashItem(at: url)
                    } catch {
                        NSLog(
                            "[ProfileTransfer] retaining source audio (trash failed): %@",
                            url.lastPathComponent
                        )
                    }
                }
            }
        }
    }

    private static func conservativeSourcePathKey(_ url: URL) -> Data {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            .precomposedStringWithCanonicalMapping.lowercased()
        return Data(path.utf8)
    }

    private static func sourceFileIdentity(
        _ attributes: [FileAttributeKey: Any]
    ) -> Data? {
        guard let system = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return Data("\(system.uint64Value):\(file.uint64Value)".utf8)
    }

    // MARK: - Final verification and commit

    /// Complete read-only proof of the placed target side: ownership
    /// claims, the target store's recorded bytes and digest, manifest
    /// completeness against the snapshot, and every placed directory and
    /// audio file. Runs before each destructive move step and again at
    /// commit — a target that degraded after placement halts the
    /// transfer before the source side changes.
    private static func verifyPlacedTargetSide(
        _ pending: PendingTransfer,
        context: String,
        dependencies: Dependencies
    ) throws {
        guard let plan = pending.audioPlan else {
            throw ExecutorError.halt("checkpoint payload missing audio plan")
        }
        let operations = dependencies.fileOperations
        try requirePlacementClaims(
            pending, context: context, dependencies: dependencies
        )
        let targetStore = dependencies.paths.storeURL(pending.targetProfileID)
        try verifyRawStagedStore(
            at: targetStore, pending: pending, dependencies: dependencies
        )
        let artifact = try snapshotArtifactURL(pending, dependencies: dependencies)
        try requireCompletePlan(
            plan,
            rowIndex: try snapshotRowIndex(artifact: artifact, dependencies: dependencies),
            transactionID: pending.transactionID
        )
        try withAudioRootAccess(of: pending.targetEvidence.profile) { targetRoot in
            let resolver = ProfileStorageResolver(root: targetRoot)
            for rewrite in plan.rewrites {
                for directory in plan.directories
                where directory.recordingID == rewrite.recordingID
                    && directory.field == rewrite.field {
                    let relative = directory.childRelativePath.map {
                        rewrite.destinationReference + "/" + $0
                    } ?? rewrite.destinationReference
                    let destination = try resolveTargetRelative(relative, resolver: resolver)
                    let attributes = try operations.attributesOfItem(at: destination)
                    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                        throw ExecutorError.halt(
                            "target tree verification failed: \(relative)"
                        )
                    }
                }
                for file in planFiles(of: plan, matching: rewrite) {
                    let destinationRelative = ProfileTransfer.audioDestinationRelativePath(
                        transactionID: pending.transactionID,
                        recordingID: rewrite.recordingID,
                        field: rewrite.field,
                        sourceReference: rewrite.sourceReference,
                        childRelativePath: file.childRelativePath
                    )
                    let destination = try resolveTargetRelative(
                        destinationRelative, resolver: resolver
                    )
                    try requireRegularFile(at: destination, fileOperations: operations)
                    guard try operations.sha256(of: destination) == file.sha256 else {
                        throw ExecutorError.halt(
                            "target audio verification failed: \(destinationRelative)"
                        )
                    }
                }
            }
        }
    }

    /// Complete re-proof immediately before the registry commit: the
    /// durable record, the target store, every planned audio file, and —
    /// for copies — the untouched source. A stale target never becomes
    /// the authority.
    private static func performFinalVerification(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        let current = try reloadAndProve(
            matching: pending, transactionID: pending.transactionID,
            dependencies: dependencies
        )
        guard let plan = current.audioPlan else {
            throw ExecutorError.halt("commit payload missing audio plan")
        }
        let operations = dependencies.fileOperations
        try verifyPlacedTargetSide(
            current, context: "at commit", dependencies: dependencies
        )
        let artifact = try snapshotArtifactURL(current, dependencies: dependencies)
        switch current.mode {
        case .copy:
            try requireSourceConsistentPlan(
                plan, pending: current, artifact: artifact,
                dependencies: dependencies
            )
            _ = try requireRecordedEvidence(current, dependencies: dependencies)
        case .move:
            let retired = retiredStoreURL(current, dependencies: dependencies)
            guard let digest = current.sourceContentDigest else {
                throw ExecutorError.halt("commit payload missing retire proofs")
            }
            guard try regularFilePresence(
                at: retired, operations: operations
            ) == .present else {
                throw ExecutorError.halt("retired store missing at commit")
            }
            guard try SQLiteLogicalDigest.digest(of: retired) == digest else {
                throw ExecutorError.halt("retired store failed commit verification")
            }
            // Raw hash and digest against the build-time proof, never a
            // SwiftData reopen of the store this process just placed.
            try verifyRawReplacementStore(
                at: dependencies.paths.storeURL(current.sourceProfileID),
                pending: current, dependencies: dependencies
            )
        }
    }

    private static func requirePlacementClaims(
        _ pending: PendingTransfer,
        context: String,
        dependencies: Dependencies
    ) throws {
        let operations = dependencies.fileOperations
        do {
            try ProfileTransfer.requireMatchingPlacementMarker(
                at: targetProfileMarker(pending, dependencies: dependencies),
                pending: pending,
                kind: .profileStore,
                fileOperations: operations
            )
        } catch {
            throw ExecutorError.halt(
                "profile placement claim failed \(context): \(error)"
            )
        }
        try withAudioRootAccess(of: pending.targetEvidence.profile) { targetRoot in
            do {
                try ProfileTransfer.requireMatchingPlacementMarker(
                    at: ProfileTransfer.placementMarkerURL(
                        inDirectory: targetRoot,
                        transactionID: pending.transactionID,
                        kind: .audioRoot
                    ),
                    pending: pending,
                    kind: .audioRoot,
                    fileOperations: operations
                )
            } catch {
                throw ExecutorError.halt(
                    "audio placement claim failed \(context): \(error)"
                )
            }
        }
    }

    private static func performCommit(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) throws {
        let document: ProfileRegistryDocument
        do {
            document = try dependencies.registry.load()
        } catch {
            throw ExecutorError.halt("registry unreadable at commit: \(error)")
        }
        guard let disk = document.pendingTransfer,
              try encodedPending(disk) == encodedPending(pending) else {
            throw ExecutorError.halt("pending transfer drifted at commit")
        }
        guard let targetIndex = document.profiles.firstIndex(where: {
            $0.id == pending.targetProfileID
        }) else {
            throw ExecutorError.halt("transfer target missing at commit")
        }
        var intended = document
        intended.pendingTransfer = nil
        intended.profiles[targetIndex].storeMaterialized = true
        intended.profiles[targetIndex].createdByBindingTransactionID = nil
        intended.profiles[targetIndex].lastActiveAt = dependencies.now()
        intended.activeProfileID = pending.targetProfileID
        switch ProfileSwitchCoordinator.classifiedSave(
            old: document, intended: intended, registry: dependencies.registry
        ) {
        case .committed:
            removeMarkers(pending, dependencies: dependencies)
            return
        case .notCommitted(let detail):
            throw ExecutorError.halt("transfer commit not recorded: \(detail)")
        case .indeterminate(let detail):
            throw ExecutorError.halt("transfer commit indeterminate: \(detail)")
        }
    }

    /// Marker removal is best-effort after commit. Residue carries no
    /// authority once the pending transfer is absent.
    private static func removeMarkers(
        _ pending: PendingTransfer, dependencies: Dependencies
    ) {
        let operations = dependencies.fileOperations
        let profileMarker = targetProfileMarker(pending, dependencies: dependencies)
        if (try? ProfileTransfer.placementMarkerPresence(
            at: profileMarker, pending: pending, kind: .profileStore,
            fileOperations: operations
        )) == .matching {
            try? operations.removeItem(at: profileMarker)
        }
        _ = try? withAudioRootAccess(of: pending.targetEvidence.profile) { audioRoot in
            let audioMarker = ProfileTransfer.placementMarkerURL(
                inDirectory: audioRoot, transactionID: pending.transactionID,
                kind: .audioRoot
            )
            if (try? ProfileTransfer.placementMarkerPresence(
                at: audioMarker, pending: pending, kind: .audioRoot,
                fileOperations: operations
            )) == .matching {
                try? operations.removeItem(at: audioMarker)
            }
        }
    }
}
