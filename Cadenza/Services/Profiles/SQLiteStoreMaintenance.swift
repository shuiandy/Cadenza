import Foundation
import SQLite3

enum SQLiteStoreMaintenanceError: Error {
    case openFailed(String)
    case queryFailed(String)
}

/// Returns free pages to the filesystem before the store is opened by
/// SwiftData. Deleting persistent history (or trash) frees pages inside the
/// file, but SwiftData stores run `auto_vacuum=INCREMENTAL`, which only moves
/// freed pages onto the freelist; the file, its startup backups and every
/// page-scan probe keep paying for them until `incremental_vacuum` runs.
///
/// Must run while no other connection has the store open, which is why the
/// boot path calls it right before the `ModelContainer` is created: a second
/// writer next to Core Data's own connection would contend for the write lock.
enum SQLiteStoreMaintenance {

    struct ReclaimOutcome: Equatable, Sendable {
        var pageSize: Int
        var freePagesBefore: Int
        var freePagesAfter: Int

        var reclaimedBytes: Int { (freePagesBefore - freePagesAfter) * pageSize }
    }

    /// Below this many free pages (16 MB at 4 KB pages) the work is not worth
    /// a boot-time write; daily history pruning stays under it for days.
    static let minimumFreePages = 4096
    /// Cap per call (128 MB at 4 KB pages). A months-old backlog compacts over
    /// a few launches instead of holding one launch for the whole file.
    static let maximumPagesPerCall = 32768

    /// Returns nil when nothing was done (store missing, auto_vacuum not
    /// incremental, or too few free pages). Throws only for open/query
    /// failures; callers on the boot path log and continue, a compaction
    /// problem must never block the app from opening its store.
    @discardableResult
    static func reclaimFreePagesIfNeeded(
        at url: URL,
        minimumFreePages: Int = minimumFreePages,
        maximumPages: Int = maximumPagesPerCall
    ) throws -> ReclaimOutcome? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: url), &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteStoreMaintenanceError.openFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        // 2 == INCREMENTAL. FULL (1) reclaims on its own; NONE (0) cannot.
        guard try scalar(db, "PRAGMA auto_vacuum") == 2 else { return nil }
        let freeBefore = try scalar(db, "PRAGMA freelist_count")
        guard freeBefore >= minimumFreePages else { return nil }
        let pageSize = try scalar(db, "PRAGMA page_size")

        try run(db, "PRAGMA incremental_vacuum(\(min(freeBefore, maximumPages)))")
        // Fold the vacuum's WAL frames back into the main file so the
        // reclaimed space is visible on disk, not parked in the -wal.
        try run(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        let freeAfter = try scalar(db, "PRAGMA freelist_count")
        return ReclaimOutcome(pageSize: pageSize, freePagesBefore: freeBefore, freePagesAfter: freeAfter)
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreMaintenanceError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreMaintenanceError.queryFailed("\(sql) returned no row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Steps a statement to completion, ignoring any rows it yields.
    private static func run(_ db: OpaquePointer?, _ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreMaintenanceError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else {
                throw SQLiteStoreMaintenanceError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
