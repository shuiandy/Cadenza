import Foundation
import SQLite3

enum SQLiteBackupError: Error, Equatable {
    case openFailed(String)
    case backupFailed(String)
}

/// The SQLite online-backup step behind its own seam, so tests can inject
/// mid-backup failures (ENOSPC/IOERR) and record the source and
/// destination of every backup performed.
protocol SQLiteBackupDriver: Sendable {
    /// Consistent copy of `source` into a fresh single-file database at
    /// `destination`, coherent under concurrent connections, journal
    /// contents folded in, artifact left in rollback-journal mode so
    /// read-only connections can open it without shared-memory sidecars.
    func consistentBackup(source: URL, destination: URL) throws
}

protocol SQLiteBackupStepper: Sendable {
    func step(_ backup: OpaquePointer, pages: Int32) -> Int32
    func sleep(milliseconds: Int32)
}

struct LiveSQLiteBackupStepper: SQLiteBackupStepper {
    func step(_ backup: OpaquePointer, pages: Int32) -> Int32 {
        sqlite3_backup_step(backup, pages)
    }

    func sleep(milliseconds: Int32) {
        sqlite3_sleep(milliseconds)
    }
}

/// Path handed to SQLite alongside SQLITE_OPEN_NOFOLLOW, which rejects a
/// symlink in ANY component. System directories legitimately contain links
/// (`/var` → `/private/var`), so the parent is canonicalized with
/// `realpath(3)` — `URL.resolvingSymlinksInPath()` special-cases `/var` and
/// `/tmp` and leaves them unresolved. The final component is appended
/// verbatim and stays guarded by NOFOLLOW — callers lstat it separately,
/// and this closes the swap window between that check and the open. A
/// failed canonicalization returns the original path; the subsequent open
/// then fails visibly rather than proceeding unguarded.
func sqliteNoFollowPath(for url: URL) -> String {
    let parent = url.deletingLastPathComponent().path
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    let ok = parent.withCString { realpath($0, &resolved) } != nil
    let canonicalParent: String
    if ok, let terminator = resolved.firstIndex(of: 0) {
        canonicalParent = String(
            decoding: resolved[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    } else {
        canonicalParent = parent
    }
    return (canonicalParent as NSString).appendingPathComponent(url.lastPathComponent)
}

struct LiveSQLiteBackupDriver: SQLiteBackupDriver {
    static let maximumBusyRetryCount = 5
    static let busyRetryDelayMilliseconds: Int32 = 25

    private let stepper: any SQLiteBackupStepper

    init(stepper: any SQLiteBackupStepper = LiveSQLiteBackupStepper()) {
        self.stepper = stepper
    }

    func consistentBackup(source: URL, destination: URL) throws {
        // The artifact file is born 0o600 via open(2) mode before SQLite
        // ever touches it — an empty file is a valid fresh database, so
        // SQLite adopts it and the permissions never depend on the umask.
        let created = destination.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard created >= 0 else {
            throw SQLiteBackupError.openFailed("destination create: errno \(errno)")
        }
        close(created)

        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: source), &sourceDB,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK else {
            let message = sourceDB.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(sourceDB)
            throw SQLiteBackupError.openFailed("source: \(message)")
        }
        defer { sqlite3_close(sourceDB) }

        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteNoFollowPath(for: destination), &destinationDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK else {
            let message = destinationDB.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(destinationDB)
            throw SQLiteBackupError.openFailed("destination: \(message)")
        }
        defer { sqlite3_close(destinationDB) }

        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(destinationDB)))
        }
        var busyRetryCount = 0
        var stepResult: Int32
        while true {
            stepResult = stepper.step(backup, pages: -1)
            let isTransientLock = stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED
            guard isTransientLock,
                  busyRetryCount < Self.maximumBusyRetryCount else { break }
            busyRetryCount += 1
            stepper.sleep(milliseconds: Self.busyRetryDelayMilliseconds)
        }
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let sourceMessage = sourceDB.map { String(cString: sqlite3_errmsg($0)) } ?? "-"
            let destinationMessage = destinationDB.map { String(cString: sqlite3_errmsg($0)) } ?? "-"
            throw SQLiteBackupError.backupFailed(
                "step=\(stepResult) finish=\(finishResult) source=\(sourceMessage) destination=\(destinationMessage)"
            )
        }
        // The mode switch reports the resulting mode; anything but
        // "delete" means it did not take effect.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            destinationDB, "PRAGMA journal_mode=DELETE", -1, &statement, nil
        ) == SQLITE_OK else {
            throw SQLiteBackupError.backupFailed(String(cString: sqlite3_errmsg(destinationDB)))
        }
        let modeStep = sqlite3_step(statement)
        let modeName = modeStep == SQLITE_ROW
            ? String(cString: sqlite3_column_text(statement, 0)).lowercased() : ""
        sqlite3_finalize(statement)
        guard modeStep == SQLITE_ROW, modeName == "delete" else {
            throw SQLiteBackupError.backupFailed("journal mode is \(modeName), not delete")
        }
        // The artifact must end life exactly as it was born.
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        guard (attributes?[.posixPermissions] as? Int) == 0o600 else {
            throw SQLiteBackupError.backupFailed("artifact permissions widened")
        }
    }
}
