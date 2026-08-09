import Foundation
import SwiftData

/// Local SwiftData store running on its own ModelActor executor.
/// Replaces XPC-based data access for recordings, folders, and post-processing jobs.
@ModelActor
actor RecordingsStore {

    typealias BackfillRecording = (id: UUID, audioFileURL: URL, title: String, hasTranscript: Bool)
    typealias CalendarAutoLinkCandidate = (id: UUID, startDate: Date, endDate: Date)

    struct SpeakerAnalysisSnapshot: Sendable {
        let detail: RecordingDetailDTO
        let speakerIdentityRevision: UInt64
    }

    enum SpeakerIdentityWriteResult: Sendable, Equatable {
        case applied
        case rejectedStaleRevision
        case preservedExistingMapping
        case targetMissing
        case saveFailed
    }

    enum TrackedAudioPathError: Error, Sendable, Equatable {
        case unresolvableReference(recordingID: UUID, storageValue: String)
    }

    enum PermanentDeletionFailure: Sendable, Equatable {
        case fileStagingFailed
        case persistenceFailed
        case rollbackIncomplete
        case pendingCleanupRecoveryFailed
    }

    enum PermanentDeletionOutcome: Sendable, Equatable {
        case deleted(count: Int)
        /// SwiftData committed and the original paths are gone, but a tracked
        /// quarantine payload or manifest still needs a later cleanup retry.
        case cleanupPending(count: Int)
        case nothingToDelete
        case failed(PermanentDeletionFailure)

        var committedCount: Int {
            switch self {
            case .deleted(let count), .cleanupPending(let count): count
            case .nothingToDelete, .failed: 0
            }
        }

        var didCommitDeletion: Bool {
            committedCount > 0
        }
    }

    enum DeletionFileOperationForTesting: Sendable, Equatable {
        case writeManifest
        case stageMove
        case restoreMove
        case cleanupPayload
        case cleanupManifest
    }

    // Detail DTO cache — avoids rebuilding full DTO on every loadDetail() call.
    // Invalidated on any save() to keep data fresh.
    var detailCache: [UUID: RecordingDetailDTO] = [:]

    /// In-memory generation for speaker-derived data. Retranscription advances
    /// the generation so an older embedding task cannot write stale samples or
    /// mappings after the new transcript has cleared them.
    private var speakerIdentityRevisions: [UUID: UInt64] = [:]

    private var speakerMemoryWriteGeneration: UInt64 = 0

    /// Audio root override for tests; production always follows the live
    /// storage location. Read through `resolver` only.
    private var audioRootOverride: URL?

    /// Boundary resolver between stored reference strings and URLs. Reads
    /// the storage location on every use so directory changes apply
    /// immediately. Internal (not private) so the archive extension shares
    /// the same boundary.
    var resolver: ProfileStorageResolver {
        ProfileStorageResolver(root: audioRootOverride ?? StorageLocationManager.recordingsDirectory)
    }

    /// Retry any durable hard-delete journal on one captured storage root.
    /// Callers that use the live root must hold a StorageMigrationGate
    /// activity lease for the full call and for any subsequent retry loop.
    @discardableResult
    func recoverPendingDeletionTransactions() -> Bool {
        let transactionResolver = resolver
        do {
            try recoverPendingDeletionTransactions(resolver: transactionResolver)
            return true
        } catch {
            NSLog(
                "[RecordingsStore] pending deletion recovery failed: %@",
                error.localizedDescription
            )
            return false
        }
    }

    /// Strict write-side conversion (spec §10.3): every normal write stores
    /// a relative reference. An out-of-root URL is a programming error — the
    /// directory-change flow is gated against active recording and
    /// processing — so the write fails loudly instead of degrading to a
    /// legacy value; crash recovery keeps the segments evidence.
    private func makeRelativeReference(for url: URL) throws -> AudioFileReference {
        do {
            return try resolver.makeReference(for: url)
        } catch {
            NSLog("[RecordingsStore] rejected out-of-root write %@: %@", url.path, "\(error)")
            throw error
        }
    }

    /// Throwing save for multi-row reference rewrites (split-root pin,
    /// migration relocation): rolls back on failure so a later save cannot
    /// persist a partial batch.
    private func saveReferenceRewriteOrRollback() throws {
        detailCache.removeAll()
#if DEBUG
        if injectedSaveFailuresRemaining > 0 {
            injectedSaveFailuresRemaining -= 1
            modelContext.rollback()
            NSLog("[RecordingsStore] save failed: injected in-memory test failure")
            throw ReferenceRewriteError.saveFailed
        }
#endif
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            NSLog("[RecordingsStore] save failed: %@", error.localizedDescription)
            throw error
        }
    }

    enum ReferenceRewriteError: Error, Equatable {
        case saveFailed
        /// A legacy row covered by the migration's copy mapping could not be
        /// rewritten. The migration must abort (and discard its copies) —
        /// completing it would delete the row's source file and leave the
        /// reference dangling.
        case relocationIncomplete(String)
    }

    /// Resolves a stored reference, or nil when the column is empty.
    /// Resolution failures (malformed relative values) surface as nil plus
    /// a log line — callers treat them like a missing file.
    func resolveURL(_ reference: AudioFileReference?) -> URL? {
        guard let reference else { return nil }
        do {
            return try resolver.resolveAudio(reference)
        } catch {
            NSLog(
                "[RecordingsStore] reference failed to resolve (%@): %@",
                reference.storageValue, "\(error)"
            )
            return nil
        }
    }

#if DEBUG
    private enum InjectedStoreReadError: Error {
        case trackedAudioPaths
    }

    /// Deterministic one-shot failure seam for isolated in-memory tests.
    private var injectedSaveFailuresRemaining = 0
    private var injectedStandalonePreflightSaveFailuresRemaining = 0
    private var injectedTrackedAudioPathFetchFailuresRemaining = 0
    private var injectedWebSyncDiscoveryFailuresRemaining = 0
    private var injectedWebSyncSnapshotFailuresRemaining = 0
    private var speakerMemoryConsentOverride: Bool?
    private var injectedDeletionFileFailure:
        (operation: DeletionFileOperationForTesting, successfulCallsBeforeFailure: Int)?
    private var deletionRootSwitchAfterJournalForTesting: URL?

    /// Rejects the filesystem root by normalized lexical path: a root of
    /// "/" makes every absolute path "in-root" and authorizes deletion and
    /// cleanup across the whole disk. Separate from the setter so the
    /// predicate itself has direct regression coverage.
    nonisolated static func isValidTestAudioRoot(_ root: URL) -> Bool {
        root.resolvingSymlinksInPath().standardizedFileURL.pathComponents.count > 1
    }

    /// Explicit per-store test root: the resolver reads it instead of the
    /// process-global storage location, so disk-backed test stores never
    /// touch global state across suspension points.
    func setAudioRootForTesting(_ root: URL?) {
        if let root {
            precondition(
                Self.isValidTestAudioRoot(root),
                "Audio root override must be a scoped directory, not the filesystem root."
            )
        }
        audioRootOverride = root
    }

    /// Seeds raw column values (e.g. legacy absolute rows from upgraded
    /// installs) — normal write APIs are strictly relative and cannot
    /// produce these states.
    func setRawAudioReferencesForTesting(
        recordingID: UUID, audioFilePath: String?, segmentsDirectory: String?
    ) -> Bool {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Raw reference seeding is restricted to in-memory stores."
        )
        guard let recording = recording(byID: recordingID) else { return false }
        recording.audioFilePath = audioFilePath
        recording.audioSegmentsDirectory = segmentsDirectory
        return save()
    }

    func failNextSaveForTesting() {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Save failure injection is restricted to in-memory stores."
        )
        injectedSaveFailuresRemaining += 1
    }

    /// Fails the pending-change preflight before a standalone mutation. This
    /// is separate from `failNextSaveForTesting()` so tests can prove the
    /// mutation is never applied when already-staged work cannot be flushed.
    func failNextStandalonePreflightSaveForTesting() {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Standalone preflight failure injection is restricted to in-memory stores."
        )
        injectedStandalonePreflightSaveFailuresRemaining += 1
    }

    /// Injects one tracked-audio catalogue read failure. Orphan recovery must
    /// treat this as an unknown database state, never as an empty catalogue.
    func failNextTrackedAudioPathFetchForTesting() {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Tracked-audio fetch failure injection is restricted to in-memory stores."
        )
        injectedTrackedAudioPathFetchFailuresRemaining += 1
    }

    /// Deterministic filesystem failure seam for the permanent-deletion
    /// transaction. `successfulCallsBeforeFailure` lets a test stage one path
    /// successfully, fail the next, and prove the first move is rolled back.
    func failDeletionFileOperationForTesting(
        _ operation: DeletionFileOperationForTesting,
        successfulCallsBeforeFailure: Int = 0
    ) {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Deletion file failure injection is restricted to in-memory stores."
        )
        injectedDeletionFileFailure = (
            operation,
            max(0, successfulCallsBeforeFailure)
        )
    }

    /// Simulates an unsanctioned root-authority change immediately after the
    /// durable journal is written. A deletion transaction must keep using its
    /// captured resolver even if the live provider changes mid-operation.
    func switchDeletionRootAfterJournalForTesting(to root: URL) {
        precondition(Self.isValidTestAudioRoot(root))
        deletionRootSwitchAfterJournalForTesting = root
    }

    func pendingDeletionTransactionCountForTesting() -> Int {
        let transactionResolver = resolver
        let manifestsURL = deletionManifestsURL(resolver: transactionResolver)
        guard itemExists(at: manifestsURL) else { return 0 }
        return ((try? FileManager.default.contentsOfDirectory(
            at: manifestsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []).count { $0.pathExtension == "json" }
    }

    @discardableResult
    func recoverPendingDeletionTransactionsForTesting() -> Bool {
        recoverPendingDeletionTransactions()
    }

    /// Injects one discovery read failure. Kept separate from save injection so
    /// coordinator tests can prove a failed queue load never looks like an
    /// authoritative empty library.
    func failNextWebSyncDiscoveryForTesting() {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Web sync discovery failure injection is restricted to in-memory stores."
        )
        injectedWebSyncDiscoveryFailuresRemaining += 1
    }

    /// Injects one detail read failure after queue discovery has succeeded.
    /// This proves a transient row fetch error cannot be mistaken for a
    /// recording that was actually deleted while a policy refresh is active.
    func failNextWebSyncSnapshotForTesting() {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Web sync snapshot failure injection is restricted to in-memory stores."
        )
        injectedWebSyncSnapshotFailuresRemaining += 1
    }

    private func throwInjectedWebSyncDiscoveryFailureIfNeeded() throws {
        guard injectedWebSyncDiscoveryFailuresRemaining > 0 else { return }
        injectedWebSyncDiscoveryFailuresRemaining -= 1
        NSLog("[RecordingsStore] web sync discovery failed: injected in-memory test failure")
        throw WebSyncPersistenceError.fetchFailed
    }

    private func throwInjectedWebSyncSnapshotFailureIfNeeded() throws {
        guard injectedWebSyncSnapshotFailuresRemaining > 0 else { return }
        injectedWebSyncSnapshotFailuresRemaining -= 1
        NSLog("[RecordingsStore] web sync snapshot failed: injected in-memory test failure")
        throw WebSyncPersistenceError.fetchFailed
    }

    /// Typed row snapshot for mutation-scope assertions: tests compare
    /// whole values before and after an operation instead of mirroring
    /// fields through joined strings.
    struct RowSnapshotForTesting: Equatable, Sendable {
        var title: String
        var startDate: Date
        var createdAt: Date?
        var updatedAt: Date?
        var audio: AudioFileReference?
        var segments: AudioFileReference?
        var ownership: AudioFileOwnership
        var tags: [String]
        var duration: TimeInterval
    }

    func rowSnapshotForTesting(recordingID: UUID) -> RowSnapshotForTesting? {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Row snapshots are restricted to in-memory stores."
        )
        guard let recording = recording(byID: recordingID) else { return nil }
        return RowSnapshotForTesting(
            title: recording.title,
            startDate: recording.startDate,
            createdAt: recording.createdAt,
            updatedAt: recording.updatedAt,
            audio: recording.audioFileReference,
            segments: recording.segmentsDirectoryReference,
            ownership: recording.ownership,
            tags: recording.tags,
            duration: recording.duration
        )
    }

    func setOwnershipForTesting(recordingID: UUID, _ ownership: AudioFileOwnership) -> Bool {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Ownership seeding is restricted to in-memory stores."
        )
        guard let recording = recording(byID: recordingID) else { return false }
        recording.ownership = ownership
        return save()
    }

    func setSpeakerMemoryConsentForTesting(_ enabled: Bool?) {
        precondition(
            !modelContainer.configurations.isEmpty
                && modelContainer.configurations.allSatisfy { $0.isStoredInMemoryOnly },
            "Speaker-memory consent override is restricted to in-memory stores."
        )
        speakerMemoryConsentOverride = enabled
    }
