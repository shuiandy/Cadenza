import CryptoKit
import Foundation

/// Every filesystem touch the migration performs goes through this seam:
/// tests inject failures (mid-operation ENOSPC) and audit the full set of
/// paths an operation reached. The seam includes hashing, node
/// enumeration, and a store-open notice, so the audit claim covers the
/// whole migration surface rather than a subset of calls.
protocol FileOperations: Sendable {
    func fileExists(at url: URL) -> Bool
    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any]
    func createDirectory(at url: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func createFileExclusively(_ data: Data, at url: URL) throws
    func removeItem(at url: URL) throws
    func moveItemExclusively(staging: URL, final: URL) throws
    /// Same-volume atomic content swap of two existing paths (RENAME_SWAP
    /// semantics), parents fsynced. Neither path is ever absent.
    func swapItems(at first: URL, with second: URL) throws
    /// Recoverable removal through the system trash; failures surface so
    /// callers can retain the item instead.
    func trashItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func write(_ data: Data, to url: URL) throws
    func read(from url: URL) throws -> Data
    func sha256(of url: URL) throws -> String
    /// Free bytes on the volume containing `url` (important-usage figure).
    func availableCapacity(at url: URL) throws -> Int64
    /// Atomic replace: exclusive temp sibling created 0o600 + fsync(file)
    /// + rename(2) + fsync(parent directory).
    func atomicReplace(_ data: Data, at destination: URL) throws
    /// Audit notice for database opens the seam cannot mediate directly
    /// (SwiftData/SQLite open their files internally).
    func noteStoreOpen(at url: URL)
}

enum FileOperationError: Error, Equatable {
    case createFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case syncFailed(errno: Int32)
    case renameFailed(errno: Int32)
    case parentSyncFailed(errno: Int32)
    case openFailed(String)
    case hashFailed(String)
    case symlinkRejected(String)
    case capacityUnavailable(String)
}

