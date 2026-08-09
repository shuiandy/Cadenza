import Darwin
import Foundation
import os

enum DiagnosticArtifactError: Error, LocalizedError, Sendable {
    case invalidName
    case invalidLimit
    case unsafeDirectory
    case unsafeArtifact
    case reportTooLarge
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "The diagnostic artifact name is invalid."
        case .invalidLimit:
            return "The diagnostic artifact size limit is invalid."
        case .unsafeDirectory:
            return "The diagnostic directory is not a private owned directory."
        case .unsafeArtifact:
            return "The diagnostic artifact is not a private regular file."
        case .reportTooLarge:
            return "The diagnostic report exceeds its size limit."
        case .posix(let operation, let code):
            return "\(operation) failed (errno \(code))."
        }
    }
}

/// Owns privacy-sensitive diagnostic artifacts under a private app directory.
/// Files are opened relative to an identity-bound directory descriptor, with
/// no symlink following and owner-only permissions.
struct DiagnosticArtifactStore: Sendable {
    /// The app is single-process, so this lock closes both the first-create
    /// directory race and the read-size/truncate/write race between tasks.
    /// `lockf` below remains as a defense if another process opens the file.
    private static let artifactLock = OSAllocatedUnfairLock(initialState: ())

    static let legacyReportNames = [
        "cadenza_test_report.txt",
        "cadenza_quality_report.txt",
        "cadenza_speaker_memory_report.txt",
        "cadenza_system_diagnostic.txt",
    ]
    static let sessionArtifactNames = [
        "meeting-detection.log",
        "system-diagnostic.txt",
        "functional-test.txt",
        "quality-comparison.txt",
        "speaker-memory.txt",
    ]

