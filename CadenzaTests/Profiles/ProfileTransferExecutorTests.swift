import Foundation
import SQLite3
import SwiftData
import Testing
import os

@testable import Cadenza

// MARK: - Fixture

private let executorFixedNow = Date(timeIntervalSince1970: 1_785_900_000)

/// Disk-backed registry wrapper with classified-save fault injection at
/// exact save ordinals; everything else forwards to the real store.
private final class InjectableDiskRegistry: ProfileRegistryProviding, Sendable {
    struct Faults: Sendable {
        var failSaveAt: Set<Int> = []
        var persistThenThrowAt: Set<Int> = []
        var thirdShapeAt: Set<Int> = []
    }

    private let base: DiskProfileRegistry
    private let faults: OSAllocatedUnfairLock<Faults>
    private let saves = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(base: DiskProfileRegistry, faults: Faults = Faults()) {
        self.base = base
        self.faults = OSAllocatedUnfairLock(initialState: faults)
    }

    func configure(_ body: @Sendable (inout Faults) -> Void) {
        faults.withLock { body(&$0) }
    }

    func presence() -> RegistryPresence { base.presence() }
    func load() throws -> ProfileRegistryDocument { try base.load() }

    func save(_ document: ProfileRegistryDocument) throws {
        struct InjectedSaveFailure: Error {}
        let ordinal = saves.withLock { count -> Int in
            count += 1
            return count
        }
        let current = faults.withLock { $0 }
        if current.failSaveAt.contains(ordinal) {
            throw InjectedSaveFailure()
        }
        if current.persistThenThrowAt.contains(ordinal) {
            try base.save(document)
            throw InjectedSaveFailure()
        }
        if current.thirdShapeAt.contains(ordinal) {
            // The drift must survive the save-side validation, so it
            // lands inside the pending record itself.
            var third = document
            if var pending = third.pendingTransfer {
                pending.startedAt = pending.startedAt.addingTimeInterval(1)
                third.pendingTransfer = pending
            }
            try base.save(third)
            throw InjectedSaveFailure()
        }
        try base.save(document)
    }
}

@MainActor
private struct ExecutorFixture {
    let base: URL
    let paths: ProfilePaths
    let suiteName: String
    let defaults: UserDefaults
    let disk: DiskProfileRegistry
    let registry: InjectableDiskRegistry
    let local: Profile
    let target: Profile
    let provenance: UUID
    let sourceAudioRoot: URL
    let targetAudioRoot: URL
    let outsideAudioURL: URL
    // Retries in one fixture share process-local scratch state.
    let scratchTracker = ProfileTransferExecutor.ScratchProcessTracker()

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    func dependencies(
        fileOperations: FileOperations = FixtureTrashFileOperations(),
        backupDriver: SQLiteBackupDriver = LiveSQLiteBackupDriver()
    ) -> ProfileTransferExecutor.Dependencies {
        ProfileTransferExecutor.Dependencies(
            paths: paths,
            registry: registry,
            fileOperations: fileOperations,
            backupDriver: backupDriver,
            inspector: LiveTransferStoreInspector(fileOperations: fileOperations),
            scratchTracker: scratchTracker,
            now: { executorFixedNow }
        )
    }

    var sourceStoreURL: URL { paths.storeURL(local.id) }
    var targetStoreURL: URL { paths.storeURL(target.id) }

    func counts(at url: URL) throws -> [String: Int]? {
        try LiveTransferStoreInspector(
            fileOperations: LiveFileOperations()
        ).entityCounts(at: url)
    }

    func beginTransfer(mode: PendingTransfer.Mode) throws -> PendingTransfer {
        try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id,
                targetProfileID: target.id,
                mode: mode,
                creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: disk,
                storeURL: { paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { executorFixedNow }
            )
        )
    }

    func pendingState() throws -> PendingTransfer.State? {
        try disk.load().pendingTransfer?.state
    }

    func rawWrite(_ document: ProfileRegistryDocument) throws {
        let data = try ProfileRegistryCoding.makeEncoder().encode(document)
        try data.write(to: paths.registryURL)
    }

    func classifyAtBoot(
        fileOperations: any FileOperations = LiveFileOperations()
    ) throws -> ProfileTransfer.BootDecision {
        ProfileTransfer.classifyAtBoot(
            document: try disk.load(),
            dependencies: .init(
                registry: disk,
                storeURL: { paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: fileOperations
                ),
                fileOperations: fileOperations,
                now: { executorFixedNow }
            )
        )
    }

    func recordingIDsByTitle() throws -> [String: UUID] {
        try autoreleasepool {
            let container = try RecordingsStore.makeContainer(storeURL: sourceStoreURL)
            let rows = try ModelContext(container).fetch(FetchDescriptor<Recording>())
            var byTitle: [String: UUID] = [:]
            for row in rows { byTitle[row.title] = row.id }
            return byTitle
        }
    }
}

/// Expected target location for one planned copy under the
/// transaction-owned namespace.
@MainActor
private func expectedAudioURL(
    root: URL,
    transactionID: UUID,
    recordingID: UUID,
    field: TransferAudioPlan.Field,
    sourceReference: String,
    child: String? = nil
) -> URL {
    root.appendingPathComponent(ProfileTransfer.audioDestinationRelativePath(
        transactionID: transactionID,
        recordingID: recordingID,
        field: field,
        sourceReference: sourceReference,
        childRelativePath: child
    ))
}

private func sqliteBasePath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    if standardized.hasSuffix("-wal") {
        return String(standardized.dropLast(4))
    }
    if standardized.hasSuffix("-shm") {
        return String(standardized.dropLast(4))
    }
    return standardized
}

private func openedStoreMutationConflicts(
    _ record: InstrumentedFileOperations.Record
) -> Set<String> {
    var opened: Set<String> = []
    var conflicts: Set<String> = []
    for event in record.events {
        switch event {
        case .storeOpen(let path):
            opened.insert(sqliteBasePath(path))
        case .remove(let path), .moveSource(let path), .swap(let path):
            let mutationPath = sqliteBasePath(path)
            for openedPath in opened where
                openedPath == mutationPath || openedPath.hasPrefix(mutationPath + "/") {
                conflicts.insert(openedPath)
            }
        }
    }
    return conflicts
}

/// Local system profile with a populated real store (rows across several
/// entity types) plus a mixed-ownership audio tree, and a freshly created
/// bound target.
@MainActor
private func makeExecutorFixture() throws -> ExecutorFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("transfer-exec-\(UUID().uuidString)", isDirectory: true)
    let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let suiteName = "transfer-exec-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!

    let sourceAudioRoot = base.appendingPathComponent("LocalAudio", isDirectory: true)
    let targetAudioRoot = base.appendingPathComponent("TargetAudio", isDirectory: true)
    let segmentsDir = sourceAudioRoot.appendingPathComponent("segments/rec-a", isDirectory: true)
    try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
    try Data("app-created-audio".utf8).write(
        to: sourceAudioRoot.appendingPathComponent("rec-a.m4a")
    )
    try Data("user-audio".utf8).write(
        to: sourceAudioRoot.appendingPathComponent("user.m4a")
    )
    try Data("segment-0".utf8).write(to: segmentsDir.appendingPathComponent("0.m4a"))
    try Data("segment-1".utf8).write(to: segmentsDir.appendingPathComponent("1.m4a"))
    try Data("unrelated".utf8).write(
        to: sourceAudioRoot.appendingPathComponent("unrelated.bin")
    )
    let outside = base.appendingPathComponent("outside-abs.m4a")
    try Data("absolute-audio".utf8).write(to: outside)

    let local = Profile(
        id: UUID(),
        kind: .system,
        name: "Local",
        colorHex: nil,
        createdAt: executorFixedNow,
        lastActiveAt: executorFixedNow,
        audioDirectory: .init(bookmark: nil, path: sourceAudioRoot.path, kind: .appManaged),
        boundAccount: nil,
        lockOnSignOut: false,
        isLocked: false,
        storeMaterialized: true,
        sessionDisposition: .active
    )

    let provenance = UUID()
    let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
    let target = Profile(
        id: UUID(),
        kind: .standard,
        name: "Account",
        colorHex: nil,
        createdAt: executorFixedNow,
        lastActiveAt: executorFixedNow,
        audioDirectory: .init(bookmark: nil, path: targetAudioRoot.path, kind: .appManaged),
        boundAccount: Profile.BoundAccount(
            userID: "user-t",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "t@example.com",
            displayName: "T",
            boundAt: executorFixedNow
        ),
        lockOnSignOut: true,
        isLocked: false,
        storeMaterialized: false,
        sessionDisposition: .active,
        createdByBindingTransactionID: provenance
    )

    let disk = DiskProfileRegistry(
        registryURL: paths.registryURL, fileOperations: LiveFileOperations()
    )
    try disk.save(ProfileRegistryDocument(
        version: 1, activeProfileID: local.id, profiles: [local, target]
    ))

    try autoreleasepool {
        let container = try RecordingsStore.makeContainer(
            storeURL: paths.storeURL(local.id)
        )
        let context = ModelContext(container)
        let appCreated = Recording(title: "App Created")
        appCreated.audioFileReference = .relative("rec-a.m4a")
        appCreated.segmentsDirectoryReference = .relative("segments/rec-a")
        appCreated.ownership = .appCreated
        context.insert(appCreated)
        let userRow = Recording(title: "User Owned")
        userRow.audioFileReference = .relative("user.m4a")
        userRow.ownership = .unknownLegacy
        context.insert(userRow)
        let absoluteRow = Recording(title: "Absolute")
        absoluteRow.audioFileReference = .legacyAbsolute(outside.path)
        absoluteRow.ownership = .unknownLegacy
        context.insert(absoluteRow)
        context.insert(Transcript(fullText: "transfer transcript"))
        context.insert(Recap(
            period: "week", startDate: executorFixedNow,
            endDate: executorFixedNow.addingTimeInterval(60), title: "Recap"
        ))
        try context.save()
    }

    return ExecutorFixture(
        base: base, paths: paths, suiteName: suiteName, defaults: defaults,
        disk: disk, registry: InjectableDiskRegistry(base: disk),
        local: local, target: target, provenance: provenance,
        sourceAudioRoot: sourceAudioRoot, targetAudioRoot: targetAudioRoot,
        outsideAudioURL: outside
    )
}

// MARK: - Copy transfers

@MainActor
struct ProfileTransferExecutorCopyTests {
    @Test func copyTransferCompletesEndToEnd() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        let sourceCountsBefore = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        let recordingIDs = try fixture.recordingIDsByTitle()

        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed(let targetID) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(targetID == fixture.target.id)

        let document = try fixture.disk.load()
        #expect(document.pendingTransfer == nil)
        #expect(document.activeProfileID == fixture.target.id)
        let targetRow = try #require(document.profiles.first { $0.id == fixture.target.id })
        #expect(targetRow.storeMaterialized)
        #expect(targetRow.createdByBindingTransactionID == nil)

