import Foundation
import Observation

/// Repair flow for a user-selected audio root whose security-scoped
/// bookmark no longer grants access: the user re-selects the exact
/// recorded folder and only the bookmark bytes are rewritten, through
/// the classified registry write path. The recorded lexical path is the
/// root's identity — a selection anywhere else is refused with nothing
/// written, so a moved or aliased copy of the folder can never be
/// silently adopted as the root.
@MainActor
@Observable
final class AudioRootRelinkCoordinator {
    /// Identity of the installed profile root, as read from the process
    /// authority.
    struct RootIdentity: Equatable {
        var bookmark: Data?
        var path: String
        var kind: Profile.AudioDirectory.Kind
    }

    enum Phase: Equatable {
        /// No repair applies: no profile authority, an app-managed root,
        /// or a bookmark that still authorizes.
        case unavailable
        /// The bookmark no longer authorizes; the offer is visible.
        case offered
        /// The last selection was refused (different folder, or the
        /// registry stopped recording this root); the offer stays.
        case refused(message: String)
        /// The registry write provably did not commit; the offer stays
        /// and retrying is safe.
        case saveFailed(message: String)
        /// The registry write could not be classified. The migration
        /// gate is poisoned by the writer; nothing more can happen in
        /// this session.
        case blocked(message: String)
        /// The bookmark was rewritten and adopted.
        case repaired
    }

    /// Every effect is injected so the flow is drivable in tests without
    /// a panel, a registry, or bookmark machinery.
    struct Dependencies {
        var rootIdentity: @MainActor () -> RootIdentity?
        /// Whether the bookmark resolves to the recorded lexical path
        /// (byte-exact) and grants security-scoped access; the probe
        /// must balance any access claim it takes. A bookmark following
        /// a moved directory is unhealthy even though it resolves.
        var probeBookmark: @MainActor (Data, String) -> Bool
        /// Presents the folder picker anchored at the recorded path;
        /// nil means the user cancelled.
        var pickFolder: @MainActor (String) -> URL?
        var makeBookmark: @MainActor (URL) throws -> Data
        /// Classified registry write plus in-process adoption; throws
        /// `ProfileAudioRootWriter.RootWriteError` shapes.
        var saveRelinkedBookmark: @MainActor (Data, String) throws -> Void
    }

    private(set) var phase: Phase = .unavailable
    private(set) var recordedPath: String = ""

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Re-probes the authority. The blocked state is terminal for the
    /// session (the writer poisoned the migration gate), so it never
    /// re-evaluates into an offer.
    func refresh() {
        if case .blocked = phase { return }
        guard let identity = dependencies.rootIdentity(),
              identity.kind == .userSelected else {
            phase = .unavailable
            return
        }
        recordedPath = identity.path
        if let bookmark = identity.bookmark,
           dependencies.probeBookmark(bookmark, identity.path) {
            phase = .unavailable
            return
        }
        // Keep a post-attempt message visible until the user retries.
        switch phase {
        case .refused, .saveFailed:
            break
        default:
            phase = .offered
        }
    }

    /// Runs one pick-validate-save attempt. Reachable only while an
    /// offer (or a retryable failure) is showing.
    func performRelink() {
        switch phase {
        case .offered, .refused, .saveFailed:
            break
        case .unavailable, .blocked, .repaired:
            return
        }
        guard let identity = dependencies.rootIdentity(),
              identity.kind == .userSelected else {
            phase = .unavailable
            return
        }
        let expectedPath = identity.path
        recordedPath = expectedPath
        guard let selected = dependencies.pickFolder(expectedPath) else {
            phase = .offered
            return
        }
        // Byte-exact lexical comparison: the recorded path is the
        // identity. No symlink or alias resolution on either side — a
        // moved original selected at a new location must be refused —
        // and no canonical-equivalence String equality, which would
        // accept an NFD respelling with different bytes.
        guard LexicalPathIdentity.equals(selected.path, expectedPath) else {
            phase = .refused(message: LocalizedBundle.string(
                "The selected folder doesn't match the recorded one, so nothing was changed. Choose the folder at the exact path shown.",
                locale: nil
            ))
            return
        }
        do {
            let bookmark = try dependencies.makeBookmark(selected)
            try dependencies.saveRelinkedBookmark(bookmark, expectedPath)
            phase = .repaired
        } catch let error as ProfileAudioRootWriter.RootWriteError {
            switch error {
            case .commitIndeterminate:
                phase = .blocked(message: error.localizedMessage())
            case .rootChanged:
                phase = .refused(message: error.localizedMessage())
            default:
                phase = .saveFailed(message: error.localizedMessage())
            }
        } catch {
            phase = .saveFailed(message: error.localizedDescription)
        }
    }

