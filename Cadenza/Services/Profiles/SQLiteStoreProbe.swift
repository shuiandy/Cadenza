import Foundation
import SQLite3

enum SQLiteStoreProbeError: Error {
    case openFailed(String)
    case queryFailed(String)
    case corrupt(String)
}

/// Boot-time availability probe for a profile store: proves the database
/// opens and every b-tree page (tables AND indexes) is structurally sound,
/// via `PRAGMA quick_check`. This is the gate the boot path needs — "can
/// this store back a container without silent data loss" — at page-scan
/// cost instead of the content-hash cost of `SQLiteLogicalDigest`, which
/// remains the tool wherever a digest VALUE is compared or recorded
/// (migration, retire, transfer). quick_check skips only the index↔row
/// cross-checks and UNIQUE verification; the digest's row scan never read
/// index pages at all, so this probe is not the weaker check.
enum SQLiteStoreProbe {

    static func verifyReadable(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: url), &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteStoreProbeError.openFailed(message)
        }
        defer { sqlite3_close(db) }
        // Same discipline as SQLiteLogicalDigest: a connection that closed
        // on another thread moments ago may still be inside its close-time
        // checkpoint; a bounded wait rides that out.
        sqlite3_busy_timeout(db, 5000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreProbeError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        // quick_check yields one row containing "ok", or one row per
        // problem. Any other shape (no rows, step error) fails closed.
        var problems: [String] = []
        var sawRow = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteStoreProbeError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            sawRow = true
            let row = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            if row != "ok" {
                problems.append(row)
            }
        }
        guard sawRow else {
            throw SQLiteStoreProbeError.queryFailed("quick_check returned no verdict")
        }
        guard problems.isEmpty else {
            // Bounded detail: the first findings identify the damage; a
            // badly corrupt store can emit thousands of rows.
            throw SQLiteStoreProbeError.corrupt(problems.prefix(3).joined(separator: "; "))
        }
    }
}