        // Target store carries the full snapshot with rewritten,
        // app-owned references: identical counts, every reference
        // target-relative, every rewritten row app-created.
        let targetCounts = try #require(try fixture.counts(at: fixture.targetStoreURL))
        #expect(targetCounts == sourceCountsBefore)
        #expect(targetCounts["Recap"] == 1)
        let targetContainer = try RecordingsStore.makeContainer(
            storeURL: fixture.targetStoreURL
        )
        let rows = try ModelContext(targetContainer).fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 3)
        let namespacePrefix = "transfers/\(pending.transactionID.uuidString)/"
        var importedRelative: String?
        for row in rows {
            #expect(row.ownership == .appCreated)
            guard let reference = row.audioFileReference else {
                Issue.record("target row lost its audio reference")
                continue
            }
            guard case .relative(let path) = reference else {
                Issue.record("target row kept an absolute reference")
                continue
            }
            #expect(path.hasPrefix(namespacePrefix))
            if path.hasSuffix("outside-abs.m4a") { importedRelative = path }
        }
        let importedPath = try #require(importedRelative)

        // Audio: every referenced file copied byte-exactly — including
        // the absolute-referenced one — while unrelated files stay put
        // and the source stays intact.
        let expectedCopies: [(String, TransferAudioPlan.Field, String, String?)] = [
            ("App Created", .audioFile, "rec-a.m4a", nil),
            ("User Owned", .audioFile, "user.m4a", nil),
            ("App Created", .segmentsDirectory, "segments/rec-a", "0.m4a"),
            ("App Created", .segmentsDirectory, "segments/rec-a", "1.m4a"),
        ]
        for (title, field, sourceReference, child) in expectedCopies {
            let sourceRelative = child.map { sourceReference + "/" + $0 } ?? sourceReference
            let source = fixture.sourceAudioRoot.appendingPathComponent(sourceRelative)
            let copied = expectedAudioURL(
                root: fixture.targetAudioRoot,
                transactionID: pending.transactionID,
                recordingID: try #require(recordingIDs[title]),
                field: field,
                sourceReference: sourceReference,
                child: child
            )
            #expect(try Data(contentsOf: copied) == Data(contentsOf: source))
        }
        #expect(try Data(
            contentsOf: fixture.targetAudioRoot.appendingPathComponent(importedPath)
        ) == Data(contentsOf: fixture.outsideAudioURL))
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("unrelated.bin").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.targetAudioRoot.appendingPathComponent("unrelated.bin").path
        ))
        #expect(FileManager.default.fileExists(atPath: fixture.outsideAudioURL.path))
        #expect(try fixture.counts(at: fixture.sourceStoreURL) == sourceCountsBefore)
    }

    @Test func copyReplacesAnExistingVerifiedEmptyTargetStore() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        try autoreleasepool {
            let container = try RecordingsStore.makeContainer(
                storeURL: fixture.targetStoreURL
            )
            withExtendedLifetime(container) {}
        }
        let pending = try fixture.beginTransfer(mode: .copy)
        let probe = WriterProbeFileOperations(
            probePath: fixture.targetStoreURL.path
        )

        let outcome = ProfileTransferExecutor.run(
            pending: pending,
            dependencies: fixture.dependencies(fileOperations: probe)
        )

        guard case .completed(let targetID) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(targetID == fixture.target.id)
        #expect(probe.probeResults == [.acquired])
        let counts = try #require(try fixture.counts(at: fixture.targetStoreURL))
        #expect(counts["Recording"] == 3)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.transferStagingDirectory(
                transactionID: pending.transactionID
            ).appendingPathComponent("Cadenza.store").path
        ))
    }

    @Test func existingEmptyTargetSwapResumesBeforePlacedCheckpoint() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        try autoreleasepool {
            let container = try RecordingsStore.makeContainer(
                storeURL: fixture.targetStoreURL
            )
            withExtendedLifetime(container) {}
        }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [4] }

        let interrupted = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .halted = interrupted else {
            Issue.record("expected placed-checkpoint interruption")
            return
        }
        #expect(try fixture.pendingState() == .targetVerified)
        let placedCounts = try #require(try fixture.counts(at: fixture.targetStoreURL))
        #expect(placedCounts["Recording"] == 3)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion after swap resume, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.transferStagingDirectory(
                transactionID: pending.transactionID
            ).appendingPathComponent("Cadenza.store").path
        ))
    }

    @Test func copyResumesAfterKillAtEveryCheckpoint() throws {
        // Save ordinals: 1 snapshot, 2 staged, 3 targetVerified,
        // 4 placed, 5 final commit.
        let expectedStateAfterKill: [Int: PendingTransfer.State] = [
            1: .initiated, 2: .sourceSnapshotted, 3: .staged,
            4: .targetVerified, 5: .placed,
        ]
        for (ordinal, expectedState) in expectedStateAfterKill.sorted(by: { $0.key < $1.key }) {
            let fixture = try makeExecutorFixture()
            defer { fixture.cleanUp() }
            let pending = try fixture.beginTransfer(mode: .copy)
            fixture.registry.configure { $0.failSaveAt = [ordinal] }

            let first = ProfileTransferExecutor.run(
                pending: pending, dependencies: fixture.dependencies()
            )
            guard case .halted = first else {
                Issue.record("expected halt at ordinal \(ordinal)")
                return
            }
            #expect(try fixture.pendingState() == expectedState)

            // The relaunch resumes from the durable checkpoint and
            // completes.
            fixture.registry.configure { $0.failSaveAt = [] }
            let resumed = try #require(try fixture.disk.load().pendingTransfer)
            let second = ProfileTransferExecutor.run(
                pending: resumed, dependencies: fixture.dependencies()
            )
            guard case .completed = second else {
                Issue.record("expected resumed completion at ordinal \(ordinal)")
                return
            }
            #expect(try fixture.disk.load().activeProfileID == fixture.target.id)
        }
    }

    /// A placed checkpoint reboots into the executor: the populated
    /// target is proven by the recorded receipt, never re-classified as
    /// a foreign non-empty target.
    @Test func placedCheckpointBootsIntoExecutorNotRefusal() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)
        let targetCounts = try #require(try fixture.counts(at: fixture.targetStoreURL))
        #expect(targetCounts["Recording"] == 3)

        let document = try fixture.disk.load()
        let decision = ProfileTransfer.classifyAtBoot(
            document: document,
            dependencies: .init(
                registry: fixture.disk,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { executorFixedNow }
            )
        )
        guard case .run(let resumed) = decision else {
            Issue.record("expected run decision, got \(decision)")
            return
        }
        #expect(resumed.state == .placed)
        // The pending record and the target's provenance survived — no
        // refusal cleared them.
        #expect(document.profiles.first { $0.id == fixture.target.id }?
            .createdByBindingTransactionID == fixture.provenance)
    }

    @Test func copyCommitRejectsSourceAudioDriftAfterPlacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)
        try Data("changed-after-placement".utf8).write(
            to: fixture.sourceAudioRoot.appendingPathComponent("user.m4a")
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )

        guard case .halted(let reason) = outcome else {
            Issue.record("expected source audio drift to halt commit, got \(outcome)")
            return
        }
        #expect(reason.contains("frozen source"))
        let document = try fixture.disk.load()
        #expect(document.pendingTransfer != nil)
        #expect(document.activeProfileID == fixture.local.id)
    }

    @Test func classifiedCheckpointMatrix() throws {
        let persisted = try makeExecutorFixture()
        defer { persisted.cleanUp() }
        let persistedPending = try persisted.beginTransfer(mode: .copy)
        persisted.registry.configure { $0.persistThenThrowAt = [1] }
        let persistedOutcome = ProfileTransferExecutor.run(
            pending: persistedPending, dependencies: persisted.dependencies()
        )
        guard case .completed = persistedOutcome else {
            Issue.record("persist-then-throw must classify committed and continue")
            return
        }

        let third = try makeExecutorFixture()
        defer { third.cleanUp() }
        let thirdPending = try third.beginTransfer(mode: .copy)
        third.registry.configure { $0.thirdShapeAt = [1] }
        let thirdOutcome = ProfileTransferExecutor.run(
            pending: thirdPending, dependencies: third.dependencies()
        )
        guard case .halted(let reason) = thirdOutcome else {
            Issue.record("third shape must halt")
            return
        }
        #expect(reason.contains("indeterminate"))
    }

    @Test func snapshotFailuresLeaveInitiatedAndRetry() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)

        let failed = ProfileTransferExecutor.run(
            pending: pending,
            dependencies: fixture.dependencies(backupDriver: FailingSQLiteBackupDriver())
        )
        guard case .halted(let reason) = failed else {
            Issue.record("expected halt on backup failure")
            return
        }
        #expect(reason.contains("snapshot"))
        #expect(try fixture.pendingState() == .initiated)
        #expect(try fixture.counts(at: fixture.targetStoreURL) == nil)

        let capacityStarved = ProfileTransferExecutor.run(
            pending: pending,
            dependencies: fixture.dependencies(
                fileOperations: InstrumentedFileOperations(capacityOverride: 1024)
            )
        )
        guard case .halted(let capacityReason) = capacityStarved else {
            Issue.record("expected halt on capacity shortage")
            return
        }
        #expect(capacityReason.contains("disk space"))

        let recovered = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = recovered else {
            Issue.record("expected completion after retry")
            return
        }
    }

    @Test func foreignTargetStoreAtPlacementHalts() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        // A foreign store appears at the target path before placement.
        let container = try RecordingsStore.makeContainer(storeURL: fixture.targetStoreURL)
        let context = ModelContext(container)
        context.insert(Recording(title: "Foreign"))
        try context.save()
        let foreignBytes = try Data(contentsOf: fixture.targetStoreURL)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on foreign target store")
            return
        }
        #expect(reason.contains("targetStoreNotEmpty"))
        #expect(try Data(contentsOf: fixture.targetStoreURL) == foreignBytes)
        #expect(try fixture.disk.load().pendingTransfer != nil)
    }

    @Test func sourceEvidenceChangeAfterSnapshotHalts() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [2] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .sourceSnapshotted)

        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        context.insert(Recording(title: "Post Snapshot Write"))
        try context.save()

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on evidence change")
            return
        }
        #expect(reason.contains("source evidence"))
        #expect(try fixture.counts(at: fixture.targetStoreURL) == nil)
    }
}

// MARK: - Audio fail-closed matrix