    /// Live wiring: authority reads and the classified write bind to the
    /// resolved profile; the folder picker stays with the presenting
    /// surface.
    static func liveDependencies(
        profileID: UUID,
        pickFolder: @escaping @MainActor (String) -> URL?
    ) -> Dependencies {
        Dependencies(
            rootIdentity: {
                StorageLocationManager.profileRootIdentity.map {
                    RootIdentity(bookmark: $0.bookmark, path: $0.path, kind: $0.kind)
                }
            },
            probeBookmark: { bookmarkGrantsAccess($0, expectedPath: $1) },
            pickFolder: pickFolder,
            makeBookmark: { try StorageLocationManager.prepareCustomDirectoryBookmark($0) },
            saveRelinkedBookmark: { bookmark, expectedPath in
                try ProfileAudioRootWriter.applyRelinkedBookmarkLive(
                    bookmark, expectedPath: expectedPath, profileID: profileID
                )
                StorageLocationManager.adoptRepairedBookmark(
                    bookmark, expectedPath: expectedPath
                )
            }
        )
    }

    /// Balanced authorization probe: resolves the bookmark, requires the
    /// resolution to byte-match the recorded lexical path (a bookmark
    /// follows a moved directory, the identity does not), then takes a
    /// security-scoped claim only to release it immediately — the
    /// process-lifetime claim stays owned by the storage resolver.
    nonisolated static func bookmarkGrantsAccess(
        _ data: Data, expectedPath: String
    ) -> Bool {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }
        guard LexicalPathIdentity.equals(url.path, expectedPath) else { return false }
        guard url.startAccessingSecurityScopedResource() else { return false }
        url.stopAccessingSecurityScopedResource()
        return true
    }
}

/// Per-recording repair for a `legacyAbsolute` audio reference whose file
/// could not be rewritten by the M1 migration (spec 10.3): candidates are
/// found by byte-exact filename inside the current root, and the user
/// explicitly picks the one to adopt — one match still requires
/// confirmation, several matches require a selection, and nothing is ever
/// rewritten without that explicit choice. The store rewrites only the
/// selected recording's audio reference, through the resolver's
/// containment rules.
@MainActor
@Observable
final class LegacyAudioRelinkCoordinator {
    enum Phase: Equatable {
        case idle
        /// The filename walk is running off the main actor; the surface
        /// shows progress instead of an idle button.
        case searching
        /// No same-named file exists in the current root.
        case noMatch
        /// Candidates found; the user must explicitly pick one.
        case matches([URL])
        /// The rewrite is running; adoption taps are refused truthfully.
        case relinking
        /// The rewrite threw; the row is unchanged (rollback-covered)
        /// and retrying is safe.
        case saveFailed(message: String)
        case repaired
    }

    struct Dependencies {
        /// Byte-exact filename search constrained to the current root.
        var searchCandidates: @MainActor (String) async -> [URL]
        /// Store rewrite for exactly this recording; throws with the row
        /// unchanged on failure.
        var relink: @MainActor (UUID, URL) async throws -> Void
    }

    let recordingID: UUID
    /// Filename identity from the legacy reference; search and adoption
    /// both bind to it.
    let fileName: String

    private(set) var phase: Phase = .idle
    private let dependencies: Dependencies
    /// Invalidates in-flight walks: cancel or a newer search bumps it, so
    /// a stale result can never land in a later phase.
    private var searchGeneration = 0
    /// The in-flight search, owned so cancel and page departure stop the
    /// traversal itself rather than merely discarding its result.
    private var searchTask: Task<[URL], Never>?

