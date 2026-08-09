import Foundation
import SQLite3

enum SourceFreezeError: Error, Equatable {
    case sourceBusy(String)
    case openFailed(String)
    case evidenceFailed(String)
}

/// Write-freeze over the migration source: a dedicated connection holds
/// `BEGIN IMMEDIATE` (RESERVED lock) from before the snapshot until the
/// caller releases it after the retire decision. A writer that is already
/// active fails the acquisition (fail-closed); writers arriving during the
/// window receive SQLITE_BUSY; readers — including the backup's read-only
/// connection — proceed normally. The lock dies with the connection, so
/// crash and cancellation release it automatically.
final class SourceFreezeLease {
    private var db: OpaquePointer?
    let storeURL: URL

    private init(db: OpaquePointer?, storeURL: URL) {
        self.db = db
        self.storeURL = storeURL
    }

    static func acquire(storeURL: URL, fileOperations: FileOperations) throws -> SourceFreezeLease {
        // Fail-closed on links before any open would follow one; the open
        // itself also refuses symlinks (NOFOLLOW) against races.
        do {
            try requireRegularFile(at: storeURL, fileOperations: fileOperations)
        } catch {
            throw SourceFreezeError.openFailed("not a regular file: \(storeURL.lastPathComponent)")
        }
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            sqliteNoFollowPath(for: storeURL), &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil
        )
        guard openResult == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SourceFreezeError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 0)
        let begin = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        if begin == SQLITE_BUSY || begin == SQLITE_LOCKED {
            sqlite3_close(db)
            throw SourceFreezeError.sourceBusy(storeURL.lastPathComponent)
        }
        guard begin == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "begin failed"
            sqlite3_close(db)
            throw SourceFreezeError.openFailed(message)
        }
        return SourceFreezeLease(db: db, storeURL: storeURL)
    }

    /// Makes the base file fully self-contained before the retire rename:
    /// folds every WAL frame into the base (checkpoint TRUNCATE), switches
    /// the database to rollback-journal mode — so the retired artifact
    /// opens read-only with no sidecars — and re-takes the write lock.
    /// Both steps require this connection to be effectively alone, which
    /// the production boot (before any container opens) guarantees; any
    /// interference fails closed. The lock hand-off instants are covered
    /// by the caller's logical-digest comparison afterwards.
    func prepareForRetire() throws {
        guard let db else {
            throw SourceFreezeError.openFailed("lease already released")
        }
        _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        var checkpoint: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &checkpoint, nil
        ) == SQLITE_OK else {
            _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            throw SourceFreezeError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        let checkpointResult = sqlite3_step(checkpoint)
        let blocked = checkpointResult == SQLITE_ROW ? sqlite3_column_int(checkpoint, 0) : 1
        sqlite3_finalize(checkpoint)
        guard checkpointResult == SQLITE_ROW, blocked == 0 else {
            _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            throw SourceFreezeError.sourceBusy(storeURL.lastPathComponent)
        }
        var mode: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "PRAGMA journal_mode=DELETE", -1, &mode, nil
        ) == SQLITE_OK else {
            _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            throw SourceFreezeError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        let modeResult = sqlite3_step(mode)
        let modeName = modeResult == SQLITE_ROW
            ? String(cString: sqlite3_column_text(mode, 0)).lowercased() : ""
        sqlite3_finalize(mode)
        guard modeResult == SQLITE_ROW, modeName == "delete" else {
            _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            throw SourceFreezeError.sourceBusy(storeURL.lastPathComponent)
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SourceFreezeError.sourceBusy(storeURL.lastPathComponent)
        }
    }

    func release() {
        guard let db else { return }
        _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        sqlite3_close(db)
        self.db = nil
    }

    deinit {
        release()
    }
}

/// Per-node evidence about the source trio, captured under the freeze lease
/// before the snapshot and re-verified before registry commit and before
/// retire. Distinct from `SnapshotReceipt`, which certifies the backup
/// artifact — an online backup's bytes never equal the live trio's, so the
/// source is bound by its own identity and content records.
struct SourceEvidence: Codable, Sendable, Equatable {
    struct NodeRecord: Codable, Sendable, Equatable {
        var name: String
        var device: Int
        var inode: Int
        var size: Int64
        var sha256: String
    }

    var nodes: [NodeRecord]

    /// Only the durable pair is evidence. The `-shm` sidecar is transient
    /// shared memory: every reader (including the backup's read-only
    /// connection) legitimately rewrites its read-mark region, and it
    /// carries no persistent data — including it would make the
    /// re-verification fail on our own snapshot read. The base is
    /// required; the WAL is optional but only a definite not-found may
    /// omit it — an unprobeable node must never silently drop out of the
    /// evidence.
    static func capture(
        source: StoreTrioURL, fileOperations: FileOperations
    ) throws -> SourceEvidence {
        var nodes: [NodeRecord] = []
        for (file, required) in [(source.base, true), (source.wal, false)] {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileOperations.attributesOfItem(at: file)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !required {
                continue
            } catch {
                throw SourceFreezeError.evidenceFailed(file.lastPathComponent)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = attributes[.systemNumber] as? Int,
                  let inode = attributes[.systemFileNumber] as? Int,
                  let size = attributes[.size] as? Int64 else {
                throw SourceFreezeError.evidenceFailed(file.lastPathComponent)
            }
            nodes.append(.init(
                name: file.lastPathComponent,
                device: device,
                inode: inode,
                size: size,
                sha256: try fileOperations.sha256(of: file)
            ))
        }
        return SourceEvidence(nodes: nodes)
    }

    enum Check: Equatable {
        case holds
        case changed(String)
        case unverifiable(String)
    }

    /// Re-verification with a diagnosis: callers treat anything but
    /// `.holds` as fail-safe, and the distinction between a detected
    /// change and an unverifiable state is preserved for the log.
    func check(
        for source: StoreTrioURL, fileOperations: FileOperations
    ) -> Check {
        let current: SourceEvidence
        do {
            current = try Self.capture(source: source, fileOperations: fileOperations)
        } catch {
            return .unverifiable(String(describing: error))
        }
        guard current == self else {
            let before = nodes.map(\.name).joined(separator: ",")
            let after = current.nodes.map(\.name).joined(separator: ",")
            return .changed("nodes [\(before)] -> [\(after)]")
        }
        return .holds
    }

    /// True when the trio still matches this evidence exactly.
    func stillHolds(
        for source: StoreTrioURL, fileOperations: FileOperations
    ) -> Bool {
        check(for: source, fileOperations: fileOperations) == .holds
    }
}
