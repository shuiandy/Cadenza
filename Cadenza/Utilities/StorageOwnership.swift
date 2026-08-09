import Darwin
import Foundation

struct SegmentObjectIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64

    init(_ fileStatus: stat) {
        device = UInt64(fileStatus.st_dev)
        inode = UInt64(fileStatus.st_ino)
        size = Int64(fileStatus.st_size)
    }

    func matches(_ fileStatus: stat, includingSize: Bool) -> Bool {
        device == UInt64(fileStatus.st_dev)
            && inode == UInt64(fileStatus.st_ino)
            && (!includingSize || size == Int64(fileStatus.st_size))
    }
}

/// Capability for one explicitly supplied recording-storage root. The token
/// binds the opened root's device/inode identity; persisted child paths never
/// mint authority on their own.
struct SegmentStorageAuthority: Sendable {
    let declaredRootURL: URL
    let openedRootURL: URL
    let rootIdentity: SegmentObjectIdentity

    private init(
        declaredRootURL: URL,
        openedRootURL: URL,
        rootIdentity: SegmentObjectIdentity
    ) {
        self.declaredRootURL = declaredRootURL
        self.openedRootURL = openedRootURL
        self.rootIdentity = rootIdentity
    }

    static func authorize(root: URL) -> Self? {
        let declaredRootURL = root.standardizedFileURL
        let openedRootURL = declaredRootURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(
            openedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              Self.isDirectory(fileStatus) else { return nil }
        return Self(
            declaredRootURL: declaredRootURL,
            openedRootURL: openedRootURL,
            rootIdentity: SegmentObjectIdentity(fileStatus)
        )
    }

    func expectedSegmentsDirectory(recordingID: UUID) -> URL {
        declaredRootURL
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    func authorizes(segmentsDirectory: URL, recordingID: UUID) -> Bool {
        segmentsDirectory.standardizedFileURL.path
            == expectedSegmentsDirectory(recordingID: recordingID).standardizedFileURL.path
    }

    private static func isDirectory(_ fileStatus: stat) -> Bool {
        fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
}

struct StorageUsageSnapshot: Sendable, Equatable {
    let ownedBytes: Int64
    let externalBytes: Int64
    let ownedFileCount: Int
    let externalFileCount: Int

    static let empty = StorageUsageSnapshot(
        ownedBytes: 0,
        externalBytes: 0,
        ownedFileCount: 0,
        externalFileCount: 0
    )
}

enum StorageImportDisposition: Sendable, Equatable {
    case rejectInvalidSource
    case reuseOwnedFile
    case copyIntoStorage
    case transcodeIntoStorage
}

struct StorageImportPlan: Sendable, Equatable {
    let sourceURL: URL
    let disposition: StorageImportDisposition
}

enum StorageOwnershipError: Error, LocalizedError, Sendable, Equatable {
    case posix(operation: String, code: Int32)
    case sourceNotRegularFile
    case destinationNotRegularFile
    case copiedSizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .sourceNotRegularFile:
            return "Import source is not a regular file"
        case .destinationNotRegularFile:
            return "Import destination is not a regular file"
        case .copiedSizeMismatch(let expected, let actual):
            return "Copied file size mismatch: expected \(expected) bytes, got \(actual)"
        }
    }
}

struct StorageQuotaStatus: Sendable, Equatable {
    let usage: StorageUsageSnapshot
    let limitBytes: Int64?

    /// Converts the persisted whole-megabyte setting into its byte limit.
    /// Non-positive values mean unlimited; positive overflow clamps to the maximum ceiling.
    static func limitBytes(fromMegabytes limitMegabytes: Int) -> Int64? {
        guard limitMegabytes > 0 else { return nil }
        let megabytes = Int64(clamping: limitMegabytes)
        let (bytes, overflow) = megabytes.multipliedReportingOverflow(by: 1_024 * 1_024)
        return overflow ? .max : bytes
    }

    var isOverLimit: Bool {
        guard let limitBytes, limitBytes > 0 else { return false }
        return usage.ownedBytes > limitBytes
    }

}

enum StorageQuotaAdvisory: Sendable, Equatable {
    case none
    case externalFilesExcluded
    case reviewRequired
}

extension StorageQuotaStatus {
    var advisory: StorageQuotaAdvisory {
        if isOverLimit { return .reviewRequired }
        if usage.externalBytes > 0 { return .externalFilesExcluded }
        return .none
    }
}

enum StorageOwnership {
    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func canonicalImportSource(_ sourceURL: URL) -> URL? {
        guard let source = reachableCanonicalURL(sourceURL),
              source.isRegularFile else { return nil }
        return source.url
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        guard let canonicalRoot = reachableCanonicalURL(root),
              canonicalRoot.isDirectory,
              let canonicalCandidate = reachableCanonicalURL(candidate) else { return false }
        let rootComponents = canonicalRoot.url.pathComponents
        let candidateComponents = canonicalCandidate.url.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return candidateComponents.starts(with: rootComponents)
    }