#endif
    private var activeWebSyncUserID: String?

    // MARK: - Schema

    static let schema = Schema([
        Recording.self, Transcript.self, MeetingSummary.self, ExternalRecordingImport.self,
        Folder.self, SpeakerProfile.self, SpeakerVoiceSample.self,
        Recap.self, AgentArtifact.self, WebSyncRecord.self
    ])

    /// Container at an explicit store location (profile boot). The legacy
    /// no-argument variant below stays for the pre-commit fallback path.
    static func makeContainer(storeURL: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(url: storeURL)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [config])
        }

        // Use a Cadenza-specific database path to avoid conflicts with other SwiftData apps
        // that use the default "default.store" location.
        let appSupport = DebugDataRoot.applicationSupportDirectory()
        let cadenzaDir = appSupport.appendingPathComponent("Cadenza", isDirectory: true)
        try FileManager.default.createDirectory(at: cadenzaDir, withIntermediateDirectories: true)
        let storeURL = cadenzaDir.appendingPathComponent("Cadenza.store")

        // Migrate from old default location if needed
        let oldStorePath = appSupport.appendingPathComponent("default.store")
        if !FileManager.default.fileExists(atPath: storeURL.path)
            && FileManager.default.fileExists(atPath: oldStorePath.path) {
            NSLog("[RecordingsStore] migrating database from default.store to Cadenza/Cadenza.store")
            do {
                try FileManager.default.copyItem(at: oldStorePath, to: storeURL)
                for ext in ["-wal", "-shm"] {
                    let src = URL(fileURLWithPath: oldStorePath.path + ext)
                    let dst = URL(fileURLWithPath: storeURL.path + ext)
                    if FileManager.default.fileExists(atPath: src.path) {
                        try FileManager.default.copyItem(at: src, to: dst)
                    }
                }
            } catch {
                NSLog("[RecordingsStore] migration failed: %@, starting fresh", error.localizedDescription)
            }
        }

        let config = ModelConfiguration(url: storeURL)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Recording Queries

    /// Cooperative cancellation plus lightweight probes for the synchronous
    /// SwiftData search walk. Production reads the current task's cancellation
    /// state; tests can observe fetches/visits without changing search results.
    struct SearchExecutionControl: Sendable {
        let isCancelled: @Sendable () -> Bool
        let didFetch: @Sendable (_ rowCount: Int) -> Void
        let didVisit: @Sendable (_ recordingID: UUID) -> Void

        static let live = SearchExecutionControl()

        init(
            isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
            didFetch: @escaping @Sendable (_ rowCount: Int) -> Void = { _ in },
            didVisit: @escaping @Sendable (_ recordingID: UUID) -> Void = { _ in }
        ) {
            self.isCancelled = isCancelled
            self.didFetch = didFetch
            self.didVisit = didVisit
        }
    }

    func fetchRecordingDTOs(sortKey: String, folderID: UUID?, tagFilter: String?) -> [RecordingDTO] {
        filteredAndSortedRecordings(
            fetchScopedRecordings(folderID: folderID),
            sortKey: sortKey,
            tagFilter: tagFilter
        ).map { recordingToDTO($0) }
    }

    func searchRecordingDTOs(
        query: String,
        sortKey: String,
        folderID: UUID?,
        tagFilter: String?,
        executionControl: SearchExecutionControl = .live
    ) -> [RecordingDTO] {
        guard !executionControl.isCancelled() else { return [] }

        let fetched = fetchScopedRecordings(folderID: folderID)
        executionControl.didFetch(fetched.count)
        guard !executionControl.isCancelled() else { return [] }

        let recordings = filteredAndSortedRecordings(
            fetched,
            sortKey: sortKey,
            tagFilter: tagFilter
        )
        guard !executionControl.isCancelled() else { return [] }

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var matches: [Recording] = []
        matches.reserveCapacity(recordings.count)

        for recording in recordings {
            guard !executionControl.isCancelled() else { return [] }
            executionControl.didVisit(recording.id)
            guard !executionControl.isCancelled() else { return [] }

            if q.isEmpty || recordingMatchesSearch(recording, query: q) {
                matches.append(recording)
            }
        }

        guard !executionControl.isCancelled() else { return [] }
        var results: [RecordingDTO] = []
        results.reserveCapacity(matches.count)
        for recording in matches {
            guard !executionControl.isCancelled() else { return [] }
            results.append(recordingToDTO(recording))
        }
        return results
    }

    private func fetchScopedRecordings(folderID: UUID?) -> [Recording] {
        var descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )

        if let folderID {
            descriptor.predicate = #Predicate { $0.trashedDate == nil && $0.folder?.id == folderID }
        } else {
            descriptor.predicate = #Predicate { $0.trashedDate == nil }
        }

        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Applies the tag workaround and list ordering shared by browsing and
    /// search to rows from a single active-folder fetch.
    private func filteredAndSortedRecordings(
        _ fetched: [Recording],
        sortKey: String,
        tagFilter: String?
    ) -> [Recording] {
        var recordings = fetched

        // Tag filtering must stay out of the #Predicate: `tags.contains` compiles
        // to a SQL string search (_NSCoreDataStringSearch) that segfaults on rows
        // whose tags column is NULL — i.e. any recording without tags.
        if let tagFilter, !tagFilter.isEmpty {
            // Match by formatKey so a filter like "designreview" still hits stored "design-review".
            let key = TagNormalizer.formatKey(tagFilter)
            recordings = recordings.filter { rec in rec.tags.contains { TagNormalizer.formatKey($0) == key } }
        }

        let sorted: [Recording]
        switch sortKey {
        case "dateOldest":
            sorted = recordings.sorted { $0.startDate < $1.startDate }
        case "recentlyAccessed":
            sorted = recordings.sorted { ($0.lastAccessedDate ?? .distantPast) > ($1.lastAccessedDate ?? .distantPast) }
        case "nameAZ":
            sorted = recordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "nameZA":
            sorted = recordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        default:
            sorted = recordings
        }

        return sorted
    }

    private func recordingMatchesSearch(_ recording: Recording, query: String) -> Bool {
        if recording.title.localizedCaseInsensitiveContains(query) { return true }
        if recording.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if let text = recording.transcript?.fullText,
           text.localizedCaseInsensitiveContains(query) { return true }
        if let overview = recording.summary?.overview,
           overview.localizedCaseInsensitiveContains(query) { return true }
        if let keyPoints = recording.summary?.keyPoints,
           keyPoints.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if let decisions = recording.summary?.decisions,
           decisions.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if let followUps = recording.summary?.followUps,
           followUps.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if let actionItems = recording.summary?.actionItems,
           actionItems.contains(where: {
               $0.task.localizedCaseInsensitiveContains(query)
                   || ($0.assignee?.localizedCaseInsensitiveContains(query) ?? false)
           }) { return true }
        return false
    }

    func fetchRecordingDetail(recordingID: UUID) -> RecordingDetailDTO? {
        if let cached = detailCache[recordingID] { return cached }
        guard let recording = recording(byID: recordingID) else { return nil }
        let dto = recordingToDetailDTO(recording)
        detailCache[recordingID] = dto
        return dto
    }

    /// Uncached variant for bulk-export / archive enumeration — bypasses
    /// detailCache so walking the whole library doesn't pin every transcript
    /// in memory for the rest of the process lifetime.
    func fetchRecordingDetailUncached(recordingID: UUID) -> RecordingDetailDTO? {
        guard let recording = recording(byID: recordingID) else { return nil }
        return recordingToDetailDTO(recording)
    }

    /// Archive bundle: detail + the fields the DTO doesn't carry, from a
    /// single model fetch, uncached (see fetchRecordingDetailUncached).
    /// Throwing：DB 读取错误必须与"行不存在"（返回 nil）可区分——
    /// 前者是导出失败，后者是"导出期间被删除"。
    func fetchArchiveDetailBundle(
        recordingID: UUID
    ) throws -> (detail: RecordingDetailDTO, trashedDate: Date?, segmentsDirectory: AudioFileReference?, calendarAutoLinkState: String?, audioOwnership: String?)? {
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == recordingID }
        )
        descriptor.fetchLimit = 1
        guard let recording = try modelContext.fetch(descriptor).first else { return nil }
        return (
            recordingToDetailDTO(recording),
            recording.trashedDate,
            recording.segmentsDirectoryReference,
            recording.calendarAutoLinkState,
            recording.audioFileOwnership
        )
    }

    /// Mark a recording as recently accessed (call once when the user opens the detail page).
    /// Uses direct modelContext.save() to avoid clearing the detail cache — lastAccessedDate
    /// is not important for display and this is called on every detail page open.
    @discardableResult
    func markAccessed(recordingID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        recording.lastAccessedDate = Date()
        do {
            try modelContext.save()
            return true
        } catch {
            return false
        }
    }

    /// Read-only duration fetch — no side effects (no lastAccessedDate write).
    func fetchRecordingDuration(recordingID: UUID) -> TimeInterval {
        guard let recording = recording(byID: recordingID) else { return 0 }
        return recording.duration
    }

    func fetchFolders() -> [FolderDTO] {
        let descriptor = FetchDescriptor<Folder>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let folders = (try? modelContext.fetch(descriptor)) ?? []
        return folders.map { folderToDTO($0) }
    }

    func fetchTrashedRecordings() -> [RecordingDTO] {
        var descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.trashedDate, order: .reverse)]
        )
        descriptor.predicate = #Predicate { $0.trashedDate != nil }
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return recordings.map { recordingToDTO($0) }
    }

    // MARK: - Recording CRUD

    @discardableResult
    func createRecording(id: UUID, title: String, startDate: Date, language: String = "auto", segmentsDirURL: URL?) -> Bool {
        let segmentsReference: AudioFileReference?
        do {
            segmentsReference = try segmentsDirURL.map { try makeRelativeReference(for: $0) }
        } catch {
            return false
        }
        let recording = Recording(id: id, title: title, startDate: startDate, language: language)
        recording.segmentsDirectoryReference = segmentsReference
        return performStandaloneMutation {
            modelContext.insert(recording)
        }
    }

    /// Resolved paths of all audio files currently tracked in the database
    /// (orphan-recovery scan compares directory listings against this set).
    /// A nil reference is a valid row without published audio; any non-nil
    /// reference that cannot be resolved makes the entire catalogue unknown.
    func allTrackedAudioPaths() throws -> Set<String> {
#if DEBUG
        if injectedTrackedAudioPathFetchFailuresRemaining > 0 {
            injectedTrackedAudioPathFetchFailuresRemaining -= 1
            throw InjectedStoreReadError.trackedAudioPaths
        }
#endif
        let descriptor = FetchDescriptor<Recording>()
        let recordings = try modelContext.fetch(descriptor)
        var paths = Set<String>()
        paths.reserveCapacity(recordings.count)
        for recording in recordings {
            guard let reference = recording.audioFileReference else { continue }
            do {
                paths.insert(try resolver.resolveAudio(reference).path)
            } catch {
                NSLog(
                    "[RecordingsStore] tracked audio reference failed to resolve for %@: %@",
                    recording.id.uuidString,
                    error.localizedDescription
                )
                throw TrackedAudioPathError.unresolvableReference(
                    recordingID: recording.id,
                    storageValue: reference.storageValue
                )
            }
        }
        return paths
    }

    /// Import an audio file as a new recording. Returns the recording ID on success.
    /// `ownership` records file provenance (INV-18): `appCreated` only when
    /// this import wrote the file (copy/transcode); reuse of an existing
    /// file and orphan recovery pass `unknownLegacy`.
    func importAudioFile(
        id: UUID,
        title: String,
        startDate: Date,
        duration: TimeInterval,
        audioURL: URL,
        ownership: AudioFileOwnership,
        language: String = "auto",
        meetingApp: String? = nil,
        meetingURL: String? = nil,
        linkedCalendarEventID: String? = nil,
        calendarAutoLinkState: String? = CalendarAutoLinkState.pending.rawValue
    ) -> Bool {
        let audioReference: AudioFileReference
        do {
            audioReference = try makeRelativeReference(for: audioURL)
        } catch {
            return false
        }
        let recording = Recording(
            id: id,
            title: title,
            startDate: startDate,
            language: language,
            source: .importedAudio
        )
        recording.audioFileReference = audioReference
        recording.ownership = ownership
        recording.duration = duration
        recording.endDate = startDate.addingTimeInterval(duration)
        recording.meetingApp = meetingApp
        recording.meetingURL = meetingURL
        recording.linkedCalendarEventID = linkedCalendarEventID
        recording.calendarAutoLinkState = linkedCalendarEventID == nil ? calendarAutoLinkState : CalendarAutoLinkState.linked.rawValue
        recording.calendarAutoLinkAttemptedAt = linkedCalendarEventID == nil ? nil : Date()
        return performStandaloneMutation {
            modelContext.insert(recording)
        }
    }

    enum FinalizeResult: Sendable, Equatable { case saved, discarded, failed }

    /// Compatibility helper for imported/test recordings without a captured
    /// stop timestamp. Live and recovery finalization must call the explicit
    /// `endDate` overload below.
    @discardableResult
    func finalizeRecording(
        id: UUID,
        duration: TimeInterval,
        audioFileURL: URL?
    ) -> FinalizeResult {
        guard let recording = recording(byID: id) else { return .failed }
        return finalizeRecording(
            id: id,
            duration: duration,
            endDate: recording.startDate.addingTimeInterval(duration),
            audioFileURL: audioFileURL
        )
    }

    @discardableResult
    func finalizeRecording(
        id: UUID,
        duration: TimeInterval,
        endDate: Date,
        audioFileURL: URL?
    ) -> FinalizeResult {
        guard let recording = recording(byID: id) else { return .failed }
        guard persistPendingChangesBeforeFinalization() else { return .failed }

        if duration < autoDiscardThreshold {
            NSLog("[RecordingsStore] auto-discarding short recording %@: duration=%.1f < %.0fs", id.uuidString, duration, autoDiscardThreshold)
            modelContext.delete(recording)
            return saveFinalizationTransaction() ? .discarded : .failed
        }

        recording.duration = duration
        recording.endDate = endDate
        if let audioFileURL {
            guard let reference = try? makeRelativeReference(for: audioFileURL) else {
                modelContext.rollback()
                return .failed
            }
            recording.audioFileReference = reference
            // Finalization binds the file the recording pipeline wrote —
            // the one provenance the app can prove (INV-18).
            recording.ownership = .appCreated
            recording.audioSegmentsDirectory = nil
        }
        touch(recording)
        return saveFinalizationTransaction() ? .saved : .failed
    }

    // MARK: - Audio Ownership (INV-18)

    func audioOwnership(recordingID: UUID) -> AudioFileOwnership? {
        recording(byID: recordingID)?.ownership
    }

    /// Copy-on-write switch target: points the row at a newly written file
    /// and records its ownership in one save. The previous file's bytes are
    /// never touched here — callers replace in place only for `appCreated`
    /// originals.
    func replaceAudioFile(
        recordingID: UUID, newURL: URL, ownership: AudioFileOwnership
    ) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let reference: AudioFileReference
        do {
            reference = try makeRelativeReference(for: newURL)
        } catch {
            NSLog(
                "[RecordingsStore] replaceAudioFile rejected for %@: %@",
                recordingID.uuidString, String(describing: error)
            )
            return false
        }
        recording.audioFileReference = reference
        recording.ownership = ownership
        touch(recording)
        guard save() else {
            // The in-memory row must not keep pointing at a file the
            // caller is about to discard.
            modelContext.rollback()
            return false
        }
        return true
    }

    // MARK: - Storage Cleanup

    @discardableResult
    func cleanupStorage() -> StorageQuotaStatus {
        let limitMB = UserDefaults.standard.integer(forKey: "storageLimitMB")
        return cleanupStorage(
            root: StorageLocationManager.recordingsDirectory,
            limitMegabytes: limitMB
        )
    }

    @discardableResult
    func cleanupStorage(root: URL, limitMegabytes: Int) -> StorageQuotaStatus {
        cleanupStorage(
            root: root,
            limitBytes: StorageQuotaStatus.limitBytes(fromMegabytes: limitMegabytes)
        )
    }

    @discardableResult
    func cleanupStorage(root: URL, limitBytes: Int64?) -> StorageQuotaStatus {
        let status = storageQuotaStatus(root: root, limitBytes: limitBytes)
        if status.isOverLimit {
            NSLog(
                "[RecordingsStore] owned storage %.1f MB exceeds limit; active recordings were preserved",
                Double(status.usage.ownedBytes) / 1_048_576
            )
        }
        return status
    }

    func storageQuotaStatus() -> StorageQuotaStatus {
        let limitMB = UserDefaults.standard.integer(forKey: "storageLimitMB")
        return storageQuotaStatus(
            root: StorageLocationManager.recordingsDirectory,
            limitMegabytes: limitMB
        )
    }

    func storageQuotaStatus(root: URL, limitMegabytes: Int) -> StorageQuotaStatus {
        storageQuotaStatus(
            root: root,
            limitBytes: StorageQuotaStatus.limitBytes(fromMegabytes: limitMegabytes)
        )
    }

    func storageQuotaStatus(root: URL, limitBytes: Int64?) -> StorageQuotaStatus {
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        let ownedFiles = recordings.compactMap { recording in
            resolveURL(recording.audioFileReference)
        }
        let ownedDirectories = recordings.compactMap { recording in
            resolveURL(recording.segmentsDirectoryReference)
        }
        let usage = StorageOwnership.measureUsage(
            in: root,
            ownedFiles: ownedFiles,
            ownedDirectories: ownedDirectories
        )
        return StorageQuotaStatus(usage: usage, limitBytes: limitBytes)
    }

    private var autoDiscardThreshold: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "autoDiscardThreshold")
        return v > 0 ? v : 30.0
    }

    /// Durable journal for file moves that straddle a SwiftData commit.
    /// The manifest lives outside its payload and is removed last, so every
    /// post-commit byte remains discoverable until cleanup has completed.
    private struct DeletionManifest: Codable, Sendable {
        struct Entry: Codable, Sendable {
            let sourceSubpath: String
            let stagedSubpath: String
        }

        let version: Int
        let transactionID: UUID
        let recordingIDs: [UUID]
        let entries: [Entry]
    }

    private enum DeletionTransactionError: Error {
        case invalidPath
        case inconsistentJournal
        case injectedFileFailure
    }

    private static let deletionQuarantineDirectory = ".cadenza-delete-quarantine"

    private func deletionQuarantineURL(resolver: ProfileStorageResolver) -> URL {
        resolver.root.appendingPathComponent(Self.deletionQuarantineDirectory, isDirectory: true)
    }

    private func deletionManifestsURL(resolver: ProfileStorageResolver) -> URL {
        deletionQuarantineURL(resolver: resolver)
            .appendingPathComponent("manifests", isDirectory: true)
    }

    private func deletionPayloadsURL(resolver: ProfileStorageResolver) -> URL {
        deletionQuarantineURL(resolver: resolver)
            .appendingPathComponent("payloads", isDirectory: true)
    }

    private func deletionManifestURL(
        transactionID: UUID,
        resolver: ProfileStorageResolver
    ) -> URL {
        deletionManifestsURL(resolver: resolver)
            .appendingPathComponent(transactionID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private func deletionPayloadURL(
        transactionID: UUID,
        resolver: ProfileStorageResolver
    ) -> URL {
        deletionPayloadsURL(resolver: resolver).appendingPathComponent(
            transactionID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func itemExists(at url: URL, fileManager: FileManager = .default) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func resolveDeletionSubpath(
        _ subpath: String,
        resolver: ProfileStorageResolver
    ) throws -> URL {
        let components = subpath.split(separator: "/", omittingEmptySubsequences: false)
        guard !subpath.isEmpty,
              !subpath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeletionTransactionError.invalidPath
        }
        return try resolver.resolveAudio(.relative(subpath))
    }

    private func throwInjectedDeletionFileFailureIfNeeded(
        _ operation: DeletionFileOperationForTesting
    ) throws {
#if DEBUG
        guard var injection = injectedDeletionFileFailure,
              injection.operation == operation else { return }
        if injection.successfulCallsBeforeFailure > 0 {
            injection.successfulCallsBeforeFailure -= 1
            injectedDeletionFileFailure = injection
            return
        }
        injectedDeletionFileFailure = nil
        NSLog("[RecordingsStore] deletion file operation failed: injected in-memory test failure")
        throw DeletionTransactionError.injectedFileFailure
#else
        _ = operation
#endif
    }

    private func sourceSubpathsForDeletion(
        _ recordings: [Recording],
        resolver: ProfileStorageResolver
    ) throws -> [String] {
        var subpaths: [String] = []

        for recording in recordings {
            var references: [AudioFileReference] = []
            if recording.ownership == .appCreated,
               let audio = recording.audioFileReference {
                references.append(audio)
            }
            // Segment directories are created and managed by Cadenza even
            // when the final audio file itself is user-owned.
            if let segments = recording.segmentsDirectoryReference {
                references.append(segments)
            }

            for reference in references {
                let sourceURL = try resolver.resolveAudio(reference)
                guard itemExists(at: sourceURL) else { continue }
                guard let subpath = resolver.lexicalSubpath(of: sourceURL),
                      subpath != Self.deletionQuarantineDirectory,
                      !subpath.hasPrefix(Self.deletionQuarantineDirectory + "/") else {
                    throw DeletionTransactionError.invalidPath
                }
                if subpaths.contains(where: { LexicalPathIdentity.equals($0, subpath) }) {
                    continue
                }
                subpaths.append(subpath)
            }
        }
        let ordered = subpaths.sorted(by: LexicalPathIdentity.isOrderedBefore)
        return ordered.reduce(into: []) { roots, candidate in
            guard !roots.contains(where: { candidate.hasPrefix($0 + "/") }) else { return }
            roots.append(candidate)
        }
    }

    private func makeDeletionManifest(
        recordings: [Recording],
        transactionID: UUID,
        resolver: ProfileStorageResolver
    ) throws -> DeletionManifest {
        let payloadSubpath = [
            Self.deletionQuarantineDirectory,
            "payloads",
            transactionID.uuidString.lowercased()
        ].joined(separator: "/")
        let entries = try sourceSubpathsForDeletion(
            recordings,
            resolver: resolver
        ).enumerated().map { index, source in
            DeletionManifest.Entry(
                sourceSubpath: source,
                stagedSubpath: payloadSubpath + "/" + String(format: "%04d", index)
            )
        }
        return DeletionManifest(
            version: 1,
            transactionID: transactionID,
            recordingIDs: recordings.map(\.id),
            entries: entries
        )
    }

    private func validateDeletionManifest(
        _ manifest: DeletionManifest,
        resolver: ProfileStorageResolver
    ) throws {
        guard manifest.version == 1,
              !manifest.recordingIDs.isEmpty,
              Set(manifest.recordingIDs).count == manifest.recordingIDs.count else {
            throw DeletionTransactionError.inconsistentJournal
        }
        let expectedPayloadPrefix = [
            Self.deletionQuarantineDirectory,
            "payloads",
            manifest.transactionID.uuidString.lowercased()
        ].joined(separator: "/") + "/"
        var sources: [String] = []
        var staged: [String] = []
        for entry in manifest.entries {
            guard !entry.sourceSubpath.hasPrefix(Self.deletionQuarantineDirectory + "/"),
                  entry.stagedSubpath.hasPrefix(expectedPayloadPrefix),
                  !sources.contains(where: {
                      LexicalPathIdentity.equals($0, entry.sourceSubpath)
                  }),
                  !staged.contains(where: {
                      LexicalPathIdentity.equals($0, entry.stagedSubpath)
                  }) else {
                throw DeletionTransactionError.inconsistentJournal
            }
            _ = try resolveDeletionSubpath(entry.sourceSubpath, resolver: resolver)
            _ = try resolveDeletionSubpath(entry.stagedSubpath, resolver: resolver)
            sources.append(entry.sourceSubpath)
            staged.append(entry.stagedSubpath)
        }
    }

    private func writeDeletionManifest(
        _ manifest: DeletionManifest,
        resolver: ProfileStorageResolver
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: deletionManifestsURL(resolver: resolver),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: deletionPayloadURL(
                transactionID: manifest.transactionID,
                resolver: resolver
            ),
            withIntermediateDirectories: true
        )
        try throwInjectedDeletionFileFailureIfNeeded(.writeManifest)
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: deletionManifestURL(
                transactionID: manifest.transactionID,
                resolver: resolver
            ),
            options: .atomic
        )
#if DEBUG
        if let nextRoot = deletionRootSwitchAfterJournalForTesting {
            deletionRootSwitchAfterJournalForTesting = nil
            audioRootOverride = nextRoot
        }
#endif
    }

    private func stageDeletionFiles(
        _ manifest: DeletionManifest,
        resolver: ProfileStorageResolver
    ) throws {
        try validateDeletionManifest(manifest, resolver: resolver)
        let fileManager = FileManager.default
        for entry in manifest.entries {
            let source = try resolveDeletionSubpath(entry.sourceSubpath, resolver: resolver)
            let staged = try resolveDeletionSubpath(entry.stagedSubpath, resolver: resolver)
            guard itemExists(at: source), !itemExists(at: staged) else {
                throw DeletionTransactionError.inconsistentJournal
            }
            try throwInjectedDeletionFileFailureIfNeeded(.stageMove)
            try fileManager.moveItem(at: source, to: staged)
        }
    }

    /// Restores every staged item. It is deliberately idempotent: a source
    /// already restored by an earlier partial attempt is accepted when the
    /// corresponding staged path is absent.
    private func restoreDeletionFiles(
        _ manifest: DeletionManifest,
        resolver: ProfileStorageResolver
    ) throws {
        try validateDeletionManifest(manifest, resolver: resolver)
        let fileManager = FileManager.default
        for entry in manifest.entries.reversed() {
            let source = try resolveDeletionSubpath(entry.sourceSubpath, resolver: resolver)
            let staged = try resolveDeletionSubpath(entry.stagedSubpath, resolver: resolver)
            let sourceExists = itemExists(at: source)
            let stagedExists = itemExists(at: staged)
            if sourceExists && !stagedExists { continue }
            guard !sourceExists, stagedExists else {
                throw DeletionTransactionError.inconsistentJournal
            }
            try fileManager.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try throwInjectedDeletionFileFailureIfNeeded(.restoreMove)
            try fileManager.moveItem(at: staged, to: source)
        }
    }

    private func cleanupDeletionArtifacts(
        _ manifest: DeletionManifest,
        resolver: ProfileStorageResolver
    ) throws {
        let fileManager = FileManager.default
        let payload = deletionPayloadURL(
            transactionID: manifest.transactionID,
            resolver: resolver
        )
        if itemExists(at: payload) {
            try throwInjectedDeletionFileFailureIfNeeded(.cleanupPayload)
            try fileManager.removeItem(at: payload)
        }
        let manifestURL = deletionManifestURL(
            transactionID: manifest.transactionID,
            resolver: resolver
        )
        if itemExists(at: manifestURL) {
            try throwInjectedDeletionFileFailureIfNeeded(.cleanupManifest)
            try fileManager.removeItem(at: manifestURL)
        }
    }

    private func persistedRecordingPresence(for ids: [UUID]) throws -> [Bool] {
        let recoveryContext = ModelContext(modelContainer)
        recoveryContext.autosaveEnabled = false
        return try ids.map { id in
            var descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            let recordings = try recoveryContext.fetch(descriptor)
            return !recordings.isEmpty
        }
    }

    /// Resolves every journal before starting a new deletion. A crash before
    /// the SwiftData commit leaves all rows present and restores their files;
    /// a crash after commit leaves all rows absent and finishes cleanup.
    private func recoverPendingDeletionTransactions(
        resolver: ProfileStorageResolver
    ) throws {
        let fileManager = FileManager.default
        let manifestsURL = deletionManifestsURL(resolver: resolver)
        guard itemExists(at: manifestsURL) else { return }
        let manifests = try fileManager.contentsOfDirectory(
            at: manifestsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension == "json" }
            .sorted { LexicalPathIdentity.isOrderedBefore($0.lastPathComponent, $1.lastPathComponent) }

        for manifestURL in manifests {
            let manifest = try JSONDecoder().decode(
                DeletionManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard LexicalPathIdentity.equals(
                manifestURL.standardizedFileURL.path,
                deletionManifestURL(
                    transactionID: manifest.transactionID,
                    resolver: resolver
                ).standardizedFileURL.path
            ) else {
                throw DeletionTransactionError.inconsistentJournal
            }
            try validateDeletionManifest(manifest, resolver: resolver)
            let presence = try persistedRecordingPresence(for: manifest.recordingIDs)
            if presence.allSatisfy({ $0 }) {
                try restoreDeletionFiles(manifest, resolver: resolver)
            } else if !presence.contains(true) {
                // The database commit won. Original paths must stay absent;
                // cleanup only the exact transaction payload.
            } else {
                throw DeletionTransactionError.inconsistentJournal
            }
            try cleanupDeletionArtifacts(manifest, resolver: resolver)
        }
    }

    private func prepareModelDeletion(
        recordingIDs: [UUID],
        context: ModelContext
    ) throws {
        let ids = Set(recordingIDs)
        let recordings = try context.fetch(FetchDescriptor<Recording>())
            .filter { ids.contains($0.id) }
        guard recordings.count == ids.count else {
            throw DeletionTransactionError.inconsistentJournal
        }
        let externalImports = try context.fetch(FetchDescriptor<ExternalRecordingImport>())
        let artifacts = try context.fetch(FetchDescriptor<AgentArtifact>())
        let recaps = try context.fetch(FetchDescriptor<Recap>())
        let syncRecords = try context.fetch(FetchDescriptor<WebSyncRecord>())
        let voiceSamples = try context.fetch(FetchDescriptor<SpeakerVoiceSample>())

        for externalImport in externalImports {
            if let id = externalImport.recording?.id, ids.contains(id) {
                externalImport.recording = nil
                externalImport.externalKey = Self.userDeletedExternalImportKey(
                    provider: externalImport.provider,
                    externalID: externalImport.externalID
                )
                externalImport.externalID = ""
                externalImport.sourceTitle = ""
                externalImport.sourceStartDate = .init(timeIntervalSince1970: 0)
                externalImport.sourceDuration = 0
                externalImport.sourceCalendarEventID = nil
                externalImport.sourceCreatedAt = nil
                externalImport.sourceUpdatedAt = .init(timeIntervalSince1970: 0)
                externalImport.lastAppliedAt = nil
                externalImport.contentFingerprint = nil
                externalImport.transcriptFingerprint = nil
                externalImport.lastAppliedSourceFingerprint = nil
                externalImport.lastAppliedLocalFingerprint = nil
                externalImport.disposition = ExternalImportDisposition.ignored.rawValue
                externalImport.reason = Self.userDeletedExternalImportReason
                externalImport.qualitySignals = []
            }
        }

        // Built-in meeting-prep artifacts may contain summaries, action
        // items, and decisions from any historical recording but have no
        // source-recording lineage. Delete all built-in artifacts so the
        // scheduler can rebuild them from the remaining library. User-owned
        // external artifacts are preserved.
        for artifact in artifacts
            where artifact.provenanceSource == ArtifactProvenanceSource.builtin.rawValue {
            context.delete(artifact)
        }

        // Recap prose, sections, action items, and decisions are generated
        // from the referenced recordings. Removing only a recording ID would
        // leave that deleted meeting's content visible, so any intersecting
        // recap is deleted atomically with the source recording.
        for recap in recaps where !ids.isDisjoint(with: recap.recordingIDs) {
            context.delete(recap)
        }

        for recording in recordings {
            let recordingID = recording.id
            let matchingSyncRecords = syncRecords.filter { $0.recordingID == recordingID }
            for record in matchingSyncRecords {
                configureDeletionTombstone(record)
            }
            if let activeWebSyncUserID,
               !matchingSyncRecords.contains(where: {
                   AccountIdentity.matches($0.userID, activeWebSyncUserID)
               }) {
                let tombstone = WebSyncRecord(
                    userID: activeWebSyncUserID,
                    recordingID: recordingID
                )
                configureDeletionTombstone(tombstone)
                context.insert(tombstone)
            }
            for sample in voiceSamples where sample.recordingID == recordingID {
                context.delete(sample)
            }
            context.delete(recording)
        }
    }

    /// Perform the SwiftData half of a hard delete in a disposable context.
    /// Cascade deletion followed by `rollback()` can assert inside SwiftData
    /// for recordings that own a Transcript. A private context gives the same
    /// single SQLite commit while failure simply discards all uncommitted
    /// mutations; the actor's long-lived context is never poisoned.
    private func commitModelDeletion(recordingIDs: [UUID]) throws {
#if DEBUG
        if injectedSaveFailuresRemaining > 0 {
            injectedSaveFailuresRemaining -= 1
            NSLog("[RecordingsStore] deletion save failed: injected in-memory test failure")
            throw DeletionTransactionError.injectedFileFailure
        }
#endif
        let deletionContext = ModelContext(modelContainer)
        deletionContext.autosaveEnabled = false
        try prepareModelDeletion(recordingIDs: recordingIDs, context: deletionContext)
        try deletionContext.save()
        detailCache.removeAll()
    }

    /// A DELETE request needs only account identity plus the client recording
    /// ID. Redact every content, upload-session, retry-history, and remote-row
    /// field before retaining the minimal durable tombstone.
    private func configureDeletionTombstone(_ record: WebSyncRecord) {
        record.remoteRecordingID = nil
        record.structuredState = WebStructuredSyncState.pending.rawValue
        record.structuredHash = nil
        record.structuredSourceRevision = nil
        record.structuredAttemptRevision = nil
        record.audioState = WebAudioSyncState.localOnly.rawValue
        record.audioFingerprint = nil
        record.audioProbeRevision = nil
        record.uploadSessionID = nil
        record.attemptCount = 0
        record.nextAttemptAt = nil
        record.retryDomain = nil
        record.lastErrorCode = nil
        record.lastAttemptAt = nil
        record.syncedAt = nil
        record.isDeletionTombstone = true
    }

    private func performPermanentDeletion(
        _ recordings: [Recording]
    ) -> PermanentDeletionOutcome {
        // Snapshot once. Settings is also excluded by a migration activity
        // lease at the AppState boundary, but this local invariant keeps every
        // manifest, move, rollback, and cleanup on one root even if another
        // caller changes the live provider unexpectedly.
        let transactionResolver = resolver
        do {
            try recoverPendingDeletionTransactions(resolver: transactionResolver)
        } catch {
            NSLog("[RecordingsStore] pending deletion recovery failed: %@", error.localizedDescription)
            return .failed(.pendingCleanupRecoveryFailed)
        }
        guard !recordings.isEmpty else { return .nothingToDelete }

        var manifest: DeletionManifest?
        do {
            let candidate = try makeDeletionManifest(
                recordings: recordings,
                transactionID: UUID(),
                resolver: transactionResolver
            )
            manifest = candidate
            if !candidate.entries.isEmpty {
                try writeDeletionManifest(candidate, resolver: transactionResolver)
                try stageDeletionFiles(candidate, resolver: transactionResolver)
            }
        } catch {
            NSLog("[RecordingsStore] deletion file staging failed: %@", error.localizedDescription)
            if let manifest,
               !rollbackDeletionManifest(manifest, resolver: transactionResolver) {
                return .failed(.rollbackIncomplete)
            }
            return .failed(.fileStagingFailed)
        }
        guard let manifest else { return .failed(.fileStagingFailed) }

        do {
            try commitModelDeletion(recordingIDs: recordings.map(\.id))
        } catch {
            guard rollbackDeletionManifest(manifest, resolver: transactionResolver) else {
                return .failed(.rollbackIncomplete)
            }
            NSLog("[RecordingsStore] permanent deletion persistence failed: %@", error.localizedDescription)
            return .failed(.persistenceFailed)
        }

        guard !manifest.entries.isEmpty else {
            return .deleted(count: recordings.count)
        }
        do {
            try cleanupDeletionArtifacts(manifest, resolver: transactionResolver)
            return .deleted(count: recordings.count)
        } catch {
            NSLog("[RecordingsStore] committed deletion cleanup is pending: %@", error.localizedDescription)
            return .cleanupPending(count: recordings.count)
        }
    }

    private func rollbackDeletionManifest(
        _ manifest: DeletionManifest,
        resolver: ProfileStorageResolver
    ) -> Bool {
        guard !manifest.entries.isEmpty else { return true }
        do {
            try restoreDeletionFiles(manifest, resolver: resolver)
            try cleanupDeletionArtifacts(manifest, resolver: resolver)
            return true
        } catch {
            NSLog("[RecordingsStore] deletion rollback failed: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func updateTitle(recordingID: UUID, title: String) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        guard recording.title != title else { return true }
        return performStandaloneMutation {
            recording.title = title
            touch(recording)
        }
    }

    @discardableResult
    func updateStartDate(recordingID: UUID, startDate: Date) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        guard recording.startDate != startDate else { return true }
        // Shift endDate by the same delta instead of recomputing startDate + duration:
        // live recordings can have endDate - startDate != duration (pauses make the
        // wall-clock span exceed audio duration), and the interval length must survive.
        return performStandaloneMutation {
            if let oldEnd = recording.endDate {
                recording.endDate = oldEnd.addingTimeInterval(
                    startDate.timeIntervalSince(recording.startDate)
                )
            }
            recording.startDate = startDate
            touch(recording)
        }
    }

    @discardableResult
    func deleteRecording(recordingID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        return performStandaloneMutation {
            recording.trashedDate = Date()
            recording.folder = nil
            touch(recording)
        }
    }

    @discardableResult
    func restoreRecording(recordingID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        return performStandaloneMutation {
            recording.trashedDate = nil
            touch(recording)
        }
    }

    func permanentlyDeleteWithOutcome(recordingID: UUID) -> PermanentDeletionOutcome {
        do {
            var descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate {
                    $0.id == recordingID && $0.trashedDate != nil
                }
            )
            descriptor.fetchLimit = 1
            guard let recording = try modelContext.fetch(descriptor).first else {
                return .nothingToDelete
            }
            return performPermanentDeletion([recording])
        } catch {
            NSLog("[RecordingsStore] permanent deletion fetch failed: %@", error.localizedDescription)
            return .failed(.persistenceFailed)
        }
    }

    @discardableResult
    func permanentlyDelete(recordingID: UUID) -> Bool {
        permanentlyDeleteWithOutcome(recordingID: recordingID).didCommitDeletion
    }

    func emptyTrashWithOutcome() -> PermanentDeletionOutcome {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate != nil }
        )
        do {
            return performPermanentDeletion(try modelContext.fetch(descriptor))
        } catch {
            NSLog("[RecordingsStore] Trash fetch failed: %@", error.localizedDescription)
            return .failed(.persistenceFailed)
        }
    }

    /// Hard-delete only the caller's original Trash snapshot. Rows moved to
    /// Trash after the snapshot are excluded, and rows restored while the
    /// caller waits for post-processing to exit are excluded as well.
    func deleteTrashedRecordingsWithOutcome(
        recordingIDs: [UUID]
    ) -> PermanentDeletionOutcome {
        let targets = Set(recordingIDs)
        guard !targets.isEmpty else { return .nothingToDelete }
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate != nil }
        )
        do {
            let recordings = try modelContext.fetch(descriptor)
                .filter { targets.contains($0.id) }
            return performPermanentDeletion(recordings)
        } catch {
            NSLog("[RecordingsStore] Trash snapshot fetch failed: %@", error.localizedDescription)
            return .failed(.persistenceFailed)
        }
    }

    @discardableResult
    func emptyTrash() -> Bool {
        switch emptyTrashWithOutcome() {
        case .deleted, .cleanupPending, .nothingToDelete:
            true
        case .failed:
            false
        }
    }

    @discardableResult
    func removeTag(recordingID: UUID, tag: String) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let key = TagNormalizer.formatKey(tag)
        let remainingTags = recording.tags.filter { TagNormalizer.formatKey($0) != key }
        guard remainingTags.count != recording.tags.count else { return true }
        return performStandaloneMutation {
            recording.tags = remainingTags
            touch(recording)
        }
    }

    @discardableResult
    // MARK: - Historical-consent marks (binding phase B2)

    /// Runtime B2 route for a binding whose target is this open store:
    /// stamps every unmarked recording with the transaction ID. A foreign
    /// mark throws — a rolled-back transaction always clears its own marks,
    /// so an alien one is unclassifiable state. Rolls back on save failure
    /// so a later save cannot persist a partial stamp batch.
    func markAllRecordingsAwaitingHistoricalConsent(
        transactionID: UUID
    ) throws -> HistoricalMarkResult {
        let rows = try modelContext.fetch(FetchDescriptor<Recording>())
        var newlyMarked = 0
        var previouslyMarked = 0
        for row in rows {
            switch row.awaitingHistoricalConsentBindingID {
            case nil:
                row.awaitingHistoricalConsentBindingID = transactionID
                newlyMarked += 1
            case transactionID:
                previouslyMarked += 1
            case .some(let foreign):
                modelContext.rollback()
                throw HistoricalMarkingError.foreignMark(existing: foreign)
            }
        }
        if newlyMarked > 0 {
            detailCache.removeAll()
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        return HistoricalMarkResult(
            newlyMarked: newlyMarked, previouslyMarked: previouslyMarked, total: rows.count
        )
    }

    /// Removes exactly the marks carrying the transaction ID (rollback of
    /// the runtime B2 route).
    func clearHistoricalConsentMarks(transactionID: UUID) throws -> Int {
        let rows = try modelContext.fetch(FetchDescriptor<Recording>())
        var cleared = 0
        for row in rows where row.awaitingHistoricalConsentBindingID == transactionID {
            row.awaitingHistoricalConsentBindingID = nil
            cleared += 1
        }
        if cleared > 0 {
            detailCache.removeAll()
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        return cleared
    }

    func addTag(recordingID: UUID, tag: String) -> Bool {
        guard let recording = recording(byID: recordingID),
              let canonical = tagNormalizer.normalize(tag, vocab: tagVocab()) else { return false }
        let key = TagNormalizer.formatKey(canonical)
        guard !recording.tags.contains(where: { TagNormalizer.formatKey($0) == key }) else { return true }
        return performStandaloneMutation {
            recording.tags.append(canonical)
            touch(recording)
        }
    }

    /// Outcome of the vocabulary-aware MCP tag write.
    enum AddTagOutcome: Sendable, Equatable {
        case added(canonical: String, isNew: Bool)  // isNew → introduced a new category
        case rejectedUnknown(canonical: String)      // valid tag, but not in vocab and allowNew=false
        case alreadyPresent(canonical: String)
        case invalid                                 // blocked / empty / over-long / unsupported chars
        case recordingNotFound
        case persistenceFailed
    }

    /// Vocabulary-aware add used by the MCP `add_tag` tool: by default only tags
    /// already in the library vocabulary are accepted, keeping tags a stable
    /// classification. `allowNew` lets a caller deliberately introduce a new
    /// category. (The 2-arg `addTag(recordingID:tag:) -> Bool` overload stays
    /// for in-app/test callers that always allow new.)
    func addTag(recordingID: UUID, tag: String, allowNew: Bool) -> AddTagOutcome {
        guard let recording = recording(byID: recordingID) else { return .recordingNotFound }
        guard let canonical = tagNormalizer.normalize(tag, vocab: tagVocab()) else { return .invalid }
        let key = TagNormalizer.formatKey(canonical)
        if recording.tags.contains(where: { TagNormalizer.formatKey($0) == key }) {
            return .alreadyPresent(canonical: canonical)
        }
        // Evaluate the known vocabulary BEFORE appending, so the new tag can't
        // count itself as "known".
        let isKnown = Set(tagVocab().keys).contains(key)
        if !isKnown && !allowNew {
            return .rejectedUnknown(canonical: canonical)
        }
        guard performStandaloneMutation({
            recording.tags.append(canonical)
            touch(recording)
        }) else { return .persistenceFailed }
        return .added(canonical: canonical, isNew: !isKnown)
    }

    // MARK: - Tag Normalization

    /// Blocklist read fresh each call (UserDefaults override; resolver-style, matches model-config pattern).
    private var currentTagBlocklist: [String] {
        UserDefaults.standard.stringArray(forKey: "tagBlocklist") ?? []
    }
    private var tagNormalizer: TagNormalizer { TagNormalizer(blocklist: currentTagBlocklist) }

    /// [formatKey: surface] from existing non-trashed tags — new tags reuse the surface already
    /// in use (most-frequent wins).
    private func tagVocab() -> [String: String] {
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.trashedDate == nil })
        let recs = (try? modelContext.fetch(descriptor)) ?? []
        var counts: [String: [String: Int]] = [:]
        for rec in recs {
            for tag in rec.tags {
                let k = TagNormalizer.formatKey(tag)
                guard !k.isEmpty else { continue }
                counts[k, default: [:]][tag, default: 0] += 1
            }
        }
        return counts.compactMapValues { Self.pickCanonicalSurface($0) }
    }

    /// Pick canonical surface from candidates: (count desc, shortest, lexicographic).
    private static func pickCanonicalSurface(_ surfaces: [String: Int]) -> String? {
        surfaces.sorted {
            $0.value != $1.value ? $0.value > $1.value
                : ($0.key.count != $1.key.count ? $0.key.count < $1.key.count : $0.key < $1.key)
        }.first?.key
    }

    /// Distinct tags across non-trashed recordings, blocklist-filtered, frequency-sorted.
    /// `language` non-nil filters by script bucket (CJK summary → CJK+universal, Latin → Latin+universal).
    func distinctTags(language: String? = nil) -> [TagCountDTO] {
        let normalizer = tagNormalizer
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.trashedDate == nil })
        let recs = (try? modelContext.fetch(descriptor)) ?? []
        var counts: [String: (surface: String, count: Int)] = [:]
        for rec in recs {
            for tag in rec.tags {
                guard let surface = normalizer.normalize(tag) else { continue }
                let k = TagNormalizer.formatKey(surface)
                if var entry = counts[k] { entry.count += 1; counts[k] = entry }
                else { counts[k] = (surface, 1) }
            }
        }
        var items = counts.values.map { TagCountDTO(tag: $0.surface, count: $0.count) }
        if let language, !language.isEmpty {
            let wantCJK = ["zh", "ja", "ko"].contains { language.hasPrefix($0) }
            items = items.filter {
                switch TagNormalizer.scriptBucket($0.tag) {
                case .universal: return true
                case .cjk: return wantCJK
                case .latin: return !wantCJK
                }
            }
        }
        return items.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// One-time deterministic migration: collapse variants + drop blocklist across ALL recordings.
    /// Guarded by version + blocklist fingerprint; idempotent; single-transaction (rollback on failure;
    /// version/fingerprint written only on success, so a failed run retries next launch).
    @discardableResult
    func normalizeAllTagsIfNeeded(force: Bool = false) -> Bool {
        let defaults = UserDefaults.standard
        let targetVersion = 2   // v2: curated English→Chinese meeting/business-word canonicalization
        let blocklist = currentTagBlocklist
        let fingerprint = blocklist.map { TagNormalizer.formatKey($0) }.sorted().joined(separator: "\u{1}")
        let versionStale = defaults.integer(forKey: "tagNormalizationVersion") < targetVersion
        let fingerprintStale = defaults.string(forKey: "tagBlocklistFingerprint") != fingerprint
        guard force || versionStale || fingerprintStale else { return true }

        let recs: [Recording]
        do {
            recs = try modelContext.fetch(FetchDescriptor<Recording>())
        } catch {
            NSLog("[RecordingsStore] tag migration fetch failed: %@", error.localizedDescription)
            return false   // do not stamp version/fingerprint — retry next launch
        }
        let normalizer = TagNormalizer(blocklist: blocklist)
        let migrationVocab = buildMigrationVocab(recs)

        let updates = recs.compactMap { rec -> (Recording, [String])? in
            let newTags = normalizer.canonicalize(rec.tags, vocab: migrationVocab)
            return newTags == rec.tags ? nil : (rec, newTags)
        }
        if !updates.isEmpty && !performStandaloneMutation({
            for (rec, newTags) in updates {
                rec.tags = newTags
                touch(rec)
            }
        }) {
            return false
        }
        defaults.set(targetVersion, forKey: "tagNormalizationVersion")
        defaults.set(fingerprint, forKey: "tagBlocklistFingerprint")
        return true
    }

    /// Migration canonical surfaces WITHOUT reusing dirty raw surfaces: per formatKey cluster,
    /// pick the best `defaultSurface` by (count desc, shortest, lexicographic).
    private func buildMigrationVocab(_ recs: [Recording]) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for rec in recs {
            for tag in rec.tags {
                let k = TagNormalizer.formatKey(tag)
                guard !k.isEmpty else { continue }
                let surface = TagNormalizer.defaultSurface(tag)
                guard !surface.isEmpty else { continue }
                counts[k, default: [:]][surface, default: 0] += 1
            }
        }
        return counts.compactMapValues { Self.pickCanonicalSurface($0) }
    }

    @discardableResult
    func linkCalendarEvent(recordingID: UUID, calendarEventID: String?) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        recording.linkedCalendarEventID = calendarEventID
        recording.calendarAutoLinkState = calendarEventID == nil
            ? CalendarAutoLinkState.userCleared.rawValue
            : CalendarAutoLinkState.linked.rawValue
        recording.calendarAutoLinkAttemptedAt = Date()
        touch(recording)
        return save()
    }

    func markCalendarAutoLinkNoMatch(recordingID: UUID, now: Date = Date()) -> Bool {
        guard let recording = recording(byID: recordingID),
              recording.linkedCalendarEventID == nil else { return false }
        recording.calendarAutoLinkState = CalendarAutoLinkState.noMatch.rawValue
        recording.calendarAutoLinkAttemptedAt = now
        return save()
    }

    func fetchCalendarAutoLinkCandidates(limit: Int = 100) -> [CalendarAutoLinkCandidate] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.trashedDate == nil
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return Array(
            recordings
                .filter {
                    $0.linkedCalendarEventID == nil
                        && $0.audioFilePath != nil
                        && $0.audioSegmentsDirectory == nil
                        && ($0.calendarAutoLinkState == nil
                        || $0.calendarAutoLinkState == CalendarAutoLinkState.pending.rawValue
                        )
                }
                .prefix(max(0, limit))
                .map { recording in
                    let resolvedEndDate: Date
                    if let endDate = recording.endDate {
                        resolvedEndDate = endDate
                    } else {
                        resolvedEndDate = recording.startDate.addingTimeInterval(recording.duration)
                    }
                    return (id: recording.id, startDate: recording.startDate, endDate: resolvedEndDate)
                }
        )
    }

    func repairCalendarAutoLinkDatesFromAudioFilenames(minimumDelta: TimeInterval = 60) -> Int {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.trashedDate == nil
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        var repaired = 0

        for recording in recordings {
            guard recording.linkedCalendarEventID == nil,
                  recording.audioSegmentsDirectory == nil,
                  recording.calendarAutoLinkState != CalendarAutoLinkState.userCleared.rawValue,
                  let audioReference = recording.audioFileReference else {
                continue
            }

            let filename = audioReference.lastPathComponent
            guard let parsedStartDate = RecordingFilenameDateParser.parse(filename),
                  abs(parsedStartDate.timeIntervalSince(recording.startDate)) > minimumDelta else {
                continue
            }

            let resolvedDuration: TimeInterval
            if let endDate = recording.endDate {
                resolvedDuration = endDate.timeIntervalSince(recording.startDate)
            } else {
                resolvedDuration = recording.duration
            }

            recording.startDate = parsedStartDate
            recording.endDate = parsedStartDate.addingTimeInterval(resolvedDuration)
            recording.calendarAutoLinkState = CalendarAutoLinkState.pending.rawValue
            recording.calendarAutoLinkAttemptedAt = nil
            touch(recording)
            repaired += 1
        }

        guard repaired > 0 else { return 0 }
        return save() ? repaired : 0
    }

    func requeueCalendarAutoLinkNoMatchesForRetry() -> Int {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.trashedDate == nil
            },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        var requeued = 0

        for recording in recordings {
            guard recording.linkedCalendarEventID == nil,
                  recording.audioFilePath != nil,
                  recording.audioSegmentsDirectory == nil,
                  recording.calendarAutoLinkState == CalendarAutoLinkState.noMatch.rawValue else {
                continue
            }

            recording.calendarAutoLinkState = CalendarAutoLinkState.pending.rawValue
            recording.calendarAutoLinkAttemptedAt = nil
            requeued += 1
        }

        guard requeued > 0 else { return 0 }
        return save() ? requeued : 0
    }

    @discardableResult
    func moveToFolder(recordingID: UUID, folderID: UUID?) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let destination = folderID.flatMap { folder(byID: $0) }
        return performStandaloneMutation {
            recording.folder = destination
            touch(recording)
        }
    }

    // MARK: - Folder CRUD

    func createFolder(name: String, icon: String, iconColor: String) -> FolderDTO? {
        let descriptor = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortOrder)])
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        let maxOrder = existing.map(\.sortOrder).max() ?? 0
        let folder = Folder(name: name, icon: icon, iconColor: iconColor, sortOrder: maxOrder + 1)
        let dto = folderToDTO(folder)
        guard performStandaloneMutation({ modelContext.insert(folder) }) else { return nil }
        return dto
    }

    @discardableResult
    func updateFolder(id: UUID, name: String, icon: String, iconColor: String) -> Bool {
        guard let folder = folder(byID: id) else { return false }
        return performStandaloneMutation {
            if folder.name != name {
                touchRecordingsInFolderTree(folder)
            }
            folder.name = name
            folder.icon = icon
            folder.iconColor = iconColor
        }
    }

    @discardableResult
    func deleteFolder(id: UUID) -> Bool {
        guard let folder = folder(byID: id) else { return false }
        return performStandaloneMutation {
            touchRecordingsInFolderTree(folder)
            for recording in folder.recordings {
                recording.folder = nil
            }
            modelContext.delete(folder)
        }
    }

    /// Folder names are part of the web-sync payload. Advance every affected
    /// recording revision, including descendants whose full path contains a
    /// renamed or deleted ancestor, so the lightweight sync scheduler cannot
    /// mistake the payload for unchanged content.
    private func touchRecordingsInFolderTree(_ root: Folder, at date: Date = Date()) {
        var pending = [root]
        var visited = Set<UUID>()
        while let folder = pending.popLast(), visited.insert(folder.id).inserted {
            for recording in folder.recordings {
                touch(recording, at: date)
            }
            pending.append(contentsOf: folder.subfolders)
        }
    }

    // MARK: - Folder Detail & AI Context

    func fetchFolderDetail(folderID: UUID) -> FolderDetailDTO? {
        guard let folder = folder(byID: folderID) else { return nil }
        let recordings = folder.recordings
            .sorted { $0.startDate > $1.startDate }
            .map { recordingToDTO($0) }

        let actionItems: [FolderActionItemDTO] = folder.recordings.flatMap { rec in
            guard let summary = rec.summary else { return [FolderActionItemDTO]() }
            return summary.actionItems.map { item in
                FolderActionItemDTO(
                    item: ActionItemDTO(
                        id: item.id,
                        assignee: item.assignee,
                        task: item.task,
                        deadline: item.deadline,
                        isCompleted: item.isCompleted,
                        priority: item.priority.rawValue
                    ),
                    sourceRecordingID: rec.id,
                    sourceRecordingTitle: rec.title
                )
            }
        }

        let decisions: [FolderDecisionDTO] = folder.recordings.flatMap { rec in
            guard let summary = rec.summary else { return [FolderDecisionDTO]() }
            return summary.decisions.map { decision in
                FolderDecisionDTO(
                    id: UUID(),
                    text: decision,
                    sourceRecordingID: rec.id,
                    sourceRecordingTitle: rec.title
                )
            }
        }

        return FolderDetailDTO(
            id: folder.id,
            name: folder.name,
            status: folder.status,
            createdAt: folder.createdAt,
            colorHex: folder.colorHex,
            recordings: recordings,
            actionItems: actionItems,
            decisions: decisions
        )
    }

    /// Fetch structured context for folder-scoped AI retrieval.
    func fetchFolderContext(folderID: UUID, meetingLimit: Int = 5) -> FolderContextDTO? {
        guard let folder = folder(byID: folderID) else { return nil }

        let sorted = folder.recordings.sorted { $0.startDate > $1.startDate }
        let recent = Array(sorted.prefix(meetingLimit))

        let meetingContexts: [FolderContextDTO.MeetingSummaryContext] = recent.map { rec in
            if let summary = rec.summary {
                return FolderContextDTO.MeetingSummaryContext(
                    recordingID: rec.id,
                    title: rec.title,
                    date: rec.startDate,
                    durationMinutes: Int(rec.duration) / 60,
                    overview: summary.overview,
                    keyPoints: summary.keyPoints,
                    actionItems: summary.actionItems.map { item in
                        ActionItemDTO(
                            id: item.id,
                            assignee: item.assignee,
                            task: item.task,
                            deadline: item.deadline,
                            isCompleted: item.isCompleted,
                            priority: item.priority.rawValue
                        )
                    },
                    decisions: summary.decisions,
                    followUps: summary.followUps
                )
            } else if let transcript = rec.transcript, !transcript.fullText.isEmpty {
                let excerpt = String(transcript.fullText.prefix(500))
                return FolderContextDTO.MeetingSummaryContext(
                    recordingID: rec.id,
                    title: rec.title,
                    date: rec.startDate,
                    durationMinutes: Int(rec.duration) / 60,
                    overview: "[Summary pending] Transcript excerpt: \(excerpt)",
                    keyPoints: [],
                    actionItems: [],
                    decisions: [],
                    followUps: []
                )
            } else {
                return FolderContextDTO.MeetingSummaryContext(
                    recordingID: rec.id,
                    title: rec.title,
                    date: rec.startDate,
                    durationMinutes: Int(rec.duration) / 60,
                    overview: "[No summary or transcript available yet]",
                    keyPoints: [],
                    actionItems: [],
                    decisions: [],
                    followUps: []
                )
            }
        }

        let openActionItems: [FolderActionItemDTO] = sorted.flatMap { rec in
            guard let summary = rec.summary else { return [FolderActionItemDTO]() }
            return summary.actionItems.filter { !$0.isCompleted }.map { item in
                FolderActionItemDTO(
                    item: ActionItemDTO(
                        id: item.id,
                        assignee: item.assignee,
                        task: item.task,
                        deadline: item.deadline,
                        isCompleted: item.isCompleted,
                        priority: item.priority.rawValue
                    ),
                    sourceRecordingID: rec.id,
                    sourceRecordingTitle: rec.title
                )
            }
        }

        let recentDecisions: [FolderDecisionDTO] = recent.flatMap { rec in
            guard let summary = rec.summary else { return [FolderDecisionDTO]() }
            return summary.decisions.map { decision in
                FolderDecisionDTO(
                    id: UUID(),
                    text: decision,
                    sourceRecordingID: rec.id,
                    sourceRecordingTitle: rec.title
                )
            }
        }

        let followUps: [FolderContextDTO.FollowUpContext] = recent.flatMap { rec in
            guard let summary = rec.summary else { return [FolderContextDTO.FollowUpContext]() }
            return summary.followUps.map { followUp in
                FolderContextDTO.FollowUpContext(
                    text: followUp,
                    sourceRecordingTitle: rec.title,
                    sourceRecordingID: rec.id
                )
            }
        }

        var speakerNames = Set<String>()
        for rec in sorted {
            for mapping in rec.speakerMappings ?? [] {
                if let profile = speakerProfile(byID: mapping.profileID) {
                    speakerNames.insert(profile.displayName)
                }
            }
        }

        return FolderContextDTO(
            folderName: folder.name,
            folderStatus: folder.status,
            totalRecordingCount: folder.recordings.count,
            recentMeetings: meetingContexts,
            openActionItems: openActionItems,
            recentDecisions: recentDecisions,
            followUps: followUps,
            knownSpeakers: speakerNames.sorted()
        )
    }

    // MARK: - Post-Processing Writes

    @discardableResult
    func saveTranscript(
        recordingID: UUID,
        fullText: String,
        segments: [TranscriptEntry],
        language: String?,
        tags: [String],
        resetSpeakerIdentity: Bool = false
    ) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let previousSpeakerIdentityRevision = speakerIdentityRevisions[recordingID] ?? 0

        if resetSpeakerIdentity {
            // Diarization cluster labels are not stable across transcription runs.
            // Keeping mappings or embeddings would attach the new labels to stale
            // identities and can poison speaker memory with mixed voices.
            let voiceSamples: [SpeakerVoiceSample]
            do {
                voiceSamples = try fetchAllVoiceSampleModelsThrowing(recordingID: recordingID)
            } catch {
                NSLog("[RecordingsStore] speaker reset fetch failed: %@", error.localizedDescription)
                return false
            }

            speakerIdentityRevisions[recordingID] = previousSpeakerIdentityRevision &+ 1
            recording.speakerMappings = []
            recording.speakerSuggestions = nil
            for sample in voiceSamples {
                modelContext.delete(sample)
            }
        }

        let transcript = Transcript(fullText: fullText, segments: segments)
        transcript.detectedLanguage = language
        recording.transcript = transcript
        let normalizedTags = tagNormalizer.canonicalize(tags, vocab: tagVocab())
        if !normalizedTags.isEmpty {
            recording.tags = normalizedTags
        }
        touch(recording)
        invalidateDetailCache(recordingID)
        guard save() else {
            modelContext.rollback()
            if resetSpeakerIdentity {
                speakerIdentityRevisions[recordingID] = previousSpeakerIdentityRevision
            }
            invalidateDetailCache(recordingID)
            return false
        }
        return true
    }

    /// Atomically replaces the transcript, invalidates old speaker-derived data,
    /// and returns the exact generation token that a follow-up analysis must use.
    /// Capturing the token here prevents a delayed detached task from adopting a
    /// newer generation while still holding older transcript spans.
    func replaceTranscriptForSpeakerAnalysis(
        recordingID: UUID,
        fullText: String,
        segments: [TranscriptEntry],
        language: String?,
        tags: [String]
    ) -> UInt64? {
        guard saveTranscript(
            recordingID: recordingID,
            fullText: fullText,
            segments: segments,
            language: language,
            tags: tags,
            resetSpeakerIdentity: true
        ) else { return nil }
        return speakerIdentityRevisions[recordingID] ?? 0
    }

    @discardableResult
    func saveSummary(recordingID: UUID, summary: SummaryResult, chaptersJSON: String?, provider: AIProvider = .openai, model: String = "", language: String = "en", meetingType: String? = nil) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let meetingSummary = MeetingSummary(
            overview: summary.overview,
            keyPoints: summary.keyPoints,
            actionItems: summary.actionItems.map {
                ActionItem(assignee: $0.assignee, task: $0.task, deadline: $0.deadline)
            },
            decisions: summary.decisions,
            followUps: summary.followUps,
            yourTasks: summary.yourTasks,
            provider: provider,
            model: model,
            language: language
        )
        meetingSummary.chaptersJSON = chaptersJSON
        recording.summary = meetingSummary
        // Merge: keep existing/manual tags, fold in AI tags, dedup by canonical formatKey.
        recording.tags = tagNormalizer.canonicalize(recording.tags + summary.tags, vocab: tagVocab())
        if !summary.title.isEmpty {
            recording.title = summary.title
        }
        if let meetingType {
            recording.meetingType = meetingType
        }
        touch(recording)
        return save()
    }

    @discardableResult
    func trashRecording(recordingID: UUID, reason: String?) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        recording.trashedDate = Date()
        touch(recording)
        return save()
    }

    /// Trash short recordings (< minDuration seconds) that have no transcript,
    /// and completely empty recordings (no audio file, no segments directory).
    /// These are typically accidental recordings or orphans from crashed sessions.
    func trashShortUntranscribedRecordings(minDuration: TimeInterval) {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.trashedDate == nil }
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        var trashed = 0
        for rec in recordings {
            // Skip recordings with pending segments — they're awaiting recovery retry
            if rec.audioSegmentsDirectory != nil { continue }
            let isShortUntranscribed = rec.duration < minDuration && rec.transcript == nil
            let isCompletelyEmpty = rec.audioFilePath == nil && rec.transcript == nil
            if isShortUntranscribed || isCompletelyEmpty {
                rec.trashedDate = Date()
                touch(rec)
                trashed += 1
            }
        }
        if trashed > 0 {
            save()
            NSLog("[RecordingsStore] auto-trashed %d short/empty recording(s)", trashed)
        }
    }

    @discardableResult
    func updateMeetingType(recordingID: UUID, meetingType: String) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        recording.meetingType = meetingType
        touch(recording)
        return save()
    }

    func currentSummaryID(for recordingID: UUID) -> UUID? {
        recording(byID: recordingID)?.summary?.id
    }

    @discardableResult
    func updateChapters(recordingID: UUID, chaptersJSON: String, expectedSummaryID: UUID? = nil) -> Bool {
        guard let recording = recording(byID: recordingID),
              let summary = recording.summary else { return false }
        // Guard against stale chapters overwriting a newer summary
        if let expected = expectedSummaryID, summary.id != expected { return false }
        summary.chaptersJSON = chaptersJSON
        touch(recording)
        return save()
    }

    @discardableResult
    func toggleActionItem(recordingID: UUID, actionItemID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID),
              let summary = recording.summary,
              let idx = summary.actionItems.firstIndex(where: { $0.id == actionItemID }) else { return false }
        let original = summary.actionItems[idx]
        let originalRecordingUpdatedAt = recording.updatedAt
        summary.actionItems[idx].isCompleted.toggle()
        let now = Date()
        summary.actionItems[idx].createdAt = summary.actionItems[idx].createdAt ?? recording.createdAt ?? recording.startDate
        summary.actionItems[idx].updatedAt = now
        touch(recording, at: now)
        guard save() else {
            summary.actionItems[idx] = original
            recording.updatedAt = originalRecordingUpdatedAt
            modelContext.rollback()
            return false
        }
        return true
    }

    @discardableResult
    func updateActionItem(recordingID: UUID, actionItemID: UUID, task: String?, assignee: String?, deadline: String?, priority: ActionPriority?) -> Bool {
        let input = ActionItemUpdateInput(
            task: task,
            assignee: assignee.map { .set($0) } ?? .unchanged,
            deadline: deadline.map { .set($0) } ?? .unchanged,
            priority: priority
        )
        return applyActionItemUpdate(recordingID: recordingID, actionItemID: actionItemID, input: input) != nil
    }

    @discardableResult
    func addActionItem(recordingID: UUID, task: String) -> Bool {
        guard let recording = recording(byID: recordingID),
              let summary = recording.summary else { return false }
        let originalItems = summary.actionItems
        let originalRecordingUpdatedAt = recording.updatedAt
        summary.actionItems.append(ActionItem(task: task))
        touch(recording)
        guard save() else {
            summary.actionItems = originalItems
            recording.updatedAt = originalRecordingUpdatedAt
            modelContext.rollback()
            return false
        }
        return true
    }

    // MARK: - Crash Recovery

    /// Recordings that were finalized (have audio) but incomplete post-processing.
    /// Returns recordings missing transcript OR missing summary.
    /// Only returns recordings from the last `maxAge` hours to avoid re-processing
    /// old imported/recovered files on every app launch.
    func fetchUnprocessedRecordings(maxAgeHours: Int = 72, maxAttempts: Int = 3) -> [BackfillRecording] {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeHours) * 3600)
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.trashedDate == nil && $0.startDate > cutoff }
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return recordings.compactMap { rec in
            guard rec.audioSegmentsDirectory == nil,
                  let url = resolveURL(rec.audioFileReference) else { return nil }
            guard rec.transcript == nil || rec.summary == nil else { return nil }
            guard rec.processingAttempts < maxAttempts else { return nil }
            return (id: rec.id, audioFileURL: url, title: rec.title, hasTranscript: rec.transcript != nil)
        }
    }

    @discardableResult
    func enqueuePostProcessingBackfill(recordingID: UUID, source: String) -> Bool {
        guard let recording = recording(byID: recordingID),
              recording.trashedDate == nil,
              recording.audioFilePath != nil,
              recording.transcript == nil || recording.summary == nil else {
            return false
        }

        let now = Date()
        let saved = performStandaloneMutation {
            recording.postProcessingBackfillState = PostProcessingBackfillState.queued.rawValue
            recording.postProcessingBackfillRequestedAt = recording.postProcessingBackfillRequestedAt ?? now
            recording.postProcessingBackfillNextAttemptAt = nil
            recording.postProcessingBackfillLastError = nil
        }
        if saved {
            NSLog("[RecordingsStore] queued post-processing backfill for %@ source=%@", recordingID.uuidString, source)
        }
        return saved
    }

    func fetchQueuedBackfillRecordings(limit: Int = 2, now: Date = Date()) -> [BackfillRecording] {
        guard limit > 0 else { return [] }
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> {
                $0.trashedDate == nil && $0.postProcessingBackfillState == "queued"
            },
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        let rows = recordings.compactMap { rec -> BackfillRecording? in
            guard rec.audioSegmentsDirectory == nil,
                  let url = resolveURL(rec.audioFileReference),
                  rec.transcript == nil || rec.summary == nil else {
                return nil
            }
            if let nextAttempt = rec.postProcessingBackfillNextAttemptAt, nextAttempt > now {
                return nil
            }
            return (id: rec.id, audioFileURL: url, title: rec.title, hasTranscript: rec.transcript != nil)
        }
        return Array(rows.prefix(limit))
    }

    @discardableResult
    func markBackfillProcessing(recordingID: UUID, now: Date = Date()) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        return performStandaloneMutation {
            recording.postProcessingBackfillState = PostProcessingBackfillState.processing.rawValue
            recording.postProcessingBackfillLastAttemptAt = now
        }
    }

    @discardableResult
    func markBackfillCompleted(recordingID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID),
              recording.trashedDate == nil,
              recording.postProcessingBackfillState != nil,
              recording.transcript != nil,
              recording.summary != nil else { return false }
        return performStandaloneMutation {
            recording.postProcessingBackfillState = PostProcessingBackfillState.completed.rawValue
            recording.postProcessingBackfillNextAttemptAt = nil
            recording.postProcessingBackfillLastError = nil
            recording.postProcessingBackfillFailureCount = 0
        }
    }

    @discardableResult
    func markBackfillFailed(
        recordingID: UUID,
        error: String,
        maxAutomaticFailures: Int = 2,
        cooldown: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) -> Bool {
        guard let recording = recording(byID: recordingID),
              recording.trashedDate == nil else { return false }
        return performStandaloneMutation {
            recording.postProcessingBackfillFailureCount += 1
            recording.postProcessingBackfillLastAttemptAt = now
            recording.postProcessingBackfillLastError = Self.compactBackfillError(error)

            if recording.postProcessingBackfillFailureCount >= maxAutomaticFailures {
                recording.postProcessingBackfillState = PostProcessingBackfillState.blocked.rawValue
                recording.postProcessingBackfillNextAttemptAt = nil
            } else {
                recording.postProcessingBackfillState = PostProcessingBackfillState.queued.rawValue
                recording.postProcessingBackfillNextAttemptAt = now.addingTimeInterval(cooldown)
            }
        }
    }

    @discardableResult
    func markInterruptedBackfillProcessingFailed(
        error: String,
        maxAutomaticFailures: Int = 2,
        cooldown: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) -> Int {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> {
                $0.trashedDate == nil && $0.postProcessingBackfillState == "processing"
            }
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        let eligible = recordings.filter {
            $0.audioSegmentsDirectory == nil
                && $0.audioFilePath != nil
                && ($0.transcript == nil || $0.summary == nil)
        }
        guard !eligible.isEmpty else { return 0 }
        let saved = performStandaloneMutation {
            for recording in eligible {
                recording.postProcessingBackfillFailureCount += 1
                recording.postProcessingBackfillLastAttemptAt = now
                recording.postProcessingBackfillLastError = Self.compactBackfillError(error)
                if recording.postProcessingBackfillFailureCount >= maxAutomaticFailures {
                    recording.postProcessingBackfillState = PostProcessingBackfillState.blocked.rawValue
                    recording.postProcessingBackfillNextAttemptAt = nil
                } else {
                    recording.postProcessingBackfillState = PostProcessingBackfillState.queued.rawValue
                    recording.postProcessingBackfillNextAttemptAt = now.addingTimeInterval(cooldown)
                }
            }
        }
        return saved ? eligible.count : 0
    }

    @discardableResult
    func resetBackfillFailure(recordingID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID),
              recording.trashedDate == nil,
              recording.audioFilePath != nil,
              recording.transcript == nil || recording.summary == nil else {
            return false
        }
        return performStandaloneMutation {
            recording.postProcessingBackfillState = PostProcessingBackfillState.queued.rawValue
            recording.postProcessingBackfillNextAttemptAt = nil
            recording.postProcessingBackfillLastError = nil
            recording.postProcessingBackfillFailureCount = 0
        }
    }

    func fetchInterruptedRecordings() -> [(id: UUID, segmentsDirURL: URL, audioFileURL: URL?, startDate: Date, title: String, duration: TimeInterval)] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.audioSegmentsDirectory != nil && $0.trashedDate == nil }
        )
        let interrupted = (try? modelContext.fetch(descriptor)) ?? []
        return interrupted.compactMap {
            guard let segmentsDirURL = resolveURL($0.segmentsDirectoryReference) else { return nil }
            return (id: $0.id, segmentsDirURL: segmentsDirURL,
                    audioFileURL: resolveURL($0.audioFileReference),
                    startDate: $0.startDate, title: $0.title, duration: $0.duration)
        }
    }

    @discardableResult
    func updateRecoveredRecording(id: UUID, endDate: Date, duration: TimeInterval, audioFileURL: URL?) -> Bool {
        guard let recording = recording(byID: id) else { return false }
        let reference: AudioFileReference?
        do {
            reference = try audioFileURL.map { try makeRelativeReference(for: $0) }
        } catch {
            return false
        }
        guard persistPendingChangesBeforeFinalization() else { return false }
        recording.endDate = endDate
        recording.duration = duration
        if let reference {
            recording.audioFileReference = reference
        }
        recording.audioSegmentsDirectory = nil
        touch(recording)
        return saveFinalizationTransaction()
    }

    @discardableResult
    func markRecoveryFailed(id: UUID) -> Bool {
        guard recording(byID: id) != nil else { return false }
        return save()
    }

    @discardableResult
    func incrementProcessingAttempts(id: UUID) -> Bool {
        guard let recording = recording(byID: id) else { return false }
        recording.processingAttempts += 1
        return save()
    }

    private static func compactBackfillError(_ value: String, limit: Int = 240) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit))
    }

    // MARK: - Storage Root Change

    /// Split-root support: when the user keeps existing files in the old
    /// directory and only routes future recordings to a new one, relative
    /// references would silently re-root and dangle. Pin them to absolute
    /// paths under the root their files actually live in, before the active
    /// root switches. This is one of the three sanctioned reference-rewrite
    /// operations (the others are `relocateAudioReferences` and
    /// `relinkLegacyAudioReference`); normal writes stay strictly relative.
    ///
    /// Throwing and all-or-nothing: every non-legacy reference either pins
    /// or the whole operation rolls back and throws — a malformed or
    /// escaping relative row skipped silently would dangle once the root
    /// switches. The mutation span is covered by the rollback, so an
    /// aborted pin can never be persisted by a later unrelated save. The
    /// caller keeps the old root active on failure.
    @discardableResult
    func pinRelativeReferencesToAbsolute(root: URL) throws -> Int {
        let pinResolver = ProfileStorageResolver(root: root)
        let recordings = try modelContext.fetch(FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate), SortDescriptor(\.id)]
        ))
        do {
            var pinned = 0
            for recording in recordings {
                var changed = false
                if let reference = recording.audioFileReference, !reference.isLegacy {
                    recording.audioFileReference = .legacyAbsolute(
                        try pinResolver.resolveAudio(reference).path
                    )
                    changed = true
                }
                if let reference = recording.segmentsDirectoryReference, !reference.isLegacy {
                    recording.segmentsDirectoryReference = .legacyAbsolute(
                        try pinResolver.resolveAudio(reference).path
                    )
                    changed = true
                }
                if changed { pinned += 1 }
            }
            guard pinned > 0 else { return 0 }
            try saveReferenceRewriteOrRollback()
            return pinned
        } catch {
            detailCache.removeAll()
            modelContext.rollback()
            throw error
        }
    }

    /// Directory-migration relocation, driven by the explicit copy mapping
    /// the migration produced: a legacy row is rewritten to relative form
    /// only when its lexical subpath under the old root names an item this
    /// migration copied (directly, or inside the copied segments tree) and
    /// the copy exists at the destination. Resolution never guesses;
    /// together with the per-recording `relinkLegacyAudioReference` repair
    /// this converges legacy rows to the relative end state. Covered rows
    /// have to rewrite successfully or the whole operation throws.
    ///
    /// Throwing and transactional like `pinRelativeReferencesToAbsolute`.
    @discardableResult
    func relocateAudioReferences(
        copies: [(from: URL, to: URL)], from oldRoot: URL, to newRoot: URL
    ) throws -> Int {
        let oldResolver = ProfileStorageResolver(root: oldRoot)
        let newResolver = ProfileStorageResolver(root: newRoot)

        // Interpret the mapping by lexical identity. A pair this store
        // cannot interpret means the migration and the relocation disagree
        // about the layout — abort rather than risk cleaning up a source
        // that no row releases.
        var copiedFileSubpaths: Set<String> = []
        var segmentsTreeCopied = false
        for pair in copies {
            guard let sourceSubpath = oldResolver.lexicalSubpath(of: pair.from),
                  let destinationSubpath = newResolver.lexicalSubpath(of: pair.to),
                  sourceSubpath == destinationSubpath else {
                throw ReferenceRewriteError.relocationIncomplete(pair.from.path)
            }
            if sourceSubpath == "segments" {
                segmentsTreeCopied = true
            } else {
                copiedFileSubpaths.insert(sourceSubpath)
            }
        }

        let fm = FileManager.default
        let recordings = try modelContext.fetch(FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate), SortDescriptor(\.id)]
        ))
        do {
            var relocated = 0
            for recording in recordings {
                var changed = false
                if let updated = try mappedRelocation(
                    of: recording.audioFileReference,
                    copiedFileSubpaths: copiedFileSubpaths, segmentsTreeCopied: segmentsTreeCopied,
                    oldResolver: oldResolver, newResolver: newResolver, fm: fm
                ) {
                    recording.audioFileReference = updated
                    changed = true
                }
                if let updated = try mappedRelocation(
                    of: recording.segmentsDirectoryReference,
                    copiedFileSubpaths: copiedFileSubpaths, segmentsTreeCopied: segmentsTreeCopied,
                    oldResolver: oldResolver, newResolver: newResolver, fm: fm
                ) {
                    recording.segmentsDirectoryReference = updated
                    changed = true
                }
                // Relative rows are not rewritten, but they must survive the
                // root switch: a row that resolved and existed under the old
                // root has to resolve and exist under the new root too.
                try validateRelativeSurvivesMigration(
                    recording.audioFileReference,
                    oldResolver: oldResolver, newResolver: newResolver, fm: fm
                )
                try validateRelativeSurvivesMigration(
                    recording.segmentsDirectoryReference,
                    oldResolver: oldResolver, newResolver: newResolver, fm: fm
                )
                if changed { relocated += 1 }
            }
            guard relocated > 0 else { return 0 }
            try saveReferenceRewriteOrRollback()
            return relocated
        } catch {
            // The mutation span is covered: an aborted relocation must not
            // leave half-rewritten rows for a later unrelated save.
            detailCache.removeAll()
            modelContext.rollback()
            throw error
        }
    }

    enum LegacyRelinkError: Error, Equatable {
        case recordingMissing
        case referenceNotLegacy
        /// Candidate filename differs (byte-exact) from the recorded one.
        case nameMismatch(String)
        case fileMissing(String)
    }

    /// Per-recording legacy repair (spec 10.3): rewrites one
    /// `legacyAbsolute` audio reference to relative after the user
    /// explicitly selected a same-named file inside the current root. The
    /// third sanctioned reference-rewrite operation. Never guesses: the
    /// caller supplies the exact file, this operation verifies byte-exact
    /// filename identity, existence, and root containment (through the
    /// resolver's relative derivation), rewrites only this row's audio
    /// reference, advances its content revision for web sync, and leaves
    /// ownership, the segments reference, and every other field untouched.
    @discardableResult
    func relinkLegacyAudioReference(
        recordingID: UUID, to url: URL
    ) throws -> AudioFileReference {
        // Throwing fetch: a database read failure on this mutation path
        // must propagate, not classify as a missing recording.
        let matches = try modelContext.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == recordingID }
        ))
        guard let recording = matches.first else {
            throw LegacyRelinkError.recordingMissing
        }
        guard let reference = recording.audioFileReference, reference.isLegacy else {
            throw LegacyRelinkError.referenceNotLegacy
        }
        guard LexicalPathIdentity.equals(
            url.lastPathComponent, reference.lastPathComponent
        ) else {
            throw LegacyRelinkError.nameMismatch(url.lastPathComponent)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw LegacyRelinkError.fileMissing(url.path)
        }
        do {
            // Containment and relative derivation go through the resolver;
            // an out-of-root candidate throws before any mutation.
            let relative = try resolver.makeReference(for: url)
            recording.audioFileReference = relative
            touch(recording)
            try saveReferenceRewriteOrRollback()
            return relative
        } catch {
            detailCache.removeAll()
            modelContext.rollback()
            throw error
        }
    }

    /// A relative reference that was healthy before the migration (resolves
    /// and its file exists under the old root) must stay healthy under the
    /// new root — resolution failure there means the copied entry depends on
    /// the old tree, e.g. an absolute symlink whose target the cleanup would
    /// delete. Rows that were already dangling or invalid never block the
    /// migration.
    private func validateRelativeSurvivesMigration(
        _ reference: AudioFileReference?,
        oldResolver: ProfileStorageResolver,
        newResolver: ProfileStorageResolver,
        fm: FileManager
    ) throws {
        guard let reference, !reference.isLegacy else { return }
        guard let oldURL = try? oldResolver.resolveAudio(reference),
              fm.fileExists(atPath: oldURL.path) else { return }
        guard let newURL = try? newResolver.resolveAudio(reference),
              fm.fileExists(atPath: newURL.path) else {
            throw ReferenceRewriteError.relocationIncomplete(reference.storageValue)
        }
    }

    /// Classifies one legacy reference against the copy mapping. Coverage
    /// is decided purely lexically — canonical resolution succeeding is not
    /// a precondition, because an entry inside the copied tree whose
    /// canonical form is invalid (e.g. a leaf symlink escaping the root)
    /// still loses its source to cleanup. Covered references have to
    /// rewrite: any resolve or existence failure throws so the migration
    /// aborts before source cleanup. References outside the mapping keep
    /// their legacy path; their source files were not copied and are not
    /// cleaned up.
    private func mappedRelocation(
        of reference: AudioFileReference?,
        copiedFileSubpaths: Set<String>,
        segmentsTreeCopied: Bool,
        oldResolver: ProfileStorageResolver,
        newResolver: ProfileStorageResolver,
        fm: FileManager
    ) throws -> AudioFileReference? {
        guard let reference, reference.isLegacy,
              let subpath = oldResolver.lexicalSubpath(
                of: URL(fileURLWithPath: reference.storageValue)
              ) else { return nil }

        let covered: Bool
        if copiedFileSubpaths.contains(subpath) {
            covered = true
        } else if segmentsTreeCopied, subpath.hasPrefix("segments/") {
            // The tree copy carried every entry present in the source —
            // including symlinks, which is why existence uses the lstat
            // form. A row whose source entry never existed was dangling
            // before the migration and stays legacy.
            let sourcePath = oldResolver.root.appendingPathComponent(subpath).path
            covered = (try? fm.attributesOfItem(atPath: sourcePath)) != nil
        } else {
            covered = false
        }
        guard covered else { return nil }

        guard let destination = try? newResolver.resolveAudio(.relative(subpath)),
              fm.fileExists(atPath: destination.path) else {
            throw ReferenceRewriteError.relocationIncomplete(reference.storageValue)
        }
        return .relative(subpath)
    }

    /// Rows still carrying absolute paths — surfaced in diagnostics as a
    /// health indicator until the stored-data migration rewrites them.
    func countLegacyAudioReferences() -> Int {
        let descriptor = FetchDescriptor<Recording>()
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return recordings.count {
            $0.audioFileReference?.isLegacy == true
                || $0.segmentsDirectoryReference?.isLegacy == true
        }
    }

    // MARK: - Trash Purge

    func purgeExpiredTrashWithOutcome() -> PermanentDeletionOutcome {
        let retentionDays = UserDefaults.standard.integer(forKey: "trashRetentionDays")
        let days = retentionDays > 0 ? retentionDays : 7
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate != nil && $0.trashedDate! < cutoff }
        )
        do {
            return performPermanentDeletion(try modelContext.fetch(descriptor))
        } catch {
            NSLog("[RecordingsStore] expired Trash fetch failed: %@", error.localizedDescription)
            return .failed(.persistenceFailed)
        }
    }

    @discardableResult
    func purgeExpiredTrash() -> Int {
        purgeExpiredTrashWithOutcome().committedCount
    }

    // MARK: - Orphan Cleanup

    /// Remove recordings that have no audio, no transcript, no summary, and duration < 1s.
    /// Called at startup to clean up entries from crashed or aborted recordings.
    func purgeOrphanedEmptyRecordingsWithOutcome() -> PermanentDeletionOutcome {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.trashedDate == nil && $0.duration < 1 }
        )
        let all: [Recording]
        do {
            all = try modelContext.fetch(descriptor)
        } catch {
            NSLog("[RecordingsStore] orphan cleanup fetch failed: %@", error.localizedDescription)
            return .failed(.persistenceFailed)
        }
        // Only delete recordings with no audio that are older than 2 minutes
        let cutoff = Date().addingTimeInterval(-120)
        let orphaned = all.filter { recording in
            recording.audioFilePath == nil
                && recording.audioSegmentsDirectory == nil
                && recording.transcript == nil
                && recording.summary == nil
                && recording.source != RecordingSource.external.rawValue
                && recording.startDate < cutoff
        }
        for recording in orphaned {
            NSLog(
                "[RecordingsStore] purging orphaned empty recording %@ (started %@)",
                recording.id.uuidString,
                recording.startDate.description
            )
        }
        return performPermanentDeletion(orphaned)
    }

    @discardableResult
    func purgeOrphanedEmptyRecordings() -> Int {
        purgeOrphanedEmptyRecordingsWithOutcome().committedCount
    }

    // MARK: - Recaps

    func fetchRecaps(period: String? = nil) -> [RecapDTO] {
        var descriptor = FetchDescriptor<Recap>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        if let period {
            descriptor.predicate = #Predicate { $0.period == period }
        }
        let recaps = (try? modelContext.fetch(descriptor)) ?? []
        return recaps.map { RecapDTO(from: $0) }
    }

    func recapExists(period: String, startDate: Date) -> Bool {
        let end = startDate.addingTimeInterval(1)
        let start = startDate.addingTimeInterval(-1)
        let descriptor = FetchDescriptor<Recap>(
            predicate: #Predicate { $0.period == period && $0.startDate > start && $0.startDate < end }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Fetch recordings with summaries in a date range.
    func fetchRecordingsForRecap(from startDate: Date, to endDate: Date) -> [(id: UUID, title: String, date: Date, duration: TimeInterval, tags: [String], overview: String, keyPoints: [String], decisions: [String], actionItems: [ActionItemResult])] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.startDate >= startDate && $0.startDate < endDate && $0.trashedDate == nil },
            sortBy: [SortDescriptor(\.startDate)]
        )
        let recordings = (try? modelContext.fetch(descriptor)) ?? []
        return recordings.compactMap { recording in
            guard let summary = recording.summary else { return nil }
            let items = summary.actionItems.map { item in
                ActionItemResult(assignee: item.assignee, task: item.task, deadline: item.deadline)
            }
            return (
                id: recording.id,
                title: recording.title,
                date: recording.startDate,
                duration: recording.duration,
                tags: recording.tags,
                overview: summary.overview,
                keyPoints: summary.keyPoints,
                decisions: summary.decisions,
                actionItems: items
            )
        }
    }

    @discardableResult
    func saveRecap(_ recap: Recap) -> Bool {
        performStandaloneMutation {
            modelContext.insert(recap)
        }
    }

    @discardableResult
    func deleteRecap(id: UUID) -> Bool {
        let descriptor = FetchDescriptor<Recap>(predicate: #Predicate { $0.id == id })
        guard let recap = (try? modelContext.fetch(descriptor))?.first else { return false }
        return performStandaloneMutation {
            modelContext.delete(recap)
        }
    }

    // MARK: - Testing Support

    /// Clear all data — for tests only.
    func clearAll() {
        let externalImports = (try? modelContext.fetch(FetchDescriptor<ExternalRecordingImport>())) ?? []
        for externalImport in externalImports {
            externalImport.recording = nil
            modelContext.delete(externalImport)
        }
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        for r in recordings { r.folder = nil; modelContext.delete(r) }
        let folders = (try? modelContext.fetch(FetchDescriptor<Folder>())) ?? []
        for f in folders { modelContext.delete(f) }
        let transcripts = (try? modelContext.fetch(FetchDescriptor<Transcript>())) ?? []
        for t in transcripts { modelContext.delete(t) }
        let summaries = (try? modelContext.fetch(FetchDescriptor<MeetingSummary>())) ?? []
        for s in summaries { modelContext.delete(s) }
        let speakers = (try? modelContext.fetch(FetchDescriptor<SpeakerProfile>())) ?? []
        for sp in speakers { modelContext.delete(sp) }
        let webSyncRecords = (try? modelContext.fetch(FetchDescriptor<WebSyncRecord>())) ?? []
        for record in webSyncRecords { modelContext.delete(record) }
        save()
    }

    // MARK: - Web Account Sync

    func fetchWebSyncCandidates(includeTrashed: Bool) throws -> [WebSyncCandidate] {
#if DEBUG
        try throwInjectedWebSyncDiscoveryFailureIfNeeded()
#endif
        var descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.propertiesToFetch = [
            \.id,
            \.startDate,
            \.createdAt,
            \.updatedAt,
            \.trashedDate,
            \.awaitingHistoricalConsentBindingID,
            \.audioFilePath,
        ]
        let recordings: [Recording]
        do {
            recordings = try modelContext.fetch(descriptor)
        } catch {
            NSLog("[RecordingsStore] web sync candidate discovery failed: %@", error.localizedDescription)
            throw WebSyncPersistenceError.fetchFailed
        }
        return recordings.compactMap { recording -> WebSyncCandidate? in
            guard includeTrashed || recording.trashedDate == nil else { return nil }
            return WebSyncCandidate(
                recordingID: recording.id,
                contentRevision: recording.updatedAt ?? recording.createdAt ?? recording.startDate,
                trashedDate: recording.trashedDate,
                awaitingHistoricalConsentBindingID: recording.awaitingHistoricalConsentBindingID,
                hasAudioReference: recording.audioFilePath != nil
            )
        }
    }

    /// Resolves audio only after the coordinator has applied its per-pass
    /// probe budget. Candidate discovery itself remains pure database metadata
    /// and never canonicalizes every recording path once per minute.
    func fetchWebSyncAudioProbeURL(recordingID: UUID) throws -> URL? {
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == recordingID }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.id, \.audioFilePath]
        let recording: Recording
        do {
            guard let fetched = try modelContext.fetch(descriptor).first else { return nil }
            recording = fetched
        } catch {
            NSLog("[RecordingsStore] web sync audio probe fetch failed: %@", error.localizedDescription)
            throw WebSyncPersistenceError.fetchFailed
        }
        return resolveURL(recording.audioFileReference)
    }

    func fetchWebSyncSnapshots(includeTrashed: Bool) -> [WebSyncSnapshot] {
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        ))) ?? []
        return recordings.compactMap { recording in
            guard includeTrashed || recording.trashedDate == nil else { return nil }
            return WebSyncSnapshot(
                detail: recordingToDetailDTO(recording),
                folderPath: webSyncFolderPath(recording.folder),
                trashedDate: recording.trashedDate,
                audioFileURL: resolveURL(recording.audioFileReference),
                awaitingHistoricalConsentBindingID: recording.awaitingHistoricalConsentBindingID
            )
        }
    }

    func fetchWebSyncSnapshot(recordingID: UUID) throws -> WebSyncSnapshot? {
#if DEBUG
        try throwInjectedWebSyncSnapshotFailureIfNeeded()
#endif
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == recordingID }
        )
        descriptor.fetchLimit = 1
        let recording: Recording
        do {
            guard let fetched = try modelContext.fetch(descriptor).first else { return nil }
            recording = fetched
        } catch {
            NSLog("[RecordingsStore] web sync snapshot fetch failed: %@", error.localizedDescription)
            throw WebSyncPersistenceError.fetchFailed
        }
        return WebSyncSnapshot(
            detail: recordingToDetailDTO(recording),
            folderPath: webSyncFolderPath(recording.folder),
            trashedDate: recording.trashedDate,
            audioFileURL: resolveURL(recording.audioFileReference),
            awaitingHistoricalConsentBindingID: recording.awaitingHistoricalConsentBindingID
        )
    }

    func fetchWebSyncRecord(userID: String, recordingID: UUID) -> WebSyncRecordDTO? {
        webSyncRecord(userID: userID, recordingID: recordingID).map(webSyncRecordDTO)
    }

    func fetchWebSyncRecords(userID: String) throws -> [WebSyncRecordDTO] {
#if DEBUG
        try throwInjectedWebSyncDiscoveryFailureIfNeeded()
#endif
        let descriptor = FetchDescriptor<WebSyncRecord>(
            predicate: #Predicate { $0.userID == userID }
        )
        let records: [WebSyncRecord]
        do {
            records = try modelContext.fetch(descriptor)
        } catch {
            NSLog("[RecordingsStore] web sync state discovery failed: %@", error.localizedDescription)
            throw WebSyncPersistenceError.fetchFailed
        }
        return records
            .filter { AccountIdentity.matches($0.userID, userID) }
            .map(webSyncRecordDTO)
    }

    /// Records a successful lightweight audio metadata probe without
    /// changing retry eligibility or either sync state.
    func markWebSyncAudioProbe(
        userID: String,
        recordingID: UUID,
        contentRevision: Date,
        at date: Date
    ) throws {
        let key = WebSyncRecord.key(userID: userID, recordingID: recordingID)
        let descriptor = FetchDescriptor<WebSyncRecord>(
            predicate: #Predicate { $0.syncKey == key }
        )
        let records: [WebSyncRecord]
        do {
            records = try modelContext.fetch(descriptor)
        } catch {
            NSLog("[RecordingsStore] web sync probe state fetch failed: %@", error.localizedDescription)
            throw WebSyncPersistenceError.fetchFailed
        }
        guard let record = records.first(where: {
            AccountIdentity.matches($0.userID, userID) && $0.recordingID == recordingID
        }) else {
            return
        }

        record.audioProbeRevision = contentRevision
        record.lastAttemptAt = date
        guard save() else {
            modelContext.rollback()
            detailCache.removeAll()
            throw WebSyncPersistenceError.saveFailed
        }
    }

    func upsertWebSyncRecord(_ mutation: WebSyncMutation) throws -> WebSyncRecordDTO {
        let record: WebSyncRecord
        if let existing = webSyncRecord(userID: mutation.userID, recordingID: mutation.recordingID) {
            record = existing
        } else {
            record = WebSyncRecord(userID: mutation.userID, recordingID: mutation.recordingID)
            modelContext.insert(record)
        }
        if let value = mutation.remoteRecordingID { record.remoteRecordingID = value }
        if let value = mutation.structuredState { record.structuredState = value }
        if let value = mutation.structuredHash { record.structuredHash = value }
        if let value = mutation.structuredSourceRevision { record.structuredSourceRevision = value }
        if let value = mutation.structuredAttemptRevision { record.structuredAttemptRevision = value }
        if let value = mutation.audioState { record.audioState = value }
        if let value = mutation.audioFingerprint { record.audioFingerprint = value }
        if let value = mutation.audioProbeRevision { record.audioProbeRevision = value }
        if mutation.clearUploadSessionID {
            record.uploadSessionID = nil
        } else if let value = mutation.uploadSessionID {
            record.uploadSessionID = value
        }
        if let value = mutation.attemptCount { record.attemptCount = value }
        record.nextAttemptAt = mutation.nextAttemptAt
        if let value = mutation.retryDomain { record.retryDomain = value }
        if let value = mutation.lastErrorCode { record.lastErrorCode = value }
        if let value = mutation.syncedAt { record.syncedAt = value }
        if let value = mutation.isDeletionTombstone { record.isDeletionTombstone = value }
        record.lastAttemptAt = Date()
        guard save() else {
            modelContext.rollback()
            detailCache.removeAll()
            throw WebSyncPersistenceError.saveFailed
        }
        return webSyncRecordDTO(record)
    }

    func fetchReadyWebSyncWork(userID: String, now: Date) -> [WebSyncRecordDTO] {
        let descriptor = FetchDescriptor<WebSyncRecord>(
            predicate: #Predicate { $0.userID == userID }
        )
        // The predicate narrows; the byte filter decides ownership
        // (store collation is not assumed byte-exact).
        return ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { AccountIdentity.matches($0.userID, userID) }
            .filter { $0.nextAttemptAt == nil || $0.nextAttemptAt! <= now }
            .sorted { ($0.lastAttemptAt ?? .distantPast) < ($1.lastAttemptAt ?? .distantPast) }
            .map(webSyncRecordDTO)
    }

    @discardableResult
    func requeueInitialWebSyncNotFoundFailures(userID: String) throws -> Int {
        try requeueInitialWebSyncFailures(userID: userID, statusCode: 404)
    }

    @discardableResult
    func requeueInitialWebSyncServerFailures(userID: String) throws -> Int {
        try requeueInitialWebSyncFailures(userID: userID, statusCode: 500)
    }

    /// Makes rows parked by a stated entitlement refusal eligible again.
    ///
    /// Scoped to the exact diagnostics the refusal wrote, so a capability
    /// reopening cannot also revive rows parked for an unrelated permanent
    /// failure. Transfer state is left alone: what was accepted stays accepted,
    /// and only the retry schedule and the spent diagnostic are cleared.
    @discardableResult
    func requeueWebSyncEntitlementFailures(userID: String, codes: Set<String>) throws -> Int {
        let descriptor = FetchDescriptor<WebSyncRecord>(
            predicate: #Predicate { $0.userID == userID }
        )
        let records = try modelContext.fetch(descriptor)
            .filter { AccountIdentity.matches($0.userID, userID) }
        let affected = records.filter { record in
            guard let code = record.lastErrorCode else { return false }
            return codes.contains(code)
        }
        guard !affected.isEmpty else { return 0 }
        for record in affected {
            record.nextAttemptAt = nil
            record.attemptCount = 0
            record.lastErrorCode = nil
        }
        try modelContext.save()
        return affected.count
    }

    private func requeueInitialWebSyncFailures(userID: String, statusCode: Int) throws -> Int {
        let descriptor = FetchDescriptor<WebSyncRecord>(
            predicate: #Predicate { $0.userID == userID }
        )
        let records = try modelContext.fetch(descriptor)
            .filter { AccountIdentity.matches($0.userID, userID) }
        let affected = records.filter { record in
            guard !record.isDeletionTombstone,
                  record.remoteRecordingID == nil,
                  record.structuredState == WebStructuredSyncState.failed.rawValue,
                  let lastErrorCode = record.lastErrorCode else {
                return false
            }
            let normalizedError = lastErrorCode.replacingOccurrences(of: " ", with: "")
            return normalizedError.contains("status:\(statusCode)")
        }
        guard !affected.isEmpty else { return 0 }

        for record in affected {
            record.structuredState = WebStructuredSyncState.pending.rawValue
            record.audioState = WebAudioSyncState.pending.rawValue
            record.audioFingerprint = nil
            record.uploadSessionID = nil
            record.attemptCount = 0
            record.nextAttemptAt = nil
            record.lastErrorCode = nil
            record.lastAttemptAt = nil
        }
        try modelContext.save()
        return affected.count
    }

    @discardableResult
    func markWebSyncDeletion(recordingID: UUID, userID: String) throws -> Bool {
        var mutation = WebSyncMutation(userID: userID, recordingID: recordingID)
        mutation.isDeletionTombstone = true
        mutation.structuredState = WebStructuredSyncState.pending.rawValue
        _ = try upsertWebSyncRecord(mutation)
        return true
    }

    func setActiveWebSyncUserID(_ userID: String?) {
        activeWebSyncUserID = userID
    }