struct LiveFileOperations: FileOperations {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func createFileExclusively(_ data: Data, at url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            } ?? -1
        }
        guard fd >= 0 else {
            throw FileOperationError.createFailed(errno: errno)
        }
        var closed = false
        var contentComplete = false
        func closeOnce() -> Bool {
            if closed { return true }
            closed = true
            return close(fd) == 0
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Foundation.write(
                        fd, raw.baseAddress! + offset, raw.count - offset
                    )
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else {
                        throw FileOperationError.writeFailed(errno: errno)
                    }
                    offset += written
                }
            }
            guard fcntl(fd, F_FULLFSYNC, 0) >= 0 || fsync(fd) >= 0 else {
                throw FileOperationError.syncFailed(errno: errno)
            }
            guard closeOnce() else {
                throw FileOperationError.syncFailed(errno: errno)
            }
            contentComplete = true
            try syncDirectory(url.deletingLastPathComponent())
        } catch {
            _ = closeOnce()
            if !contentComplete {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Exclusive rename plus durability: both parent directory entries are
    /// synced so neither the disappearance from the source directory nor
    /// the appearance in the destination directory can be lost.
    func moveItemExclusively(staging: URL, final: URL) throws {
        let result = staging.withUnsafeFileSystemRepresentation { stagingPath in
            final.withUnsafeFileSystemRepresentation { finalPath in
                renamex_np(stagingPath, finalPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw FileOperationError.renameFailed(errno: errno)
        }
        let sourceParent = staging.deletingLastPathComponent()
        let destinationParent = final.deletingLastPathComponent()
        try syncDirectory(destinationParent)
        if sourceParent.path != destinationParent.path {
            try syncDirectory(sourceParent)
        }
    }

    func swapItems(at first: URL, with second: URL) throws {
        let result = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw FileOperationError.renameFailed(errno: errno)
        }
        let firstParent = first.deletingLastPathComponent()
        let secondParent = second.deletingLastPathComponent()
        try syncDirectory(firstParent)
        if firstParent.path != secondParent.path {
            try syncDirectory(secondParent)
        }
    }

    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: []
        )
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [])
    }

    /// Reads without following a symlink at the target — a link swapped in
    /// after a caller's lstat check must fail the open, not read the
    /// link's destination.
    func read(from url: URL) throws -> Data {
        let fd = try openNoFollow(url, flags: O_RDONLY)
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = readRetryingInterrupts(fd, &buffer)
            if count == 0 { break }
            guard count > 0 else {
                throw FileOperationError.openFailed(url.lastPathComponent)
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Streaming hash with the same no-follow open as `read`.
    func sha256(of url: URL) throws -> String {
        let fd: Int32
        do {
            fd = try openNoFollow(url, flags: O_RDONLY)
        } catch {
            throw FileOperationError.hashFailed(url.lastPathComponent)
        }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = readRetryingInterrupts(fd, &buffer)
            if count == 0 { break }
            guard count > 0 else {
                throw FileOperationError.hashFailed(url.lastPathComponent)
            }
            buffer.withUnsafeBytes { hasher.update(data: Data($0[0..<count])) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw FileOperationError.capacityUnavailable(url.path)
        }
        return capacity
    }

    /// The temp file is born 0o600 via open(2) mode — there is no window
    /// with wider permissions — and is exclusive (O_EXCL) and never a
    /// symlink target (O_NOFOLLOW). The descriptor closes exactly once, a
    /// failed close counts as a persistence failure (the data may not have
    /// reached the file), and interrupted writes retry.
    func atomicReplace(_ data: Data, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".atomic-\(UUID().uuidString).tmp")
        let fd = temp.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard fd >= 0 else {
            throw FileOperationError.createFailed(errno: errno)
        }
        var fdClosed = false
        func closeOnce() -> Bool {
            if fdClosed { return true }
            fdClosed = true
            return close(fd) == 0
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else {
                        throw FileOperationError.writeFailed(errno: errno)
                    }
                    offset += written
                }
            }
            guard fcntl(fd, F_FULLFSYNC, 0) >= 0 || fsync(fd) >= 0 else {
                throw FileOperationError.syncFailed(errno: errno)
            }
            guard closeOnce() else {
                throw FileOperationError.syncFailed(errno: errno)
            }
            let renameResult = temp.withUnsafeFileSystemRepresentation { tempPath in
                destination.withUnsafeFileSystemRepresentation { finalPath in
                    rename(tempPath, finalPath)
                }
            }
            guard renameResult == 0 else {
                throw FileOperationError.renameFailed(errno: errno)
            }
            try syncDirectory(directory)
        } catch {
            _ = closeOnce()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    func noteStoreOpen(at url: URL) {}

    /// read(2) with EINTR retry; other outcomes pass through.
    private func readRetryingInterrupts(_ fd: Int32, _ buffer: inout [UInt8]) -> Int {
        while true {
            let count = Foundation.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            return count
        }
    }

    private func openNoFollow(_ url: URL, flags: Int32) throws -> Int32 {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, flags | O_NOFOLLOW | O_CLOEXEC, 0) } ?? -1
        }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw FileOperationError.symlinkRejected(url.lastPathComponent)
            }
            throw FileOperationError.openFailed(url.lastPathComponent)
        }
        return fd
    }

    /// The rename is durable only once the parent directory entry is synced.
    private func syncDirectory(_ directory: URL) throws {
        let fd = directory.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY, 0) } ?? -1
        }
        guard fd >= 0 else {
            throw FileOperationError.parentSyncFailed(errno: errno)
        }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC, 0) >= 0 || fsync(fd) >= 0 else {
            throw FileOperationError.parentSyncFailed(errno: errno)
        }
    }
}

/// Shared trusted-root probe for Migration/ artifacts: the directory must
/// be a real directory (lstat semantics), never a link — an atomic
/// replace would otherwise write through a redirected parent. Definite
/// absence passes (creation follows); anything else throws.
func requireTrustedMigrationRoot(
    at url: URL, fileOperations: FileOperations
) throws {
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try fileOperations.attributesOfItem(at: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return
    }
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw FileOperationError.symlinkRejected(url.lastPathComponent)
    }
}

/// Shared lstat helper: known migration inputs must be regular files, never
/// symlinks (fail-closed before any open follows a link).
func requireRegularFile(
    at url: URL, fileOperations: FileOperations
) throws {
    let attributes = try fileOperations.attributesOfItem(at: url)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw FileOperationError.symlinkRejected(url.lastPathComponent)
    }
}
