import Foundation
import SQLite3
import Testing
@testable import Cadenza

@Suite("SQLite free-page reclaim")
struct SQLiteStoreMaintenanceTests {

    /// Builds a database with `auto_vacuum=INCREMENTAL` (SwiftData's mode),
    /// fills it, then deletes everything so the pages sit on the freelist.
    private func makeBloatedDatabase(rows: Int, incremental: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, Comment(rawValue: sql))
        }
        // auto_vacuum must be chosen before the first table exists.
        exec("PRAGMA auto_vacuum=\(incremental ? "INCREMENTAL" : "NONE")")
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE payload(id INTEGER PRIMARY KEY, blob BLOB)")
        exec("BEGIN")
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO payload(blob) VALUES (zeroblob(8192))", -1, &statement, nil) == SQLITE_OK)
        for _ in 0..<rows {
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_reset(statement)
        }
        sqlite3_finalize(statement)
        exec("COMMIT")
        exec("DELETE FROM payload")
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    @Test func reclaimsFreePagesAndShrinksTheFile() throws {
        // ~3000 x 8 KB rows: about 6000 free pages at 4 KB, above the minimum.
        let url = try makeBloatedDatabase(rows: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let sizeBefore = try fileSize(url)

        let outcome = try #require(try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(at: url))
        #expect(outcome.freePagesBefore >= SQLiteStoreMaintenance.minimumFreePages)
        #expect(outcome.freePagesAfter == 0)
        #expect(outcome.reclaimedBytes > 0)
        #expect(try fileSize(url) < sizeBefore / 4)

        // Second call: nothing left to do.
        #expect(try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(at: url) == nil)
    }

    @Test func respectsThePerCallPageCap() throws {
        let url = try makeBloatedDatabase(rows: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try #require(try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(
            at: url, maximumPages: 1000
        ))
        #expect(outcome.freePagesBefore - outcome.freePagesAfter <= 1000)
        #expect(outcome.freePagesAfter > 0)
    }

    @Test func smallFreelistsAndNonIncrementalStoresAreLeftAlone() throws {
        let small = try makeBloatedDatabase(rows: 20)
        defer { try? FileManager.default.removeItem(at: small) }
        #expect(try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(at: small) == nil)

        let none = try makeBloatedDatabase(rows: 3000, incremental: false)
        defer { try? FileManager.default.removeItem(at: none) }
        #expect(try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(at: none) == nil)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        #expect(try SQLiteStoreMaintenance.reclaimFreePagesIfNeeded(at: missing) == nil)
    }
}
