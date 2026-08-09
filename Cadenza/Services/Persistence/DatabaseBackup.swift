import Darwin
import Foundation
import os

enum DatabaseBackupError: Error, Equatable, LocalizedError, Sendable {
    case directoryCreationFailed(String)
    case fileInspectionFailed(String, errno: Int32)
    case unsafeBackupDirectory(String)
    case unsafeArtifact(String)
    case snapshotFailed(String, cleanupFailure: String?)
    case publishFailed(String, cleanupFailure: String?)
    case rotationFailed([String])
    case postPublishMaintenanceFailed([String])
    case invalidProfileBackupDirectory(String)
    case invalidProfileRoot(String)
    case clearFailed([String])

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let reason):
            return "Could not create the backup directory: \(reason)"
        case .fileInspectionFailed(let name, let code):
            return "Could not inspect \(name): errno \(code)"
        case .unsafeBackupDirectory(let name):
            return "The backup directory is not a trusted directory: \(name)"
        case .unsafeArtifact(let name):
            return "The managed backup artifact is not a regular file: \(name)"
        case .snapshotFailed(let reason, let cleanupFailure):
            return Self.operationDescription(
                prefix: "SQLite backup failed", reason: reason, cleanupFailure: cleanupFailure
            )
        case .publishFailed(let reason, let cleanupFailure):
            return Self.operationDescription(
                prefix: "Could not publish the completed backup",
                reason: reason,
                cleanupFailure: cleanupFailure
            )
        case .rotationFailed(let failures):
            return "Backup rotation failed: \(failures.joined(separator: "; "))"
        case .postPublishMaintenanceFailed(let failures):
            return "Backup was created but maintenance failed: \(failures.joined(separator: "; "))"
        case .invalidProfileBackupDirectory(let path):
            return "Not a profile backup directory: \(path)"
        case .invalidProfileRoot(let path):
            return "Not a trusted profile root: \(path)"
        case .clearFailed(let failures):
            return "Could not clear automatic backups: \(failures.joined(separator: "; "))"
        }
    }

    private static func operationDescription(
        prefix: String,
        reason: String,
        cleanupFailure: String?
    ) -> String {
        guard let cleanupFailure else { return "\(prefix): \(reason)" }
        return "\(prefix): \(reason); staging cleanup also failed: \(cleanupFailure)"
    }
}

enum DatabaseBackupOutcome: Equatable, Sendable {
    case created(URL)
    case createdWithMaintenanceError(URL, DatabaseBackupError)
    case skippedNoSource
    case failed(DatabaseBackupError)
}

struct DatabaseBackupClearLocationOutcome: Equatable, Sendable {
    let backupsRemoved: Int
    let stagingBackupsRemoved: Int
    let managedArtifactsRemoved: Int
    let residualManagedArtifacts: [String]
    let failures: [String]

    var isComplete: Bool {
        failures.isEmpty && residualManagedArtifacts.isEmpty
    }

    static let empty = DatabaseBackupClearLocationOutcome(
        backupsRemoved: 0,
        stagingBackupsRemoved: 0,
        managedArtifactsRemoved: 0,
        residualManagedArtifacts: [],
        failures: []
    )
}

struct DatabaseBackupClearOutcome: Equatable, Sendable {
    let profile: DatabaseBackupClearLocationOutcome
    let legacy: DatabaseBackupClearLocationOutcome

    var profileBackupsRemoved: Int {
        profile.backupsRemoved
    }

    var legacyBackupsRemoved: Int {
        legacy.backupsRemoved
    }

    var totalBackupsRemoved: Int {
        profileBackupsRemoved + legacyBackupsRemoved
    }

    var totalStagingBackupsRemoved: Int {
        profile.stagingBackupsRemoved + legacy.stagingBackupsRemoved
    }

    var isComplete: Bool {
        profile.isComplete && legacy.isComplete
    }
}

enum DatabaseBackupArtifactRemovalResult: Equatable, Sendable {
    case removed
    case missing
    case failed(errno: Int32)
}