    static func importPlan(for sourceURL: URL, storageRoot: URL) -> StorageImportPlan? {
        guard let canonicalSource = canonicalImportSource(sourceURL) else { return nil }

        let disposition: StorageImportDisposition
        if canonicalSource.pathExtension.lowercased() != "m4a" {
            disposition = .transcodeIntoStorage
        } else if contains(canonicalSource, in: storageRoot) {
            disposition = .reuseOwnedFile
        } else {
            disposition = .copyIntoStorage
        }

        return StorageImportPlan(sourceURL: canonicalSource, disposition: disposition)
    }

    static func importDisposition(for sourceURL: URL, storageRoot: URL) -> StorageImportDisposition {
        importPlan(for: sourceURL, storageRoot: storageRoot)?.disposition ?? .rejectInvalidSource
    }

    static func copyRegularFile(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceFD = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw StorageOwnershipError.posix(operation: "Opening import source", code: errno)
        }
        defer { _ = Darwin.close(sourceFD) }

        var sourceStatus = stat()
        guard Darwin.fstat(sourceFD, &sourceStatus) == 0 else {
            throw StorageOwnershipError.posix(operation: "Inspecting import source", code: errno)
        }
        guard isRegularFile(sourceStatus) else {
            throw StorageOwnershipError.sourceNotRegularFile
        }

        let destinationFD = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationFD >= 0 else {
            throw StorageOwnershipError.posix(operation: "Creating import destination", code: errno)
        }

        var copySucceeded = false
        defer {
            _ = Darwin.close(destinationFD)
            if !copySucceeded {
                _ = Darwin.unlink(destinationURL.path)
            }
        }

        var destinationStatus = stat()
        guard Darwin.fstat(destinationFD, &destinationStatus) == 0 else {
            throw StorageOwnershipError.posix(operation: "Inspecting import destination", code: errno)
        }
        guard isRegularFile(destinationStatus) else {
            throw StorageOwnershipError.destinationNotRegularFile
        }

        guard fcopyfile(sourceFD, destinationFD, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw StorageOwnershipError.posix(operation: "Copying import data", code: errno)
        }
        guard Darwin.fsync(destinationFD) == 0 else {
            throw StorageOwnershipError.posix(operation: "Syncing import destination", code: errno)
        }
        guard Darwin.fstat(destinationFD, &destinationStatus) == 0 else {
            throw StorageOwnershipError.posix(operation: "Verifying import destination", code: errno)
        }
        guard isRegularFile(destinationStatus) else {
            throw StorageOwnershipError.destinationNotRegularFile
        }
        guard destinationStatus.st_size == sourceStatus.st_size else {
            throw StorageOwnershipError.copiedSizeMismatch(
                expected: Int64(sourceStatus.st_size),
                actual: Int64(destinationStatus.st_size)
            )
        }

        copySucceeded = true
    }

    static func measureUsage(
        in root: URL,
        ownedFiles: [URL],
        ownedDirectories: [URL]
    ) -> StorageUsageSnapshot {
        let canonicalRoot = canonicalURL(root)
        let filePaths = Set(ownedFiles
            .map(canonicalURL)
            .filter { contains($0, in: canonicalRoot) }
            .map(\.path))
        let directories = Array(Set(ownedDirectories
            .map(canonicalURL)
            .filter { contains($0, in: canonicalRoot) }
            .map(\.path)))
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        var ownedBytes: Int64 = 0
        var externalBytes: Int64 = 0
        var ownedFileCount = 0
        var externalFileCount = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let canonicalFile = canonicalURL(fileURL)
            let isOwned = filePaths.contains(canonicalFile.path)
                || directories.contains { contains(canonicalFile, in: $0) }
            let size = Int64(values.fileSize ?? 0)
            if isOwned {
                ownedBytes += size
                ownedFileCount += 1
            } else {
                externalBytes += size
                externalFileCount += 1
            }
        }

        return StorageUsageSnapshot(
            ownedBytes: ownedBytes,
            externalBytes: externalBytes,
            ownedFileCount: ownedFileCount,
            externalFileCount: externalFileCount
        )
    }

    private static func reachableCanonicalURL(
        _ url: URL
    ) -> (url: URL, isRegularFile: Bool, isDirectory: Bool)? {
        let canonical = canonicalURL(url)
        guard FileManager.default.fileExists(atPath: canonical.path) else { return nil }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? canonical.resourceValues(forKeys: keys),
              values.isSymbolicLink != true else { return nil }

        let isRegularFile = values.isRegularFile == true
        let isDirectory = values.isDirectory == true
        guard isRegularFile || isDirectory else { return nil }
        return (canonical, isRegularFile, isDirectory)
    }

    private static func isRegularFile(_ fileStatus: stat) -> Bool {
        fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}