@MainActor
struct ProfileTransferExecutorAudioTests {
    @Test func audioPreflightRequiresTheFrozenBookmarkAuthority() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        var document = try fixture.disk.load()
        let targetIndex = try #require(document.profiles.firstIndex {
            $0.id == fixture.target.id
        })
        document.profiles[targetIndex].audioDirectory.kind = .userSelected
        document.profiles[targetIndex].audioDirectory.bookmark = Data([0xFF])
        try fixture.disk.save(document)
        let pending = try fixture.beginTransfer(mode: .copy)

        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )

        guard case .halted(let reason) = outcome else {
            Issue.record("expected the unresolvable bookmark to halt preflight")
            return
        }
        #expect(reason.contains("bookmark unresolvable"))
        #expect(try fixture.pendingState() == .sourceSnapshotted)
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }

    @Test func missingReferencedAudioFailsClosed() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        try FileManager.default.removeItem(
            at: fixture.sourceAudioRoot.appendingPathComponent("user.m4a")
        )
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on missing audio")
            return
        }
        #expect(reason.contains("audio file missing"))
    }

    /// Normalization variants used to share one destination directory;
    /// the per-recording transaction namespace keeps them disjoint, so
    /// both rows place cleanly instead of false-colliding. The canonical
    /// collision gate stays in the plan builder as defense in depth for
    /// case-sensitive source volumes.
    @Test func canonicallyEquivalentAudioPathsLandInDisjointNamespaces() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let nfc = "caf\u{00E9}.m4a"
        let nfd = "cafe\u{0301}.m4a"
        try Data("nfc-audio".utf8).write(
            to: fixture.sourceAudioRoot.appendingPathComponent(nfc)
        )
        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        let first = Recording(title: "NFC")
        first.audioFileReference = .relative(nfc)
        first.ownership = .appCreated
        context.insert(first)
        let second = Recording(title: "NFD")
        second.audioFileReference = .relative(nfd)
        second.ownership = .appCreated
        context.insert(second)
        try context.save()

        let pending = try fixture.beginTransfer(mode: .copy)
        let ids = try fixture.recordingIDsByTitle()
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        for (title, reference) in [("NFC", nfc), ("NFD", nfd)] {
            let copied = expectedAudioURL(
                root: fixture.targetAudioRoot,
                transactionID: pending.transactionID,
                recordingID: try #require(ids[title]),
                field: .audioFile,
                sourceReference: reference
            )
            #expect(try Data(contentsOf: copied) == Data("nfc-audio".utf8))
        }
    }

    @Test func componentLengthLimitDoesNotBreakPartialPlacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let filename = String(repeating: "a", count: 249) + ".m4a"
        try Data("long-name-audio".utf8).write(
            to: fixture.sourceAudioRoot.appendingPathComponent(filename)
        )
        let recordingID = UUID()
        try autoreleasepool {
            let container = try RecordingsStore.makeContainer(
                storeURL: fixture.sourceStoreURL
            )
            let context = ModelContext(container)
            let recording = Recording(id: recordingID, title: "Long Filename")
            recording.audioFileReference = .relative(filename)
            recording.ownership = .appCreated
            context.insert(recording)
            try context.save()
        }

        let pending = try fixture.beginTransfer(mode: .copy)
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )

        guard case .completed = outcome else {
            Issue.record("expected long-filename completion, got \(outcome)")
            return
        }
        let destination = expectedAudioURL(
            root: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            recordingID: recordingID,
            field: .audioFile,
            sourceReference: filename
        )
        #expect(try Data(contentsOf: destination) == Data("long-name-audio".utf8))
    }

    @Test func changedSourceAudioAfterManifestHalts() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)
        try Data("tampered".utf8).write(
            to: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a")
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on changed source audio")
            return
        }
        #expect(reason.contains("does not match the frozen source"))
    }

    @Test func foreignAudioAtTargetOnResumeHalts() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [4] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .targetVerified)
        // Audio landed before the checkpoint failure; corrupt one copy.
        let ids = try fixture.recordingIDsByTitle()
        try Data("corrupted".utf8).write(
            to: expectedAudioURL(
                root: fixture.targetAudioRoot,
                transactionID: pending.transactionID,
                recordingID: try #require(ids["User Owned"]),
                field: .audioFile,
                sourceReference: "user.m4a"
            )
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on foreign target audio")
            return
        }
        #expect(reason.contains("foreign audio"))
    }

    @Test func interruptedAudioPartialIsRebuiltAndPlaced() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [4] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .targetVerified)

        let ids = try fixture.recordingIDsByTitle()
        let recordingID = try #require(ids["User Owned"])
        let destinationRelative = ProfileTransfer.audioDestinationRelativePath(
            transactionID: pending.transactionID,
            recordingID: recordingID,
            field: .audioFile,
            sourceReference: "user.m4a",
            childRelativePath: nil
        )
        let destination = fixture.targetAudioRoot.appendingPathComponent(
            destinationRelative
        )
        try FileManager.default.removeItem(at: destination)
        let partial = fixture.targetAudioRoot.appendingPathComponent(
            ProfileTransfer.audioPartialRelativePath(for: destinationRelative)
        )
        try Data("truncated".utf8).write(to: partial)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )

        guard case .completed = outcome else {
            Issue.record("expected partial-copy recovery, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: destination) == Data("user-audio".utf8))
    }

    @Test func freshAudioClaimCannotAdoptAnExistingNamespace() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        let namespace = fixture.targetAudioRoot.appendingPathComponent(
            "transfers/\(pending.transactionID.uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: namespace, withIntermediateDirectories: true
        )
        try Data("app-created-audio".utf8).write(
            to: namespace.appendingPathComponent("foreign.bin")
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected pre-existing namespace to remain unclaimed")
            return
        }
        #expect(reason.contains("namespace occupied before ownership claim"))
        let profileMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        let audioMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            kind: .audioRoot
        )
        #expect(!FileManager.default.fileExists(atPath: profileMarker.path))
        #expect(!FileManager.default.fileExists(atPath: audioMarker.path))
        #expect(try Data(contentsOf: namespace.appendingPathComponent("foreign.bin"))
            == Data("app-created-audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }
}

// MARK: - Move transfers

@MainActor
struct ProfileTransferExecutorMoveTests {
    @Test func moveTransferCompletesWithVerifiedLocalReplacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let sourceDigest = try SQLiteLogicalDigest.digest(of: fixture.sourceStoreURL)
        let pending = try fixture.beginTransfer(mode: .move)
        let recordingIDs = try fixture.recordingIDsByTitle()
        let probe = WriterProbeFileOperations(probePath: fixture.sourceStoreURL.path)

        let outcome = ProfileTransferExecutor.run(
            pending: pending,
            dependencies: fixture.dependencies(fileOperations: probe)
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }

        let document = try fixture.disk.load()
        #expect(document.pendingTransfer == nil)
        #expect(document.activeProfileID == fixture.target.id)
        #expect(probe.probeResults == [.acquired])

        // The target holds the transferred content (rewritten rows).
        let targetCounts = try #require(try fixture.counts(at: fixture.targetStoreURL))
        #expect(targetCounts["Recording"] == 3)

        // Local owns a fresh, openable, fully empty store; the retired
        // original keeps the exact source logical content under its
        // transaction-keyed name.
        let localCounts = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        #expect(localCounts.values.allSatisfy { $0 == 0 })
        let retired = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".transferred-\(pending.transactionID.uuidString)"
        )
        #expect(try SQLiteLogicalDigest.digest(of: retired) == sourceDigest)
        let reopened = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<Recording>()) == 0)

        // Audio cleanup honors ownership: app-created copies leave the
        // source, everything else stays.
        #expect(!FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("segments/rec-a/0.m4a").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("user.m4a").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("unrelated.bin").path
        ))
        #expect(FileManager.default.fileExists(atPath: fixture.outsideAudioURL.path))
        let movedCopy = expectedAudioURL(
            root: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            recordingID: try #require(recordingIDs["App Created"]),
            field: .audioFile,
            sourceReference: "rec-a.m4a"
        )
        #expect(try Data(contentsOf: movedCopy) == Data("app-created-audio".utf8))
    }

    @Test func mixedOwnershipSharedSourceIsRetained() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        try autoreleasepool {
            let container = try RecordingsStore.makeContainer(
                storeURL: fixture.sourceStoreURL
            )
            let context = ModelContext(container)
            let shared = Recording(title: "Shared Unknown")
            shared.audioFileReference = .relative("rec-a.m4a")
            shared.ownership = .unknownLegacy
            context.insert(shared)
            try context.save()
        }

        let pending = try fixture.beginTransfer(mode: .move)
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )

        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a").path
        ))
    }

    /// A crash after retirement but before the final commit leaves the
    /// target populated, Local openable and empty, and the original store
    /// recoverable at its retired path. Resume converges without unsafe cleanup.
    @Test func moveResumeAfterCommitFailureConverges() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .move)
        // Ordinals for move: 1 snapshot, 2 staged, 3 targetVerified,
        // 4 placed, 5 localRebuilt, 6 final commit.
        fixture.registry.configure { $0.failSaveAt = [6] }
        let first = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .halted = first else {
            Issue.record("expected halt at final commit")
            return
        }
        #expect(try fixture.pendingState() == .localRebuilt)
        // Both sides exist: the target store and an openable Local store.
        #expect(try fixture.counts(at: fixture.targetStoreURL) != nil)
        let localCounts = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        #expect(localCounts.values.allSatisfy { $0 == 0 })

        // The source audio changed while halted; the resumed cleanup
        // must retain it rather than deleting unproven bytes.
        try Data("changed-after-halt".utf8).write(
            to: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a")
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected resumed completion")
            return
        }
        #expect(try fixture.disk.load().activeProfileID == fixture.target.id)
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a").path
        ))
    }

    /// Resume repairs the post-swap, pre-rename state while the Local store
    /// remains openable at its stable path.
    @Test func moveResumeRepairsMidSwapWindow() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .move)
        fixture.registry.configure { $0.failSaveAt = [6] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .localRebuilt)

        // Reconstruct the post-swap, pre-rename window: the base already
        // holds the empty store, the transaction-keyed replacement path
        // holds the old database, and the retired name does not exist
        // yet. Local stays openable throughout.
        let replacement = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".replacement-\(pending.transactionID.uuidString)"
        )
        let retired = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".transferred-\(pending.transactionID.uuidString)"
        )
        try FileManager.default.moveItem(at: retired, to: replacement)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceStoreURL.path))

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected repair and completion, got \(outcome)")
            return
        }
        let localCounts = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        #expect(localCounts.values.allSatisfy { $0 == 0 })
        let reopened = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        #expect(try ModelContext(reopened).fetchCount(FetchDescriptor<Recording>()) == 0)
    }

    /// A target store that degrades after placement halts the move at
    /// the placed checkpoint, before any move-side work: the Local
    /// store, its content, and every source audio file stay untouched.
    @Test func corruptTargetStoreAtPlacedHaltsBeforeLocalChanges() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .move)
        let sourceCountsBefore = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        try Data("corrupted".utf8).write(to: fixture.targetStoreURL)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on corrupt target store")
            return
        }
        #expect(reason.contains("store bytes differ"))
        // The source side is exactly as it was: same Local content, no
        // retired artifact, every referenced audio file still present.
        #expect(try fixture.counts(at: fixture.sourceStoreURL) == sourceCountsBefore)
        let retired = URL(fileURLWithPath: fixture.sourceStoreURL.path
            + ".transferred-\(pending.transactionID.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        for relative in ["rec-a.m4a", "user.m4a", "segments/rec-a/0.m4a",
                         "segments/rec-a/1.m4a", "unrelated.bin"] {
            #expect(FileManager.default.fileExists(
                atPath: fixture.sourceAudioRoot.appendingPathComponent(relative).path
            ))
        }
    }

    /// The same proof guards the retire entry: resuming directly at the
    /// rebuilt checkpoint with degraded target audio halts before the
    /// swap ever runs.
    @Test func corruptTargetAudioAtLocalRebuiltHaltsBeforeRetire() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .move)
        let sourceCountsBefore = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        let ids = try fixture.recordingIDsByTitle()
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        // Reconstruct the durable state a crash between the rebuilt
        // checkpoint and the retire step would leave behind: the
        // replacement store exists on disk and the record carries its
        // recorded proofs.
        let replacement = URL(fileURLWithPath: fixture.sourceStoreURL.path
            + ".replacement-\(pending.transactionID.uuidString)")
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        var document = try fixture.disk.load()
        var rebuilt = try #require(document.pendingTransfer)
        rebuilt.state = .localRebuilt
        rebuilt.replacementStoreSHA256 =
            try LiveFileOperations().sha256(of: replacement)
        rebuilt.replacementContentDigest =
            try SQLiteLogicalDigest.digest(of: replacement)
        document.pendingTransfer = rebuilt
        try fixture.rawWrite(document)

        try Data("corrupted".utf8).write(
            to: expectedAudioURL(
                root: fixture.targetAudioRoot,
                transactionID: pending.transactionID,
                recordingID: try #require(ids["User Owned"]),
                field: .audioFile,
                sourceReference: "user.m4a"
            )
        )

        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on corrupt target audio")
            return
        }
        #expect(reason.contains("target audio verification failed"))
        #expect(try fixture.counts(at: fixture.sourceStoreURL) == sourceCountsBefore)
        let retired = URL(fileURLWithPath: fixture.sourceStoreURL.path
            + ".transferred-\(pending.transactionID.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        for relative in ["rec-a.m4a", "user.m4a", "segments/rec-a/0.m4a"] {
            #expect(FileManager.default.fileExists(
                atPath: fixture.sourceAudioRoot.appendingPathComponent(relative).path
            ))
        }
    }

    /// A source write after placement halts before Local rebuild or retirement,
    /// preserving the source as the authoritative copy.
    @Test func moveKeepsDuplicateWhenSourceChangedSinceSnapshot() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .move)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        // Real writes land after placement; the rebuild-side evidence
        // check must halt before creating or swapping the Local replacement.
        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        context.insert(Recording(title: "Late Write"))
        try context.save()

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected evidence halt, got \(outcome)")
            return
        }
        #expect(reason.contains("source evidence"))
        // Nothing was retired and Local still opens with its full data.
        let counts = try #require(try fixture.counts(at: fixture.sourceStoreURL))
        #expect(counts["Recording"] == 4)
        #expect(try fixture.disk.load().pendingTransfer != nil)
    }
}

