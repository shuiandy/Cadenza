import Foundation
import Darwin

/// DEBUG-only relocation of the entire on-disk data plane.
///
/// Setting `CADENZA_DATA_ROOT` runs an instance whose profile registry,
/// stores, backups, chat history, and audio all live under a throwaway
/// directory — the supported way to launch a second instance against fixture
/// data (documentation screenshots, manual walkthroughs) without opening the
/// real library. When unset, and in every release build, each path resolves
/// exactly as it did before this type existed.
///
/// Why this exists as one type rather than per-call-site environment reads:
/// the data plane has several entry points (`ProfilePaths.live()`,
/// `StorageLocationManager`, `DatabaseBackup`, `ChatHistoryManager`,
/// `RecordingsStore`'s legacy container), and relocating a subset is worse
/// than relocating none — an instance that reads a fixture store while
/// resolving the *real* audio root will scan, and import from, the user's
/// recordings directory. Every entry point routes through here so that
/// "isolated" means isolated.
///
/// The value is read once at launch: the data plane is settled before any
/// store opens, and a value changing mid-process would split writes across
/// two roots.
///
/// Deliberately **not** relocated: the Whisper model cache. Models are large,
/// read-only, and carry no user content, so a relocated instance shares them
/// rather than re-downloading gigabytes.
enum DebugDataRoot {

    /// Environment variable name — also the thing to grep for when a
    /// relocated instance behaves unexpectedly.
    static let environmentKey = "CADENZA_DATA_ROOT"

    /// CoreFoundation consults this before resolving the user domain. Requiring
    /// it to live under the same throwaway root keeps UserDefaults, caches, and
    /// every framework-owned user path on the isolated side of the boundary.
    static let fixedUserHomeEnvironmentKey = "CFFIXED_USER_HOME"

    enum Configuration: Equatable, Sendable {
        case inactive
        case isolated(root: URL, fixedUserHome: URL)
        case invalid(reason: String)
    }

#if DEBUG
    /// Settled once, before AppBootSequence or any live service exists.
    static let configuration: Configuration = {
        let result = validate(environment: ProcessInfo.processInfo.environment)
        switch result {
        case .inactive:
            break
        case .isolated(let root, let fixedUserHome):
            NSLog(
                "[DebugDataRoot] isolated runtime root=%@ fixedHome=%@",
                root.path,
                fixedUserHome.path
            )
        case .invalid(let reason):
            NSLog("[DebugDataRoot] refusing unsafe isolated runtime: %@", reason)
        }
        return result
    }()
#else
    static let configuration: Configuration = .inactive
#endif

    /// Configuration decision over an injected environment. Both directories
    /// must already exist so `realpath(3)` can prove their physical locations
    /// before any store or service is constructed. The data root is accepted
    /// only as a strict child of a canonical temporary directory; an arbitrary
    /// absolute path is not an isolation boundary.
    static func validate(environment: [String: String]) -> Configuration {
        guard let rawRoot = nonempty(environment[environmentKey]) else {
            return .inactive
        }
        guard (rawRoot as NSString).isAbsolutePath else {
            return .invalid(reason: "\(environmentKey) must be an absolute path")
        }
        guard let rawFixedHome = nonempty(environment[fixedUserHomeEnvironmentKey]) else {
            return .invalid(
                reason: "\(fixedUserHomeEnvironmentKey) is required when \(environmentKey) is set"
            )
        }
        guard (rawFixedHome as NSString).isAbsolutePath else {
            return .invalid(reason: "\(fixedUserHomeEnvironmentKey) must be an absolute path")
        }

        guard let root = canonicalExistingDirectoryURL(path: rawRoot) else {
            return .invalid(reason: "\(environmentKey) must resolve to an existing directory")
        }
        guard let fixedUserHome = canonicalExistingDirectoryURL(path: rawFixedHome) else {
            return .invalid(
                reason: "\(fixedUserHomeEnvironmentKey) must resolve to an existing directory"
            )
        }
        guard let physicalHome = physicalHomeDirectory() else {
            return .invalid(reason: "unable to resolve the physical user home")
        }
        guard let sourceRepositoryRoot = sourceRepositoryRoot() else {
            return .invalid(reason: "unable to resolve the source repository root")
        }
        if contains(root: sourceRepositoryRoot, candidate: root) {
            return .invalid(reason: "\(environmentKey) must not resolve inside the source repository")
        }
        if contains(root: physicalHome, candidate: root) {
            return .invalid(reason: "\(environmentKey) must not resolve inside the physical user home")
        }
        guard approvedTemporaryRoots().contains(where: {
            isStrictDescendant(root: $0, candidate: root)
        }) else {
            return .invalid(
                reason: "\(environmentKey) must be a strict descendant of an approved temporary directory"
            )
        }
        guard isOwnedByCurrentUserAndNotGroupOrWorldWritable(root) else {
            return .invalid(
                reason: "\(environmentKey) must be owned by the current user and not group/world-writable"
            )
        }
        guard isStrictDescendant(root: root, candidate: fixedUserHome) else {
            return .invalid(
                reason: "\(fixedUserHomeEnvironmentKey) must resolve to a strict descendant of \(environmentKey)"
            )
        }
        return .isolated(root: root, fixedUserHome: fixedUserHome)
    }

