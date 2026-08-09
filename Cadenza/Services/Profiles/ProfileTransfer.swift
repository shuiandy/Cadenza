import CryptoKit
import Foundation
import SQLite3
import SwiftData

/// Read-only emptiness probe for a transfer target store. `nil` means the
/// store is definitively absent; otherwise the exact row count of every
/// schema entity. Unclassifiable stores throw — the caller fails closed.
protocol TransferStoreInspecting {
    func entityCounts(at url: URL) throws -> [String: Int]?
}

enum TransferStoreInspectionError: Error {
    case openFailed(String)
    case queryFailed(String)
}

/// Live inspector: classified absence probe, then synchronous read-only
/// SQLite counts over the full recordings schema. Counts cover every entity
/// type; the inventory test seals the list against the schema, so a future
/// entity cannot silently make a populated store look empty.
struct LiveTransferStoreInspector: TransferStoreInspecting {
    let fileOperations: FileOperations

    private static let entityTables: [(entity: String, table: String)] = [
        ("Recording", "ZRECORDING"),
        ("Transcript", "ZTRANSCRIPT"),
        ("MeetingSummary", "ZMEETINGSUMMARY"),
        ("ExternalRecordingImport", "ZEXTERNALRECORDINGIMPORT"),
        ("Folder", "ZFOLDER"),
        ("SpeakerProfile", "ZSPEAKERPROFILE"),
        ("SpeakerVoiceSample", "ZSPEAKERVOICESAMPLE"),
        ("Recap", "ZRECAP"),
        ("AgentArtifact", "ZAGENTARTIFACT"),
        ("WebSyncRecord", "ZWEBSYNCRECORD"),
    ]

    func entityCounts(at url: URL) throws -> [String: Int]? {
        let presence = ProfileBindingTransaction.classifiedStorePresence(
            fileOperations: fileOperations
        )
        guard try presence(url) else { return nil }
        fileOperations.noteStoreOpen(at: url)
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: url), &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "open failed"
            sqlite3_close(database)
            throw TransferStoreInspectionError.openFailed(detail)
        }
        var needsClose = true
        defer {
            if needsClose { sqlite3_close(database) }
        }
        sqlite3_busy_timeout(database, 5_000)

        var counts: [String: Int] = [:]
        for (entity, table) in Self.entityTables {
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM \"\(table)\""
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw TransferStoreInspectionError.queryFailed(
                    String(cString: sqlite3_errmsg(database))
                )
            }
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                sqlite3_finalize(statement)
                throw TransferStoreInspectionError.queryFailed(
                    String(cString: sqlite3_errmsg(database))
                )
            }
            counts[entity] = Int(sqlite3_column_int64(statement, 0))
            guard sqlite3_finalize(statement) == SQLITE_OK else {
                throw TransferStoreInspectionError.queryFailed(
                    String(cString: sqlite3_errmsg(database))
                )
            }
        }
        guard sqlite3_close(database) == SQLITE_OK else {
            throw TransferStoreInspectionError.openFailed("close failed")
        }
        database = nil
        needsClose = false
        return counts
    }
}

struct TransferPlacementClaim: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case profileStore = "profile-store"
        case audioRoot = "audio-root"
    }

    static let currentVersion = 1

    var version: Int
    var transactionID: UUID
    var claimToken: UUID
    var kind: Kind
}

/// Whole-store transfer between profiles (spec §6.4, INV-19): durable
/// initiation, the fail-closed preflight, and the boot classification.
/// The transfer executor (snapshot, stage, place, move cleanup) builds on
/// these seams; nothing here mutates a store or an audio file.
enum ProfileTransfer {
    enum AudioRootAccessError: Error {
        case bookmarkUnresolvable(String)
        case pathDrift
    }

    enum PlacementMarkerError: Error {
        case missing
        case malformed
        case unsupportedVersion(Int)
        case claimMismatch
    }

    enum PlacementMarkerPresence: Equatable {
        case absent
        case matching
    }

    /// The entity types the emptiness proof counts. Must stay identical
    /// to `RecordingsStore.schema`; the inventory test enforces it.
    static let inspectedEntityNames: [String] = [
        "Recording", "Transcript", "MeetingSummary", "ExternalRecordingImport",
        "Folder", "SpeakerProfile", "SpeakerVoiceSample", "Recap",
        "AgentArtifact", "WebSyncRecord",
    ]