// MARK: - Manifest lattice and shape validation

@MainActor
struct ProfileTransferExecutorPlanValidationTests {
    /// A traversal child in a tampered manifest must never reach the
    /// filesystem: the boot classifier rejects the record, and a resumed
    /// executor halts at its own re-validation with every source file —
    /// including legitimate deletion candidates — untouched.
    @Test func tamperedChildTraversalNeverTouchesOutsideTree() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let victim = fixture.base.appendingPathComponent("victim.m4a")
        try Data("segment-0".utf8).write(to: victim)
        let pending = try fixture.beginTransfer(mode: .move)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        var plan = try #require(tampered.audioPlan)
        let index = try #require(plan.files.firstIndex {
            $0.childRelativePath == "0.m4a"
        })
        plan.files[index].childRelativePath = "../../../victim.m4a"
        tampered.audioPlan = plan
        document.pendingTransfer = tampered
        try fixture.rawWrite(document)

        guard case .halted(let bootReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected boot halt on traversal child")
            return
        }
        #expect(bootReason.contains("unsafe tree child path"))

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted = outcome else {
            Issue.record("expected executor halt on traversal child")
            return
        }
        #expect(FileManager.default.fileExists(atPath: victim.path))
        for relative in ["rec-a.m4a", "user.m4a", "segments/rec-a/0.m4a"] {
            #expect(FileManager.default.fileExists(
                atPath: fixture.sourceAudioRoot.appendingPathComponent(relative).path
            ))
        }
    }

    /// Every shape violation of the persisted manifest is a boot halt.
    @Test func manifestShapeViolationsHaltAtBoot() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)
        let intact = try fixture.disk.load()

        func expectHalt(
            _ expectedReason: String,
            _ mutate: (inout TransferAudioPlan) -> Void
        ) throws {
            var document = intact
            var tampered = try #require(document.pendingTransfer)
            var plan = try #require(tampered.audioPlan)
            mutate(&plan)
            tampered.audioPlan = plan
            document.pendingTransfer = tampered
            try fixture.rawWrite(document)
            guard case .halted(let reason) = try fixture.classifyAtBoot() else {
                Issue.record("expected boot halt: \(expectedReason)")
                return
            }
            #expect(reason.contains(expectedReason))
        }

        try expectHalt("audio file entry carries a child path") { plan in
            if let index = plan.files.firstIndex(where: {
                $0.field == .audioFile && $0.childRelativePath == nil
            }) {
                plan.files[index].childRelativePath = "x.m4a"
            }
        }
        try expectHalt("duplicate plan destination") { plan in
            if let entry = plan.files.first {
                plan.files.append(entry)
            }
        }
        try expectHalt("plan file without a rewrite") { plan in
            if var entry = plan.files.first(where: { $0.field == .audioFile }) {
                entry.recordingID = UUID()
                plan.files.append(entry)
            }
        }
        try expectHalt("malformed plan hash") { plan in
            plan.files[0].sha256 = "NOT-A-HASH"
        }
        try expectHalt("negative plan size") { plan in
            plan.files[0].size = -1
        }
        try expectHalt("rewrite destination is not the transaction namespace") { plan in
            plan.rewrites[0].destinationReference = "elsewhere/x.m4a"
        }
        try expectHalt("segments rewrite missing its tree root entry") { plan in
            plan.directories.removeAll { $0.childRelativePath == nil }
        }
        func collideWithScratch(
            _ plan: inout TransferAudioPlan, uppercase: Bool
        ) {
            let segmentIndexes = plan.files.indices.filter {
                plan.files[$0].field == .segmentsDirectory
            }
            if segmentIndexes.count >= 2,
               let firstChild = plan.files[segmentIndexes[0]].childRelativePath,
               let rewrite = plan.rewrites.first(where: {
                   $0.recordingID == plan.files[segmentIndexes[0]].recordingID
                       && $0.field == .segmentsDirectory
               }) {
                let firstDestination = rewrite.destinationReference + "/" + firstChild
                let scratch = ProfileTransfer.audioPartialRelativePath(
                    for: firstDestination
                )
                let prefix = rewrite.destinationReference + "/"
                var child = String(scratch.dropFirst(prefix.count))
                if uppercase {
                    child = child.replacingOccurrences(
                        of: ".cadenza-partial-", with: ".CADENZA-PARTIAL-"
                    )
                }
                plan.files[segmentIndexes[1]].childRelativePath = child
            }
        }
        try expectHalt("audio copy scratch collides") { plan in
            collideWithScratch(&plan, uppercase: false)
        }
        try expectHalt("audio copy scratch collides") { plan in
            collideWithScratch(&plan, uppercase: true)
        }
    }

    /// The payload lattice is exact in both directions: missing proofs
    /// and extra later-state proofs are both drifted authority.
    @Test func payloadLatticeViolationsHaltAtBoot() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.beginTransfer(mode: .copy)
        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        tampered.sourceContentDigest = String(repeating: "a", count: 64)
        document.pendingTransfer = tampered
        try fixture.rawWrite(document)
        guard case .halted(let initiatedReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected halt on initiated with later payloads")
            return
        }
        #expect(initiatedReason.contains("later-state payloads"))
        fixture.cleanUp()

        let second = try makeExecutorFixture()
        defer { second.cleanUp() }
        let pending = try second.beginTransfer(mode: .copy)
        second.registry.configure { $0.failSaveAt = [2] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: second.dependencies()
        )
        #expect(try second.pendingState() == .sourceSnapshotted)
        var snapshotDocument = try second.disk.load()
        var snapshotTampered = try #require(snapshotDocument.pendingTransfer)
        snapshotTampered.stagedStoreSHA256 = String(repeating: "b", count: 64)
        snapshotDocument.pendingTransfer = snapshotTampered
        try second.rawWrite(snapshotDocument)
        guard case .halted(let snapshotReason) = try second.classifyAtBoot() else {
            Issue.record("expected halt on snapshot state with stage payloads")
            return
        }
        #expect(snapshotReason.contains("carries stage payloads"))
    }

    /// A receipt with duplicate inventory cannot identify one exact
    /// snapshot artifact and must stop before resume.
    @Test func ambiguousSnapshotReceiptInventoryHaltsAtBoot() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [2] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .sourceSnapshotted)

        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        var receipt = try #require(tampered.snapshotReceipt)
        receipt.files.append(try #require(receipt.files.first))
        tampered.snapshotReceipt = receipt
        document.pendingTransfer = tampered
        try fixture.rawWrite(document)

        guard case .halted(let reason) = try fixture.classifyAtBoot() else {
            Issue.record("expected halt on ambiguous snapshot inventory")
            return
        }
        #expect(reason.contains("ambiguous snapshot receipt inventory"))
    }

    @Test func reblessedSnapshotContentCannotDivergeFromFrozenSource() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.thirdShapeAt = [1] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .sourceSnapshotted)

        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        var receipt = try #require(tampered.snapshotReceipt)
        let original = receipt.directory.appendingPathComponent("Cadenza.store")
        let replacementDirectory = receipt.directory.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacementDirectory, withIntermediateDirectories: true
        )
        let replacement = replacementDirectory.appendingPathComponent("Cadenza.store")
        try LiveSQLiteBackupDriver().consistentBackup(
            source: original, destination: replacement
        )

        var database: OpaquePointer?
        #expect(sqlite3_open_v2(
            sqliteNoFollowPath(for: replacement), &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil
        ) == SQLITE_OK)
        let update = sqlite3_exec(
            database,
            "UPDATE ZRECORDING SET ZTITLE = 'Receipt Tamper' WHERE ZTITLE = 'App Created'",
            nil, nil, nil
        )
        #expect(update == SQLITE_OK)
        #expect(sqlite3_changes(database) == 1)
        #expect(sqlite3_close(database) == SQLITE_OK)
        database = nil

        let operations = LiveFileOperations()
        let attributes = try operations.attributesOfItem(at: replacement)
        receipt.directory = replacementDirectory
        receipt.files = [.init(
            name: "Cadenza.store",
            size: try #require(attributes[.size] as? Int64),
            sha256: try operations.sha256(of: replacement)
        )]
        tampered.snapshotReceipt = receipt
        document.pendingTransfer = tampered
        try fixture.rawWrite(document)

        fixture.registry.configure { $0.thirdShapeAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected frozen-source content proof to halt")
            return
        }
        #expect(reason.contains("snapshot content differs from frozen source"))
        #expect(try fixture.pendingState() == .sourceSnapshotted)
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }

    /// An emptied manifest cannot skip placement or cleanup: the
    /// completeness proof compares it against the snapshot rows before
    /// the first placement write.
    @Test func emptiedPlanCannotSkipPlacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        tampered.audioPlan = TransferAudioPlan(files: [], directories: [], rewrites: [])
        document.pendingTransfer = tampered
        try fixture.rawWrite(document)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on emptied plan")
            return
        }
        #expect(reason.contains("does not cover every snapshot reference"))
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.targetAudioRoot
                .appendingPathComponent("transfers", isDirectory: true).path
        ))
    }

    /// Byte-identity with a rebuild from the frozen source catches every
    /// remaining manifest tamper class: an extra safe child, a removed
    /// entry, or an altered hash.
    @Test func manifestDriftFromSourceHaltsAtPlacement() throws {
        let variants: [(String, (inout TransferAudioPlan) -> Void)] = [
            ("extra child", { plan in
                if let entry = plan.files.first(where: {
                    $0.field == .segmentsDirectory && $0.childRelativePath == "0.m4a"
                }) {
                    var ghost = entry
                    ghost.childRelativePath = "ghost.m4a"
                    plan.files.append(ghost)
                }
            }),
            ("removed entry", { plan in
                plan.files.removeAll {
                    $0.field == .segmentsDirectory && $0.childRelativePath == "1.m4a"
                }
            }),
            ("altered hash", { plan in
                plan.files[0].sha256 = String(repeating: "c", count: 64)
            }),
        ]
        for (label, mutate) in variants {
            let fixture = try makeExecutorFixture()
            defer { fixture.cleanUp() }
            let pending = try fixture.beginTransfer(mode: .copy)
            fixture.registry.configure { $0.failSaveAt = [3] }
            _ = ProfileTransferExecutor.run(
                pending: pending, dependencies: fixture.dependencies()
            )
            #expect(try fixture.pendingState() == .staged)

            var document = try fixture.disk.load()
            var tampered = try #require(document.pendingTransfer)
            var plan = try #require(tampered.audioPlan)
            mutate(&plan)
            tampered.audioPlan = plan
            document.pendingTransfer = tampered
            try fixture.rawWrite(document)

            fixture.registry.configure { $0.failSaveAt = [] }
            let resumed = try #require(try fixture.disk.load().pendingTransfer)
            let outcome = ProfileTransferExecutor.run(
                pending: resumed, dependencies: fixture.dependencies()
            )
            guard case .halted(let reason) = outcome else {
                Issue.record("expected halt for \(label)")
                continue
            }
            #expect(
                reason.contains("does not match the frozen source"),
                "\(label): \(reason)"
            )
            #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
        }
    }

    @Test func missingManifestComponentsHaltBeforePlacementWrites() throws {
        let variants: [(String, (inout TransferAudioPlan) -> Void)] = [
            ("rewrite", { plan in
                plan.rewrites.removeAll { $0.field == .audioFile }
            }),
            ("file", { plan in
                plan.files.removeAll {
                    $0.field == .segmentsDirectory && $0.childRelativePath == "1.m4a"
                }
            }),
            ("directory", { plan in
                plan.directories.removeAll {
                    $0.field == .segmentsDirectory && $0.childRelativePath == nil
                }
            }),
        ]
        for (label, mutate) in variants {
            let fixture = try makeExecutorFixture()
            defer { fixture.cleanUp() }
            let pending = try fixture.beginTransfer(mode: .copy)
            fixture.registry.configure { $0.failSaveAt = [3] }
            _ = ProfileTransferExecutor.run(
                pending: pending, dependencies: fixture.dependencies()
            )
            #expect(try fixture.pendingState() == .staged)

            var document = try fixture.disk.load()
            var tampered = try #require(document.pendingTransfer)
            var plan = try #require(tampered.audioPlan)
            mutate(&plan)
            tampered.audioPlan = plan
            document.pendingTransfer = tampered
            try fixture.rawWrite(document)

            fixture.registry.configure { $0.failSaveAt = [] }
            let resumed = try #require(try fixture.disk.load().pendingTransfer)
            let outcome = ProfileTransferExecutor.run(
                pending: resumed, dependencies: fixture.dependencies()
            )
            guard case .halted = outcome else {
                Issue.record("expected halt for missing \(label)")
                continue
            }
            let marker = ProfileTransfer.placementMarkerURL(
                inDirectory: fixture.paths.profileDirectory(fixture.target.id),
                transactionID: pending.transactionID,
                kind: .profileStore
            )
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.targetAudioRoot
                    .appendingPathComponent("transfers", isDirectory: true).path
            ))
        }
    }

    @Test func foreignProfileMarkerClaimHaltsBeforePlacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        let profileDirectory = fixture.paths.profileDirectory(fixture.target.id)
        try FileManager.default.createDirectory(
            at: profileDirectory, withIntermediateDirectories: true
        )
        let marker = ProfileTransfer.placementMarkerURL(
            inDirectory: profileDirectory,
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        let foreignClaim = Data("foreign-claim".utf8)
        try foreignClaim.write(to: marker)
        guard case .halted(let bootReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected boot halt for foreign marker claim")
            return
        }
        #expect(bootReason.contains("marker claim unavailable"))

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected executor halt for foreign marker claim")
            return
        }
        #expect(reason.contains("marker claim mismatch"))
        #expect(try Data(contentsOf: marker) == foreignClaim)
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }

    @Test func foreignAudioMarkerClaimHaltsBeforeStorePlacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        let operations = LiveFileOperations()
        try operations.createDirectory(
            at: fixture.paths.profileDirectory(fixture.target.id)
        )
        let profileMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        try operations.createFileExclusively(
            ProfileTransfer.placementMarkerPayload(pending, kind: .profileStore),
            at: profileMarker
        )
        try operations.createDirectory(at: fixture.targetAudioRoot)
        let audioMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            kind: .audioRoot
        )
        let foreignClaim = Data("foreign-audio-claim".utf8)
        try operations.createFileExclusively(foreignClaim, at: audioMarker)

        guard case .halted(let bootReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected boot halt for foreign audio marker claim")
            return
        }
        #expect(bootReason.contains("marker claim unavailable"))

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt for foreign audio marker claim")
            return
        }
        #expect(reason.contains("marker claim mismatch"))
        #expect(try Data(contentsOf: audioMarker) == foreignClaim)
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }

    @Test func placedCheckpointMarkersCarryThePersistedClaim() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)
        let expectedProfile = try ProfileTransfer.placementMarkerPayload(
            pending, kind: .profileStore
        )
        let expectedAudio = try ProfileTransfer.placementMarkerPayload(
            pending, kind: .audioRoot
        )
        let profileMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        let audioMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            kind: .audioRoot
        )
        #expect(try Data(contentsOf: profileMarker) == expectedProfile)
        #expect(try Data(contentsOf: audioMarker) == expectedAudio)
        let decoder = ProfileRegistryCoding.makeDecoder()
        let profileClaim = try decoder.decode(
            TransferPlacementClaim.self, from: expectedProfile
        )
        let audioClaim = try decoder.decode(
            TransferPlacementClaim.self, from: expectedAudio
        )
        #expect(profileClaim.version == TransferPlacementClaim.currentVersion)
        #expect(profileClaim.transactionID == pending.transactionID)
        #expect(profileClaim.claimToken == pending.placementClaimToken)
        #expect(profileClaim.kind == .profileStore)
        #expect(audioClaim.kind == .audioRoot)

        try FileManager.default.removeItem(at: audioMarker)
        guard case .halted(let missingReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected boot halt when a placed claim is missing")
            return
        }
        #expect(missingReason.contains("claim missing after placement"))

        try expectedProfile.write(to: audioMarker)
        guard case .halted(let wrongRoleReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected boot halt when a placed claim has the wrong role")
            return
        }
        #expect(wrongRoleReason.contains("claim unavailable"))

        var unsupported = audioClaim
        unsupported.version += 1
        try ProfileRegistryCoding.makeEncoder().encode(unsupported).write(to: audioMarker)
        guard case .halted(let versionReason) = try fixture.classifyAtBoot() else {
            Issue.record("expected boot halt for an unsupported placement claim")
            return
        }
        #expect(versionReason.contains("claim unavailable"))
    }

    @Test func placedCheckpointCannotCommitAfterPlacementClaimIsRemoved() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        let profileMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        try FileManager.default.removeItem(at: profileMarker)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected final placement claim verification to halt")
            return
        }
        #expect(reason.contains("profile placement claim failed at commit"))
        let document = try fixture.disk.load()
        #expect(document.pendingTransfer?.state == .placed)
        #expect(document.activeProfileID == fixture.local.id)
    }

    @Test func targetVerifiedCannotReclaimAnUnmarkedPlacedStore() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [4] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .targetVerified)

        let profileMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        try FileManager.default.removeItem(at: profileMarker)
        let targetDigest = try SQLiteLogicalDigest.digest(of: fixture.targetStoreURL)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )

        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt without the profile-store claim")
            return
        }
        #expect(reason.contains("lacks its ownership claim"))
        #expect(!FileManager.default.fileExists(atPath: profileMarker.path))
        #expect(try SQLiteLogicalDigest.digest(of: fixture.targetStoreURL) == targetDigest)
        #expect(try fixture.pendingState() == .targetVerified)
    }

    @Test func moveCannotRetireSourceAfterPlacementClaimIsRemoved() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let sourceDigest = try SQLiteLogicalDigest.digest(of: fixture.sourceStoreURL)
        let pending = try fixture.beginTransfer(mode: .move)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        let profileMarker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        try FileManager.default.removeItem(at: profileMarker)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected missing claim to halt before source retirement")
            return
        }
        #expect(reason.contains("placement claim failed before local rebuild"))
        #expect(try fixture.pendingState() == .placed)
        #expect(try SQLiteLogicalDigest.digest(of: fixture.sourceStoreURL) == sourceDigest)
        let retired = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".transferred-\(pending.transactionID.uuidString)"
        )
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try fixture.disk.load().activeProfileID == fixture.local.id)
    }

    @Test func unprobeablePlacementMarkerNeverMeansAbsent() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        let marker = ProfileTransfer.placementMarkerURL(
            inDirectory: fixture.paths.profileDirectory(fixture.target.id),
            transactionID: pending.transactionID,
            kind: .profileStore
        )
        let operations = InstrumentedFileOperations(
            failAttributeNames: [marker.lastPathComponent]
        )
        guard case .halted(let reason) = try fixture.classifyAtBoot(
            fileOperations: operations
        ) else {
            Issue.record("expected boot halt on an unprobeable placement marker")
            return
        }
        #expect(reason.contains("marker claim unavailable"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }

    /// Tree structure is manifest-driven end to end: nested directories
    /// and empty nested directories are recreated at the target.
    @Test func nestedAndEmptyTreeDirectoriesRoundTrip() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let tree = fixture.sourceAudioRoot.appendingPathComponent(
            "segments/nested", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("sub/empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("top".utf8).write(to: tree.appendingPathComponent("a.m4a"))
        try Data("deep".utf8).write(to: tree.appendingPathComponent("sub/b.m4a"))
        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        let row = Recording(title: "Nested")
        row.segmentsDirectoryReference = .relative("segments/nested")
        row.ownership = .appCreated
        context.insert(row)
        try context.save()

        let pending = try fixture.beginTransfer(mode: .copy)
        let ids = try fixture.recordingIDsByTitle()
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        let treeDestination = expectedAudioURL(
            root: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            recordingID: try #require(ids["Nested"]),
            field: .segmentsDirectory,
            sourceReference: "segments/nested"
        )
        #expect(try Data(
            contentsOf: treeDestination.appendingPathComponent("a.m4a")
        ) == Data("top".utf8))
        #expect(try Data(
            contentsOf: treeDestination.appendingPathComponent("sub/b.m4a")
        ) == Data("deep".utf8))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: treeDestination.appendingPathComponent("sub/empty").path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }
}