    static var url: URL? {
        guard case .isolated(let root, _) = configuration else { return nil }
        return root
    }

    static var haltReason: String? {
        guard case .invalid(let reason) = configuration else { return nil }
        return reason
    }

    static var isActive: Bool { url != nil }

    /// Any explicit DEBUG override, valid or not, closes access to live
    /// credentials. Invalid input renders only the halt shell, but this keeps
    /// an incidental static initializer from constructing a real Keychain
    /// client even if startup ordering later changes.
    static var blocksLiveAccess: Bool {
        blocksLiveAccess(configuration: configuration)
    }

    static func blocksLiveAccess(configuration: Configuration) -> Bool {
        configuration != .inactive
    }

    /// Stand-in for `~/Library/Application Support` — registry, stores,
    /// backups, and chat history hang off this.
    static var applicationSupport: URL? {
        url?.appendingPathComponent("Application Support", isDirectory: true)
    }

    /// Stand-in for the recordings directory.
    static var audioDirectory: URL? {
        url?.appendingPathComponent("Audio", isDirectory: true)
    }

    /// `~/Library/Application Support` for the active data plane.
    static func applicationSupportDirectory() -> URL {
        applicationSupport
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
    }

    /// `~/Documents` for the active data plane — the base for app-managed
    /// audio roots.
    static func documentsDirectory() -> URL {
        url ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Direct store opened by the local-only fixture runtime. It deliberately
    /// bypasses ProfileBootstrap: a demo must not perform migrations, inspect
    /// account binding, or derive authority from shared defaults merely to
    /// render a fictional library.
    static var fixtureStoreURL: URL? {
        applicationSupport?
            .appendingPathComponent("Cadenza", isDirectory: true)
            .appendingPathComponent("Cadenza.store")
    }

    static var fixtureChatHistoryDirectory: URL? {
        applicationSupport?
            .appendingPathComponent("Cadenza", isDirectory: true)
            .appendingPathComponent("ChatHistory", isDirectory: true)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Uses the account database instead of Foundation's home-directory APIs,
    /// which may already be redirected by `CFFIXED_USER_HOME` in this process.
    static func physicalHomeDirectory() -> URL? {
        guard let passwordEntry = getpwuid(getuid()),
              let directory = passwordEntry.pointee.pw_dir else { return nil }
        return canonicalExistingDirectoryURL(path: String(cString: directory))
    }

    static func approvedTemporaryRoots() -> [URL] {
        let candidates = [
            "/private/tmp",
            FileManager.default.temporaryDirectory.path,
        ]
        var seen: Set<String> = []
        return candidates.compactMap { path in
            guard let url = canonicalExistingDirectoryURL(path: path),
                  seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    static func sourceRepositoryRoot() -> URL? {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repository = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return canonicalExistingDirectoryURL(path: repository.path)
    }

    /// Intentionally does not call `standardizedFileURL` after `realpath(3)`.
    /// Foundation may rewrite an existing `/private/var` prefix back to `/var`
    /// while a prospective child retains `/private/var`, breaking component
    /// boundary checks.
    private static func canonicalExistingDirectoryURL(path: String) -> URL? {
        guard !path.utf8.contains(0),
              let resolvedPath = realpath(path, nil) else { return nil }
        defer { free(resolvedPath) }

        let canonicalPath = String(cString: resolvedPath)
        var fileInfo = stat()
        guard stat(canonicalPath, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private static func contains(root: URL, candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func isStrictDescendant(root: URL, candidate: URL) -> Bool {
        root != candidate && contains(root: root, candidate: candidate)
    }

    private static func isOwnedByCurrentUserAndNotGroupOrWorldWritable(_ directory: URL) -> Bool {
        var fileInfo = stat()
        guard stat(directory.path, &fileInfo) == 0,
              fileInfo.st_uid == getuid() else { return false }
        return fileInfo.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}
