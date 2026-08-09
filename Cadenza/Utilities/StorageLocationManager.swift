import CryptoKit
import Foundation
import os.lock

/// Manages the recording storage location, supporting custom folders and cloud service detection.
///
/// Caching policy: bookmark resolution + cloud detection are cached for the
/// process lifetime. Each `setCustomDirectory` / `resetToDefault` invalidates
/// the relevant caches. This avoids re-running `URL(resolvingBookmarkData:)`
/// and `contentsOfDirectory(~/Library/CloudStorage)` on every read — the old
/// design hit those paths from 14+ call sites on every recording start, every
/// settings render, every diagnostic, prompting macOS for folder access on
/// signature-mismatched dev builds.
///
/// Thread safety: all caches live behind `OSAllocatedUnfairLock` because read
/// paths run on RecordingEngine queues, PostProcessingCoordinator background
/// tasks, and the main actor; writes (`setCustomDirectory` / `resetToDefault`)
/// only ever fire from the SettingsView main-actor flow.
enum StorageLocationManager {

    private static let bookmarkKey = "recordingsDirectoryBookmark"
    private static let pathKey = "recordingsDirectory"

    /// Per-profile root authority (spec §4.2): installed at boot from the
    /// registry's recorded directory for the resolved profile. Once
    /// installed, resolution and root changes never touch the global
    /// defaults keys — those stay operative only for the pre-commit legacy
    /// fallback — and every root change is durably recorded in the
    /// registry before it commits.
    struct ProfileRootAuthority: Sendable {
        let bookmark: Data?
        let path: String
        let kind: Profile.AudioDirectory.Kind
        /// Stable per-profile app-managed default (keyed by profile ID so
        /// display-name collisions cannot alias roots); reset targets it,
        /// never a directory shared with another profile.
        let profileDefaultPath: String
        /// Persists a refreshed security-scoped bookmark for the active
        /// profile; best-effort — a stale bookmark re-resolves next boot.
        /// Ownership-conditioned: the write carries the directory identity
        /// it refreshed from, and applies only while the registry still
        /// records exactly that identity — a root committed in between
        /// must never receive a bookmark resolved under the old root.
        let recordRefreshedBookmark: @Sendable (RefreshedBookmark) -> Void
        /// Durably records a root change for the active profile; a failure
        /// aborts the commit. Main-actor so runtime registry mutations
        /// stay serialized against auth/session writers.
        let recordRootChange: @MainActor (Data?, String, Profile.AudioDirectory.Kind) throws -> Void
    }

    /// A refreshed bookmark together with the exact directory identity it
    /// was resolved from.
    struct RefreshedBookmark: Sendable {
        let refreshed: Data
        let expectedBookmark: Data
        let expectedPath: String
        let expectedKind: Profile.AudioDirectory.Kind
    }

    private static let profileRootState =
        OSAllocatedUnfairLock<ProfileRootAuthority?>(initialState: nil)

    /// One-way boot installation; the active profile's identity binds the
    /// process, so a second differing installation is programmer error.
    static func configureProfileRoot(_ authority: ProfileRootAuthority) {
        profileRootState.withLock { current in
            precondition(current == nil, "profile audio root already configured")
            current = authority
        }
        invalidateDirectoryCache()
    }

#if DEBUG
    /// Test seam: installs an authority for the closure's duration and
    /// restores the previous state; callers serialize their own use.
    static func withProfileRootForTesting<T>(
        _ authority: ProfileRootAuthority, _ body: () throws -> T
    ) rethrows -> T {
        let previous = profileRootState.withLock { current in
            let previous = current
            current = authority
            return previous
        }
        invalidateDirectoryCache()
        defer {
            profileRootState.withLock { $0 = previous }
            invalidateDirectoryCache()
        }
        return try body()
    }
#endif

    /// Identity of the installed profile root authority, for surfaces
    /// that diagnose or repair it; nil outside profile mode.
    static var profileRootIdentity:
        (bookmark: Data?, path: String, kind: Profile.AudioDirectory.Kind)? {
        profileRootState.withLock { state in
            state.map { ($0.bookmark, $0.path, $0.kind) }
        }
    }