// MARK: - Historical-consent markers

@MainActor
struct ProfileTransferExecutorConsentMarkerTests {
    /// Every transferred row — including rows with no audio references —
    /// carries the target's creation-binding ID as its historical
    /// marker, so the consent gate treats transferred data as historical
    /// rather than freshly recorded.
    @Test func transferStampsConsentMarkerOnEveryRow() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        let audioless = Recording(title: "No Audio")
        context.insert(audioless)
        try context.save()

        let pending = try fixture.beginTransfer(mode: .copy)
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        let target = try RecordingsStore.makeContainer(storeURL: fixture.targetStoreURL)
        let rows = try ModelContext(target).fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.awaitingHistoricalConsentBindingID == fixture.provenance)
        }
        // The source keeps its own rows unmarked: only the transferred
        // copies are historical data of the target's binding.
        let source = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let sourceRows = try ModelContext(source).fetch(FetchDescriptor<Recording>())
        for row in sourceRows {
            #expect(row.awaitingHistoricalConsentBindingID == nil)
        }
    }
}

// MARK: - Namespace and locator authority

@MainActor
struct ProfileTransferExecutorLocatorTests {
    /// A symlink alias cannot hide that a source file is already the
    /// transaction destination. The transfer halts before claiming it.
    @Test func symlinkAliasIntoNamespaceHaltsBeforePlacement() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }

        var document = try fixture.disk.load()
        let targetIndex = try #require(document.profiles.firstIndex {
            $0.id == fixture.target.id
        })
        document.profiles[targetIndex].audioDirectory = .init(
            bookmark: nil, path: fixture.sourceAudioRoot.path, kind: .appManaged
        )
        try fixture.disk.save(document)

        let pending = try fixture.beginTransfer(mode: .move)
        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Recording>())
        let row = try #require(rows.first { $0.title == "App Created" })
        let destination = expectedAudioURL(
            root: fixture.sourceAudioRoot,
            transactionID: pending.transactionID,
            recordingID: row.id,
            field: .audioFile,
            sourceReference: "alias/rec-a.m4a"
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("app-created-audio".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(
            at: fixture.sourceAudioRoot.appendingPathComponent("alias", isDirectory: true),
            withDestinationURL: destination.deletingLastPathComponent()
        )
        row.audioFileReference = .relative("alias/rec-a.m4a")
        try context.save()

        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on overlapping source alias")
            return
        }
        #expect(reason.contains("overlaps the transaction namespace"))
        #expect(try Data(contentsOf: destination) == Data("app-created-audio".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: ProfileTransfer.placementMarkerURL(
                inDirectory: fixture.paths.profileDirectory(fixture.target.id),
                transactionID: pending.transactionID,
                kind: .profileStore
            ).path
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.targetStoreURL.path))
    }

    /// Source and target sharing one audio root is the hard case the
    /// transaction namespace exists for: move-side cleanup trashes the
    /// original source paths while every placed copy survives under
    /// transfers/<transaction>/.
    @Test func sameRootMoveKeepsPlacedCopiesDisjointFromCleanup() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        var document = try fixture.disk.load()
        let targetIndex = try #require(document.profiles.firstIndex {
            $0.id == fixture.target.id
        })
        document.profiles[targetIndex].audioDirectory = .init(
            bookmark: nil, path: fixture.sourceAudioRoot.path, kind: .appManaged
        )
        try fixture.disk.save(document)

        let pending = try fixture.beginTransfer(mode: .move)
        let ids = try fixture.recordingIDsByTitle()
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }

        // The app-created original left the root; its placed copy lives
        // on in the namespace of the same root.
        #expect(!FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a").path
        ))
        let survivor = expectedAudioURL(
            root: fixture.sourceAudioRoot,
            transactionID: pending.transactionID,
            recordingID: try #require(ids["App Created"]),
            field: .audioFile,
            sourceReference: "rec-a.m4a"
        )
        #expect(try Data(contentsOf: survivor) == Data("app-created-audio".utf8))
        let segmentSurvivor = expectedAudioURL(
            root: fixture.sourceAudioRoot,
            transactionID: pending.transactionID,
            recordingID: try #require(ids["App Created"]),
            field: .segmentsDirectory,
            sourceReference: "segments/rec-a",
            child: "0.m4a"
        )
        #expect(try Data(contentsOf: segmentSurvivor) == Data("segment-0".utf8))
        // Non-app-created and unreferenced files are untouched.
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("user.m4a").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("unrelated.bin").path
        ))
    }

    /// A tampered plan that redirects a source reference — internally
    /// consistent with the namespace derivation — still halts against
    /// the verified snapshot row before any filesystem use.
    @Test func tamperedPlanReferenceHaltsBeforeCopy() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [3] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .staged)

        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        var plan = try #require(tampered.audioPlan)
        let index = try #require(plan.rewrites.firstIndex {
            $0.sourceReference == "user.m4a"
        })
        plan.rewrites[index].sourceReference = "unrelated.bin"
        plan.rewrites[index].destinationReference =
            ProfileTransfer.audioDestinationRelativePath(
                transactionID: tampered.transactionID,
                recordingID: plan.rewrites[index].recordingID,
                field: .audioFile,
                sourceReference: "unrelated.bin",
                childRelativePath: nil
            )
        tampered.audioPlan = plan
        document.pendingTransfer = tampered
        let raw = try ProfileRegistryCoding.makeEncoder().encode(document)
        try raw.write(to: fixture.paths.registryURL)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on tampered plan")
            return
        }
        #expect(reason.contains("snapshot row"))
        let redirected = expectedAudioURL(
            root: fixture.targetAudioRoot,
            transactionID: resumed.transactionID,
            recordingID: plan.rewrites[index].recordingID,
            field: .audioFile,
            sourceReference: "unrelated.bin"
        )
        #expect(!FileManager.default.fileExists(atPath: redirected.path))
    }

    /// An ownership escalation in the persisted plan halts against the
    /// snapshot row before the first deletion — nothing is trashed.
    @Test func tamperedOwnershipHaltsBeforeCleanup() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .move)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .placed)

        var document = try fixture.disk.load()
        var tampered = try #require(document.pendingTransfer)
        var plan = try #require(tampered.audioPlan)
        let index = try #require(plan.files.firstIndex {
            $0.sourceOwnership == .unknownLegacy && $0.childRelativePath == nil
        })
        plan.files[index].sourceOwnership = .appCreated
        tampered.audioPlan = plan
        document.pendingTransfer = tampered
        let raw = try ProfileRegistryCoding.makeEncoder().encode(document)
        try raw.write(to: fixture.paths.registryURL)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .halted(let reason) = outcome else {
            Issue.record("expected halt on tampered ownership")
            return
        }
        #expect(reason.contains("ownership does not match"))
        // Every source file is still present — including the app-created
        // one whose deletion would otherwise be legitimate.
        for relative in ["rec-a.m4a", "user.m4a", "segments/rec-a/0.m4a"] {
            #expect(FileManager.default.fileExists(
                atPath: fixture.sourceAudioRoot.appendingPathComponent(relative).path
            ))
        }
    }

    @Test func emptySegmentsTreeCreatesTargetDirectory() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let emptyTree = fixture.sourceAudioRoot.appendingPathComponent(
            "segments/empty", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyTree, withIntermediateDirectories: true
        )
        let container = try RecordingsStore.makeContainer(storeURL: fixture.sourceStoreURL)
        let context = ModelContext(container)
        let row = Recording(title: "Empty Tree")
        row.segmentsDirectoryReference = .relative("segments/empty")
        row.ownership = .appCreated
        context.insert(row)
        try context.save()

        let pending = try fixture.beginTransfer(mode: .copy)
        let ids = try fixture.recordingIDsByTitle()
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        let treeDestination = expectedAudioURL(
            root: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            recordingID: try #require(ids["Empty Tree"]),
            field: .segmentsDirectory,
            sourceReference: "segments/empty"
        )
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: treeDestination.path, isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }
}