#if DEBUG
    /// Test seam: the store-side active-user value the sync coordinator
    /// last published.
    func debugActiveWebSyncUserID() -> String? {
        activeWebSyncUserID
    }
#endif

    private func ensureWebSyncTombstone(recordingID: UUID, userID: String) {
        let record: WebSyncRecord
        if let existing = webSyncRecord(userID: userID, recordingID: recordingID) {
            record = existing
        } else {
            record = WebSyncRecord(userID: userID, recordingID: recordingID)
            modelContext.insert(record)
        }
        record.isDeletionTombstone = true
        record.structuredState = WebStructuredSyncState.pending.rawValue
        record.nextAttemptAt = nil
    }

    private func ensureWebSyncTombstonesForKnownAccounts(recordingID: UUID) {
        let descriptor = FetchDescriptor<WebSyncRecord>(
            predicate: #Predicate { $0.recordingID == recordingID }
        )
        let records = (try? modelContext.fetch(descriptor)) ?? []
        for record in records {
            record.isDeletionTombstone = true
            record.structuredState = WebStructuredSyncState.pending.rawValue
            record.nextAttemptAt = nil
        }
        if let activeWebSyncUserID,
           !records.contains(where: { AccountIdentity.matches($0.userID, activeWebSyncUserID) }) {
            ensureWebSyncTombstone(recordingID: recordingID, userID: activeWebSyncUserID)
        }
    }

    private func webSyncRecord(userID: String, recordingID: UUID) -> WebSyncRecord? {
        let key = WebSyncRecord.key(userID: userID, recordingID: recordingID)
        let descriptor = FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.syncKey == key })
        // Byte-exact ownership on top of the key predicate.
        return (try? modelContext.fetch(descriptor))?
            .first(where: { AccountIdentity.matches($0.userID, userID) })
    }

    private func webSyncFolderPath(_ folder: Folder?) -> String {
        var names: [String] = []
        var current = folder
        var visited = Set<UUID>()
        while let value = current, visited.insert(value.id).inserted {
            names.append(value.name)
            current = value.parentFolder
        }
        return names.reversed().joined(separator: "/")
    }

    private func webSyncRecordDTO(_ record: WebSyncRecord) -> WebSyncRecordDTO {
        WebSyncRecordDTO(
            syncKey: record.syncKey,
            userID: record.userID,
            recordingID: record.recordingID,
            remoteRecordingID: record.remoteRecordingID,
            structuredState: record.structuredState,
            structuredHash: record.structuredHash,
            structuredSourceRevision: record.structuredSourceRevision,
            structuredAttemptRevision: record.structuredAttemptRevision,
            audioState: record.audioState,
            audioFingerprint: record.audioFingerprint,
            audioProbeRevision: record.audioProbeRevision,
            uploadSessionID: record.uploadSessionID,
            attemptCount: record.attemptCount,
            nextAttemptAt: record.nextAttemptAt,
            retryDomain: record.retryDomain,
            lastAttemptAt: record.lastAttemptAt,
            syncedAt: record.syncedAt,
            isDeletionTombstone: record.isDeletionTombstone,
            lastErrorCode: record.lastErrorCode
        )
    }

    // MARK: - Private Helpers

    func recording(byID id: UUID) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func folder(byID id: UUID) -> Folder? {
        var descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Flush pending context changes. Use when batching multiple `persist:false` writes.
    @discardableResult
    func flushPendingChanges() -> Bool {
        guard save() else {
            modelContext.rollback()
            detailCache.removeAll()
            return false
        }
        return true
    }

    @discardableResult
    func save() -> Bool {
        detailCache.removeAll()
#if DEBUG
        if injectedSaveFailuresRemaining > 0 {
            injectedSaveFailuresRemaining -= 1
            NSLog("[RecordingsStore] save failed: injected in-memory test failure")
            return false
        }
#endif
        do {
            try modelContext.save()
            if !AppState.isRunningTests,
               UserDefaults.standard.bool(forKey: MarkdownMirrorLocationManager.enabledDefaultsKey) {
                NotificationCenter.default.post(name: .cadenzaRecordingsChanged, object: nil)
            }
            return true
        } catch {
            NSLog("[RecordingsStore] save failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Runs one public, independently persisted mutation without letting a
    /// failed save remain live in this actor's context. Intentionally batched
    /// `persist:false` work is committed first, so rolling back this mutation
    /// cannot erase the caller's earlier work.
    func performStandaloneMutation(_ mutation: () -> Void) -> Bool {
        guard persistPendingChangesBeforeStandaloneMutation() else { return false }
        mutation()
        guard save() else {
            modelContext.rollback()
            detailCache.removeAll()
            return false
        }
        return true
    }

    /// Bypasses the one-shot save-failure seam so tests can target the new
    /// mutation while still proving already-staged batching work is preserved.
    private func persistPendingChangesBeforeStandaloneMutation() -> Bool {
        guard modelContext.hasChanges else { return true }
        detailCache.removeAll()
#if DEBUG
        if injectedStandalonePreflightSaveFailuresRemaining > 0 {
            injectedStandalonePreflightSaveFailuresRemaining -= 1
            NSLog("[RecordingsStore] standalone preflight save failed: injected in-memory test failure")
            return false
        }
#endif
        do {
            try modelContext.save()
            if !AppState.isRunningTests,
               UserDefaults.standard.bool(forKey: MarkdownMirrorLocationManager.enabledDefaultsKey) {
                NotificationCenter.default.post(name: .cadenzaRecordingsChanged, object: nil)
            }
            return true
        } catch {
            NSLog(
                "[RecordingsStore] cannot begin standalone mutation with pending changes: %@",
                error.localizedDescription
            )
            return false
        }
    }

#if DEBUG
    func _test_failNextSave() {
        failNextSaveForTesting()
    }
#endif

    func invalidateDetailCache(_ recordingID: UUID) {
        detailCache.removeValue(forKey: recordingID)
    }

    /// Finalization is the boundary that clears the crash-recovery pointer or
    /// deletes the model for auto-discard. A failed save must also rollback the
    /// actor's live SwiftData state so a later save cannot persist that failed
    /// transaction accidentally.
    private func persistPendingChangesBeforeFinalization() -> Bool {
        guard modelContext.hasChanges else { return true }
        do {
            // Finalization may need to rollback its own mutation. Persist work
            // already queued on this actor first so that rollback cannot erase
            // an unrelated caller's intentionally batched changes.
            try modelContext.save()
            return true
        } catch {
            NSLog(
                "[RecordingsStore] cannot begin finalization with pending changes: %@",
                error.localizedDescription
            )
            return false
        }
    }

    private func saveFinalizationTransaction() -> Bool {
        detailCache.removeAll()
#if DEBUG
        if injectedSaveFailuresRemaining > 0 {
            injectedSaveFailuresRemaining -= 1
            modelContext.rollback()
            NSLog("[RecordingsStore] finalization save failed: injected in-memory test failure")
            return false
        }
#endif
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            NSLog("[RecordingsStore] finalization save failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Tracks changes visible through recording/search/MCP APIs. Internal
    /// bookkeeping such as last-access time and retry counters deliberately
    /// does not advance this timestamp.
    private func touch(_ recording: Recording, at date: Date = Date()) {
        recording.updatedAt = date
    }

    // MARK: - DTO Conversions

    private func recordingToDTO(_ recording: Recording) -> RecordingDTO {
        RecordingDTO(
            id: recording.id,
            title: recording.title,
            startDate: recording.startDate,
            endDate: recording.endDate,
            duration: recording.duration,
            meetingApp: recording.meetingApp,
            meetingURL: recording.meetingURL,
            language: recording.language,
            tags: recording.tags,
            meetingType: recording.meetingType,
            lastAccessedDate: recording.lastAccessedDate,
            trashedDate: recording.trashedDate,
            folderID: recording.folder?.id,
            linkedCalendarEventID: recording.linkedCalendarEventID,
            createdAt: recording.createdAt,
            updatedAt: recording.updatedAt,
            source: recording.source,
            hasTranscript: recording.transcript != nil,
            hasSummary: recording.summary != nil,
            transcriptPreview: recording.transcript.map { String($0.fullText.prefix(200)) },
            summaryPreview: recording.summary.map { String($0.overview.prefix(200)) },
            audioFile: recording.audioFileReference
        )
    }

    private func recordingToDetailDTO(_ recording: Recording) -> RecordingDetailDTO {
        var transcriptDTO: TranscriptDTO?
        if let t = recording.transcript {
            transcriptDTO = TranscriptDTO(
                id: t.id,
                fullText: t.fullText,
                segments: t.segments.map { entry in
                    TranscriptEntryDTO(
                        id: entry.id,
                        startTime: entry.startTime,
                        endTime: entry.endTime,
                        text: entry.text,
                        speaker: entry.speaker
                    )
                },
                detectedLanguage: t.detectedLanguage,
                createdAt: t.createdAt
            )
        }

        var summaryDTO: SummaryDTO?
        if let s = recording.summary {
            var chapters: [ChapterDTO] = []
            if let json = s.chaptersJSON,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([ChapterDTO].self, from: data) {
                chapters = decoded
            }
            summaryDTO = SummaryDTO(
                id: s.id,
                overview: s.overview,
                keyPoints: s.keyPoints,
                actionItems: s.actionItems.map { item in
                    ActionItemDTO(
                        id: item.id,
                        assignee: item.assignee,
                        task: item.task,
                        deadline: item.deadline,
                        isCompleted: item.isCompleted,
                        priority: item.priority.rawValue,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt
                    )
                },
                decisions: s.decisions,
                followUps: s.followUps,
                yourTasks: s.yourTasks,
                provider: s.provider,
                model: s.model,
                language: s.language,
                createdAt: s.createdAt,
                chapters: chapters
            )
        }

        return RecordingDetailDTO(
            id: recording.id,
            title: recording.title,
            startDate: recording.startDate,
            endDate: recording.endDate,
            duration: recording.duration,
            meetingApp: recording.meetingApp,
            meetingURL: recording.meetingURL,
            language: recording.language,
            tags: recording.tags,
            meetingType: recording.meetingType,
            lastAccessedDate: recording.lastAccessedDate,
            folderID: recording.folder?.id,
            audioFile: recording.audioFileReference,
            linkedCalendarEventID: recording.linkedCalendarEventID,
            createdAt: recording.createdAt,
            updatedAt: recording.updatedAt,
            source: recording.source,
            transcript: transcriptDTO,
            summary: summaryDTO,
            speakerMappings: (recording.speakerMappings ?? []).compactMap { mapping in
                guard let profile = speakerProfile(byID: mapping.profileID) else { return nil }
                return SpeakerLabelMappingDTO(
                    rawLabel: mapping.rawLabel,
                    profileID: mapping.profileID,
                    profileName: profile.displayName
                )
            },
            speakerSuggestions: (recording.speakerSuggestions ?? []).compactMap { s in
                guard let profile = speakerProfile(byID: s.profileID) else { return nil }
                return SpeakerLabelSuggestionDTO(
                    rawLabel: s.rawLabel,
                    profileID: s.profileID,
                    profileName: profile.displayName,
                    score: s.score,
                    strategy: s.strategy
                )
            }
        )
    }

    private func folderToDTO(_ folder: Folder) -> FolderDTO {
        FolderDTO(
            id: folder.id,
            name: folder.name,
            icon: folder.icon,
            iconColor: folder.iconColor,
            colorHex: folder.colorHex,
            status: folder.status,
            createdAt: folder.createdAt,
            sortOrder: folder.sortOrder,
            recordingCount: folder.recordings.count,
            parentFolderID: folder.parentFolder?.id,
            subfolderCount: folder.subfolders.count
        )
    }

    // MARK: - Speaker Profiles

    func speakerProfile(byID id: UUID) -> SpeakerProfile? {
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func fetchSpeakerProfiles() -> [SpeakerProfileDTO] {
        let descriptor = FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.displayName)])
        let profiles = (try? modelContext.fetch(descriptor)) ?? []
        return profiles.map { speakerProfileToDTO($0) }
    }

    @discardableResult
    func createSpeakerProfile(displayName: String, notes: String = "", teamOrOrg: String? = nil) -> SpeakerProfileDTO? {
        let profile = SpeakerProfile(displayName: displayName, notes: notes, teamOrOrg: teamOrOrg)
        let dto = speakerProfileToDTO(profile)
        guard performStandaloneMutation({ modelContext.insert(profile) }) else { return nil }
        return dto
    }

    @discardableResult
    func updateSpeakerProfile(id: UUID, displayName: String, notes: String, teamOrOrg: String?) -> Bool {
        guard let profile = speakerProfile(byID: id) else { return false }
        guard profile.displayName != displayName
                || profile.notes != notes
                || profile.teamOrOrg != teamOrOrg else { return true }

        let recordings: [Recording]
        do {
            recordings = try modelContext.fetch(FetchDescriptor<Recording>())
        } catch {
            NSLog("[RecordingsStore] speaker profile recording fetch failed: %@", error.localizedDescription)
            return false
        }

        profile.displayName = displayName
        profile.notes = notes
        profile.teamOrOrg = teamOrOrg
        for recording in recordings where
            (recording.speakerMappings ?? []).contains(where: { $0.profileID == id })
                || (recording.speakerSuggestions ?? []).contains(where: { $0.profileID == id }) {
            touch(recording)
            invalidateDetailCache(recording.id)
        }

        guard save() else {
            modelContext.rollback()
            detailCache.removeAll()
            return false
        }
        return true
    }

    @discardableResult
    func deleteSpeakerProfile(id: UUID) -> Bool {
        guard let profile = speakerProfile(byID: id) else { return false }

        let recordings: [Recording]
        let voiceSamples: [SpeakerVoiceSample]
        do {
            recordings = try modelContext.fetch(FetchDescriptor<Recording>())
            voiceSamples = try modelContext.fetch(FetchDescriptor<SpeakerVoiceSample>())
        } catch {
            NSLog("[RecordingsStore] speaker profile dependency fetch failed: %@", error.localizedDescription)
            return false
        }

        let sampleRecordingIDs = Set(
            voiceSamples.compactMap { sample in
                sample.profile?.id == id ? sample.recordingID : nil
            }
        )
        let affectedRecordings = recordings.filter { recording in
            (recording.speakerMappings ?? []).contains { $0.profileID == id }
                || (recording.speakerSuggestions ?? []).contains { $0.profileID == id }
                || sampleRecordingIDs.contains(recording.id)
        }
        let previousRevisions = Dictionary(
            uniqueKeysWithValues: affectedRecordings.map { recording in
                (recording.id, speakerIdentityRevisions[recording.id] ?? 0)
            }
        )

        for recording in affectedRecordings {
            var mappings = recording.speakerMappings ?? []
            mappings.removeAll { $0.profileID == id }
            recording.speakerMappings = mappings

            if var suggestions = recording.speakerSuggestions {
                suggestions.removeAll { $0.profileID == id }
                recording.speakerSuggestions = suggestions.isEmpty ? nil : suggestions
            }

            touch(recording)

            speakerIdentityRevisions[recording.id] = (previousRevisions[recording.id] ?? 0) &+ 1
            invalidateDetailCache(recording.id)
        }

        modelContext.delete(profile)
        guard save() else {
            modelContext.rollback()
            for (recordingID, revision) in previousRevisions {
                speakerIdentityRevisions[recordingID] = revision
                invalidateDetailCache(recordingID)
            }
            return false
        }
        return true
    }

    // MARK: - Speaker Mappings

    /// Atomic find-or-create-by-name + mapping write, for the MCP
    /// set_speaker_name tool. Runs entirely inside the actor so two
    /// concurrent calls can't race the lookup into duplicate profiles,
    /// and the save result is surfaced instead of swallowed.
    func setSpeakerName(recordingID: UUID, rawLabel: String, profileNamed name: String)
        -> (profileName: String, reusedExisting: Bool)? {
        guard recording(byID: recordingID) != nil else { return nil }

        let profile: SpeakerProfileDTO
        let reused: Bool
        let existing = fetchSpeakerProfiles().first {
            $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        if let existing {
            profile = existing
            reused = true
        } else {
            guard let created = createSpeakerProfile(displayName: name) else { return nil }
            profile = created
            reused = false
        }

        // setSpeakerMapping returns its save() result — a failed save means
        // the mapping did NOT durably land, so report failure.
        guard setSpeakerMapping(recordingID: recordingID, rawLabel: rawLabel, profileID: profile.id) else {
            return nil
        }
        return (profile.displayName, reused)
    }

    @discardableResult
    func setSpeakerMapping(
        recordingID: UUID,
        rawLabel: String,
        profileID: UUID,
        expectedSpeakerIdentityRevision: UInt64? = nil,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) -> Bool {
        if let expectedSpeakerIdentityRevision {
            return applySpeakerMappingIfCurrent(
                recordingID: recordingID,
                rawLabel: rawLabel,
                profileID: profileID,
                expectedSpeakerIdentityRevision: expectedSpeakerIdentityRevision,
                speakerMemorySession: speakerMemorySession
            ) == .applied
        }

        if let speakerMemorySession,
           !allowsSpeakerMemoryWrite(speakerMemorySession) {
            return false
        }
        guard let recording = recording(byID: recordingID),
              let profile = speakerProfile(byID: profileID) else { return false }

        let previousRevision = speakerIdentityRevisions[recordingID] ?? 0
        speakerIdentityRevisions[recordingID] = previousRevision &+ 1

        stageSpeakerMapping(
            recording: recording,
            rawLabel: rawLabel,
            profile: profile,
            speakerMemorySession: speakerMemorySession
        )

        invalidateDetailCache(recordingID)
        guard save() else {
            modelContext.rollback()
            speakerIdentityRevisions[recordingID] = previousRevision
            invalidateDetailCache(recordingID)
            return false
        }
        return true
    }

    /// Applies a speaker-memory mapping only when its transcript generation is
    /// still current and the user has not already chosen a mapping for the
    /// label. The actor keeps the compare-and-set decision and save atomic.
    func applySpeakerMappingIfCurrent(
        recordingID: UUID,
        rawLabel: String,
        profileID: UUID,
        expectedSpeakerIdentityRevision: UInt64,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) -> SpeakerIdentityWriteResult {
        if let speakerMemorySession,
           !allowsSpeakerMemoryWrite(speakerMemorySession) {
            return .rejectedStaleRevision
        }
        guard speakerIdentityRevisionMatches(
            recordingID: recordingID,
            expected: expectedSpeakerIdentityRevision
        ) else { return .rejectedStaleRevision }
        guard let recording = recording(byID: recordingID),
              let profile = speakerProfile(byID: profileID) else { return .targetMissing }

        if (recording.speakerMappings ?? []).contains(where: { $0.rawLabel == rawLabel }) {
            return .preservedExistingMapping
        }

        stageSpeakerMapping(
            recording: recording,
            rawLabel: rawLabel,
            profile: profile,
            speakerMemorySession: speakerMemorySession
        )

        invalidateDetailCache(recordingID)
        guard save() else {
            modelContext.rollback()
            invalidateDetailCache(recordingID)
            return .saveFailed
        }
        return .applied
    }

    private func stageSpeakerMapping(
        recording: Recording,
        rawLabel: String,
        profile: SpeakerProfile,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) {
        let recordingID = recording.id
        let profileID = profile.id

        var mappings = recording.speakerMappings ?? []
        mappings.removeAll { $0.rawLabel == rawLabel }
        mappings.append(SpeakerLabelMapping(rawLabel: rawLabel, profileID: profileID))
        recording.speakerMappings = mappings
        touch(recording)

        profile.lastSeenAt = Date()

        // Explicit naming remains available without voice-memory consent, but
        // it must not silently confirm an existing embedding for reuse.
        let mayUpdateVoiceMemory = speakerMemorySession.map(allowsSpeakerMemoryWrite)
            ?? isSpeakerMemoryEnabled()
        if mayUpdateVoiceMemory {
            let sampleDimension = fetchVoiceSample(
                recordingID: recordingID,
                rawLabel: rawLabel
            )?.embeddingDimension
            attachSampleToProfile(
                recordingID: recordingID,
                rawLabel: rawLabel,
                profileID: profileID,
                persist: false,
                speakerMemorySession: speakerMemorySession
            )
            enforceRetentionCap(
                profileID: profileID,
                modelVersion: SpeakerKitEmbeddingExtractor.currentModelVersion,
                embeddingDimension: sampleDimension,
                maxSamples: 5,
                persist: false
            )
        }
    }

    @discardableResult
    func removeSpeakerMapping(recordingID: UUID, rawLabel: String) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let previousRevision = speakerIdentityRevisions[recordingID] ?? 0
        speakerIdentityRevisions[recordingID] = previousRevision &+ 1

        var mappings = recording.speakerMappings ?? []
        mappings.removeAll { $0.rawLabel == rawLabel }
        recording.speakerMappings = mappings
        touch(recording)

        detachSampleFromProfile(recordingID: recordingID, rawLabel: rawLabel, persist: false)

        invalidateDetailCache(recordingID)
        guard save() else {
            modelContext.rollback()
            speakerIdentityRevisions[recordingID] = previousRevision
            invalidateDetailCache(recordingID)
            return false
        }
        return true
    }

    // MARK: - Voice Sample APIs

    struct VoiceSampleWrite: Sendable {
        let rawLabel: String
        let embeddingData: Data
        let embeddingDimension: Int
        let sampleDuration: TimeInterval
        let nonOverlapRatio: Float
        let qualityScore: Float
        let modelVersion: String
    }

    /// Replaces all supplied per-label samples and attaches them to any existing
    /// mappings in one revision-guarded transaction. A stale generation, missing
    /// mapped profile, or save failure leaves the previous sample set intact.
    func upsertVoiceSamplesIfCurrent(
        recordingID: UUID,
        samples: [VoiceSampleWrite],
        expectedSpeakerIdentityRevision: UInt64,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) -> SpeakerIdentityWriteResult {
        if let speakerMemorySession,
           !allowsSpeakerMemoryWrite(speakerMemorySession) {
            return .rejectedStaleRevision
        }
        guard speakerIdentityRevisionMatches(
            recordingID: recordingID,
            expected: expectedSpeakerIdentityRevision
        ) else { return .rejectedStaleRevision }
        guard let recording = recording(byID: recordingID) else { return .targetMissing }
        guard !samples.isEmpty else { return .applied }

        let existingSamples: [SpeakerVoiceSample]
        let profiles: [SpeakerProfile]
        do {
            existingSamples = try fetchAllVoiceSampleModelsThrowing(recordingID: recordingID)
            profiles = try modelContext.fetch(FetchDescriptor<SpeakerProfile>())
        } catch {
            NSLog("[RecordingsStore] voice sample batch dependency fetch failed: %@", error.localizedDescription)
            return .saveFailed
        }

        let labels = Set(samples.map(\.rawLabel))
        let relevantMappings = (recording.speakerMappings ?? []).filter {
            labels.contains($0.rawLabel)
        }
        var profileByID: [UUID: SpeakerProfile] = [:]
        for profile in profiles {
            profileByID[profile.id] = profile
        }
        var profileByLabel: [String: SpeakerProfile] = [:]
        for mapping in relevantMappings {
            guard let profile = profileByID[mapping.profileID] else {
                return .targetMissing
            }
            profileByLabel[mapping.rawLabel] = profile
        }

        for existing in existingSamples where labels.contains(existing.rawLabel) {
            modelContext.delete(existing)
        }
        for sample in samples {
            modelContext.insert(SpeakerVoiceSample(
                recordingID: recordingID,
                rawLabel: sample.rawLabel,
                profile: profileByLabel[sample.rawLabel],
                embeddingData: sample.embeddingData,
                embeddingDimension: sample.embeddingDimension,
                sampleDuration: sample.sampleDuration,
                nonOverlapRatio: sample.nonOverlapRatio,
                qualityScore: sample.qualityScore,
                modelVersion: sample.modelVersion
            ))
        }

        let didSave = if let speakerMemorySession {
            saveSpeakerMemoryBatch(session: speakerMemorySession)
        } else {
            save()
        }
        guard didSave else {
            modelContext.rollback()
            return .saveFailed
        }
        return .applied
    }

    @discardableResult
    func upsertVoiceSample(
        recordingID: UUID,
        rawLabel: String,
        embeddingData: Data,
        embeddingDimension: Int,
        sampleDuration: TimeInterval,
        nonOverlapRatio: Float,
        qualityScore: Float,
        modelVersion: String,
        expectedSpeakerIdentityRevision: UInt64? = nil,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) -> Bool {
        guard allowsSpeakerMemoryWrite(speakerMemorySession) else { return false }
        guard speakerIdentityRevisionMatches(
            recordingID: recordingID,
            expected: expectedSpeakerIdentityRevision
        ) else { return false }
        // Guard: don't create samples for deleted recordings (race with deletion)
        guard recording(byID: recordingID) != nil else { return false }

        let existing = fetchVoiceSample(recordingID: recordingID, rawLabel: rawLabel)
        if let existing {
            modelContext.delete(existing)
        }

        let sample = SpeakerVoiceSample(
            recordingID: recordingID,
            rawLabel: rawLabel,
            embeddingData: embeddingData,
            embeddingDimension: embeddingDimension,
            sampleDuration: sampleDuration,
            nonOverlapRatio: nonOverlapRatio,
            qualityScore: qualityScore,
            modelVersion: modelVersion
        )
        modelContext.insert(sample)
        let didSave = if let speakerMemorySession {
            saveSpeakerMemoryBatch(session: speakerMemorySession)
        } else {
            save()
        }
        guard didSave else {
            modelContext.rollback()
            return false
        }
        return true
    }

    struct VoiceSampleSnapshot: Sendable {
        let recordingID: UUID
        let rawLabel: String
        let profileID: UUID?
        let embeddingDimension: Int
        let sampleDuration: TimeInterval
        let nonOverlapRatio: Float
        let qualityScore: Float
        let modelVersion: String
        let createdAt: Date
    }

    func fetchAllVoiceSamples(recordingID: UUID) -> [VoiceSampleSnapshot] {
        fetchAllVoiceSampleModels(recordingID: recordingID).map { sample in
            VoiceSampleSnapshot(
                recordingID: sample.recordingID,
                rawLabel: sample.rawLabel,
                profileID: sample.profile?.id,
                embeddingDimension: sample.embeddingDimension,
                sampleDuration: sample.sampleDuration,
                nonOverlapRatio: sample.nonOverlapRatio,
                qualityScore: sample.qualityScore,
                modelVersion: sample.modelVersion,
                createdAt: sample.createdAt
            )
        }
    }

    private func fetchAllVoiceSampleModels(recordingID: UUID) -> [SpeakerVoiceSample] {
        (try? fetchAllVoiceSampleModelsThrowing(recordingID: recordingID)) ?? []
    }

    private func fetchAllVoiceSampleModelsThrowing(recordingID: UUID) throws -> [SpeakerVoiceSample] {
        let descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.recordingID == recordingID }
        )
        return try modelContext.fetch(descriptor)
    }

    func hasVoiceSamples(recordingID: UUID) -> Bool {
        var descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.recordingID == recordingID }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    func beginSpeakerMemoryWriteSession() -> SpeakerMemoryWriteSession? {
        guard isSpeakerMemoryEnabled() else { return nil }
        return SpeakerMemoryWriteSession(generation: speakerMemoryWriteGeneration)
    }

    func invalidateSpeakerMemoryWriteSessions() {
        speakerMemoryWriteGeneration &+= 1
    }

    /// Attaches all voice samples that correspond to existing explicit
    /// mappings in one actor-isolated transaction. The transaction refuses to
    /// absorb older pending changes because a rollback must affect only this
    /// speaker-memory batch.
    @discardableResult
    func attachMappedVoiceSamplesToProfiles(
        recordingID: UUID,
        mappings: [SpeakerLabelMappingDTO],
        speakerMemorySession: SpeakerMemoryWriteSession
    ) -> Bool {
        guard allowsSpeakerMemoryWrite(speakerMemorySession) else { return false }
        guard !modelContext.hasChanges else {
            NSLog("[RecordingsStore] speaker-memory attach skipped: unrelated pending changes")
            return false
        }
        guard recording(byID: recordingID) != nil else { return false }

        let attachments = mappings.compactMap { mapping -> (SpeakerVoiceSample, SpeakerProfile)? in
            guard let sample = fetchVoiceSample(
                recordingID: recordingID,
                rawLabel: mapping.rawLabel
            ), let profile = speakerProfile(byID: mapping.profileID) else {
                return nil
            }
            return (sample, profile)
        }
        guard !attachments.isEmpty else { return true }
        guard allowsSpeakerMemoryWrite(speakerMemorySession) else { return false }

        for (sample, profile) in attachments {
            sample.profile = profile
        }
        return saveSpeakerMemoryBatch(session: speakerMemorySession)
    }

    private func allowsSpeakerMemoryWrite(_ session: SpeakerMemoryWriteSession?) -> Bool {
        guard let session else { return true }
        return isSpeakerMemoryEnabled()
            && session.generation == speakerMemoryWriteGeneration
    }

    private func isSpeakerMemoryEnabled() -> Bool {
#if DEBUG
        if let speakerMemoryConsentOverride {
            return speakerMemoryConsentOverride
        }
#endif
        return SpeakerMemoryConsent.isEnabled()
    }

    private func saveSpeakerMemoryBatch(
        session: SpeakerMemoryWriteSession
    ) -> Bool {
        guard allowsSpeakerMemoryWrite(session) else {
            modelContext.rollback()
            return false
        }
        detailCache.removeAll()
#if DEBUG
        if injectedSaveFailuresRemaining > 0 {
            injectedSaveFailuresRemaining -= 1
            modelContext.rollback()
            NSLog("[RecordingsStore] speaker-memory batch save failed: injected test failure")
            return false
        }
#endif
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            NSLog("[RecordingsStore] speaker-memory batch save failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Removes reusable cross-recording voice embeddings and generated voice
    /// suggestions while preserving explicit speaker profiles and mappings.
    /// The mutation is rolled back if persistence fails so the UI never reports
    /// a privacy deletion that only changed the in-memory context.
    @discardableResult
    func deleteAllSpeakerMemory() -> Bool {
        invalidateSpeakerMemoryWriteSessions()

        let samples: [SpeakerVoiceSample]
        let recordings: [Recording]
        do {
            samples = try modelContext.fetch(FetchDescriptor<SpeakerVoiceSample>())
            recordings = try modelContext.fetch(FetchDescriptor<Recording>())
        } catch {
            NSLog("[RecordingsStore] voice memory deletion fetch failed: %@", error.localizedDescription)
            return false
        }
        let sampleSnapshots = samples.map { sample in
            (
                recordingID: sample.recordingID,
                rawLabel: sample.rawLabel,
                profileID: sample.profile?.id,
                embeddingData: sample.embeddingData,
                embeddingDimension: sample.embeddingDimension,
                sampleDuration: sample.sampleDuration,
                nonOverlapRatio: sample.nonOverlapRatio,
                qualityScore: sample.qualityScore,
                modelVersion: sample.modelVersion,
                createdAt: sample.createdAt
            )
        }
        let suggestionsByRecording = recordings.compactMap { recording in
            recording.speakerSuggestions.map { (recording, $0) }
        }

        for sample in samples {
            modelContext.delete(sample)
        }
        for recording in recordings where recording.speakerSuggestions != nil {
            recording.speakerSuggestions = nil
        }

        guard save() else {
            // Restore only this operation's mutations. A context-wide rollback
            // could silently discard an unrelated Store batch that is waiting
            // for its own flush.
            for snapshot in sampleSnapshots {
                let restored = SpeakerVoiceSample(
                    recordingID: snapshot.recordingID,
                    rawLabel: snapshot.rawLabel,
                    profile: snapshot.profileID.flatMap(speakerProfile(byID:)),
                    embeddingData: snapshot.embeddingData,
                    embeddingDimension: snapshot.embeddingDimension,
                    sampleDuration: snapshot.sampleDuration,
                    nonOverlapRatio: snapshot.nonOverlapRatio,
                    qualityScore: snapshot.qualityScore,
                    modelVersion: snapshot.modelVersion
                )
                restored.createdAt = snapshot.createdAt
                modelContext.insert(restored)
            }
            for (recording, suggestions) in suggestionsByRecording {
                recording.speakerSuggestions = suggestions
            }
            detailCache.removeAll()
            return false
        }
        return true
    }

    struct ConfirmedVoiceSample: Sendable {
        let profileID: UUID
        let profileName: String
        let embedding: [Float]
        let embeddingDimension: Int
        let modelVersion: String
        let sampleCount: Int  // total confirmed samples for this profile
    }

    func fetchConfirmedSamples(modelVersion: String, embeddingDimension: Int? = nil) -> [ConfirmedVoiceSample] {
        let descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.modelVersion == modelVersion && $0.profile != nil }
        )
        guard let samples = try? modelContext.fetch(descriptor) else { return [] }

        struct BucketKey: Hashable {
            let profileID: UUID
            let dimension: Int
        }

        // Group by profile and embedding dimension. SpeakerKit has changed
        // embedding width without changing our app-level modelVersion string,
        // and mixed-dimension centroids cannot be compared meaningfully.
        var byProfile: [BucketKey: (name: String, embeddings: [[Float]])] = [:]
        for sample in samples {
            if let embeddingDimension, sample.embeddingDimension != embeddingDimension {
                continue
            }
            guard let profileID = sample.profile?.id else { continue }
            let name = sample.profile?.displayName ?? ""
            let key = BucketKey(profileID: profileID, dimension: sample.embeddingDimension)
            byProfile[key, default: (name, [])].embeddings.append(sample.embedding)
        }

        return byProfile.map { key, info in
            ConfirmedVoiceSample(
                profileID: key.profileID,
                profileName: info.name,
                embedding: SpeakerMemoryService.computeCentroid(
                    info.embeddings.map { SpeakerMemoryService.l2Normalize($0) }
                ),
                embeddingDimension: key.dimension,
                modelVersion: modelVersion,
                sampleCount: info.embeddings.count
            )
        }
    }

    @discardableResult
    func attachSampleToProfile(
        recordingID: UUID,
        rawLabel: String,
        profileID: UUID,
        persist: Bool = true,
        expectedSpeakerIdentityRevision: UInt64? = nil,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) -> Bool {
        guard allowsSpeakerMemoryWrite(speakerMemorySession) else { return false }
        guard speakerIdentityRevisionMatches(
            recordingID: recordingID,
            expected: expectedSpeakerIdentityRevision
        ) else { return false }
        guard let sample = fetchVoiceSample(recordingID: recordingID, rawLabel: rawLabel),
              let profile = speakerProfile(byID: profileID) else { return false }
        sample.profile = profile
        if persist {
            let didSave = if let speakerMemorySession {
                saveSpeakerMemoryBatch(session: speakerMemorySession)
            } else {
                save()
            }
            guard didSave else {
                modelContext.rollback()
                return false
            }
        }
        return true
    }

    @discardableResult
    func detachSampleFromProfile(recordingID: UUID, rawLabel: String, persist: Bool = true) -> Bool {
        guard let sample = fetchVoiceSample(recordingID: recordingID, rawLabel: rawLabel) else { return false }
        sample.profile = nil
        if persist {
            guard save() else {
                modelContext.rollback()
                return false
            }
        }
        return true
    }

    func enforceRetentionCap(
        profileID: UUID,
        modelVersion: String,
        embeddingDimension: Int? = nil,
        maxSamples: Int,
        persist: Bool = true
    ) {
        // Two-step approach: SwiftData predicates don't support optional chaining on relationships
        let descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.modelVersion == modelVersion && $0.profile != nil },
            sortBy: [SortDescriptor(\.qualityScore, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let allSamples = try? modelContext.fetch(descriptor) else { return }
        let samples = allSamples.filter {
            $0.profile?.id == profileID && (embeddingDimension == nil || $0.embeddingDimension == embeddingDimension)
        }
        guard samples.count > maxSamples else { return }
        let excess = samples.prefix(samples.count - maxSamples)
        for sample in excess {
            modelContext.delete(sample)
        }
        if persist {
            guard save() else {
                modelContext.rollback()
                return
            }
        }
    }

    private func fetchVoiceSample(recordingID: UUID, rawLabel: String) -> SpeakerVoiceSample? {
        let descriptor = FetchDescriptor<SpeakerVoiceSample>(
            predicate: #Predicate { $0.recordingID == recordingID && $0.rawLabel == rawLabel }
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Speaker Suggestions

    @discardableResult
    func saveSpeakerSuggestions(
        recordingID: UUID,
        suggestions: [SpeakerLabelSuggestion],
        expectedSpeakerIdentityRevision: UInt64? = nil,
        speakerMemorySession: SpeakerMemoryWriteSession? = nil
    ) -> Bool {
        guard allowsSpeakerMemoryWrite(speakerMemorySession) else { return false }
        guard speakerIdentityRevisionMatches(
            recordingID: recordingID,
            expected: expectedSpeakerIdentityRevision
        ) else { return false }
        guard let recording = recording(byID: recordingID) else { return false }

        let suggestedProfileIDs = Set(suggestions.map(\.profileID))
        if !suggestedProfileIDs.isEmpty {
            let existingProfileIDs: Set<UUID>
            do {
                existingProfileIDs = Set(
                    try modelContext.fetch(FetchDescriptor<SpeakerProfile>()).map(\.id)
                )
            } catch {
                NSLog("[RecordingsStore] suggestion profile validation failed: %@", error.localizedDescription)
                return false
            }
            guard suggestedProfileIDs.isSubset(of: existingProfileIDs) else {
                NSLog("[RecordingsStore] rejected suggestions referencing a deleted profile")
                return false
            }
        }

        recording.speakerSuggestions = suggestions
        invalidateDetailCache(recordingID)
        let didSave = if let speakerMemorySession {
            saveSpeakerMemoryBatch(session: speakerMemorySession)
        } else {
            save()
        }
        guard didSave else {
            modelContext.rollback()
            invalidateDetailCache(recordingID)
            return false
        }
        return true
    }

    func fetchSpeakerAnalysisSnapshot(recordingID: UUID) -> SpeakerAnalysisSnapshot? {
        guard let detail = fetchRecordingDetail(recordingID: recordingID) else { return nil }
        return SpeakerAnalysisSnapshot(
            detail: detail,
            speakerIdentityRevision: speakerIdentityRevisions[recordingID] ?? 0
        )
    }

    func isSpeakerIdentityRevisionCurrent(recordingID: UUID, revision: UInt64) -> Bool {
        speakerIdentityRevisionMatches(recordingID: recordingID, expected: revision)
    }

    private func speakerIdentityRevisionMatches(
        recordingID: UUID,
        expected: UInt64?
    ) -> Bool {
        guard let expected else { return true }
        return (speakerIdentityRevisions[recordingID] ?? 0) == expected
    }

    @discardableResult
    func clearSpeakerSuggestions(recordingID: UUID) -> Bool {
        guard let recording = recording(byID: recordingID) else { return false }
        let previousRevision = speakerIdentityRevisions[recordingID] ?? 0
        speakerIdentityRevisions[recordingID] = previousRevision &+ 1

        recording.speakerSuggestions = nil
        invalidateDetailCache(recordingID)
        guard save() else {
            modelContext.rollback()
            speakerIdentityRevisions[recordingID] = previousRevision
            invalidateDetailCache(recordingID)
            return false
        }
        return true
    }

    func speakerMappings(forRecordingID recordingID: UUID) -> [SpeakerLabelMappingDTO] {
        guard let recording = recording(byID: recordingID) else { return [] }
        return (recording.speakerMappings ?? []).compactMap { mapping in
            guard let profile = speakerProfile(byID: mapping.profileID) else { return nil }
            return SpeakerLabelMappingDTO(
                rawLabel: mapping.rawLabel,
                profileID: mapping.profileID,
                profileName: profile.displayName
            )
        }
    }

    /// Returns distinct raw speaker labels from a recording's transcript.
    func rawSpeakerLabels(forRecordingID recordingID: UUID) -> [String] {
        guard let recording = recording(byID: recordingID),
              let transcript = recording.transcript else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for segment in transcript.segments {
            if let speaker = segment.speaker, !speaker.isEmpty, seen.insert(speaker).inserted {
                result.append(speaker)
            }
        }
        return result
    }

    // MARK: - AI Context Queries

    /// Lightweight query returning all known speaker names and aliases for
    /// use in AI context pre-filtering (e.g. resolving "what did Alice say?").
    func fetchSpeakerNamesAndAliases() -> [SpeakerNameInfo] {
        let descriptor = FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.displayName)])
        let profiles = (try? modelContext.fetch(descriptor)) ?? []
        return profiles.map { SpeakerNameInfo(displayName: $0.displayName, aliases: $0.aliases) }
    }

    /// Heavy context query that returns recordings, summaries, action items,
    /// decisions, follow-ups, and transcript excerpts for the AI context layer.
    func fetchAIContext(
        recordingIDs: [UUID]? = nil,
        dateRange: (start: Date, end: Date)? = nil,
        speakerQueries: [String]? = nil,
        keywords: [String]? = nil,
        meetingType: MeetingType? = nil,
        mostRecentRecordingOnly: Bool = false,
        speakerMatchMode: SpeakerMatchMode = .all,
        maxTranscriptEntries: Int = 200
    ) -> AIContextData {
        // 1. Fetch recordings filtered by IDs or date range (exclude trashed)
        let recordings: [Recording]
        if let ids = recordingIDs, !ids.isEmpty {
            let descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { rec in
                    rec.trashedDate == nil
                },
                sortBy: [SortDescriptor(\.startDate, order: .reverse)]
            )
            let all = (try? modelContext.fetch(descriptor)) ?? []
            recordings = all.filter { ids.contains($0.id) }
        } else if let range = dateRange {
            let start = range.start
            let end = range.end
            let descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { rec in
                    rec.trashedDate == nil && rec.startDate >= start && rec.startDate <= end
                },
                sortBy: [SortDescriptor(\.startDate, order: .reverse)]
            )
            recordings = (try? modelContext.fetch(descriptor)) ?? []
        } else {
            // No date filter ("all recordings" chat scope). Cap the fetch so a
            // large library doesn't turn one chat turn into a full-store
            // relationship walk — the context token budget (≤30k) can't fit
            // more than ~200 summaries anyway, and the sort is newest-first,
            // so the cap drops exactly the recordings the budget would drop.
            var descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { rec in
                    rec.trashedDate == nil
                },
                sortBy: [SortDescriptor(\.startDate, order: .reverse)]
            )
            let needsRecordingLevelResolution = mostRecentRecordingOnly
                || meetingType != nil
                || !(speakerQueries?.isEmpty ?? true)
            if !needsRecordingLevelResolution {
                descriptor.fetchLimit = 200
            }
            recordings = (try? modelContext.fetch(descriptor)) ?? []
        }

        // 2. Build speaker profile lookup (profileID → displayName)
        let allProfiles = (try? modelContext.fetch(FetchDescriptor<SpeakerProfile>())) ?? []
        let profilesByID = Dictionary(uniqueKeysWithValues: allProfiles.map { ($0.id, $0) })

        // 3. Build speaker label → resolved name map per recording
        func resolvedName(for rawLabel: String?, in recording: Recording) -> String? {
            guard let label = rawLabel, !label.isEmpty else { return nil }
            guard let mappings = recording.speakerMappings else { return nil }
            guard let mapping = mappings.first(where: { $0.rawLabel == label }) else { return nil }
            return profilesByID[mapping.profileID]?.displayName
        }

        // Trim + lowercase queries for case-insensitive matching, dropping blanks.
        // Semantics (careful — chat's QueryAnalyzer passes NON-optional arrays, often []):
        //   nil or []      = caller has no speaker/keyword condition → no filtering.
        //   non-empty but all-blank after cleaning = caller INTENDED to filter but every
        //   query is whitespace (e.g. a blank attendee name) → reject ALL segments, never
        //   fall through to "no filter" (contains("") matches everything → full-library
        //   leak, see MeetingPrepContextBuilder.assemble's blank-attendee regression).
        let lowerSpeakerQueries = speakerQueries?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let lowerKeywords = keywords?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let speakerQueriesRequestedButAllBlank =
            (speakerQueries?.isEmpty == false) && (lowerSpeakerQueries?.isEmpty ?? true)
        let keywordsRequestedButAllBlank =
            (keywords?.isEmpty == false) && (lowerKeywords?.isEmpty ?? true)

        func recordingContainsRequestedSpeaker(_ recording: Recording) -> Bool {
            guard let queries = lowerSpeakerQueries, !queries.isEmpty,
                  let segments = recording.transcript?.segments else {
                return lowerSpeakerQueries?.isEmpty ?? true
            }
            func recordingHasSpeaker(_ query: String) -> Bool {
                segments.contains { segment in
                    let rawLower = segment.speaker?.lowercased() ?? ""
                    let resolvedLower = resolvedName(for: segment.speaker, in: recording)?.lowercased() ?? ""
                    return rawLower.contains(query) || resolvedLower.contains(query)
                }
            }
            // `.all` = every named speaker co-occurred here (chat disambiguation);
            // `.any` = at least one appears (meeting prep — see SpeakerMatchMode).
            switch speakerMatchMode {
            case .all: return queries.allSatisfy(recordingHasSpeaker)
            case .any: return queries.contains(where: recordingHasSpeaker)
            }
        }

        func recordingMatchesMeetingType(_ recording: Recording, type: MeetingType) -> Bool {
            if recording.meetingType == type.rawValue { return true }
            guard type == .oneOnOne else { return false }
            let title = recording.title.lowercased()
            return title.contains("1on1")
                || title.contains("1:1")
                || title.contains("1-1")
                || title.contains("1 on 1")
                || title.contains("1-on-1")
                || title.contains("one on one")
                || title.contains("one-on-one")
                || title.contains("1对1")
                || title.contains("一对一")
        }

        let hasExplicitRecordingScope = !(recordingIDs?.isEmpty ?? true)
        let includesCompleteTranscript = hasExplicitRecordingScope || mostRecentRecordingOnly

        // Recording-level selectors must narrow strictly before segment
        // filtering. A missing match is an empty result, never an unrelated
        // recording chosen as a fallback.
        var filteredRecordings = recordings
        if let meetingType {
            filteredRecordings = filteredRecordings.filter {
                recordingMatchesMeetingType($0, type: meetingType)
            }
        }

        if let queries = lowerSpeakerQueries, !queries.isEmpty {
            filteredRecordings = filteredRecordings.filter(recordingContainsRequestedSpeaker)
        }

        if mostRecentRecordingOnly {
            filteredRecordings = Array(filteredRecordings.prefix(1))
        }

        // 5. Build summaries
        var summaries: [AIContextData.RecordingSummary] = []
        var actionItems: [AIContextData.ActionItem] = []
        var decisions: [AIContextData.Decision] = []
        var followUps: [AIContextData.Decision] = []
        var transcriptExcerpts: [AIContextData.TranscriptExcerpt] = []

        // Track speaker appearances across recordings for SpeakerInfo
        var speakerRecordingCounts: [String: Set<UUID>] = [:]

        for rec in filteredRecordings {
            let title = rec.title

            // RecordingSummary
            summaries.append(AIContextData.RecordingSummary(
                recordingID: rec.id,
                title: title,
                startDate: rec.startDate,
                duration: rec.duration,
                summary: rec.summary?.overview,
                meetingType: rec.meetingType
            ))

            // Action items
            if let items = rec.summary?.actionItems {
                for item in items {
                    // Parse deadline string to Date if possible (best-effort)
                    actionItems.append(AIContextData.ActionItem(
                        recordingID: rec.id,
                        recordingTitle: title,
                        text: item.task,
                        isCompleted: item.isCompleted,
                        assignee: item.assignee,
                        deadline: item.deadline,
                        priority: item.priority.rawValue
                    ))
                }
            }

            // Decisions
            if let decs = rec.summary?.decisions {
                for dec in decs {
                    decisions.append(AIContextData.Decision(
                        recordingID: rec.id,
                        recordingTitle: title,
                        text: dec
                    ))
                }
            }

            // Follow-ups
            if let fups = rec.summary?.followUps {
                for fup in fups {
                    followUps.append(AIContextData.Decision(
                        recordingID: rec.id,
                        recordingTitle: title,
                        text: fup
                    ))
                }
            }

            // Transcript entries
            if let transcript = rec.transcript {
                for segment in transcript.segments {
                    let resolved = resolvedName(for: segment.speaker, in: rec)

                    if !includesCompleteTranscript {
                        // Broad search returns matching excerpts. Once a
                        // concrete recording is resolved, keep every segment
                        // so the model receives the coherent conversation.

                        // Caller intended to filter (non-empty input) but every query was blank
                        // → no segment can match, skip all (prevents full-library leak).
                        if speakerQueriesRequestedButAllBlank || keywordsRequestedButAllBlank { continue }

                        if let queries = lowerSpeakerQueries, !queries.isEmpty {
                            let rawLower = segment.speaker?.lowercased() ?? ""
                            let resolvedLower = resolved?.lowercased() ?? ""
                            let matches = queries.contains { q in
                                rawLower.contains(q) || resolvedLower.contains(q)
                            }
                            if !matches { continue }
                        }

                        if let kws = lowerKeywords, !kws.isEmpty {
                            let textLower = segment.text.lowercased()
                            if !kws.contains(where: { textLower.contains($0) }) { continue }
                        }
                    }

                    transcriptExcerpts.append(AIContextData.TranscriptExcerpt(
                        recordingID: rec.id,
                        recordingTitle: title,
                        startTime: segment.startTime,
                        rawSpeaker: segment.speaker,
                        resolvedSpeakerName: resolved,
                        text: segment.text
                    ))

                    // Track speaker for SpeakerInfo
                    let speakerKey = resolved ?? segment.speaker ?? ""
                    if !speakerKey.isEmpty {
                        speakerRecordingCounts[speakerKey, default: []].insert(rec.id)
                    }
                }
            }
        }

        // 6. Trim transcript excerpts to budget
        if !includesCompleteTranscript && transcriptExcerpts.count > maxTranscriptEntries {
            transcriptExcerpts = Array(transcriptExcerpts.prefix(maxTranscriptEntries))
        }

        // 7. Build speaker info — only speakers that actually appear in this context
        var speakers: [AIContextData.SpeakerInfo] = []
        for (name, recordingIDs) in speakerRecordingCounts {
            let profile = allProfiles.first { $0.displayName == name }
            speakers.append(AIContextData.SpeakerInfo(
                name: name,
                aliases: profile?.aliases ?? [],
                recordingCount: recordingIDs.count
            ))
        }

        return AIContextData(
            summaries: summaries,
            actionItems: actionItems,
            decisions: decisions,
            followUps: followUps,
            transcriptExcerpts: transcriptExcerpts,
            transcriptCoverage: includesCompleteTranscript ? .complete : .excerpts,
            speakers: speakers
        )
    }

    func speakerProfileToDTO(_ profile: SpeakerProfile) -> SpeakerProfileDTO {
        SpeakerProfileDTO(
            id: profile.id,
            displayName: profile.displayName,
            aliases: profile.aliases,
            notes: profile.notes,
            teamOrOrg: profile.teamOrOrg,
            createdAt: profile.createdAt,
            lastSeenAt: profile.lastSeenAt
        )
    }
}