    /// Advances the in-memory authority after a committed bookmark
    /// repair. Identity-conditioned like the registry write: a root
    /// change that landed in between makes this a no-op, so a bookmark
    /// taken for the old directory can never shadow the new root.
    @MainActor
    @discardableResult
    static func adoptRepairedBookmark(_ bookmark: Data, expectedPath: String) -> Bool {
        let adopted = profileRootState.withLock { current -> Bool in
            guard let authority = current,
                  authority.kind == .userSelected,
                  LexicalPathIdentity.equals(authority.path, expectedPath) else { return false }
            current = ProfileRootAuthority(
                bookmark: bookmark,
                path: authority.path,
                kind: authority.kind,
                profileDefaultPath: authority.profileDefaultPath,
                recordRefreshedBookmark: authority.recordRefreshedBookmark,
                recordRootChange: authority.recordRootChange
            )
            return true
        }
        if adopted { invalidateDirectoryCache() }
        return adopted
    }

    // MARK: - Process-lifetime caches

    private struct CacheState: Sendable {
        /// Resolved recordings directory. Holds the security-scoped claim for
        /// the process lifetime — we deliberately never call
        /// `stopAccessingSecurityScopedResource()` while the URL is still
        /// active because the URL is shared across many call sites; the OS
        /// releases the claim on app termination. We do release the previous
        /// claim when the directory is changed (`invalidateDirectoryCache`).
        var recordingsURL: URL?

        /// Cloud service available-on-disk cache. Cloud client install state
        /// does not meaningfully change during a single app session.
        var availableClouds: [CloudService]?

        /// Path the cached `detectedCloud` was computed against. We key by
        /// path rather than a generation counter so that even if a writer
        /// invalidates the cache while a reader is mid-flight, the next
        /// reader's path comparison catches the mismatch and recomputes.
        var detectedCloudFor: String?
        var detectedCloud: CloudService?
    }

    private static let cache = OSAllocatedUnfairLock(initialState: CacheState())

    // MARK: - Public API

    /// The active recordings directory. Falls back to ~/Documents/Cadenza/ if no custom path is set.
    ///
    /// Resolution runs *under the lock* on cold-cache. Bookmark resolution +
    /// `UserDefaults` access are sync and complete in milliseconds; holding
    /// `OSAllocatedUnfairLock` for that window is preferable to the
    /// resolve-outside-then-write-back pattern, which races with
    /// `invalidateDirectoryCache` (Codex review 2026-05-06 #1).
    static var recordingsDirectory: URL {
        cache.withLock { state in
            if let cached = state.recordingsURL { return cached }
            let resolved = Self.resolveRecordingsDirectory()
            state.recordingsURL = resolved
            return resolved
        }
    }