// MARK: - Work-store scratch lifecycle

@MainActor
struct ProfileTransferExecutorScratchLifecycleTests {
    @Test func priorProcessSweepRemovesOnlyStaleRecognizedScratch() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        let staleTransactionID = UUID()
        let operations = LiveFileOperations()

        let staleStaging = fixture.paths.transferStagingDirectory(
            transactionID: staleTransactionID
        )
        let activeStaging = fixture.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        )
        try operations.createDirectory(at: staleStaging)
        try operations.createDirectory(at: activeStaging)
        let trackedStale = staleStaging.appendingPathComponent(
            "Cadenza.store.work-\(UUID().uuidString)"
        )
        let staleStaged = staleStaging.appendingPathComponent("Cadenza.store")
        let activeWork = activeStaging.appendingPathComponent(
            "Cadenza.store.work-\(UUID().uuidString)"
        )
        try Data("tracked".utf8).write(to: trackedStale)
        try Data("staged".utf8).write(to: staleStaged)
        try Data("active".utf8).write(to: activeWork)
        fixture.scratchTracker.markOpened(baseURL: trackedStale)

        let staleSnapshot = fixture.paths.migrationDirectory
            .appendingPathComponent("snapshots/transfer-\(staleTransactionID.uuidString)")
            .appendingPathComponent(UUID().uuidString)
        let activeSnapshot = fixture.paths.migrationDirectory
            .appendingPathComponent("snapshots/transfer-\(pending.transactionID.uuidString)")
            .appendingPathComponent(UUID().uuidString)
        try operations.createDirectory(at: staleSnapshot)
        try operations.createDirectory(at: activeSnapshot)
        let staleArtifact = staleSnapshot.appendingPathComponent("Cadenza.store")
        let activeArtifact = activeSnapshot.appendingPathComponent("Cadenza.store")
        try Data("snapshot".utf8).write(to: staleArtifact)
        try Data("active-snapshot".utf8).write(to: activeArtifact)

        let staleReplacement = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".replacement-\(staleTransactionID.uuidString)"
                + ".verify-\(UUID().uuidString)"
        )
        let activeReplacement = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".replacement-\(pending.transactionID.uuidString)"
                + ".verify-\(UUID().uuidString)"
        )
        try Data("replacement".utf8).write(to: staleReplacement)
        try Data("active-replacement".utf8).write(to: activeReplacement)

        let victim = fixture.base.appendingPathComponent("victim")
        try Data("victim".utf8).write(to: victim)
        let linkedScratch = staleStaging.appendingPathComponent(
            "Cadenza.store.verify-\(UUID().uuidString)"
        )
        try FileManager.default.createSymbolicLink(
            at: linkedScratch, withDestinationURL: victim
        )

        let document = try fixture.disk.load()
        ProfileTransferExecutor.sweepPriorProcessScratch(
            document: document,
            paths: fixture.paths,
            fileOperations: operations,
            scratchTracker: fixture.scratchTracker
        )

        #expect(FileManager.default.fileExists(atPath: trackedStale.path))
        #expect(!FileManager.default.fileExists(atPath: staleStaged.path))
        #expect(!FileManager.default.fileExists(atPath: staleArtifact.path))
        #expect(!FileManager.default.fileExists(atPath: staleReplacement.path))
        #expect(FileManager.default.fileExists(atPath: activeWork.path))
        #expect(FileManager.default.fileExists(atPath: activeArtifact.path))
        #expect(FileManager.default.fileExists(atPath: activeReplacement.path))
        #expect(FileManager.default.fileExists(atPath: linkedScratch.path))
        #expect(try Data(contentsOf: victim) == Data("victim".utf8))

        ProfileTransferExecutor.sweepPriorProcessScratch(
            document: document,
            paths: fixture.paths,
            fileOperations: operations,
            scratchTracker: ProfileTransferExecutor.ScratchProcessTracker()
        )
        #expect(!FileManager.default.fileExists(atPath: trackedStale.path))
        #expect(FileManager.default.fileExists(atPath: activeWork.path))
    }

    @Test func advisoryRecordCannotDirectScratchCleanup() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        var foreign = pending
        foreign.transactionID = UUID()
        let foreignStaging = fixture.paths.transferStagingDirectory(
            transactionID: foreign.transactionID
        )
        try FileManager.default.createDirectory(
            at: foreignStaging, withIntermediateDirectories: true
        )
        let protected = foreignStaging.appendingPathComponent(
            "Cadenza.store.work-protected"
        )
        try Data("protected".utf8).write(to: protected)

        let outcome = ProfileTransferExecutor.run(
            pending: foreign, dependencies: fixture.dependencies()
        )

        guard case .halted(let reason) = outcome else {
            Issue.record("expected a durable-record mismatch")
            return
        }
        #expect(reason.contains("exchanged during execution"))
        #expect(try Data(contentsOf: protected) == Data("protected".utf8))
        #expect(try fixture.pendingState() == .initiated)
    }

    @Test func symlinkedMigrationRootHaltsBeforeCreatingScratch() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        let foreign = fixture.base.appendingPathComponent(
            "ForeignMigration", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: foreign, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.migrationDirectory,
            withDestinationURL: foreign
        )

        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )

        guard case .halted(let reason) = outcome else {
            Issue.record("expected a migration-root halt")
            return
        }
        #expect(reason.contains("migration directory unavailable"))
        #expect(try FileManager.default.contentsOfDirectory(
            at: foreign, includingPropertiesForKeys: nil
        ).isEmpty)
        #expect(try fixture.pendingState() == .initiated)
    }

    @Test func symlinkedSnapshotAncestorHaltsBeforeCreatingScratch() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        let foreign = fixture.base.appendingPathComponent(
            "ForeignSnapshots", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixture.paths.migrationDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: foreign, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.migrationDirectory.appendingPathComponent("snapshots"),
            withDestinationURL: foreign
        )

        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )

        guard case .halted(let reason) = outcome else {
            Issue.record("expected a nested scratch-root halt")
            return
        }
        #expect(reason.contains("scratch path untrusted"))
        #expect(try FileManager.default.contentsOfDirectory(
            at: foreign, includingPropertiesForKeys: nil
        ).isEmpty)
        #expect(try fixture.pendingState() == .initiated)
    }

    /// Same-process retries retain work stores opened by SwiftData.
    @Test func retryRetainsTrackedWorkStoreAndCompletes() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [2] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .sourceSnapshotted)

        let staging = fixture.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        )
        let orphans = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Cadenza.store.work-") }
        guard let orphan = orphans.first else {
            Issue.record("expected an orphaned work file from the failed attempt")
            return
        }

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected the retry to complete, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    /// The sweep removes only untracked regular scratch files.
    @Test func sweepClassifiesScratchEntries() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        let staging = fixture.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        )
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true
        )
        let victim = fixture.base.appendingPathComponent("victim-content")
        try Data("victim".utf8).write(to: victim)
        let fakeScratch = staging.appendingPathComponent("Cadenza.store.work-fake")
        try FileManager.default.createSymbolicLink(at: fakeScratch, withDestinationURL: victim)

        let trackedScratch = staging.appendingPathComponent("Cadenza.store.work-tracked")
        try Data("tracked".utf8).write(to: trackedScratch)
        fixture.scratchTracker.markOpened(baseURL: trackedScratch)
        let untrackedScratch = staging.appendingPathComponent("Cadenza.store.work-old")
        try Data("old".utf8).write(to: untrackedScratch)

        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fakeScratch.path))
        #expect(try Data(contentsOf: victim) == Data("victim".utf8))
        #expect(FileManager.default.fileExists(atPath: trackedScratch.path))
        #expect(!FileManager.default.fileExists(atPath: untrackedScratch.path))
    }

    @Test func openedStoresNeverBecomeMutationSources() throws {
        for mode in [PendingTransfer.Mode.copy, .move] {
            let fixture = try makeExecutorFixture()
            defer { fixture.cleanUp() }
            let operations = InstrumentedFileOperations()
            let pending = try fixture.beginTransfer(mode: mode)
            let outcome = ProfileTransferExecutor.run(
                pending: pending,
                dependencies: fixture.dependencies(fileOperations: operations)
            )
            guard case .completed = outcome else {
                Issue.record("expected \(mode) completion, got \(outcome)")
                continue
            }
            #expect(openedStoreMutationConflicts(operations.recorded).isEmpty)
        }
    }

    @Test func replacementCheckpointRetryDoesNotMutateOpenedStores() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let operations = InstrumentedFileOperations()
        let pending = try fixture.beginTransfer(mode: .move)
        fixture.registry.configure { $0.failSaveAt = [5] }
        _ = ProfileTransferExecutor.run(
            pending: pending,
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        #expect(try fixture.pendingState() == .placed)
        let replacement = URL(
            fileURLWithPath: fixture.sourceStoreURL.path
                + ".replacement-\(pending.transactionID.uuidString)"
        )
        try Data("stale-wal".utf8).write(
            to: URL(fileURLWithPath: replacement.path + "-wal")
        )
        try Data("stale-shm".utf8).write(
            to: URL(fileURLWithPath: replacement.path + "-shm")
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed,
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .completed = outcome else {
            Issue.record("expected retry completion, got \(outcome)")
            return
        }
        #expect(openedStoreMutationConflicts(operations.recorded).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: replacement.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: replacement.path + "-shm"))
    }

    @Test func stagedCheckpointRetryRemovesOwnedRawSidecars() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [2] }
        _ = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        #expect(try fixture.pendingState() == .sourceSnapshotted)

        let staged = fixture.paths.transferStagingDirectory(
            transactionID: pending.transactionID
        ).appendingPathComponent("Cadenza.store")
        try Data("stale-wal".utf8).write(
            to: URL(fileURLWithPath: staged.path + "-wal")
        )
        try Data("stale-shm".utf8).write(
            to: URL(fileURLWithPath: staged.path + "-shm")
        )

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected retry completion, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: staged.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: staged.path + "-shm"))
    }

    @Test func snapshotCheckpointRetryDoesNotMutateOpenedStores() throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        let operations = InstrumentedFileOperations()
        let pending = try fixture.beginTransfer(mode: .copy)
        fixture.registry.configure { $0.failSaveAt = [1] }
        _ = ProfileTransferExecutor.run(
            pending: pending,
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        #expect(try fixture.pendingState() == .initiated)

        fixture.registry.configure { $0.failSaveAt = [] }
        let resumed = try #require(try fixture.disk.load().pendingTransfer)
        let outcome = ProfileTransferExecutor.run(
            pending: resumed,
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .completed = outcome else {
            Issue.record("expected retry completion, got \(outcome)")
            return
        }
        #expect(openedStoreMutationConflicts(operations.recorded).isEmpty)
    }
}

