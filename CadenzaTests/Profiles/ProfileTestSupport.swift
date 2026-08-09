import Foundation
import SQLite3
import os

@testable import Cadenza

/// Test stand-in for the recoverable trash: the item moves to a unique
/// sibling path instead of the user's real Trash, so suites never write
/// outside their fixture directories while keeping the observable
/// contract (the item leaves its original path, bytes stay recoverable).
func moveToFixtureTrash(_ url: URL) throws {
    let destination = URL(fileURLWithPath: url.path + ".trashed-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: url, to: destination)
}

/// Forwarding wrapper whose only override is the trash seam; the default
/// executor fixture uses it so no test can reach the real Trash.
final class FixtureTrashFileOperations: FileOperations, Sendable {
    private let base: FileOperations

    init(base: FileOperations = LiveFileOperations()) {
        self.base = base
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(at: url)
    }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }
    func createFileExclusively(_ data: Data, at url: URL) throws {
        try base.createFileExclusively(data, at: url)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func moveItemExclusively(staging: URL, final: URL) throws {
        try base.moveItemExclusively(staging: staging, final: final)
    }
    func swapItems(at first: URL, with second: URL) throws {
        try base.swapItems(at: first, with: second)
    }
    func trashItem(at url: URL) throws { try moveToFixtureTrash(url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func read(from url: URL) throws -> Data { try base.read(from: url) }
    func sha256(of url: URL) throws -> String { try base.sha256(of: url) }
    func availableCapacity(at url: URL) throws -> Int64 {
        try base.availableCapacity(at: url)
    }
    func atomicReplace(_ data: Data, at destination: URL) throws {
        try base.atomicReplace(data, at: destination)
    }
    func noteStoreOpen(at url: URL) { base.noteStoreOpen(at: url) }
}

/// Seam double that forwards to the live implementation while recording
/// every path that crosses the seam, with optional failure injection for
/// specific file names. It audits what routes through the seam; it makes
/// no claim about IO performed by other subsystems (SQLite, SwiftData).
final class InstrumentedFileOperations: FileOperations, Sendable {
    struct Record: Sendable {
        enum Event: Sendable {
            case storeOpen(String)
            case remove(String)
            case moveSource(String)
            case swap(String)
        }

        var touchedPaths: [String] = []
        var hashedPaths: [String] = []
        var storeOpenPaths: [String] = []
        var removedPaths: [String] = []
        var moveSourcePaths: [String] = []
        var moveDestinationPaths: [String] = []
        var swapPaths: [String] = []
        var events: [Event] = []
    }

    private let base = LiveFileOperations()
    private let record = OSAllocatedUnfairLock<Record>(initialState: .init())
    private let failHashNames: Set<String>
    private let stripSizeNames: Set<String>
    private let capacityOverride: Int64?
    private let failWriteNames: Set<String>
    private let failCopyNames: Set<String>
    private let failAttributeNames: Set<String>
    private let failJournalWriteAtCount: Int?
    private let journalWriteCount = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(
        failHashNames: Set<String> = [],
        stripSizeNames: Set<String> = [],
        capacityOverride: Int64? = nil,
        failWriteNames: Set<String> = [],
        failCopyNames: Set<String> = [],
        failAttributeNames: Set<String> = [],
        failJournalWriteAtCount: Int? = nil
    ) {
        self.failHashNames = failHashNames
        self.stripSizeNames = stripSizeNames
        self.capacityOverride = capacityOverride
        self.failWriteNames = failWriteNames
        self.failCopyNames = failCopyNames
        self.failAttributeNames = failAttributeNames
        self.failJournalWriteAtCount = failJournalWriteAtCount
    }

    var recorded: Record { record.withLock { $0 } }

    private func note(_ url: URL) {
        record.withLock { $0.touchedPaths.append(url.path) }
    }

    func fileExists(at url: URL) -> Bool {
        note(url)
        return base.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        note(url)
        if failAttributeNames.contains(url.lastPathComponent) {
            throw CocoaError(.fileReadNoPermission)
        }
        var attributes = try base.attributesOfItem(at: url)
        if stripSizeNames.contains(url.lastPathComponent) {
            attributes.removeValue(forKey: .size)
        }
        return attributes
    }

    func createDirectory(at url: URL) throws {
        note(url)
        try base.createDirectory(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        note(source)
        note(destination)
        if failCopyNames.contains(destination.lastPathComponent) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try base.copyItem(at: source, to: destination)
    }

    func createFileExclusively(_ data: Data, at url: URL) throws {
        note(url)
        try base.createFileExclusively(data, at: url)
    }

    func removeItem(at url: URL) throws {
        note(url)
        record.withLock {
            $0.removedPaths.append(url.path)
            $0.events.append(.remove(url.path))
        }
        try base.removeItem(at: url)
    }

    func moveItemExclusively(staging: URL, final: URL) throws {
        note(staging)
        note(final)
        record.withLock {
            $0.moveSourcePaths.append(staging.path)
            $0.moveDestinationPaths.append(final.path)
            $0.events.append(.moveSource(staging.path))
        }
        try base.moveItemExclusively(staging: staging, final: final)
    }

    func swapItems(at first: URL, with second: URL) throws {
        note(first)
        note(second)
        record.withLock {
            $0.swapPaths.append(first.path)
            $0.swapPaths.append(second.path)
            $0.events.append(.swap(first.path))
            $0.events.append(.swap(second.path))
        }
        try base.swapItems(at: first, with: second)
    }

    func trashItem(at url: URL) throws {
        try moveToFixtureTrash(url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        note(url)
        return try base.contentsOfDirectory(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        note(url)
        if failWriteNames.contains(url.lastPathComponent) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try base.write(data, to: url)
    }

    func read(from url: URL) throws -> Data {
        note(url)
        return try base.read(from: url)
    }

    func sha256(of url: URL) throws -> String {
        note(url)
        record.withLock { $0.hashedPaths.append(url.path) }
        if failHashNames.contains(url.lastPathComponent) {
            throw FileOperationError.hashFailed(url.lastPathComponent)
        }
        return try base.sha256(of: url)
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        note(url)
        if let capacityOverride { return capacityOverride }
        return try base.availableCapacity(at: url)
    }

    func atomicReplace(_ data: Data, at destination: URL) throws {
        note(destination)
        if failWriteNames.contains(destination.lastPathComponent) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        // Boundary-interruption injection: dying at the Nth journal write
        // reproduces a crash at exactly that state transition.
        if destination.lastPathComponent == "journal.json", let failJournalWriteAtCount {
            let count = journalWriteCount.withLock { count -> Int in
                count += 1
                return count
            }
            if count == failJournalWriteAtCount {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        try base.atomicReplace(data, at: destination)
    }

    func noteStoreOpen(at url: URL) {
        record.withLock {
            $0.storeOpenPaths.append(url.path)
            $0.events.append(.storeOpen(url.path))
        }
    }
}

/// Seam double that fails `moveItemExclusively` once for each configured
/// SOURCE file name — the shape of a crash at that exact rename boundary.
final class FailingRenameFileOperations: FileOperations, Sendable {
    private let base = LiveFileOperations()
    private let remaining: OSAllocatedUnfairLock<Set<String>>

    init(failSourceNames: Set<String>) {
        remaining = OSAllocatedUnfairLock(initialState: failSourceNames)
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(at: url)
    }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }
    func createFileExclusively(_ data: Data, at url: URL) throws {
        try base.createFileExclusively(data, at: url)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func moveItemExclusively(staging: URL, final: URL) throws {
        let shouldFail = remaining.withLock { names -> Bool in
            names.remove(staging.lastPathComponent) != nil
        }
        if shouldFail { throw FileOperationError.renameFailed(errno: EIO) }
        try base.moveItemExclusively(staging: staging, final: final)
    }

    func swapItems(at first: URL, with second: URL) throws {
        try base.swapItems(at: first, with: second)
    }

    func trashItem(at url: URL) throws {
        try moveToFixtureTrash(url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func read(from url: URL) throws -> Data { try base.read(from: url) }
    func sha256(of url: URL) throws -> String { try base.sha256(of: url) }
    func availableCapacity(at url: URL) throws -> Int64 {
        try base.availableCapacity(at: url)
    }
    func atomicReplace(_ data: Data, at destination: URL) throws {
        try base.atomicReplace(data, at: destination)
    }
    func noteStoreOpen(at url: URL) {}
}

/// Seam double that probes SQLite lock state immediately before a database
/// path is renamed or swapped.
final class WriterProbeFileOperations: FileOperations, Sendable {
    enum ProbeResult: Sendable, Equatable {
        case busy
        case acquired
        case openFailed
    }

    private let base = LiveFileOperations()
    private let probePath: String
    private let results = OSAllocatedUnfairLock<[ProbeResult]>(initialState: [])

    init(probePath: String) {
        self.probePath = probePath
    }

    var probeResults: [ProbeResult] { results.withLock { $0 } }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributesOfItem(at: url)
    }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }
    func createFileExclusively(_ data: Data, at url: URL) throws {
        try base.createFileExclusively(data, at: url)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func moveItemExclusively(staging: URL, final: URL) throws {
        probeIfNeeded(staging)
        try base.moveItemExclusively(staging: staging, final: final)
    }

    func swapItems(at first: URL, with second: URL) throws {
        probeIfNeeded(first)
        probeIfNeeded(second)
        try base.swapItems(at: first, with: second)
    }

    private func probeIfNeeded(_ url: URL) {
        guard url.path == probePath else { return }
        var db: OpaquePointer?
        if sqlite3_open_v2(probePath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 0)
            let begin = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            let outcome: ProbeResult =
                (begin == SQLITE_BUSY || begin == SQLITE_LOCKED) ? .busy : .acquired
            if begin == SQLITE_OK { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            results.withLock { $0.append(outcome) }
        } else {
            results.withLock { $0.append(.openFailed) }
        }
        sqlite3_close(db)
    }

    func trashItem(at url: URL) throws {
        try moveToFixtureTrash(url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func read(from url: URL) throws -> Data { try base.read(from: url) }
    func sha256(of url: URL) throws -> String { try base.sha256(of: url) }
    func availableCapacity(at url: URL) throws -> Int64 {
        try base.availableCapacity(at: url)
    }
    func atomicReplace(_ data: Data, at destination: URL) throws {
        try base.atomicReplace(data, at: destination)
    }
    func noteStoreOpen(at url: URL) {}
}

/// Backup driver double that always fails, standing in for mid-backup
/// ENOSPC/IOERR conditions.
struct FailingSQLiteBackupDriver: SQLiteBackupDriver {
    func consistentBackup(source: URL, destination: URL) throws {
        throw SQLiteBackupError.backupFailed("injected failure")
    }
}

/// Backup driver double that forwards to the live driver while recording
/// each (source, destination) pair.
final class AuditingSQLiteBackupDriver: SQLiteBackupDriver, Sendable {
    struct BackupCall: Sendable, Equatable {
        var source: String
        var destination: String
    }

    private let live = LiveSQLiteBackupDriver()
    private let record = OSAllocatedUnfairLock<[BackupCall]>(initialState: [])

    var calls: [BackupCall] { record.withLock { $0 } }

    func consistentBackup(source: URL, destination: URL) throws {
        record.withLock { $0.append(.init(source: source.path, destination: destination.path)) }
        try live.consistentBackup(source: source, destination: destination)
    }
}

/// Valid v1 pending-transfer record whose frozen evidence is captured
/// from the given rows.
func makeTestPendingTransfer(
    source: Profile,
    target: Profile,
    mode: PendingTransfer.Mode = .copy,
    state: PendingTransfer.State = .initiated,
    startedAt: Date = Date(timeIntervalSince1970: 1_785_700_000)
) -> PendingTransfer {
    PendingTransfer(
        version: 1,
        transactionID: UUID(),
        placementClaimToken: UUID(),
        sourceProfileID: source.id,
        targetProfileID: target.id,
        mode: mode,
        state: state,
        startedAt: startedAt,
        sourceEvidence: .init(profile: source),
        targetEvidence: .init(profile: target)
    )
}