protocol DatabaseBackupArtifactRemover: Sendable {
    func remove(at url: URL) -> DatabaseBackupArtifactRemovalResult
    func remove(name: String, from directoryFD: Int32) -> DatabaseBackupArtifactRemovalResult
}

struct LiveDatabaseBackupArtifactRemover: DatabaseBackupArtifactRemover {
    func remove(at url: URL) -> DatabaseBackupArtifactRemovalResult {
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.unlink($0) } ?? -1
        }
        if result == 0 { return .removed }
        let code = errno
        return code == ENOENT ? .missing : .failed(errno: code)
    }

    func remove(name: String, from directoryFD: Int32) -> DatabaseBackupArtifactRemovalResult {
        if unlinkat(directoryFD, name, 0) == 0 { return .removed }
        let code = errno
        return code == ENOENT ? .missing : .failed(errno: code)
    }
}

enum DatabaseBackup {
    static let maxBackups = 3

    private static let managedSidecarSuffixes = ["-wal", "-shm", "-journal"]
    private static let stagingPrefix = ".cadenza-backup-staging-"
    // Within one running Cadenza process, a controlled staging artifact
    // cannot belong to another in-flight operation once this lease is held.
    // The next backup therefore reclaims crash residue immediately instead
    // of retaining a full database copy. This is not a cross-process lock.
    private static let executionLease = OSAllocatedUnfairLock(initialState: ())

    /// Back up the pre-profile Cadenza SwiftData store into its legacy
    /// backup directory. The DEBUG data-root seam still relocates every
    /// path used by this entry point.
    @discardableResult
    static func performBackup(
        didAcquireExecutionLease: (@Sendable () -> Void)? = nil
    ) -> DatabaseBackupOutcome {
        withExecutionLease(didAcquire: didAcquireExecutionLease) {
            let appSupport = DebugDataRoot.applicationSupportDirectory()
            let cadenzaStore = appSupport
                .appendingPathComponent("Cadenza", isDirectory: true)
                .appendingPathComponent("Cadenza.store")
            let defaultStore = appSupport.appendingPathComponent("default.store")

            let storeURL: URL
            if FileManager.default.fileExists(atPath: cadenzaStore.path) {
                storeURL = cadenzaStore
            } else if FileManager.default.fileExists(atPath: defaultStore.path) {
                storeURL = defaultStore
            } else {
                return .skippedNoSource
            }

            let backupDirectory = appSupport
                .appendingPathComponent("Cadenza-Backups", isDirectory: true)
            return performBackupUnlocked(
                storeURL: storeURL,
                backupDirectory: backupDirectory,
                backupDriver: LiveSQLiteBackupDriver(),
                fileOperations: LiveFileOperations(),
                artifactRemover: LiveDatabaseBackupArtifactRemover(),
                now: Date(),
                backupID: UUID()
            )
        }
    }

    /// Creates a coherent, single-file SQLite recovery artifact while the
    /// source database remains live. The driver writes to a unique staging
    /// sibling; only a completed backup is published through an exclusive
    /// rename, and rotation never runs after a snapshot or publish failure.
    @discardableResult
    static func performBackup(
        storeURL: URL,
        backupsDirectory backupDirectory: URL,
        backupDriver: any SQLiteBackupDriver = LiveSQLiteBackupDriver(),
        fileOperations: any FileOperations = LiveFileOperations(),
        artifactRemover: any DatabaseBackupArtifactRemover = LiveDatabaseBackupArtifactRemover(),
        now: Date = Date(),
        backupID: UUID = UUID(),
        didAcquireExecutionLease: (@Sendable () -> Void)? = nil
    ) -> DatabaseBackupOutcome {
        withExecutionLease(didAcquire: didAcquireExecutionLease) {
            performBackupUnlocked(
                storeURL: storeURL,
                backupDirectory: backupDirectory,
                backupDriver: backupDriver,
                fileOperations: fileOperations,
                artifactRemover: artifactRemover,
                now: now,
                backupID: backupID
            )
        }
    }