/// The executor's crash-safety story is structural: intermediate work
/// stores plus online backup, never waiting out another connection.
@Suite struct ProfileTransferExecutorSealTests {
    @Test func executorHasNoTimeBasedWaitPath() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cadenza/Services/Profiles/ProfileTransferExecutor.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["sleep(", "asyncAfter", "DispatchTime", "Task.sleep", "RunLoop"] {
            #expect(!text.contains(forbidden), "forbidden wait primitive: \(forbidden)")
        }
    }
}

// MARK: - Acceptance-matrix gaps

@MainActor
struct ProfileTransferExecutorAcceptanceGapTests {
    /// End to end over a user-selected, security-scope-bookmarked source
    /// root: the production orphan scan first catalogues a real audio
    /// file the app never created, the move then transfers everything,
    /// and the catalogued original stays in place — referencing is not
    /// owning.
    @Test func userSelectedScopedRootMovePreservesRecoveredOrphanFile() async throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }

        // The recorded path and the bookmark come from one resolution,
        // exactly as the production folder picker records them.
        let bookmark = try fixture.sourceAudioRoot.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var stale = false
        let resolvedRoot = try URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        #expect(!stale)
        var document = try fixture.disk.load()
        let sourceIndex = try #require(document.profiles.firstIndex {
            $0.id == fixture.local.id
        })
        document.profiles[sourceIndex].audioDirectory = .init(
            bookmark: bookmark, path: resolvedRoot.path, kind: .userSelected
        )
        try fixture.disk.save(document)
        _ = try #require(
            try fixture.disk.load().profiles.first { $0.id == fixture.local.id }
        )

        // A real, decodable, 31-second file — the production scan's own
        // gates must accept it.
        let orphanURL = resolvedRoot.appendingPathComponent("imported note.m4a")
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(
                count: 16_000 * 31,
                amplitude: 0.1
            )],
            to: orphanURL
        )
        let orphanBytes = try Data(contentsOf: orphanURL)

        // Production recovery with the store's explicit test audio root;
        // the store engine is scoped so its teardown finishes before the
        // move's exclusive retire checkpoint.
        let orphanID: UUID = try await {
            let container = try RecordingsStore.makeContainer(
                storeURL: fixture.sourceStoreURL
            )
            let store = RecordingsStore(modelContainer: container)
            await store.setAudioRootForTesting(resolvedRoot)
            let recovered = await OrphanAudioRecovery.run(
                storageRoot: resolvedRoot, store: store
            )
            #expect(recovered == 1)
            let rows = try ModelContext(container).fetch(FetchDescriptor<Recording>())
            let orphan = try #require(rows.first { $0.title == "imported note" })
            #expect(orphan.ownership == .unknownLegacy)
            #expect(orphan.audioFileReference == .relative("imported note.m4a"))
            return orphan.id
        }()

        let pending = try fixture.beginTransfer(mode: .move)
        let outcome = ProfileTransferExecutor.run(
            pending: pending, dependencies: fixture.dependencies()
        )
        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }

        // The catalogued file survives in place byte-for-byte; its
        // transferred copy lives in the namespace; the app-created
        // original was cleaned as usual.
        #expect(try Data(contentsOf: orphanURL) == orphanBytes)
        let copied = expectedAudioURL(
            root: fixture.targetAudioRoot,
            transactionID: pending.transactionID,
            recordingID: orphanID,
            field: .audioFile,
            sourceReference: "imported note.m4a"
        )
        #expect(try Data(contentsOf: copied) == orphanBytes)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.sourceAudioRoot.appendingPathComponent("rec-a.m4a").path
        ))
    }
}