    struct Dependencies {
        let registry: any ProfileRegistryProviding
        let storeURL: (UUID) -> URL
        let inspector: any TransferStoreInspecting
        let fileOperations: FileOperations
        let now: () -> Date
    }

    static func withAudioRootAccess<T>(
        of profile: Profile,
        _ body: (URL) throws -> T
    ) throws -> T {
        let recorded = URL(
            fileURLWithPath: profile.audioDirectory.path, isDirectory: true
        )
        guard profile.audioDirectory.kind == .userSelected,
              let bookmarkData = profile.audioDirectory.bookmark else {
            return try body(recorded)
        }
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw AudioRootAccessError.bookmarkUnresolvable(String(describing: error))
        }
        guard AccountIdentity.matches(resolved.path, recorded.path) else {
            throw AudioRootAccessError.pathDrift
        }
        let accessing = resolved.startAccessingSecurityScopedResource()
        defer {
            if accessing { resolved.stopAccessingSecurityScopedResource() }
        }
        return try body(resolved)
    }

    /// Transaction ownership marker beside a placed artifact: resume may
    /// confirm existing files only under its own marker — a matching
    /// path or hash alone never claims foreign content.
    static func placementMarkerURL(
        inDirectory directory: URL,
        transactionID: UUID,
        kind: TransferPlacementClaim.Kind
    ) -> URL {
        directory.appendingPathComponent(
            ".cadenza-transfer-\(transactionID.uuidString)-\(kind.rawValue)"
        )
    }

    static func placementMarkerPayload(
        _ pending: PendingTransfer,
        kind: TransferPlacementClaim.Kind
    ) throws -> Data {
        try ProfileRegistryCoding.makeEncoder().encode(TransferPlacementClaim(
            version: TransferPlacementClaim.currentVersion,
            transactionID: pending.transactionID,
            claimToken: pending.placementClaimToken,
            kind: kind
        ))
    }

    static func placementMarkerPresence(
        at url: URL,
        pending: PendingTransfer,
        kind: TransferPlacementClaim.Kind,
        fileOperations: FileOperations
    ) throws -> PlacementMarkerPresence {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileOperations.attributesOfItem(at: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PlacementMarkerError.malformed
        }
        let data = try fileOperations.read(from: url)
        let claim: TransferPlacementClaim
        do {
            claim = try ProfileRegistryCoding.makeDecoder().decode(
                TransferPlacementClaim.self, from: data
            )
        } catch {
            throw PlacementMarkerError.malformed
        }
        guard claim.version == TransferPlacementClaim.currentVersion else {
            throw PlacementMarkerError.unsupportedVersion(claim.version)
        }
        guard claim.transactionID == pending.transactionID,
              claim.claimToken == pending.placementClaimToken,
              claim.kind == kind else {
            throw PlacementMarkerError.claimMismatch
        }
        guard try placementMarkerPayload(pending, kind: kind) == data else {
            throw PlacementMarkerError.malformed
        }
        return .matching
    }

    static func requireMatchingPlacementMarker(
        at url: URL,
        pending: PendingTransfer,
        kind: TransferPlacementClaim.Kind,
        fileOperations: FileOperations
    ) throws {
        guard try placementMarkerPresence(
            at: url, pending: pending, kind: kind, fileOperations: fileOperations
        ) == .matching else {
            throw PlacementMarkerError.missing
        }
    }

    /// Every copied audio path lives in a transaction-owned namespace
    /// under the target root. Placement proves every source path disjoint
    /// from that namespace, including symlink aliases, before claiming it.
    /// The value is re-derived at every use; the persisted copy in the plan
    /// is checked against it, never trusted on its own.
    static func audioDestinationRelativePath(
        transactionID: UUID,
        recordingID: UUID,
        field: TransferAudioPlan.Field,
        sourceReference: String,
        childRelativePath: String?
    ) -> String {
        var path = "transfers/\(transactionID.uuidString)"
            + "/\(recordingID.uuidString)/\(field.rawValue)"
            + "/\((sourceReference as NSString).lastPathComponent)"
        if let childRelativePath {
            path += "/\(childRelativePath)"
        }
        return path
    }

    /// Fixed-length same-directory scratch name for an atomic audio copy.
    /// Hashing the final relative path avoids extending a source basename
    /// that may already be at the filesystem's component-length limit.
    static func audioPartialRelativePath(for destinationRelativePath: String) -> String {
        let digest = SHA256.hash(data: Data(destinationRelativePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let parent = (destinationRelativePath as NSString).deletingLastPathComponent
        let name = ".cadenza-partial-" + digest
        return parent.isEmpty || parent == "." ? name : parent + "/" + name
    }

    /// A relative path whose every component is a plain name: non-empty,
    /// no leading slash, no NUL, and no "." or ".." components. This is
    /// the only shape a manifest child or relative reference may take.
    static func isSafeRelativePathComponents(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            return false
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                return false
            }
        }
        return true
    }

    /// A legacy absolute reference with plain components throughout.
    static func isSafeAbsolutePathComponents(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
        guard !components.isEmpty else { return false }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                return false
            }
        }
        return true
    }

    static func isLowercaseHex64(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    /// Structural validation of the audio manifest — shape only, no
    /// filesystem access — run at every load, save, and boot alongside
    /// the payload lattice, and re-run by the executor before any
    /// filesystem mutation the plan directs.
    static func planProblem(
        _ plan: TransferAudioPlan, transactionID: UUID
    ) -> String? {
        func rewriteKey(_ recordingID: UUID, _ field: TransferAudioPlan.Field) -> Data {
            Data("\(recordingID.uuidString)/\(field.rawValue)".utf8)
        }
        var rewritesByKey: [Data: TransferAudioPlan.Rewrite] = [:]
        for rewrite in plan.rewrites {
            let key = rewriteKey(rewrite.recordingID, rewrite.field)
            guard rewritesByKey[key] == nil else {
                return "duplicate rewrite for one recording field"
            }
            switch AudioFileReference(storageValue: rewrite.sourceReference) {
            case .relative(let path):
                guard isSafeRelativePathComponents(path) else {
                    return "unsafe relative source reference"
                }
            case .legacyAbsolute(let path):
                guard isSafeAbsolutePathComponents(path) else {
                    return "unsafe absolute source reference"
                }
            }
            let derived = audioDestinationRelativePath(
                transactionID: transactionID,
                recordingID: rewrite.recordingID,
                field: rewrite.field,
                sourceReference: rewrite.sourceReference,
                childRelativePath: nil
            )
            guard Array(rewrite.destinationReference.utf8) == Array(derived.utf8) else {
                return "rewrite destination is not the transaction namespace"
            }
            rewritesByKey[key] = rewrite
        }

        // Directories: complete tree description, roots included.
        var occupied = Set<Data>()
        var canonicalGroups: [String: Data] = [:]
        var directoryPaths = Set<Data>()
        var rootsSeen = Set<Data>()
        func occupy(_ full: String) -> String? {
            let key = Data(full.utf8)
            guard occupied.insert(key).inserted else {
                return "duplicate plan destination"
            }
            let folded = full.precomposedStringWithCanonicalMapping.lowercased()
            if let existing = canonicalGroups[folded], existing != key {
                return "canonically colliding plan destinations"
            }
            canonicalGroups[folded] = key
            return nil
        }
        for directory in plan.directories {
            guard directory.field == .segmentsDirectory else {
                return "directory entry on an audio file field"
            }
            let key = rewriteKey(directory.recordingID, directory.field)
            guard let rewrite = rewritesByKey[key] else {
                return "plan directory without a rewrite"
            }
            let full: String
            if let child = directory.childRelativePath {
                guard isSafeRelativePathComponents(child) else {
                    return "unsafe tree directory path"
                }
                full = rewrite.destinationReference + "/" + child
            } else {
                rootsSeen.insert(key)
                full = rewrite.destinationReference
            }
            if let problem = occupy(full) { return problem }
            directoryPaths.insert(Data(full.utf8))
        }
        for (key, rewrite) in rewritesByKey where rewrite.field == .segmentsDirectory {
            guard rootsSeen.contains(key) else {
                return "segments rewrite missing its tree root entry"
            }
            _ = rewrite
        }
        // Every proper prefix of a manifest path must itself be a
        // manifest directory: the tree is closed under parents.
        func parentsPresent(
            base: String, child: String
        ) -> Bool {
            let components = child.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1 else { return true }
            var prefix = base
            for component in components.dropLast() {
                prefix += "/" + component
                guard directoryPaths.contains(Data(prefix.utf8)) else { return false }
            }
            return true
        }
        for directory in plan.directories {
            guard let child = directory.childRelativePath,
                  let rewrite = rewritesByKey[
                    rewriteKey(directory.recordingID, directory.field)
                  ] else { continue }
            guard parentsPresent(base: rewrite.destinationReference, child: child) else {
                return "tree directory without its parent entry"
            }
        }

        var audioFileCounts: [Data: Int] = [:]
        var partialPaths = Set<Data>()
        var partialPathStrings: [String] = []
        for file in plan.files {
            guard file.size >= 0 else { return "negative plan size" }
            guard isLowercaseHex64(file.sha256) else { return "malformed plan hash" }
            let key = rewriteKey(file.recordingID, file.field)
            guard let rewrite = rewritesByKey[key] else {
                return "plan file without a rewrite"
            }
            let full: String
            switch file.field {
            case .audioFile:
                guard file.childRelativePath == nil else {
                    return "audio file entry carries a child path"
                }
                audioFileCounts[key, default: 0] += 1
                full = rewrite.destinationReference
            case .segmentsDirectory:
                guard let child = file.childRelativePath,
                      isSafeRelativePathComponents(child) else {
                    return "unsafe tree child path"
                }
                guard parentsPresent(base: rewrite.destinationReference, child: child) else {
                    return "tree file without its directory entry"
                }
                full = rewrite.destinationReference + "/" + child
            }
            if let problem = occupy(full) { return problem }
            let partial = audioPartialRelativePath(for: full)
            partialPaths.insert(Data(partial.utf8))
            partialPathStrings.append(partial)
        }
        guard partialPaths.isDisjoint(with: occupied) else {
            return "audio copy scratch collides with a plan destination"
        }
        var partialCanonicalGroups: [String: Data] = [:]
        for partial in partialPathStrings {
            let key = Data(partial.utf8)
            let folded = partial.precomposedStringWithCanonicalMapping.lowercased()
            guard canonicalGroups[folded] == nil else {
                return "audio copy scratch collides with a plan destination"
            }
            if let existing = partialCanonicalGroups[folded], existing != key {
                return "canonically colliding audio copy scratch paths"
            }
            partialCanonicalGroups[folded] = key
        }
        for (key, rewrite) in rewritesByKey where rewrite.field == .audioFile {
            guard audioFileCounts[key] == 1 else {
                return "audio file rewrite without exactly one file"
            }
            _ = rewrite
        }
        return nil
    }

    /// Initiation request. `creationTransactionID` pins eligibility to
    /// the exact binding transaction the current login flow just ran; a
    /// target created by any other flow — or whose one-shot eligibility
    /// was already consumed — refuses.
    struct Request {
        let sourceProfileID: UUID
        let targetProfileID: UUID
        let mode: PendingTransfer.Mode
        let creationTransactionID: UUID
    }

    enum PreflightError: Error, Equatable {
        case sourceMissing
        case targetMissing
        case sameProfile
        case sourceNotSystemLocal
        case sourceNotActive
        case targetNotStandard
        case targetUnbound
        case targetLocked
        case targetNotFreshlyCreated
        case competingPendingOperation
        case targetStoreNotEmpty(entity: String, count: Int)
        case targetStoreUnreadable(String)
    }

    enum TransferError: Error {
        case preflight(PreflightError)
        /// The registry provably still holds the old shape — retryable.
        case saveNotCommitted(String)
        /// The write cannot be classified; the caller must halt.
        case commitIndeterminate(String)
    }

    /// Fail-closed eligibility proof over a fresh document plus the
    /// target store's full entity counts. Returns the two frozen
    /// full-row snapshots the durable record carries.
    static func preflight(
        document: ProfileRegistryDocument,
        request: Request,
        dependencies: Dependencies
    ) throws -> (source: PendingTransfer.ProfileEvidence,
                 target: PendingTransfer.ProfileEvidence) {
        guard request.sourceProfileID != request.targetProfileID else {
            throw TransferError.preflight(.sameProfile)
        }
        guard document.pendingBinding == nil, document.pendingTransfer == nil else {
            throw TransferError.preflight(.competingPendingOperation)
        }
        guard let source = document.profiles.first(where: {
            $0.id == request.sourceProfileID
        }) else {
            throw TransferError.preflight(.sourceMissing)
        }
        guard let target = document.profiles.first(where: {
            $0.id == request.targetProfileID
        }) else {
            throw TransferError.preflight(.targetMissing)
        }
        guard source.kind == .system else {
            throw TransferError.preflight(.sourceNotSystemLocal)
        }
        guard document.activeProfileID == source.id else {
            throw TransferError.preflight(.sourceNotActive)
        }
        guard target.kind == .standard else {
            throw TransferError.preflight(.targetNotStandard)
        }
        guard target.boundAccount != nil else {
            throw TransferError.preflight(.targetUnbound)
        }
        guard !target.isLocked else {
            throw TransferError.preflight(.targetLocked)
        }
        // Structural freshness: the exact creation provenance of the
        // login flow's binding transaction, still unconsumed, and a
        // store that never materialized. Time is never consulted.
        guard let provenance = target.createdByBindingTransactionID,
              provenance == request.creationTransactionID,
              !target.storeMaterialized else {
            throw TransferError.preflight(.targetNotFreshlyCreated)
        }
        try requireEmptyTargetStore(targetID: target.id, dependencies: dependencies)
        return (
            source: PendingTransfer.ProfileEvidence(profile: source),
            target: PendingTransfer.ProfileEvidence(profile: target)
        )
    }

    /// Every schema entity must be provably zero; a missing count for an
    /// inspected entity is an unreadable proof, not emptiness.
    static func requireEmptyTargetStore(
        targetID: UUID, dependencies: Dependencies
    ) throws {
        let targetStoreURL = dependencies.storeURL(targetID)
        let counts: [String: Int]?
        do {
            counts = try dependencies.inspector.entityCounts(
                at: targetStoreURL
            )
        } catch {
            throw TransferError.preflight(.targetStoreUnreadable(String(describing: error)))
        }
        guard let counts else {
            let trio = StoreTrioURL(base: targetStoreURL)
            for sidecar in [trio.wal, trio.shm] {
                do {
                    _ = try dependencies.fileOperations.attributesOfItem(at: sidecar)
                    throw TransferError.preflight(.targetStoreUnreadable(
                        "orphan target sidecar: \(sidecar.lastPathComponent)"
                    ))
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    continue
                } catch let error as TransferError {
                    throw error
                } catch {
                    throw TransferError.preflight(.targetStoreUnreadable(
                        "target sidecar probe failed: \(error)"
                    ))
                }
            }
            return
        }
        for entity in inspectedEntityNames {
            guard let count = counts[entity] else {
                throw TransferError.preflight(
                    .targetStoreUnreadable("no count for \(entity)")
                )
            }
            guard count == 0 else {
                throw TransferError.preflight(
                    .targetStoreNotEmpty(entity: entity, count: count)
                )
            }
        }
    }

    /// User-side initiation: preflight, then one classified registry
    /// write recording the `initiated` checkpoint. On success the caller
    /// relaunches into transfer mode.
    static func begin(
        request: Request,
        dependencies: Dependencies
    ) throws -> PendingTransfer {
        let document: ProfileRegistryDocument
        do {
            document = try dependencies.registry.load()
        } catch {
            throw TransferError.commitIndeterminate(
                "registry unreadable before initiation: \(error)"
            )
        }
        let evidence = try preflight(
            document: document, request: request, dependencies: dependencies
        )
        let pending = PendingTransfer(
            version: 1,
            transactionID: UUID(),
            placementClaimToken: UUID(),
            sourceProfileID: request.sourceProfileID,
            targetProfileID: request.targetProfileID,
            mode: request.mode,
            state: .initiated,
            startedAt: dependencies.now(),
            sourceEvidence: evidence.source,
            targetEvidence: evidence.target
        )
        var intended = document
        intended.pendingTransfer = pending
        switch ProfileSwitchCoordinator.classifiedSave(
            old: document, intended: intended, registry: dependencies.registry
        ) {
        case .committed:
            return pending
        case .notCommitted(let detail):
            throw TransferError.saveNotCommitted(detail)
        case .indeterminate(let detail):
            throw TransferError.commitIndeterminate(detail)
        }
    }

    /// Semantic legality of a pending transfer against the trusted
    /// document it was loaded with. Nil means the record may run. Any
    /// problem here is drifted or corrupt authority and must halt with
    /// zero writes — these are deliberately not registry `validate()`
    /// rules, because a load failure would route the boot into the M1
    /// journal rebuild and destroy the later authority this registry
    /// still records.
    static func structuralProblem(
        document: ProfileRegistryDocument, pending: PendingTransfer
    ) -> String? {
        // Per-state payload legality: every checkpoint carries exactly
        // the proofs its state requires. The registry rows themselves
        // stay frozen until the final commit, so the shape rules below
        // apply identically at every checkpoint.
        let snapshotComplete = pending.snapshotReceipt != nil
            && pending.sourceStoreEvidence != nil
            && pending.sourceContentDigest != nil
        let snapshotEmpty = pending.snapshotReceipt == nil
            && pending.sourceStoreEvidence == nil
            && pending.sourceContentDigest == nil
        let stageComplete = pending.audioPlan != nil
            && pending.targetContentDigest != nil
            && pending.stagedStoreSHA256 != nil
        let stageEmpty = pending.audioPlan == nil
            && pending.targetContentDigest == nil
            && pending.stagedStoreSHA256 == nil
        let replacementComplete = pending.replacementContentDigest != nil
            && pending.replacementStoreSHA256 != nil
        let replacementEmpty = pending.replacementContentDigest == nil
            && pending.replacementStoreSHA256 == nil
        switch pending.state {
        case .initiated:
            guard snapshotEmpty, stageEmpty, replacementEmpty else {
                return "initiated transfer carries later-state payloads"
            }
        case .sourceSnapshotted:
            guard snapshotComplete else {
                return "snapshot checkpoint payload incomplete"
            }
            guard stageEmpty, replacementEmpty else {
                return "snapshot checkpoint carries stage payloads"
            }
        case .staged, .targetVerified, .placed:
            guard snapshotComplete, stageComplete else {
                return "staged checkpoint payload incomplete"
            }
            guard replacementEmpty else {
                return "staged checkpoint carries rebuild payloads"
            }
        case .localRebuilt:
            guard pending.mode == .move else {
                return "local rebuild checkpoint on a copy transfer"
            }
            guard snapshotComplete, stageComplete else {
                return "rebuild checkpoint payload incomplete"
            }
            guard replacementComplete else {
                return "rebuild checkpoint replacement payload incomplete"
            }
        }
        if let sha = pending.replacementStoreSHA256, !isLowercaseHex64(sha) {
            return "malformed replacement store hash"
        }
        if let digest = pending.sourceContentDigest, !isLowercaseHex64(digest) {
            return "malformed source store digest"
        }
        if let digest = pending.targetContentDigest, !isLowercaseHex64(digest) {
            return "malformed staged store digest"
        }
        if let digest = pending.replacementContentDigest, !isLowercaseHex64(digest) {
            return "malformed replacement store digest"
        }
        if let sha = pending.stagedStoreSHA256, !isLowercaseHex64(sha) {
            return "malformed staged store hash"
        }
        if let receipt = pending.snapshotReceipt {
            let names = receipt.files.map(\.name)
            guard names.filter({ $0 == "Cadenza.store" }).count == 1,
                  Set(names).count == names.count else {
                return "ambiguous snapshot receipt inventory"
            }
            for file in receipt.files {
                guard file.size >= 0 else { return "negative receipt size" }
                guard isLowercaseHex64(file.sha256) else {
                    return "malformed receipt hash"
                }
            }
        }
        if let plan = pending.audioPlan,
           let problem = planProblem(plan, transactionID: pending.transactionID) {
            return problem
        }
        guard let source = document.profiles.first(where: {
            $0.id == pending.sourceProfileID
        }) else {
            return "transfer source missing from registry"
        }
        guard let target = document.profiles.first(where: {
            $0.id == pending.targetProfileID
        }) else {
            return "transfer target missing from registry"
        }
        guard pending.sourceEvidence.profile.id == pending.sourceProfileID,
              pending.targetEvidence.profile.id == pending.targetProfileID else {
            return "transfer evidence names a different profile"
        }
        guard source.kind == .system else {
            return "transfer source is not the system profile"
        }
        // The active profile is not part of any row snapshot, so it is
        // proven here explicitly: the transfer relaunches from the
        // source, and a third party switching the active profile behind
        // the pending record is drifted authority.
        guard document.activeProfileID == pending.sourceProfileID else {
            return "active profile is not the transfer source"
        }
        guard target.kind == .standard else {
            return "transfer target is not a standard profile"
        }
        guard target.boundAccount != nil, !target.isLocked, !target.storeMaterialized else {
            return "transfer target lost its fresh account shape"
        }
        guard let evidenceProvenance =
                pending.targetEvidence.profile.createdByBindingTransactionID else {
            return "transfer evidence missing creation provenance"
        }
        guard target.createdByBindingTransactionID == evidenceProvenance else {
            return "transfer target provenance does not match the evidence"
        }
        guard pending.sourceEvidence.matches(source),
              pending.targetEvidence.matches(target) else {
            return "transfer evidence does not match the registry"
        }
        return nil
    }

    enum BootDecision {
        /// The pending record re-proved; the process belongs to the
        /// transfer executor.
        case run(PendingTransfer)
        /// Before placement has claimed either target namespace, the target
        /// store gained rows. The pending record and the target's one-shot
        /// eligibility are cleared in one classified write, and normal boot
        /// continues with the cleared document.
        case refusedAndCleared(ProfileRegistryDocument, reason: String)
        /// Unknown, corrupt, or drifted — the boot must halt with zero
        /// writes.
        case halted(String)
    }

    /// Transfer-mode entry classification, run on the first trusted
    /// registry load before any normal boot step. The only deterministic
    /// refusal is a non-empty target store before either placement marker
    /// exists. Once one matching marker exists, placement has begun and the
    /// executor must classify the artifacts from its recorded proofs instead
    /// of re-applying the emptiness preflight.
    static func classifyAtBoot(
        document: ProfileRegistryDocument,
        dependencies: Dependencies
    ) -> BootDecision {
        guard let pending = document.pendingTransfer else {
            return .halted("no pending transfer to classify")
        }
        if let problem = structuralProblem(document: document, pending: pending) {
            return .halted(problem)
        }
        let profileMarker = placementMarkerURL(
            inDirectory: dependencies.storeURL(pending.targetProfileID)
                .deletingLastPathComponent(),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        let profileMarkerPresence: PlacementMarkerPresence
        let audioMarkerPresence: PlacementMarkerPresence
        do {
            profileMarkerPresence = try placementMarkerPresence(
                at: profileMarker, pending: pending, kind: .profileStore,
                fileOperations: dependencies.fileOperations
            )
            audioMarkerPresence = try withAudioRootAccess(
                of: pending.targetEvidence.profile
            ) { targetRoot in
                try placementMarkerPresence(
                    at: placementMarkerURL(
                        inDirectory: targetRoot,
                        transactionID: pending.transactionID,
                        kind: .audioRoot
                    ),
                    pending: pending,
                    kind: .audioRoot,
                    fileOperations: dependencies.fileOperations
                )
            }
        } catch {
            return .halted("placement marker claim unavailable: \(error)")
        }
        // Before either ownership claim exists, foreign target content is
        // still a deterministic refusal. Once placement begins, every
        // existing claim has already been validated above and resume owns
        // the target namespace. Completed placement requires both roles.
        switch pending.state {
        case .placed, .localRebuilt:
            guard profileMarkerPresence == .matching,
                  audioMarkerPresence == .matching else {
                return .halted("placement marker claim missing after placement")
            }
            return .run(pending)
        case .initiated, .sourceSnapshotted, .staged, .targetVerified:
            if profileMarkerPresence == .matching || audioMarkerPresence == .matching {
                return .run(pending)
            }
        }
        do {
            try requireEmptyTargetStore(
                targetID: pending.targetProfileID, dependencies: dependencies
            )
        } catch TransferError.preflight(.targetStoreNotEmpty(let entity, let count)) {
            var cleared = document
            cleared.pendingTransfer = nil
            if let index = cleared.profiles.firstIndex(where: {
                $0.id == pending.targetProfileID
            }) {
                cleared.profiles[index].createdByBindingTransactionID = nil
            }
            switch ProfileSwitchCoordinator.classifiedSave(
                old: document, intended: cleared, registry: dependencies.registry
            ) {
            case .committed:
                return .refusedAndCleared(
                    cleared, reason: "target store not empty: \(entity) = \(count)"
                )
            case .notCommitted(let detail):
                return .halted("transfer refusal not recorded: \(detail)")
            case .indeterminate(let detail):
                return .halted("transfer refusal indeterminate: \(detail)")
            }
        } catch {
            return .halted("target store unreadable: \(error)")
        }
        return .run(pending)
    }
}