    init(recordingID: UUID, fileName: String, dependencies: Dependencies) {
        self.recordingID = recordingID
        self.fileName = fileName
        self.dependencies = dependencies
    }

    func search() async {
        switch phase {
        case .repaired, .searching, .relinking:
            return
        case .idle, .noMatch, .matches, .saveFailed:
            break
        }
        searchGeneration += 1
        let generation = searchGeneration
        phase = .searching
        let name = fileName
        let dependencies = dependencies
        let task = Task { await dependencies.searchCandidates(name) }
        searchTask = task
        let candidates = await task.value
        // Only this generation may clear the handle: a cancel followed by
        // a newer search must keep the newer task cancellable.
        if generation == searchGeneration { searchTask = nil }
        guard generation == searchGeneration, case .searching = phase else { return }
        phase = candidates.isEmpty ? .noMatch : .matches(candidates)
    }

    func cancel() {
        switch phase {
        case .repaired, .relinking:
            return
        case .idle, .searching, .noMatch, .matches, .saveFailed:
            searchTask?.cancel()
            searchTask = nil
            searchGeneration += 1
            phase = .idle
        }
    }

    /// Adopts one candidate. Only URLs from the current search result are
    /// accepted — an arbitrary URL is refused without touching the store.
    func adopt(_ url: URL) async {
        guard case .matches(let candidates) = phase,
              candidates.contains(where: { LexicalPathIdentity.equals($0.path, url.path) })
        else { return }
        phase = .relinking
        do {
            try await dependencies.relink(recordingID, url)
            phase = .repaired
        } catch {
            phase = .saveFailed(message: LocalizedBundle.string(
                "The file couldn't be relinked — try again.", locale: nil
            ))
            NSLog(
                "[LegacyAudioRelink] rewrite failed for %@: %@",
                recordingID.uuidString, String(describing: error)
            )
        }
    }

    /// Live wiring over the store boundary; the search walks the store's
    /// current root so the containment authority and the search authority
    /// are the same resolver.
    static func live(
        recordingID: UUID, fileName: String, store: RecordingsStore
    ) -> LegacyAudioRelinkCoordinator {
        LegacyAudioRelinkCoordinator(
            recordingID: recordingID,
            fileName: fileName,
            dependencies: Dependencies(
                searchCandidates: { name in
                    await performLiveSearch(name: name, store: store)
                },
                relink: { id, url in
                    try await store.relinkLegacyAudioReference(recordingID: id, to: url)
                }
            )
        )
    }

    /// Live search: the filesystem walk is IO-bound and must not run on
    /// the main actor — only the Sendable name and root cross into the
    /// detached task. Detached tasks do not inherit cancellation, so the
    /// caller's cancellation is bridged explicitly and the walker checks
    /// it during traversal.
    static func performLiveSearch(name: String, store: RecordingsStore) async -> [URL] {
        let resolver = await store.resolver
        let root = resolver.root
        let walk = Task.detached(priority: .userInitiated) {
            findFilesNamed(name, under: root)
        }
        return await withTaskCancellationHandler {
            await walk.value
        } onCancel: {
            walk.cancel()
        }
    }

    /// Recursive byte-exact filename search under the root. Hidden files
    /// are skipped (staging entries are dot-prefixed); results are in
    /// UTF-8 byte order, which stays total and deterministic when
    /// canonically equivalent spellings tie under String comparison.
    nonisolated static func findFilesNamed(_ name: String, under root: URL) -> [URL] {
        guard !Task.isCancelled else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            // Prompt exit on cancellation: the caller discards partial
            // results, so returning early is safe.
            if Task.isCancelled { return [] }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            if LexicalPathIdentity.equals(url.lastPathComponent, name) {
                matches.append(url)
            }
        }
        return matches.sorted { LexicalPathIdentity.isOrderedBefore($0.path, $1.path) }
    }
}
