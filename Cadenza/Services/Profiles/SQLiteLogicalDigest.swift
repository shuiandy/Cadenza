import CryptoKit
import Foundation
import SQLite3

enum SQLiteLogicalDigestError: Error {
    case openFailed(String)
    case queryFailed(String)
}

/// Deterministic digest over the LOGICAL content of a SQLite database:
/// schema plus every row of every table, in a stable order, with
/// length-prefixed, type-tagged values (no delimiter injection). Unlike a
/// file hash it is invariant under physical rewrites that preserve content
/// — WAL checkpoints in particular — which makes it the crash-stable
/// evidence for the resumed retire decision: a real write between
/// launches changes rows and therefore the digest.
enum SQLiteLogicalDigest {

    static func digest(of url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: url), &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteLogicalDigestError.openFailed(message)
        }
        defer { sqlite3_close(db) }
        // A connection that closed on another thread moments ago may still
        // be inside its close-time checkpoint, which takes a brief
        // exclusive lock; a bounded wait rides that out instead of
        // reporting the database as locked.
        sqlite3_busy_timeout(db, 5000)

        var hasher = SHA256()

        // Schema first: table names and their SQL, ordered by name.
        let tables = try query(
            db, "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name"
        ) { statement in
            (text(statement, 0), sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil : text(statement, 1))
        }
        for (name, sql) in tables {
            update(&hasher, tag: "T", bytes: Array(name.utf8))
            update(&hasher, tag: "S", bytes: Array((sql ?? "").utf8))
        }

        // Rows by rowid. Every table in these stores has a rowid; a table
        // without one fails the query and the digest fails closed. Each
        // table's row stream is bracketed by its own name marker — emitted
        // for empty tables too — so identically-encoded rows can never
        // collide across tables with compatible shapes.
        for (name, _) in tables {
            update(&hasher, tag: "B", bytes: Array(name.utf8))
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            try forEachRow(db, "SELECT * FROM \"\(escaped)\" ORDER BY rowid") { statement in
                let columns = sqlite3_column_count(statement)
                for index in 0..<columns {
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER:
                        var value = sqlite3_column_int64(statement, index)
                        update(&hasher, tag: "i", bytes: withUnsafeBytes(of: &value, Array.init))
                    case SQLITE_FLOAT:
                        var bits = sqlite3_column_double(statement, index).bitPattern
                        update(&hasher, tag: "f", bytes: withUnsafeBytes(of: &bits, Array.init))
                    case SQLITE_TEXT:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        let base = sqlite3_column_text(statement, index)
                        let bytes = base.map { pointer in
                            [UInt8](UnsafeBufferPointer(start: pointer, count: count))
                        } ?? []
                        update(&hasher, tag: "t", bytes: bytes)
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        let base = sqlite3_column_blob(statement, index)
                        let bytes = base.map { pointer in
                            [UInt8](UnsafeRawBufferPointer(start: pointer, count: count))
                        } ?? []
                        update(&hasher, tag: "b", bytes: bytes)
                    default:
                        update(&hasher, tag: "n", bytes: [])
                    }
                }
                update(&hasher, tag: "R", bytes: [])
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func update(_ hasher: inout SHA256, tag: String, bytes: [UInt8]) {
        var length = UInt64(bytes.count).littleEndian
        hasher.update(data: Data(tag.utf8))
        hasher.update(data: Data(bytes: &length, count: 8))
        hasher.update(data: Data(bytes))
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private static func query<T>(
        _ db: OpaquePointer?, _ sql: String, row: (OpaquePointer?) -> T
    ) throws -> [T] {
        var results: [T] = []
        try forEachRow(db, sql) { results.append(row($0)) }
        return results
    }

    private static func forEachRow(
        _ db: OpaquePointer?, _ sql: String, row: (OpaquePointer?) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteLogicalDigestError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteLogicalDigestError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            try row(statement)
        }
    }
}
