import Foundation
import SwiftData

/// Result of a verified snapshot: where the backup artifact lives, the
/// per-file hashes after the read-only open (opening may rewrite files),
/// and the entity counts observed in the artifact. The receipt certifies
/// the ARTIFACT only; the live source is bound separately by
/// `SourceEvidence` — an online backup's bytes never equal the live trio's.
struct SnapshotReceipt: Codable, Sendable, Equatable {
    struct FileRecord: Codable, Sendable, Equatable {
        var name: String
        var size: Int64
        var sha256: String
    }

    var directory: URL
    var files: [FileRecord]
    var entityCounts: [String: Int]
}

enum StoreSnapshotError: Error {
    case sourceMissing(String)
    case openFailed(String)
    case receiptIncomplete(String)
}

/// Consistent snapshot of a store with content verification. Consistency
/// comes from the SQLite online-backup driver — the trio files are never
/// copied while live. Fully throwing on the integrity path: any metadata,
/// hash, open, or listing failure aborts (INV-9).
enum StoreSnapshotter {
    static func performVerifiedSnapshot(
        source: StoreTrioURL,
        into directory: URL,
        label: String,
        fileOperations: FileOperations,
        backupDriver: SQLiteBackupDriver
    ) throws -> SnapshotReceipt {
        // The source we open must be a regular file, never a link; any
        // metadata failure (including not-found) aborts here.
        try requireRegularFile(at: source.base, fileOperations: fileOperations)

        let snapshotDir = directory.appendingPathComponent(label, isDirectory: true)
        if fileOperations.fileExists(at: snapshotDir) {
            try fileOperations.removeItem(at: snapshotDir)
        }
        try fileOperations.createDirectory(at: snapshotDir)

        // 1. Consistent single-file artifact via the backup driver.
        let copyBase = snapshotDir.appendingPathComponent("Cadenza.store")
        try backupDriver.consistentBackup(source: source.base, destination: copyBase)

        // 2. Read-only open of the artifact for entity counts.
        fileOperations.noteStoreOpen(at: copyBase)
        let entityCounts = try readEntityCounts(storeURL: copyBase)

        // 3. Final hashes are post-open — that is the on-disk state later
        //    steps compare against. Metadata failures abort; a receipt with
        //    guessed sizes is not evidence. The base is required; sidecars
        //    enter the receipt when definitely present, and an unprobeable
        //    sidecar aborts rather than silently dropping out.
        let trio = StoreTrioURL(base: copyBase)
        var records: [SnapshotReceipt.FileRecord] = []
        for (file, required) in [(trio.base, true), (trio.wal, false), (trio.shm, false)] {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileOperations.attributesOfItem(at: file)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !required {
                continue
            } catch {
                throw StoreSnapshotError.receiptIncomplete(file.lastPathComponent)
            }
            guard let size = attributes[.size] as? Int64 else {
                throw StoreSnapshotError.receiptIncomplete(file.lastPathComponent)
            }
            records.append(.init(
                name: file.lastPathComponent,
                size: size,
                sha256: try fileOperations.sha256(of: file)
            ))
        }
        return SnapshotReceipt(directory: snapshotDir, files: records, entityCounts: entityCounts)
    }

    /// Opens a store read-only and returns counts for the verified entities.
    static func readEntityCounts(storeURL: URL) throws -> [String: Int] {
        let configuration = ModelConfiguration(url: storeURL, allowsSave: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: RecordingsStore.schema, configurations: configuration
            )
        } catch {
            throw StoreSnapshotError.openFailed(error.localizedDescription)
        }
        return try readEntityCounts(container: container)
    }

    static func readEntityCounts(container: ModelContainer) throws -> [String: Int] {
        do {
            let context = ModelContext(container)
            // Every schema entity is counted: a receipt that omitted a
            // type could make a populated store verify as unchanged.
            var counts: [String: Int] = [:]
            counts["Recording"] = try context.fetchCount(FetchDescriptor<Recording>())
            counts["Transcript"] = try context.fetchCount(FetchDescriptor<Transcript>())
            counts["MeetingSummary"] = try context.fetchCount(FetchDescriptor<MeetingSummary>())
            counts["ExternalRecordingImport"] =
                try context.fetchCount(FetchDescriptor<ExternalRecordingImport>())
            counts["Folder"] = try context.fetchCount(FetchDescriptor<Folder>())
            counts["SpeakerProfile"] =
                try context.fetchCount(FetchDescriptor<SpeakerProfile>())
            counts["SpeakerVoiceSample"] =
                try context.fetchCount(FetchDescriptor<SpeakerVoiceSample>())
            counts["Recap"] = try context.fetchCount(FetchDescriptor<Recap>())
            counts["AgentArtifact"] =
                try context.fetchCount(FetchDescriptor<AgentArtifact>())
            counts["WebSyncRecord"] =
                try context.fetchCount(FetchDescriptor<WebSyncRecord>())
            return counts
        } catch {
            throw StoreSnapshotError.openFailed(error.localizedDescription)
        }
    }
}