    private static func performBackupUnlocked(
        storeURL: URL,
        backupDirectory: URL,
        backupDriver: any SQLiteBackupDriver,
        fileOperations: any FileOperations,
        artifactRemover: any DatabaseBackupArtifactRemover,
        now: Date,
        backupID: UUID
    ) -> DatabaseBackupOutcome {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .skippedNoSource
        }

        do {
            try fileOperations.createDirectory(at: backupDirectory)
        } catch {
            return logFailure(.directoryCreationFailed(failureReason(error)))
        }

        do {
            guard try nodeKind(at: backupDirectory) == .directory else {
                return logFailure(.unsafeBackupDirectory(backupDirectory.lastPathComponent))
            }
        } catch let error as DatabaseBackupError {
            return logFailure(error)
        } catch {
            return logFailure(.unsafeBackupDirectory(backupDirectory.lastPathComponent))
        }

        var maintenanceFailures = garbageCollectCrashStaging(
            in: backupDirectory,
            artifactRemover: artifactRemover
        )

        let identifier = backupID.uuidString.lowercased()
        let backupName = "cadenza-\(timestamp(for: now))-\(identifier).store"
        let backupURL = backupDirectory.appendingPathComponent(backupName)
        let stagingURL = backupDirectory
            .appendingPathComponent("\(stagingPrefix)\(identifier).store")

        do {
            guard try nodeKind(at: stagingURL) == .missing else {
                return logFailure(.snapshotFailed("staging name collision", cleanupFailure: nil))
            }
            guard try nodeKind(at: backupURL) == .missing else {
                return logFailure(.publishFailed("backup name collision", cleanupFailure: nil))
            }
        } catch let error as DatabaseBackupError {
            return logFailure(error)
        } catch {
            return logFailure(.snapshotFailed(failureReason(error), cleanupFailure: nil))
        }

        do {
            try backupDriver.consistentBackup(source: storeURL, destination: stagingURL)
        } catch {
            let cleanupFailure = cleanupStagingArtifact(
                at: stagingURL,
                artifactRemover: artifactRemover
            )
            return logFailure(.snapshotFailed(
                failureReason(error),
                cleanupFailure: cleanupFailure
            ))
        }

        do {
            try fileOperations.moveItemExclusively(staging: stagingURL, final: backupURL)
        } catch {
            let cleanupFailure = cleanupStagingArtifact(
                at: stagingURL,
                artifactRemover: artifactRemover
            )
            return logFailure(.publishFailed(
                failureReason(error),
                cleanupFailure: cleanupFailure
            ))
        }

        if let cleanupFailure = cleanupStagingArtifact(
            at: stagingURL,
            artifactRemover: artifactRemover
        ) {
            maintenanceFailures.append("staging sidecars: \(cleanupFailure)")
        }
        do {
            try pruneOldBackups(
                in: backupDirectory,
                protecting: backupURL,
                artifactRemover: artifactRemover
            )
        } catch {
            maintenanceFailures.append(failureReason(error))
        }