    static let shared: Self = {
        let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return Self(
            rootDirectory: cacheRoot
                .appendingPathComponent("Cadenza-Diagnostics", isDirectory: true)
        )
    }()

    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    /// Removes the obsolete predictable temp artifact without ever following
    /// it. An attacker-created symlink is unlinked as a link; its target is not
    /// opened or modified.
    @discardableResult
    static func removeLegacyOwnedArtifact(at url: URL) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_uid == geteuid() else {
            return false
        }
        let type = status.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else { return false }
        return Darwin.unlink(url.path) == 0
    }

    static func removeLegacyArtifacts(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        meetingLogURL: URL = URL(
            fileURLWithPath: "/tmp/cadenza_meeting_diagnostics.log"
        )
    ) {
        removeLegacyOwnedArtifact(at: meetingLogURL)
        for name in legacyReportNames {
            removeLegacyOwnedArtifact(
                at: temporaryDirectory.appendingPathComponent(name)
            )
        }
    }

    func resetSessionArtifacts() {
        do {
            try Self.artifactLock.withLock { _ in
                try withPrivateDirectory { directoryFD in
                    for name in Self.sessionArtifactNames {
                        if Darwin.unlinkat(directoryFD, name, 0) != 0, errno != ENOENT {
                            throw DiagnosticArtifactError.posix(
                                operation: "Removing prior diagnostic artifact",
                                code: errno
                            )
                        }
                    }
                }
            }
        } catch {
            NSLog(
                "[DiagnosticArtifactStore] session cleanup failed: %@",
                error.localizedDescription
            )
        }
    }

    func appendLog(
        named name: String,
        data: Data,
        maximumBytes: Int
    ) throws {
        try validateFileName(name)
        guard maximumBytes > 0 else { throw DiagnosticArtifactError.invalidLimit }
        let payload = data.count > maximumBytes
            ? Data(data.prefix(maximumBytes))
            : data

        try Self.artifactLock.withLock { _ in
            try withPrivateDirectory { directoryFD in
                let fileFD = Darwin.openat(
                    directoryFD,
                    name,
                    O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    mode_t(S_IRUSR | S_IWUSR)
                )
                guard fileFD >= 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Opening diagnostic log",
                        code: errno
                    )
                }
                defer { _ = Darwin.close(fileFD) }
                guard Darwin.lockf(fileFD, F_TLOCK, 0) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Locking diagnostic log",
                        code: errno
                    )
                }
                defer { _ = Darwin.lockf(fileFD, F_ULOCK, 0) }

                var status = stat()
                guard Darwin.fstat(fileFD, &status) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Inspecting diagnostic log",
                        code: errno
                    )
                }
                try validatePrivateRegularFile(status)
                guard Darwin.fchmod(fileFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Securing diagnostic log",
                        code: errno
                    )
                }

                let projectedSize = Int64(status.st_size) + Int64(payload.count)
                if projectedSize > Int64(maximumBytes) {
                    guard Darwin.ftruncate(fileFD, 0) == 0 else {
                        throw DiagnosticArtifactError.posix(
                            operation: "Bounding diagnostic log",
                            code: errno
                        )
                    }
                }

                try writeAll(payload, to: fileFD)
            }
        }
    }

    func writeReport(
        prefix: String,
        contents: String,
        maximumBytes: Int
    ) throws -> URL {
        try validatePrefix(prefix)
        guard maximumBytes > 0 else { throw DiagnosticArtifactError.invalidLimit }
        let data = Data(contents.utf8)
        guard data.count <= maximumBytes else {
            throw DiagnosticArtifactError.reportTooLarge
        }

        return try Self.artifactLock.withLock { _ in
            try withPrivateDirectory { directoryFD in
                let fileName = "\(prefix).txt"
                let fileFD = Darwin.openat(
                    directoryFD,
                    fileName,
                    O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    mode_t(S_IRUSR | S_IWUSR)
                )
                guard fileFD >= 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Opening diagnostic report",
                        code: errno
                    )
                }
                defer { _ = Darwin.close(fileFD) }

                var status = stat()
                guard Darwin.fstat(fileFD, &status) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Inspecting diagnostic report",
                        code: errno
                    )
                }
                try validatePrivateRegularFile(status)
                guard Darwin.fchmod(fileFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Securing diagnostic report",
                        code: errno
                    )
                }
                guard Darwin.ftruncate(fileFD, 0) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Resetting diagnostic report",
                        code: errno
                    )
                }
                try writeAll(data, to: fileFD)
                guard Darwin.fsync(fileFD) == 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Syncing diagnostic report",
                        code: errno
                    )
                }

                return rootDirectory.appendingPathComponent(fileName)
            }
        }
    }

    private func withPrivateDirectory<Value>(
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        let parent = rootDirectory.deletingLastPathComponent()
        let directoryName = rootDirectory.lastPathComponent
        try validateFileName(directoryName)

        let parentFD = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentFD >= 0 else {
            throw DiagnosticArtifactError.unsafeDirectory
        }
        defer { _ = Darwin.close(parentFD) }

        var parentStatus = stat()
        guard Darwin.fstat(parentFD, &parentStatus) == 0 else {
            throw DiagnosticArtifactError.posix(
                operation: "Inspecting diagnostic parent directory",
                code: errno
            )
        }
        guard (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              (parentStatus.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0 else {
            throw DiagnosticArtifactError.unsafeDirectory
        }

        if Darwin.mkdirat(parentFD, directoryName, mode_t(S_IRWXU)) != 0,
           errno != EEXIST {
            throw DiagnosticArtifactError.posix(
                operation: "Creating diagnostic directory",
                code: errno
            )
        }

        let directoryFD = Darwin.openat(
            parentFD,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            throw DiagnosticArtifactError.unsafeDirectory
        }
        defer { _ = Darwin.close(directoryFD) }

        var status = stat()
        guard Darwin.fstat(directoryFD, &status) == 0 else {
            throw DiagnosticArtifactError.posix(
                operation: "Inspecting diagnostic directory",
                code: errno
            )
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw DiagnosticArtifactError.unsafeDirectory
        }
        guard Darwin.fchmod(directoryFD, mode_t(S_IRWXU)) == 0 else {
            throw DiagnosticArtifactError.posix(
                operation: "Securing diagnostic directory",
                code: errno
            )
        }

        return try operation(directoryFD)
    }

    private func validatePrivateRegularFile(_ status: stat) throws {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw DiagnosticArtifactError.unsafeArtifact
        }
    }

    private func validateFileName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw DiagnosticArtifactError.invalidName
        }
    }

    private func validatePrefix(_ prefix: String) throws {
        guard !prefix.isEmpty,
              prefix.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
              }) else {
            throw DiagnosticArtifactError.invalidName
        }
    }

    private func writeAll(_ data: Data, to fileFD: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileFD,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DiagnosticArtifactError.posix(
                        operation: "Writing diagnostic artifact",
                        code: errno
                    )
                }
                guard written > 0 else {
                    throw DiagnosticArtifactError.posix(
                        operation: "Writing diagnostic artifact",
                        code: EIO
                    )
                }
                offset += written
            }
        }
    }
}