// MARK: - Consent gate after transfer

@MainActor
struct ProfileTransferExecutorWebSyncConsentTests {
    /// Routing fake for the full sync protocol: structured upserts, audio
    /// sessions, parts, and commits each answer by endpoint, so a single
    /// deterministic pass can carry any number of rows to completion.
    /// `AuthHTTP` is main-actor isolated, so plain state suffices.
    private final class RoutedSyncHTTP: AuthHTTP {
        private(set) var requests: [URLRequest] = []
        private var sessions = 0

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let path = request.url?.path ?? ""
            func ok(_ json: String, status: Int) -> (Data, URLResponse) {
                (Data(json.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: nil
                )!)
            }
            if path.contains("/audio/sessions") {
                sessions += 1
                return ok(
                    #"{"session_id":"s\#(sessions)","recording_id":"remote-1","expires_at":4102444800}"#,
                    status: 201
                )
            }
            if path.contains("/parts/") { return ok("{}", status: 200) }
            if path.contains("/commit") {
                return ok(#"{"recording_id":"remote-1","version":1,"ready":true}"#, status: 200)
            }
            return ok(
                #"{"recording_id":"remote-1","version":1,"content_hash":""#
                    + String(repeating: "a", count: 64)
                    + #"","audio_state":"unavailable"}"#,
                status: 201
            )
        }
    }

    private struct Harness {
        let store: RecordingsStore
        let coordinator: WebSyncCoordinator
        let http: RoutedSyncHTTP
        let recordingIDs: [String: UUID]
        let transactionID: UUID
    }

    /// Runs a real copy transfer, opens the placed target store from a
    /// scratch copy with an explicit per-store audio root, hands the
    /// harness to `body`, and removes the scratch only after the store
    /// and coordinator references have left scope.
    private func withHarness(
        _ fixture: ExecutorFixture,
        consent: HistoricalSyncConsent,
        audioSwitchOn: Bool = false,
        _ body: (Harness) async throws -> Void
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-consent-store-\(UUID().uuidString)", isDirectory: true)
        do {
            let pending = try fixture.beginTransfer(mode: .copy)
            let recordingIDs = try fixture.recordingIDsByTitle()
            let outcome = ProfileTransferExecutor.run(
                pending: pending, dependencies: fixture.dependencies()
            )
            guard case .completed = outcome else {
                Issue.record("expected completion, got \(outcome)")
                throw CancellationError()
            }
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true
            )
            let storeCopy = scratch.appendingPathComponent("Cadenza.store")
            try FileManager.default.copyItem(at: fixture.targetStoreURL, to: storeCopy)
            let store = RecordingsStore(
                modelContainer: try RecordingsStore.makeContainer(storeURL: storeCopy)
            )
            await store.setAudioRootForTesting(fixture.targetAudioRoot)
            let http = RoutedSyncHTTP()
            let secrets = InMemoryAuthSecretStore()
            try! writeStoredToken(
                into: secrets, value: "token", expiresAt: Date().addingTimeInterval(3_600)
            )
            let users = InMemoryUserStore()
            users.user = .init(
                id: "user-1", email: "u@example.com", displayName: "User", pictureURL: nil
            )
            let auth = try CadenzaAuthService.bootstrapped(
                sessionProfile: AuthTestProfile.bound(userID: "user-1"),
                http: http,
                authorizer: FakeAuthorizationProvider(),
                secretStore: secrets,
                sessionUserStore: users,
                registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "user-1"))
            )
            let defaults = UserDefaults(suiteName: "transfer-consent-\(UUID().uuidString)")!
            if audioSwitchOn {
                defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
            }
            let coordinator = WebSyncCoordinator(
                store: store, auth: auth, defaults: defaults,
                startAutomatically: false,
                historicalConsent: { consent }
            )
            let harness = Harness(
                store: store, coordinator: coordinator, http: http,
                recordingIDs: recordingIDs, transactionID: pending.transactionID
            )
            await harness.coordinator.runOnePassForTesting(
                user: .init(
                    id: "user-1", email: "u@example.com",
                    displayName: "User", pictureURL: nil
                ),
                entitlementResolution: .selfHostOpen
            )
            // The drain runs on success and failure alike; a body error
            // propagates only after the coordinator has stopped.
            var bodyError: (any Error)?
            do {
                try await body(harness)
            } catch {
                bodyError = error
            }
            _ = await harness.coordinator.stopAndWait()
            if let bodyError { throw bodyError }
        } catch {
            // The inner scope has unwound, so no store reference can
            // still hold the scratch database.
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Undecided consent keeps every transferred row fully local: the
    /// marker the transfer stamped makes them historical, and a full
    /// reconcile pass — awaited, not timed — produces zero traffic.
    @Test func transferredRowsStayFullyLocalWhileUndecided() async throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        try await withHarness(fixture, consent: .undecided) { harness in
            #expect(harness.http.requests.isEmpty)
            for id in harness.recordingIDs.values {
                #expect(await harness.store.fetchWebSyncRecord(
                    userID: "user-1", recordingID: id
                ) == nil)
            }
        }
    }

    /// Text-only consent uploads exactly the structured payloads: every
    /// row syncs, every row's audio stays local, and no audio endpoint
    /// is ever touched.
    @Test func textOnlyConsentSyncsTextAndKeepsAudioLocal() async throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        try await withHarness(fixture, consent: .textOnly) { harness in
            for id in harness.recordingIDs.values {
                let record = await harness.store.fetchWebSyncRecord(
                    userID: "user-1", recordingID: id
                )
                #expect(record?.structuredState == WebStructuredSyncState.synced.rawValue)
                #expect(record?.audioState == WebAudioSyncState.localOnly.rawValue)
            }
            // One structured upsert per recording; the once-per-pass
            // /me/mcp-prefs read is not sync traffic and is not counted.
            #expect(harness.http.requests.filter {
                $0.url?.path.hasSuffix("/me/mcp-prefs") != true
            }.count == 3)
            #expect(!harness.http.requests.contains {
                let path = $0.url?.path ?? ""
                return path.contains("/audio/sessions") || path.contains("/parts/")
                    || path.contains("/commit")
            })
        }
    }

    /// With-audio consent plus the explicit audio switch uploads the
    /// audio through the full session protocol: readable transferred
    /// files, session + part + commit traffic, byte-exact part bodies,
    /// and a final synced audio state for every row.
    @Test func withAudioConsentUploadsAudioToSynced() async throws {
        let fixture = try makeExecutorFixture()
        defer { fixture.cleanUp() }
        try await withHarness(fixture, consent: .withAudio, audioSwitchOn: true) { harness in
            for id in harness.recordingIDs.values {
                let record = await harness.store.fetchWebSyncRecord(
                    userID: "user-1", recordingID: id
                )
                #expect(record?.structuredState == WebStructuredSyncState.synced.rawValue)
                #expect(record?.audioState == WebAudioSyncState.synced.rawValue)
            }
            let paths = harness.http.requests.map { $0.url?.path ?? "" }
            #expect(paths.filter { $0.contains("/audio/sessions") }.count == 3)
            #expect(paths.filter { $0.contains("/parts/") }.count == 3)
            #expect(paths.filter { $0.contains("/commit") }.count == 3)
            // Byte-exact upload proof: the three part bodies are exactly
            // the three transferred audio files' bytes.
            let uploaded = Set(harness.http.requests.compactMap { request -> Data? in
                guard request.url?.path.contains("/parts/") == true else { return nil }
                return request.httpBody
            })
            var expected = Set<Data>()
            let sources: [(String, String)] = [
                ("App Created", "rec-a.m4a"),
                ("User Owned", "user.m4a"),
                ("Absolute", fixture.outsideAudioURL.path),
            ]
            for (title, reference) in sources {
                expected.insert(try Data(contentsOf: expectedAudioURL(
                    root: fixture.targetAudioRoot,
                    transactionID: harness.transactionID,
                    recordingID: try #require(harness.recordingIDs[title]),
                    field: .audioFile,
                    sourceReference: reference
                )))
            }
            #expect(uploaded == expected)
        }
    }
}