        if maintenanceFailures.isEmpty {
            NSLog("[DatabaseBackup] created %@", backupName)
            return .created(backupURL)
        }
        let maintenanceError = DatabaseBackupError.postPublishMaintenanceFailed(
            maintenanceFailures
        )
        NSLog(
            "[DatabaseBackup] created %@ but maintenance failed: %@",
            backupName,
            maintenanceError.localizedDescription
        )
        return .createdWithMaintenanceError(backupURL, maintenanceError)
    }

    /// Removes automatic backups for exactly one trusted profile backup
    /// directory. This is intentionally not wired to UI yet. The supplied
    /// directory must equal the location derived from `paths` and
    /// `profileID`; a lookalike `.../Profiles/<UUID>/Backups` tree is not
    /// sufficient. Controlled path components are opened relative to bound
    /// directory descriptors. Only regular `cadenza-*.store` files, controlled
    /// staging artifacts, and their sidecars are unlinked, so a symlink is
    /// never followed and an unrelated file is never removed.
    @discardableResult
    static func clearAutomaticBackups(
        in backupDirectory: URL,
        for profileID: UUID,
        paths: ProfilePaths = .live(),
        artifactRemover: any DatabaseBackupArtifactRemover = LiveDatabaseBackupArtifactRemover(),
        didAcquireExecutionLease: (@Sendable () -> Void)? = nil
    ) throws -> Int {
        try withExecutionLease(didAcquire: didAcquireExecutionLease) {
            let standardized = backupDirectory.standardizedFileURL
            let expected = paths.backupsDirectory(profileID).standardizedFileURL
            guard standardized.isFileURL,
                  expected.isFileURL,
                  standardized.path == expected.path else {
                throw DatabaseBackupError.invalidProfileBackupDirectory(backupDirectory.path)
            }

            guard let directoryFD = try openProfileBackupDirectory(standardized) else {
                return 0
            }
            defer { Darwin.close(directoryFD) }

            let managed = try managedArtifactNames(
                in: directoryFD,
                includeLegacy: false,
                includeStaging: true
            )
            let outcome = removeManagedArtifacts(
                managed,
                from: directoryFD,
                includeLegacy: false,
                includeStaging: true,
                artifactRemover: artifactRemover
            )
            guard outcome.isComplete else {
                var failures = outcome.failures
                if !outcome.residualManagedArtifacts.isEmpty {
                    failures.append(
                        "residual artifacts: \(outcome.residualManagedArtifacts.joined(separator: ", "))"
                    )
                }
                throw DatabaseBackupError.clearFailed(failures)
            }
            return outcome.backupsRemoved
        }
    }

    /// Clears every Cadenza-managed automatic recovery backup that can
    /// retain data for `profileID`: the active profile directory and the
    /// pre-profile `Cadenza-Backups` sibling. Both directories and every
    /// managed entry are opened and preflighted before the first unlink, so
    /// a symlink in either location fails closed without clearing the other.
    @discardableResult
    static func clearAllAutomaticBackups(
        for profileID: UUID,
        paths: ProfilePaths = .live(),
        artifactRemover: any DatabaseBackupArtifactRemover = LiveDatabaseBackupArtifactRemover(),
        didAcquireExecutionLease: (@Sendable () -> Void)? = nil
    ) throws -> DatabaseBackupClearOutcome {
        try withExecutionLease(didAcquire: didAcquireExecutionLease) {
            let profileDirectory = paths.backupsDirectory(profileID).standardizedFileURL
            let profileFD = try openProfileBackupDirectory(profileDirectory)
            defer {
                if let profileFD { Darwin.close(profileFD) }
            }
            let legacyFD = try openLegacyBackupDirectory(paths: paths)
            defer {
                if let legacyFD { Darwin.close(legacyFD) }
            }

            // Preflight both locations before the first unlink. Static path
            // trust failures therefore remain fail-closed and all-or-nothing;
            // runtime unlink failures are returned as a structured partial
            // outcome after both directories have been attempted.
            let profileManaged = try profileFD.map {
                try managedArtifactNames(
                    in: $0,
                    includeLegacy: false,
                    includeStaging: true
                )
            } ?? []
            let legacyManaged = try legacyFD.map {
                try managedArtifactNames(
                    in: $0,
                    includeLegacy: true,
                    includeStaging: true
                )
            } ?? []

            let profileOutcome = profileFD.map {
                removeManagedArtifacts(
                    profileManaged,
                    from: $0,
                    includeLegacy: false,
                    includeStaging: true,
                    artifactRemover: artifactRemover
                )
            } ?? .empty
            let legacyOutcome = legacyFD.map {
                removeManagedArtifacts(
                    legacyManaged,
                    from: $0,
                    includeLegacy: true,
                    includeStaging: true,
                    artifactRemover: artifactRemover
                )
            } ?? .empty
            return DatabaseBackupClearOutcome(
                profile: profileOutcome,
                legacy: legacyOutcome
            )
        }
    }

    private static func managedArtifactNames(
        in directoryFD: Int32,
        includeLegacy: Bool,
        includeStaging: Bool
    ) throws -> [String] {
        let managed = try directoryEntryNames(directoryFD).filter {
            managedArtifactKind(
                $0,
                includeLegacy: includeLegacy,
                includeStaging: includeStaging
            ) != nil
        }

        for name in managed {
            var status = stat()
            guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DatabaseBackupError.fileInspectionFailed(name, errno: errno)
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw DatabaseBackupError.unsafeArtifact(name)
            }
        }
        return managed
    }

    private static func removeManagedArtifacts(
        _ managed: [String],
        from directoryFD: Int32,
        includeLegacy: Bool,
        includeStaging: Bool,
        artifactRemover: any DatabaseBackupArtifactRemover
    ) -> DatabaseBackupClearLocationOutcome {
        var backupsRemoved = 0
        var stagingBackupsRemoved = 0
        var managedArtifactsRemoved = 0
        var failures: [String] = []
        var failedBases: Set<String> = []

        let bases = managed.filter { name in
            switch managedArtifactKind(
                name,
                includeLegacy: includeLegacy,
                includeStaging: includeStaging
            ) {
            case .backupBase, .stagingBase: return true
            case .backupSidecar, .stagingSidecar, nil: return false
            }
        }

        for name in bases.sorted() {
            let kind = managedArtifactKind(
                name,
                includeLegacy: includeLegacy,
                includeStaging: includeStaging
            )
            switch artifactRemover.remove(name: name, from: directoryFD) {
            case .removed:
                managedArtifactsRemoved += 1
                if kind == .backupBase { backupsRemoved += 1 }
                if kind == .stagingBase { stagingBackupsRemoved += 1 }
            case .missing:
                break
            case .failed(let code):
                failedBases.insert(name)
                failures.append("\(name): errno \(code)")
            }
        }

        let sidecars = managed.compactMap { name -> (name: String, base: String)? in
            switch managedArtifactKind(
                name,
                includeLegacy: includeLegacy,
                includeStaging: includeStaging
            ) {
            case .backupSidecar(let base), .stagingSidecar(let base):
                return (name, base)
            case .backupBase, .stagingBase, nil:
                return nil
            }
        }
        for sidecar in sidecars.sorted(by: { $0.name < $1.name }) {
            // A failed base unlink must never leave a potentially valid raw
            // SQLite backup stripped of the WAL/SHM it may require.
            guard !failedBases.contains(sidecar.base) else { continue }
            switch artifactRemover.remove(name: sidecar.name, from: directoryFD) {
            case .removed:
                managedArtifactsRemoved += 1
            case .missing:
                break
            case .failed(let code):
                failures.append("\(sidecar.name): errno \(code)")
            }
        }

        var residual = failures.compactMap { failure in
            failure.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        do {
            residual = try directoryEntryNames(directoryFD).filter {
                managedArtifactKind(
                    $0,
                    includeLegacy: includeLegacy,
                    includeStaging: includeStaging
                ) != nil
            }.sorted()
        } catch {
            failures.append("residual scan: \(failureReason(error))")
            residual = Array(Set(residual)).sorted()
        }

        return DatabaseBackupClearLocationOutcome(
            backupsRemoved: backupsRemoved,
            stagingBackupsRemoved: stagingBackupsRemoved,
            managedArtifactsRemoved: managedArtifactsRemoved,
            residualManagedArtifacts: residual,
            failures: failures
        )
    }

    // MARK: - Rotation

    private static func pruneOldBackups(
        in directory: URL,
        protecting newBackup: URL,
        artifactRemover: any DatabaseBackupArtifactRemover
    ) throws {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: []
            )
        } catch {
            throw DatabaseBackupError.rotationFailed([failureReason(error)])
        }

        let managed = contents.filter {
            isManagedBaseName($0.lastPathComponent, includeLegacy: true)
                || managedBaseName(forSidecar: $0.lastPathComponent, includeLegacy: true) != nil
        }
        for artifact in managed {
            guard try nodeKind(at: artifact) == .regular else {
                throw DatabaseBackupError.unsafeArtifact(artifact.lastPathComponent)
            }
        }

        let bases = managed.filter {
            isManagedBaseName($0.lastPathComponent, includeLegacy: true)
        }
        let protectedName = newBackup.lastPathComponent
        let sortedOthers = try bases
            .filter { $0.lastPathComponent != protectedName }
            .map { url -> (url: URL, date: Date) in
                let values = try url.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]
                )
                guard let date = values.creationDate ?? values.contentModificationDate else {
                    throw DatabaseBackupError.rotationFailed([
                        "missing timestamp for \(url.lastPathComponent)"
                    ])
                }
                return (url, date)
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }

        let retainedNames = Set(
            [protectedName]
                + sortedOthers.prefix(maxBackups - 1).map { $0.url.lastPathComponent }
        )
        let removedBases = bases.filter { !retainedNames.contains($0.lastPathComponent) }
        var failures: [String] = []
        var failedBaseNames: Set<String> = []

        // Unlink a base before its siblings. A failed base unlink protects
        // every one of its sidecars so a potentially valid raw backup is
        // never stripped of the WAL/SHM it may need for recovery.
        for base in removedBases {
            switch artifactRemover.remove(at: base) {
            case .removed, .missing:
                break
            case .failed(let code):
                failedBaseNames.insert(base.lastPathComponent)
                failures.append("\(base.lastPathComponent): errno \(code)")
            }
        }

        let sidecars = managed.filter {
            managedBaseName(forSidecar: $0.lastPathComponent, includeLegacy: true) != nil
        }
        for sidecar in sidecars {
            guard let baseName = managedBaseName(
                forSidecar: sidecar.lastPathComponent,
                includeLegacy: true
            ), !retainedNames.contains(baseName),
              !failedBaseNames.contains(baseName) else { continue }
            switch artifactRemover.remove(at: sidecar) {
            case .removed, .missing:
                break
            case .failed(let code):
                failures.append("\(sidecar.lastPathComponent): errno \(code)")
            }
        }

        guard failures.isEmpty else {
            throw DatabaseBackupError.rotationFailed(failures)
        }
    }

    // MARK: - Artifact safety

    /// Opens each controlled suffix component relative to its already-open
    /// parent. `O_NOFOLLOW` therefore applies to `Profiles`, the profile UUID,
    /// and `Backups` independently; later enumeration and unlink are bound to
    /// the returned directory descriptor even if a path is swapped.
    private static func openProfileBackupDirectory(_ backupDirectory: URL) throws -> Int32? {
        let profileDirectory = backupDirectory.deletingLastPathComponent()
        let profilesDirectory = profileDirectory.deletingLastPathComponent()
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let profilesFD = profilesDirectory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, flags) } ?? -1
        }
        if profilesFD < 0 {
            if errno == ENOENT { return nil }
            throw DatabaseBackupError.unsafeBackupDirectory(profilesDirectory.lastPathComponent)
        }
        defer { Darwin.close(profilesFD) }

        let profileName = profileDirectory.lastPathComponent
        let profileFD = openat(profilesFD, profileName, flags)
        if profileFD < 0 {
            if errno == ENOENT { return nil }
            throw DatabaseBackupError.unsafeBackupDirectory(profileName)
        }
        defer { Darwin.close(profileFD) }

        let backupFD = openat(profileFD, backupDirectory.lastPathComponent, flags)
        if backupFD < 0 {
            if errno == ENOENT { return nil }
            throw DatabaseBackupError.unsafeBackupDirectory(backupDirectory.lastPathComponent)
        }
        return backupFD
    }

    /// The pre-profile backup directory is a sibling of the trusted Cadenza
    /// root (`<Application Support>/Cadenza-Backups`). Its location is never
    /// accepted from a caller. The Application Support directory is bound
    /// first and the legacy child is then opened relative to that descriptor.
    private static func openLegacyBackupDirectory(paths: ProfilePaths) throws -> Int32? {
        let root = paths.root.standardizedFileURL
        guard root.isFileURL, root.lastPathComponent == "Cadenza" else {
            throw DatabaseBackupError.invalidProfileRoot(paths.root.path)
        }
        let appSupportDirectory = root.deletingLastPathComponent()
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let appSupportFD = appSupportDirectory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, flags) } ?? -1
        }
        if appSupportFD < 0 {
            if errno == ENOENT { return nil }
            throw DatabaseBackupError.unsafeBackupDirectory(
                appSupportDirectory.lastPathComponent
            )
        }
        defer { Darwin.close(appSupportFD) }

        let legacyName = "Cadenza-Backups"
        let legacyFD = openat(appSupportFD, legacyName, flags)
        if legacyFD < 0 {
            if errno == ENOENT { return nil }
            throw DatabaseBackupError.unsafeBackupDirectory(legacyName)
        }
        return legacyFD
    }

    private static func directoryEntryNames(_ directoryFD: Int32) throws -> [String] {
        // `dup` would share the directory stream offset with the bound FD,
        // making a second scan appear empty. Opening `.` produces a fresh
        // file description while remaining anchored to the trusted FD.
        let scanFD = openat(
            directoryFD,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard scanFD >= 0 else {
            throw DatabaseBackupError.clearFailed(["directory reopen: errno \(errno)"])
        }
        guard let directory = fdopendir(scanFD) else {
            let code = errno
            Darwin.close(scanFD)
            throw DatabaseBackupError.clearFailed(["directory scan: errno \(code)"])
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw DatabaseBackupError.clearFailed(["directory scan: errno \(errno)"])
        }
        return names
    }

    private enum NodeKind: Equatable {
        case missing
        case regular
        case directory
        case symbolicLink
        case other
    }

    private static func nodeKind(at url: URL) throws -> NodeKind {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &status) } ?? -1
        }
        if result == 0 {
            switch status.st_mode & S_IFMT {
            case S_IFREG: return .regular
            case S_IFDIR: return .directory
            case S_IFLNK: return .symbolicLink
            default: return .other
            }
        }
        let code = errno
        if code == ENOENT { return .missing }
        throw DatabaseBackupError.fileInspectionFailed(url.lastPathComponent, errno: code)
    }

    private static func garbageCollectCrashStaging(
        in directory: URL,
        artifactRemover: any DatabaseBackupArtifactRemover
    ) -> [String] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return ["staging scan: \(failureReason(error))"]
        }

        var groups: [String: [URL]] = [:]
        for artifact in contents {
            let name = artifact.lastPathComponent
            let baseName: String?
            switch managedArtifactKind(
                name,
                includeLegacy: false,
                includeStaging: true
            ) {
            case .stagingBase:
                baseName = name
            case .stagingSidecar(let base):
                baseName = base
            case .backupBase, .backupSidecar, nil:
                baseName = nil
            }
            if let baseName { groups[baseName, default: []].append(artifact) }
        }

        var failures: [String] = []
        for baseName in groups.keys.sorted() {
            guard let artifacts = groups[baseName] else { continue }
            var isSafe = true
            for artifact in artifacts {
                do {
                    guard try nodeKind(at: artifact) == .regular else {
                        failures.append("unsafe staging artifact \(artifact.lastPathComponent)")
                        isSafe = false
                        continue
                    }
                } catch {
                    failures.append(failureReason(error))
                    isSafe = false
                }
            }
            guard isSafe else { continue }

            let baseURL = directory.appendingPathComponent(baseName)
            let baseExists = artifacts.contains { $0.lastPathComponent == baseName }
            if baseExists {
                switch artifactRemover.remove(at: baseURL) {
                case .removed, .missing:
                    break
                case .failed(let code):
                    failures.append("\(baseName): errno \(code)")
                    continue
                }
            }
            for artifact in artifacts where artifact.lastPathComponent != baseName {
                switch artifactRemover.remove(at: artifact) {
                case .removed, .missing:
                    break
                case .failed(let code):
                    failures.append("\(artifact.lastPathComponent): errno \(code)")
                }
            }
        }
        return failures
    }

    private static func cleanupStagingArtifact(
        at stagingURL: URL,
        artifactRemover: any DatabaseBackupArtifactRemover
    ) -> String? {
        let candidates = [stagingURL] + managedSidecarSuffixes.map {
            URL(fileURLWithPath: stagingURL.path + $0)
        }
        var failures: [String] = []
        for candidate in candidates {
            do {
                switch try nodeKind(at: candidate) {
                case .missing:
                    continue
                case .regular:
                    if case .failed(let code) = artifactRemover.remove(at: candidate) {
                        failures.append("\(candidate.lastPathComponent): errno \(code)")
                    }
                case .directory, .symbolicLink, .other:
                    failures.append("unsafe staging artifact \(candidate.lastPathComponent)")
                }
            } catch {
                failures.append(failureReason(error))
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private enum ManagedArtifactKind: Equatable {
        case backupBase
        case backupSidecar(base: String)
        case stagingBase
        case stagingSidecar(base: String)
    }

    private static func managedArtifactKind(
        _ name: String,
        includeLegacy: Bool,
        includeStaging: Bool
    ) -> ManagedArtifactKind? {
        if isManagedBaseName(name, includeLegacy: includeLegacy) {
            return .backupBase
        }
        if let base = managedBaseName(forSidecar: name, includeLegacy: includeLegacy) {
            return .backupSidecar(base: base)
        }
        guard includeStaging else { return nil }
        if isManagedStagingBaseName(name) { return .stagingBase }
        if let base = managedStagingBaseName(forSidecar: name) {
            return .stagingSidecar(base: base)
        }
        return nil
    }

    private static func isManagedCadenzaBaseName(_ name: String) -> Bool {
        isManagedBaseName(name, includeLegacy: false)
    }

    private static func isManagedBaseName(_ name: String, includeLegacy: Bool) -> Bool {
        guard name.hasSuffix(".store") else { return false }
        let validPrefix = name.hasPrefix("cadenza-")
            || (includeLegacy && name.hasPrefix("default-"))
        guard validPrefix else { return false }
        let prefixLength = name.hasPrefix("cadenza-") ? "cadenza-".count : "default-".count
        return name.count > prefixLength + ".store".count
    }

    private static func managedBaseName(
        forSidecar name: String,
        includeLegacy: Bool
    ) -> String? {
        for suffix in managedSidecarSuffixes where name.hasSuffix(suffix) {
            let baseName = String(name.dropLast(suffix.count))
            if isManagedBaseName(baseName, includeLegacy: includeLegacy) {
                return baseName
            }
        }
        return nil
    }

    private static func isManagedStagingBaseName(_ name: String) -> Bool {
        guard name.hasPrefix(stagingPrefix), name.hasSuffix(".store") else { return false }
        let identifier = name
            .dropFirst(stagingPrefix.count)
            .dropLast(".store".count)
        return UUID(uuidString: String(identifier)) != nil
    }

    private static func managedStagingBaseName(forSidecar name: String) -> String? {
        for suffix in managedSidecarSuffixes where name.hasSuffix(suffix) {
            let baseName = String(name.dropLast(suffix.count))
            if isManagedStagingBaseName(baseName) { return baseName }
        }
        return nil
    }

    private static func withExecutionLease<T: Sendable>(
        didAcquire: (@Sendable () -> Void)?,
        _ operation: @Sendable () throws -> T
    ) rethrows -> T {
        try executionLease.withLock { _ in
            didAcquire?()
            return try operation()
        }
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter.string(from: date)
    }

    private static func failureReason(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func logFailure(_ error: DatabaseBackupError) -> DatabaseBackupOutcome {
        NSLog("[DatabaseBackup] failed: %@", error.localizedDescription)
        return .failed(error)
    }
}