    private static func resolveRecordingsDirectory() -> URL {
        if let authority = profileRootState.withLock({ $0 }) {
            // A relocated data plane resolves only roots inside itself. A
            // registry inherited from (or pointing back at) the real library
            // would otherwise aim this instance at the user's recordings —
            // where the orphan scan imports whatever it finds.
            guard !DebugDataRoot.isActive || isInsideDebugRoot(authority.path) else {
                NSLog(
                    "[StorageLocationManager] profile root %@ is outside the debug data root; using the relocated default",
                    authority.path
                )
                return defaultDirectory
            }
            if let bookmarkData = authority.bookmark {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    // A bookmark follows a moved directory; the recorded
                    // lexical path is the identity. A resolution that no
                    // longer byte-matches it must not be read, written,
                    // refreshed, or claimed — the frozen path stands and
                    // the repair surface takes over.
                    guard LexicalPathIdentity.equals(url.path, authority.path) else {
                        NSLog(
                            "[StorageLocationManager] bookmark resolved off the recorded root (%@); using the frozen path",
                            url.path
                        )
                        return URL(fileURLWithPath: authority.path, isDirectory: true)
                    }
                    if isStale,
                       let newData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                       ) {
                        authority.recordRefreshedBookmark(RefreshedBookmark(
                            refreshed: newData,
                            expectedBookmark: bookmarkData,
                            expectedPath: authority.path,
                            expectedKind: authority.kind
                        ))
                    }
                    _ = url.startAccessingSecurityScopedResource()
                    return url
                }
            }
            // Recorded lexical path — the identity the registry carries.
            // Sandbox may still refuse IO for a lost bookmark; the
            // recording flow surfaces that rather than this resolver
            // guessing a different directory.
            return URL(fileURLWithPath: authority.path, isDirectory: true)
        }
        // The global bookmark belongs to the real library; a relocated data
        // plane never adopts it.
        if DebugDataRoot.isActive { return defaultDirectory }
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale,
                   let newData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                   ) {
                    UserDefaults.standard.set(newData, forKey: bookmarkKey)
                }
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return defaultDirectory
    }

    /// Default storage: ~/Documents/Cadenza/ (or the relocated equivalent
    /// under a DEBUG data root).
    static var defaultDirectory: URL {
        if let relocated = DebugDataRoot.audioDirectory { return relocated }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Cadenza", isDirectory: true)
    }

    /// Whether a resolved root belongs to the active DEBUG data plane.
    /// Lexical containment, matching the identity rule the rest of the
    /// storage layer uses — a relocated instance must never widen its reach
    /// by following a symlink out of its own root.
    private static func isInsideDebugRoot(_ path: String) -> Bool {
        guard let root = DebugDataRoot.url else { return false }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path == root.path || path.hasPrefix(rootPath)
    }

    /// Segments subdirectory for a given recording ID.
    static func segmentsDirectory(for recordingID: UUID) -> URL {
        recordingsDirectory
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
    }

    /// Audio file URL for a merged recording.
    static func audioFileURL(for recordingID: UUID) -> URL {
        recordingsDirectory
            .appendingPathComponent("\(recordingID.uuidString).m4a")
    }

    /// Whether a custom (non-default) directory is set.
    static var isCustomDirectorySet: Bool {
        if let authority = profileRootState.withLock({ $0 }) {
            return authority.kind == .userSelected
        }
        return UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// The directory a reset targets: the profile's own app-managed root
    /// in profile mode, the shared legacy default otherwise.
    static var resetTargetDirectory: URL {
        if let authority = profileRootState.withLock({ $0 }) {
            return URL(fileURLWithPath: authority.profileDefaultPath, isDirectory: true)
        }
        return defaultDirectory
    }

    /// Set a new storage directory. Saves a security-scoped bookmark.
    @MainActor
    static func setCustomDirectory(_ url: URL) throws {
        let bookmarkData = try prepareCustomDirectoryBookmark(url)
        try commitCustomDirectory(bookmarkData: bookmarkData, path: url.path)
    }

    /// Bookmark creation is the only fallible part of a root switch. The
    /// migration flow runs this before touching any files, so a bookmark
    /// failure aborts with nothing changed on disk.
    static func prepareCustomDirectoryBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Commits a previously prepared bookmark. In profile mode the
    /// registry record is the only commit point, and its result is
    /// classified: a proven-uncommitted write aborts with the in-memory
    /// authority, cache, and effective root unchanged; a save that
    /// provably landed advances them despite the throw; an
    /// unclassifiable write poisons the migration gate so root-dependent
    /// work stays blocked until restart. The global keys are never
    /// touched in profile mode — the writes below belong solely to the
    /// explicit legacy fallback.
    @MainActor
    static func commitCustomDirectory(bookmarkData: Data, path: String) throws {
        if profileRootState.withLock({ $0 }) != nil {
            try recordProfileRootChange(bookmark: bookmarkData, path: path, kind: .userSelected)
            return
        }
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        UserDefaults.standard.set(path, forKey: pathKey)
        invalidateDirectoryCache()
    }

    /// Reset to the default directory: in profile mode that is the
    /// profile's own app-managed root, never a directory another profile
    /// could share.
    @MainActor
    static func resetToDefault() throws {
        if let authority = profileRootState.withLock({ $0 }) {
            try recordProfileRootChange(
                bookmark: nil, path: authority.profileDefaultPath, kind: .appManaged
            )
            return
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
        invalidateDirectoryCache()
    }

    @MainActor
    private static func recordProfileRootChange(
        bookmark: Data?, path: String, kind: Profile.AudioDirectory.Kind
    ) throws {
        guard let authority = profileRootState.withLock({ $0 }) else { return }
        // An indeterminate registry write poisons the migration gate
        // inside the writer itself; this throw only surfaces it.
        try authority.recordRootChange(bookmark, path, kind)
        profileRootState.withLock {
            $0 = ProfileRootAuthority(
                bookmark: bookmark,
                path: path,
                kind: kind,
                profileDefaultPath: authority.profileDefaultPath,
                recordRefreshedBookmark: authority.recordRefreshedBookmark,
                recordRootChange: authority.recordRootChange
            )
        }
        invalidateDirectoryCache()
    }

    private static func invalidateDirectoryCache() {
        cache.withLock { state in
            if let previous = state.recordingsURL {
                previous.stopAccessingSecurityScopedResource()
            }
            state.recordingsURL = nil
            state.detectedCloudFor = nil
            state.detectedCloud = nil
        }
    }

    /// Human-readable display path.
    static var displayPath: String {
        let path = recordingsDirectory.path
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String? {
            return path.replacingOccurrences(of: home, with: "~")
        }
        return path
    }

    // MARK: - Cloud Service Detection

    enum CloudService: CaseIterable, Sendable {
        case icloud, onedrive, googledrive, dropbox

        var displayName: String {
            switch self {
            case .icloud: "iCloud Drive"
            case .onedrive: "OneDrive"
            case .googledrive: "Google Drive"
            case .dropbox: "Dropbox"
            }
        }

        var icon: String {
            switch self {
            case .icloud: "icloud"
            case .onedrive: "cloud"
            case .googledrive: "externaldrive.badge.icloud"
            case .dropbox: "shippingbox"
            }
        }

        /// Check if a path is inside this cloud service's sync folder.
        func matches(path: String) -> Bool {
            switch self {
            case .icloud:
                return path.contains("/Library/Mobile Documents/com~apple~CloudDocs")
            case .onedrive:
                return path.contains("/Library/CloudStorage/OneDrive")
            case .googledrive:
                return path.contains("/Library/CloudStorage/GoogleDrive")
            case .dropbox:
                return path.contains("/Library/CloudStorage/Dropbox")
            }
        }

        /// Returns the root sync folder URL if this cloud service is installed, nil otherwise.
        var installedPath: URL? {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            switch self {
            case .icloud:
                let path = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
                return fm.fileExists(atPath: path.path) ? path : nil
            case .onedrive, .googledrive, .dropbox:
                let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
                guard let contents = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil) else { return nil }
                let prefix: String = switch self {
                case .onedrive: "OneDrive"
                case .googledrive: "GoogleDrive"
                case .dropbox: "Dropbox"
                default: ""
                }
                return contents.first { $0.lastPathComponent.hasPrefix(prefix) }
            }
        }

        /// Whether this cloud service's desktop client is installed.
        var isInstalled: Bool { installedPath != nil }

        /// Suggested Cadenza subfolder inside this cloud service.
        var suggestedCadenzaPath: URL? {
            installedPath?.appendingPathComponent("Cadenza", isDirectory: true)
        }
    }

    /// Detect which cloud service (if any) the current storage directory is synced with.
    /// Cached, keyed by path so invalidate-mid-resolve races are caught on
    /// the next reader (Codex review 2026-05-06 #1).
    static var detectedCloudService: CloudService? {
        let path = recordingsDirectory.path
        return cache.withLock { state in
            if state.detectedCloudFor == path {
                return state.detectedCloud
            }
            let result = CloudService.allCases.first { $0.matches(path: path) }
            state.detectedCloud = result
            state.detectedCloudFor = path
            return result
        }
    }

    /// Returns all cloud services that have their desktop client installed.
    /// Cached for the process lifetime — install state does not change mid-session
    /// in any meaningful way for our UI.
    static var availableCloudServices: [CloudService] {
        if let cached = cache.withLock({ $0.availableClouds }) {
            return cached
        }
        let result = CloudService.allCases.filter { $0.isInstalled }
        cache.withLock { state in
            state.availableClouds = result
        }
        return result
    }

    // MARK: - Storage Stats

    /// Calculate total size and file count of the recordings directory.
    static func storageStats() -> (size: Int64, fileCount: Int) {
        let fm = FileManager.default
        let dir = recordingsDirectory
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        var totalSize: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            totalSize += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (totalSize, count)
    }

    // MARK: - Migration

    private static let migratableAudioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aiff", "flac", "aac", "mp4", "mov", "caf",
    ]

    enum MigrationError: LocalizedError, Equatable {
        /// An item with this name already exists at the destination. Aborting
        /// (rather than skipping) matters: a skipped file would leave its
        /// reference pointing at a different same-named file after the root
        /// switch.
        case destinationCollision(String)
        case enumerationFailed(String)
        case copyVerificationFailed(String)
        /// Source and destination are nested one inside the other; copying
        /// a tree into its own subtree recurses.
        case overlappingRoots

        var errorDescription: String? {
            switch self {
            case .destinationCollision(let name):
                String(localized: "\"\(name)\" already exists in the destination folder.")
            case .enumerationFailed(let path):
                String(localized: "Could not list the folder: \(path)")
            case .copyVerificationFailed(let name):
                String(localized: "Copy verification failed for \"\(name)\".")
            case .overlappingRoots:
                String(localized: "The source and destination folders overlap.")
            }
        }
    }

    /// Stable node identity (device + inode), lstat semantics.
    struct FileIdentity: Equatable, Sendable {
        let device: Int
        let inode: Int
    }

    /// Structured content descriptor — no string delimiters, so untrusted
    /// values (symlink destinations) cannot collide with the encoding.
    enum ContentDescriptor: Equatable, Sendable {
        case regular(size: Int64, sha256: String)
        case directory
        case symlink(destination: Data)
    }

    /// Ownership evidence: content descriptors plus per-entry modification
    /// times (interval bit patterns). Copy verification compares `content`
    /// only — copies legitimately carry their own timestamps; ownership
    /// re-verification compares the whole structure.
    struct OwnershipSnapshot: Equatable, Sendable {
        let content: [Data: ContentDescriptor]
        let modification: [Data: UInt64]
    }

    /// One migrated item plus the ownership evidence captured when its copy
    /// completed: identities bind the exact nodes, snapshots bind the
    /// content — cleanup and discard re-verify both before deleting
    /// anything.
    struct CopiedItem: Sendable {
        let from: URL
        let to: URL
        let sourceIdentity: FileIdentity
        let sourceSnapshot: OwnershipSnapshot
        let destinationIdentity: FileIdentity
        let destinationSnapshot: OwnershipSnapshot
    }

    /// Every copy performed by a migration. Sources are untouched until
    /// `cleanupMigrationSources`; `discardMigrationCopies` deletes only
    /// nodes this migration placed and that are verifiably unchanged.
    struct MigrationOutcome: Sendable {
        let copiedItems: [CopiedItem]
        var copiedPairs: [(from: URL, to: URL)] { copiedItems.map { ($0.from, $0.to) } }
        var count: Int { copiedItems.count }
    }

    /// Copy-first migration of the segments tree and top-level audio files.
    /// The source directory stays complete until the caller commits the new
    /// root and runs `cleanupMigrationSources` — a failure or interruption
    /// at any earlier point leaves the old root fully usable, and the only
    /// possible leftover after a late failure is a duplicate copy. Each item
    /// is verified by kind, relative path, and content digest against its
    /// source. A name collision at the destination aborts (a
    /// silently skipped file would leave its reference pointing at a
    /// different same-named file after the root switch); a missing source
    /// directory is an empty migration, not an error (fresh installs may
    /// never have created it).
    static func migrateFiles(from oldDir: URL, to newDir: URL) throws -> MigrationOutcome {
        let fm = FileManager.default
        // A source that never existed is an empty migration (fresh install);
        // the overlap preflight only applies to a real source tree.
        guard fm.fileExists(atPath: oldDir.path) else {
            return MigrationOutcome(copiedItems: [])
        }
        try rejectOverlappingRoots(oldDir, newDir)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        var copiedItems: [CopiedItem] = []
        do {
            let oldSegments = oldDir.appendingPathComponent("segments", isDirectory: true)
            let newSegments = newDir.appendingPathComponent("segments", isDirectory: true)
            if fm.fileExists(atPath: oldSegments.path) {
                copiedItems.append(
                    try stageAndPlaceCopy(from: oldSegments, to: newSegments, in: newDir)
                )
            }

            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
            } catch {
                throw MigrationError.enumerationFailed(oldDir.path)
            }
            for file in contents {
                guard migratableAudioExtensions.contains(file.pathExtension.lowercased()) else { continue }
                let dest = newDir.appendingPathComponent(file.lastPathComponent)
                copiedItems.append(try stageAndPlaceCopy(from: file, to: dest, in: newDir))
            }
        } catch {
            discardMigrationCopies(MigrationOutcome(copiedItems: copiedItems))
            throw error
        }
        return MigrationOutcome(copiedItems: copiedItems)
    }

    /// One migration item: copy to a unique staging name inside the
    /// destination directory, verify the staging copy, then claim the final
    /// name exclusively. A failure removes only the staging copy this
    /// attempt created; a node occupying the final name — present up front,
    /// dangling symlink included, or appearing between the check and the
    /// claim — is a collision and is never deleted or replaced. A crash can
    /// at worst leave a uniquely-named dot-prefixed staging entry behind;
    /// retries are unaffected because staging names never repeat.
    ///
    /// The returned item carries the ownership evidence for later cleanup:
    /// node identities and content snapshots captured when the copy
    /// completed.
    @discardableResult
    static func stageAndPlaceCopy(
        from source: URL, to final: URL, in directory: URL
    ) throws -> CopiedItem {
        let fm = FileManager.default
        // lstat form: fileExists() follows symlinks and reports false for a
        // dangling link that nonetheless occupies the final name.
        if (try? fm.attributesOfItem(atPath: final.path)) != nil {
            throw MigrationError.destinationCollision(final.lastPathComponent)
        }
        // Source evidence before the copy: the same identity and snapshot
        // must hold afterwards, or the source changed mid-copy and the copy
        // cannot be trusted.
        let sourceIdentity = try fileIdentity(of: source)
        let sourceSnapshot = try ownershipSnapshot(of: source)
        let staging = directory.appendingPathComponent(
            ".cadenza-migration-\(UUID().uuidString)"
        )
        do {
            try fm.copyItem(at: source, to: staging)
            guard try fileIdentity(of: source) == sourceIdentity,
                  try ownershipSnapshot(of: source) == sourceSnapshot else {
                throw MigrationError.copyVerificationFailed(source.lastPathComponent)
            }
            let stagingIdentity = try fileIdentity(of: staging)
            let stagingSnapshot = try ownershipSnapshot(of: staging)
            guard stagingSnapshot.content == sourceSnapshot.content else {
                throw MigrationError.copyVerificationFailed(source.lastPathComponent)
            }
            // The exclusive claim is the last fallible step: the rename
            // preserves the staged inode, so the returned item is built from
            // already-captured evidence and nothing can throw once the final
            // name exists — no path leaves an unowned node behind.
            try claimFinalNameExclusively(staging: staging, final: final)
            return CopiedItem(
                from: source,
                to: final,
                sourceIdentity: sourceIdentity,
                sourceSnapshot: sourceSnapshot,
                destinationIdentity: stagingIdentity,
                destinationSnapshot: stagingSnapshot
            )
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// lstat-based identity; the rename preserves the staged inode, so the
    /// destination identity binds the exact node this migration placed.
    static func fileIdentity(of url: URL) throws -> FileIdentity {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw MigrationError.copyVerificationFailed(url.lastPathComponent)
        }
        guard let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int else {
            throw MigrationError.copyVerificationFailed(url.lastPathComponent)
        }
        return FileIdentity(device: device, inode: inode)
    }

    /// Content snapshot for ownership re-verification before deletion:
    /// structured content descriptors plus per-entry modification times, so
    /// a same-size edit fails on the digest and a bare mtime touch fails on
    /// the modification map.
    static func ownershipSnapshot(of url: URL) throws -> OwnershipSnapshot {
        let content = try copyManifest(of: url)
        let fm = FileManager.default
        var modification: [Data: UInt64] = [:]
        for key in content.keys {
            let relative = String(decoding: key, as: UTF8.self)
            let item = relative.isEmpty ? url : url.appendingPathComponent(relative)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fm.attributesOfItem(atPath: item.path)
            } catch {
                throw MigrationError.copyVerificationFailed(item.lastPathComponent)
            }
            let interval = (attributes[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? -1
            modification[key] = interval.bitPattern
        }
        return OwnershipSnapshot(content: content, modification: modification)
    }

    /// Atomic no-overwrite rename via `renamex_np(RENAME_EXCL)`: any node at
    /// the final name — including one created after the collision pre-check
    /// — fails the claim instead of being replaced.
    static func claimFinalNameExclusively(staging: URL, final: URL) throws {
        let result = staging.withUnsafeFileSystemRepresentation { stagingPath in
            final.withUnsafeFileSystemRepresentation { finalPath in
                renamex_np(stagingPath, finalPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw MigrationError.destinationCollision(final.lastPathComponent)
            }
            throw MigrationError.copyVerificationFailed(final.lastPathComponent)
        }
    }

    /// Nested source/destination roots recurse a tree copy into its own
    /// subtree. Compared component-wise on both the given and the
    /// symlink-resolved spellings, since either side may be spelled through
    /// /var-style links or not exist yet.
    private static func rejectOverlappingRoots(_ oldDir: URL, _ newDir: URL) throws {
        let oldSpellings = [oldDir, oldDir.resolvingSymlinksInPath()].map(\.pathComponents)
        let newSpellings = [newDir, newDir.resolvingSymlinksInPath()].map(\.pathComponents)
        for old in oldSpellings {
            for new in newSpellings {
                let shared = min(old.count, new.count)
                if Array(old.prefix(shared)) == Array(new.prefix(shared)) {
                    throw MigrationError.overlappingRoots
                }
            }
        }
    }

    /// Deletes the copies this migration created — but only after
    /// re-verifying that the node at the final name is still the exact one
    /// this migration placed (identity) and unmodified since (snapshot).
    /// Anything uncertain is kept and logged; deleting a node someone else
    /// replaced or edited is never acceptable on a failure path.
    static func discardMigrationCopies(_ outcome: MigrationOutcome) {
        let fm = FileManager.default
        for item in outcome.copiedItems.reversed() {
            guard let identity = try? fileIdentity(of: item.to),
                  identity == item.destinationIdentity,
                  let snapshot = try? ownershipSnapshot(of: item.to),
                  snapshot == item.destinationSnapshot else {
                NSLog(
                    "[StorageLocationManager] discard kept %@: node changed since placement",
                    item.to.path
                )
                continue
            }
            try? fm.removeItem(at: item.to)
        }
    }

    /// Deletes the migrated sources after the new root is committed — but
    /// only when the source is still the exact content that was copied
    /// (identity + snapshot) and the destination is still this migration's
    /// placement. A source a sync client or another process touched after
    /// the copy holds data the copy does not, so it stays; failures leave
    /// duplicates behind, which is benign, and every kept path is logged.
    /// Verification-to-deletion is still not atomic; the identity binding
    /// narrows the race to same-inode in-place edits inside that window.
    static func cleanupMigrationSources(_ outcome: MigrationOutcome) {
        let fm = FileManager.default
        for item in outcome.copiedItems {
            guard let sourceIdentity = try? fileIdentity(of: item.from),
                  sourceIdentity == item.sourceIdentity,
                  let sourceSnapshot = try? ownershipSnapshot(of: item.from),
                  sourceSnapshot == item.sourceSnapshot,
                  let destinationIdentity = try? fileIdentity(of: item.to),
                  destinationIdentity == item.destinationIdentity,
                  let destinationSnapshot = try? ownershipSnapshot(of: item.to),
                  destinationSnapshot == item.destinationSnapshot else {
                NSLog(
                    "[StorageLocationManager] cleanup kept %@: changed since the copy",
                    item.from.path
                )
                continue
            }
            do {
                try fm.removeItem(at: item.from)
            } catch {
                NSLog(
                    "[StorageLocationManager] source cleanup left a duplicate at %@: %@",
                    item.from.path, error.localizedDescription
                )
            }
        }
    }

    /// Item-level comparison of two copies via a manifest of relative path
    /// bytes to entry descriptor: regular files carry their size,
    /// directories (including empty ones) their kind, symlinks their
    /// destination. Aggregate counts alone would accept two trees with the
    /// same totals but different contents. Fully throwing on the integrity
    /// path: every metadata or listing error becomes
    /// `copyVerificationFailed` — a swallowed error on both sides must
    /// never compare as equal — and entry kinds outside file/dir/symlink
    /// are rejected rather than silently ignored.
    static func verifyCopy(from source: URL, to destination: URL) throws {
        guard try copyManifest(of: source) == copyManifest(of: destination) else {
            throw MigrationError.copyVerificationFailed(source.lastPathComponent)
        }
    }

    /// Streaming SHA-256 of a regular file; IO errors surface as
    /// verification failures.
    private static func contentDigest(of url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.copyVerificationFailed(url.lastPathComponent)
        }
    }

    private static func copyManifest(of url: URL) throws -> [Data: ContentDescriptor] {
        let fm = FileManager.default

        func descriptor(at item: URL) throws -> ContentDescriptor {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fm.attributesOfItem(atPath: item.path)
            } catch {
                throw MigrationError.copyVerificationFailed(item.lastPathComponent)
            }
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular:
                guard let size = attributes[.size] as? Int64 else {
                    throw MigrationError.copyVerificationFailed(item.lastPathComponent)
                }
                return .regular(size: size, sha256: try contentDigest(of: item))
            case .typeDirectory:
                return .directory
            case .typeSymbolicLink:
                do {
                    let destination = try fm.destinationOfSymbolicLink(atPath: item.path)
                    return .symlink(destination: Data(destination.utf8))
                } catch {
                    throw MigrationError.copyVerificationFailed(item.lastPathComponent)
                }
            default:
                throw MigrationError.copyVerificationFailed(item.lastPathComponent)
            }
        }

        var manifest: [Data: ContentDescriptor] = [Data(): try descriptor(at: url)]
        func walk(_ directory: URL, prefix: String) throws {
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: []
                )
            } catch {
                throw MigrationError.copyVerificationFailed(directory.lastPathComponent)
            }
            for child in children {
                let relative = prefix.isEmpty
                    ? child.lastPathComponent
                    : "\(prefix)/\(child.lastPathComponent)"
                let value = try descriptor(at: child)
                manifest[Data(relative.utf8)] = value
                if value == .directory {
                    try walk(child, prefix: relative)
                }
            }
        }
        if manifest[Data()] == .directory {
            try walk(url, prefix: "")
        }
        return manifest
    }
}
