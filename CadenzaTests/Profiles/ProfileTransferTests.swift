import Foundation
import SwiftData
import Testing
import os

@testable import Cadenza

// MARK: - Shared fixtures

private let transferFixedNow = Date(timeIntervalSince1970: 1_785_800_000)

private func makeSystemLocal(
    id: UUID = UUID(), audioPath: String = "/tmp/audio-local"
) -> Profile {
    Profile(
        id: id,
        kind: .system,
        name: "Local",
        colorHex: nil,
        createdAt: transferFixedNow,
        lastActiveAt: transferFixedNow,
        audioDirectory: .init(bookmark: nil, path: audioPath, kind: .appManaged),
        boundAccount: nil,
        lockOnSignOut: false,
        isLocked: false,
        storeMaterialized: true,
        sessionDisposition: .active
    )
}

private func makeFreshTarget(
    id: UUID = UUID(),
    provenance: UUID? = UUID(),
    bound: Bool = true,
    isLocked: Bool = false,
    storeMaterialized: Bool = false
) throws -> Profile {
    let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
    return Profile(
        id: id,
        kind: .standard,
        name: "Account",
        colorHex: nil,
        createdAt: transferFixedNow,
        lastActiveAt: transferFixedNow,
        audioDirectory: .init(bookmark: nil, path: "/tmp/audio-\(id)", kind: .appManaged),
        boundAccount: bound ? Profile.BoundAccount(
            userID: "user-t",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "t@example.com",
            displayName: "T",
            boundAt: transferFixedNow
        ) : nil,
        lockOnSignOut: true,
        isLocked: isLocked,
        storeMaterialized: storeMaterialized,
        sessionDisposition: .active,
        createdByBindingTransactionID: provenance
    )
}

private struct ScriptedInspector: TransferStoreInspecting {
    var result: Result<[String: Int]?, Error>

    struct ProbeFailure: Error {}

    static func absent() -> ScriptedInspector { .init(result: .success(nil)) }

    static func empty() -> ScriptedInspector {
        .init(result: .success(
            Dictionary(uniqueKeysWithValues: ProfileTransfer.inspectedEntityNames.map {
                ($0, 0)
            })
        ))
    }

    func entityCounts(at url: URL) throws -> [String: Int]? {
        try result.get()
    }
}

/// Forwards to the live operations, injecting a failure mode on the
/// phase-authority seal write only.
private struct SealWriteOperations: FileOperations {
    enum Behavior {
        case failBeforeWrite
        case persistThenThrow
    }

    let behavior: Behavior
    private let base = LiveFileOperations()

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
        guard destination.lastPathComponent == PhaseAuthoritySealStore.filename else {
            try base.atomicReplace(data, at: destination)
            return
        }
        switch behavior {
        case .failBeforeWrite:
            throw CocoaError(.fileWriteNoPermission)
        case .persistThenThrow:
            try base.atomicReplace(data, at: destination)
            throw CocoaError(.fileWriteNoPermission)
        }
    }
    func noteStoreOpen(at url: URL) { base.noteStoreOpen(at: url) }
}

@MainActor
private struct TransferBootFixture {
    let base: URL
    let paths: ProfilePaths
    let suiteName: String
    let defaults: UserDefaults
    let registry: DiskProfileRegistry
    let secretStore: ThrowingSecretStore
    let userStores: SessionMigrationTests.SharedSessionUserStores
    let fileOperations: FileOperations
    let m1: M1StorageMigration.Dependencies
    let session: SessionMigrationDependencies

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    var sealStore: PhaseAuthoritySealStore {
        PhaseAuthoritySealStore(paths: paths, fileOperations: fileOperations)
    }
}

@MainActor
private func makeBootFixture(
    fileOperations: FileOperations = LiveFileOperations()
) throws -> TransferBootFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("transfer-tests-\(UUID().uuidString)", isDirectory: true)
    let audioRoot = base.appendingPathComponent("AudioRoot", isDirectory: true)
    try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
    let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    let suiteName = "transfer-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let registry = DiskProfileRegistry(
        registryURL: paths.registryURL, fileOperations: fileOperations
    )
    let secretStore = ThrowingSecretStore()
    let userStores = SessionMigrationTests.SharedSessionUserStores()
    let m1 = M1StorageMigration.Dependencies(
        paths: paths,
        registry: registry,
        fileOperations: fileOperations,
        backupDriver: LiveSQLiteBackupDriver(),
        audioRoot: { audioRoot },
        audioDirectoryState: {
            .init(bookmark: nil, path: audioRoot.path, kind: .userSelected)
        },
        scopedDefaults: ProfileScopedDefaults(
            defaults: defaults, persistentDomainName: suiteName
        ),
        now: { transferFixedNow }
    )
    let session = SessionMigrationDependencies(
        registry: registry,
        secretStore: secretStore,
        sessionUserStore: { userStores.store($0) },
        marker: SwiftDataHistoricalConsentMarker(),
        storeURL: { paths.storeURL($0) },
        storePresence: ProfileBindingTransaction.classifiedStorePresence(
            fileOperations: fileOperations
        ),
        profileDirectoryPresence: { id in
            do {
                _ = try fileOperations.attributesOfItem(at: paths.profileDirectory(id))
                return true
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return false
            }
        },
        defaults: defaults,
        backend: CadenzaBackendConfig.official(),
        newLocalAudioDirectory: { id in
            Profile.AudioDirectory(
                bookmark: nil,
                path: audioRoot.appendingPathComponent(id.uuidString).path,
                kind: .appManaged
            )
        },
        now: { transferFixedNow }
    )
    return TransferBootFixture(
        base: base, paths: paths, suiteName: suiteName, defaults: defaults,
        registry: registry, secretStore: secretStore, userStores: userStores,
        fileOperations: fileOperations, m1: m1, session: session
    )
}

/// Registry with an active system Local (real store, `rows` recordings)
/// and a freshly created bound target with the returned provenance.
@MainActor
private func establishTransferShape(
    _ fixture: TransferBootFixture, rows: Int = 1
) throws -> (local: Profile, target: Profile, provenance: UUID) {
    let provenance = UUID()
    let local = makeSystemLocal(
        audioPath: fixture.base.appendingPathComponent("AudioRoot").path
    )
    let target = try makeFreshTarget(provenance: provenance)
    let document = ProfileRegistryDocument(
        version: 1, activeProfileID: local.id, profiles: [local, target]
    )
    try fixture.registry.save(document)
    let container = try RecordingsStore.makeContainer(
        storeURL: fixture.paths.storeURL(local.id)
    )
    let context = ModelContext(container)
    for index in 0..<rows {
        context.insert(Recording(title: "Local \(index)"))
    }
    try context.save()
    return (local, target, provenance)
}

@MainActor
private func seedEntity(_ name: String, into context: ModelContext) throws {
    switch name {
    case "Recording":
        context.insert(Recording(title: "Seed"))
    case "Transcript":
        context.insert(Transcript(fullText: "seed"))
    case "MeetingSummary":
        context.insert(MeetingSummary(overview: "seed"))
    case "ExternalRecordingImport":
        context.insert(ExternalRecordingImport(
            externalKey: "k", provider: "p", externalID: "x", sourceTitle: "t",
            sourceStartDate: transferFixedNow, sourceDuration: 1,
            sourceCalendarEventID: nil, sourceCreatedAt: nil,
            sourceUpdatedAt: transferFixedNow, lastSeenAt: transferFixedNow,
            disposition: .pending
        ))
    case "Folder":
        context.insert(Folder(name: "Seed"))
    case "SpeakerProfile":
        context.insert(SpeakerProfile(displayName: "Seed"))
    case "SpeakerVoiceSample":
        context.insert(SpeakerVoiceSample(
            recordingID: UUID(), rawLabel: "L", embeddingData: Data([0]),
            embeddingDimension: 1, sampleDuration: 1, nonOverlapRatio: 1,
            qualityScore: 1, modelVersion: "v"
        ))
    case "Recap":
        context.insert(Recap(
            period: "week", startDate: transferFixedNow,
            endDate: transferFixedNow.addingTimeInterval(60), title: "Seed"
        ))
    case "AgentArtifact":
        context.insert(AgentArtifact(
            kind: "k", targetType: "t", targetKey: "key", slotKey: "slot",
            bodyMarkdown: "", provenanceSource: "auto", provenanceDetail: "",
            status: "ready", targetStartDate: transferFixedNow,
            targetEndDate: transferFixedNow, targetFingerprint: "f",
            contextBuiltAt: transferFixedNow
        ))
    case "WebSyncRecord":
        context.insert(WebSyncRecord(userID: "u", recordingID: UUID()))
    default:
        Issue.record("unknown entity \(name)")
    }
    try context.save()
}

// MARK: - Writer-side schema enforcement

@MainActor
struct ProfileTransferSchemaTests {
    private func makeDocument() throws -> (
        ProfileRegistryDocument, local: Profile, target: Profile
    ) {
        let local = makeSystemLocal()
        let target = try makeFreshTarget()
        return (
            ProfileRegistryDocument(
                version: 1, activeProfileID: local.id, profiles: [local, target]
            ),
            local, target
        )
    }

    /// Save rejects every illegal writer shape; the loaded document stays
    /// byte-identical to what was there before.
    @Test func saveRejectsIllegalWriterShapes() throws {
        let (document, local, target) = try makeDocument()
        let registry = InMemoryProfileRegistry()
        try registry.save(document)
        let before = try registry.load()

        var evidenceDrift = document
        var driftedTargetRow = target
        driftedTargetRow.name = "Renamed"
        evidenceDrift.pendingTransfer = makeTestPendingTransfer(
            source: local, target: driftedTargetRow
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(evidenceDrift) }

        var activeDrift = document
        activeDrift.pendingTransfer = makeTestPendingTransfer(source: local, target: target)
        activeDrift.activeProfileID = target.id
        #expect(throws: ProfileRegistryError.self) { try registry.save(activeDrift) }

        var laterState = document
        laterState.pendingTransfer = makeTestPendingTransfer(
            source: local, target: target, state: .staged
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(laterState) }

        var noProvenance = document
        var unprovenTarget = target
        unprovenTarget.createdByBindingTransactionID = nil
        noProvenance.profiles = [local, unprovenTarget]
        noProvenance.pendingTransfer = makeTestPendingTransfer(
            source: local, target: unprovenTarget
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(noProvenance) }

        var wrongVersion = document
        var record = makeTestPendingTransfer(source: local, target: target)
        record.version = 2
        wrongVersion.pendingTransfer = record
        #expect(throws: ProfileRegistryError.self) { try registry.save(wrongVersion) }

        #expect(try registry.load() == before)
    }

    /// A semantically drifted transfer that already sits on disk loads as
    /// a trusted document (the boot classification halts on it); only
    /// hard decode failures make the registry unreadable.
    @Test func driftedEvidenceLoadsAsTrustedDocument() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, _) = try establishTransferShape(fixture)
        var document = try fixture.registry.load()
        document.pendingTransfer = makeTestPendingTransfer(source: local, target: target)
        try fixture.registry.save(document)

        // Drift the target row behind the frozen evidence, bypassing the
        // save-side writer validation by editing the file directly.
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.registryURL)
        ) as! [String: Any]
        var profiles = raw["profiles"] as! [[String: Any]]
        for index in profiles.indices
        where profiles[index]["id"] as? String == target.id.uuidString {
            profiles[index]["name"] = "Drifted"
        }
        raw["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: fixture.paths.registryURL)

        let loaded = try fixture.registry.load()
        #expect(loaded.pendingTransfer != nil)
        let pending = try #require(loaded.pendingTransfer)
        #expect(ProfileTransfer.structuralProblem(
            document: loaded, pending: pending
        ) != nil)
    }
}

// MARK: - Preflight and initiation

@MainActor
struct ProfileTransferPreflightTests {
    private func makeDependencies(
        registry: ScriptedRegistry,
        inspector: TransferStoreInspecting = ScriptedInspector.absent(),
        storeURL: @escaping (UUID) -> URL = { _ in
            URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        }
    ) -> ProfileTransfer.Dependencies {
        ProfileTransfer.Dependencies(
            registry: registry,
            storeURL: storeURL,
            inspector: inspector,
            fileOperations: LiveFileOperations(),
            now: { transferFixedNow }
        )
    }

    private func makeRequest(
        source: Profile, target: Profile, provenance: UUID,
        mode: PendingTransfer.Mode = .copy
    ) -> ProfileTransfer.Request {
        ProfileTransfer.Request(
            sourceProfileID: source.id,
            targetProfileID: target.id,
            mode: mode,
            creationTransactionID: provenance
        )
    }

    @Test func preflightRefusalMatrixLeavesRegistryUntouched() throws {
        let provenance = UUID()
        let local = makeSystemLocal()
        let target = try makeFreshTarget(provenance: provenance)

        func expectRefusal(
            _ expected: ProfileTransfer.PreflightError,
            document: ProfileRegistryDocument,
            request: ProfileTransfer.Request
        ) {
            let registry = ScriptedRegistry(document: document)
            do {
                _ = try ProfileTransfer.begin(
                    request: request,
                    dependencies: makeDependencies(registry: registry)
                )
                Issue.record("expected refusal \(expected)")
            } catch ProfileTransfer.TransferError.preflight(let reason) {
                #expect(reason == expected)
            } catch {
                Issue.record("expected preflight error, got \(error)")
            }
            #expect(registry.saveCount == 0)
        }

        let valid = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id, profiles: [local, target]
        )

        expectRefusal(
            .sameProfile, document: valid,
            request: makeRequest(source: local, target: local, provenance: provenance)
        )
        expectRefusal(
            .sourceMissing, document: valid,
            request: .init(
                sourceProfileID: UUID(), targetProfileID: target.id,
                mode: .copy, creationTransactionID: provenance
            )
        )
        expectRefusal(
            .targetMissing, document: valid,
            request: .init(
                sourceProfileID: local.id, targetProfileID: UUID(),
                mode: .copy, creationTransactionID: provenance
            )
        )
        expectRefusal(
            .sourceNotSystemLocal, document: valid,
            request: makeRequest(source: target, target: local, provenance: provenance)
        )

        var inactiveSource = valid
        inactiveSource.activeProfileID = target.id
        expectRefusal(
            .sourceNotActive, document: inactiveSource,
            request: makeRequest(source: local, target: target, provenance: provenance)
        )

        let unbound = try makeFreshTarget(provenance: nil, bound: false)
        expectRefusal(
            .targetUnbound,
            document: ProfileRegistryDocument(
                version: 1, activeProfileID: local.id, profiles: [local, unbound]
            ),
            request: makeRequest(source: local, target: unbound, provenance: provenance)
        )

        let locked = try makeFreshTarget(provenance: provenance, isLocked: true)
        expectRefusal(
            .targetLocked,
            document: ProfileRegistryDocument(
                version: 1, activeProfileID: local.id, profiles: [local, locked]
            ),
            request: makeRequest(source: local, target: locked, provenance: provenance)
        )

        let unproven = try makeFreshTarget(provenance: nil)
        expectRefusal(
            .targetNotFreshlyCreated,
            document: ProfileRegistryDocument(
                version: 1, activeProfileID: local.id, profiles: [local, unproven]
            ),
            request: makeRequest(source: local, target: unproven, provenance: provenance)
        )
        expectRefusal(
            .targetNotFreshlyCreated, document: valid,
            request: makeRequest(source: local, target: target, provenance: UUID())
        )

        // A valid document cannot pair provenance with a materialized
        // store (the registry invariant forbids it), so the runtime sees
        // this shape only with the provenance already consumed.
        let materialized = try makeFreshTarget(
            provenance: nil, storeMaterialized: true
        )
        expectRefusal(
            .targetNotFreshlyCreated,
            document: ProfileRegistryDocument(
                version: 1, activeProfileID: local.id, profiles: [local, materialized]
            ),
            request: makeRequest(
                source: local, target: materialized, provenance: provenance
            )
        )

        var pendingBindingDocument = valid
        var bindTarget = try makeFreshTarget(provenance: nil, bound: false)
        bindTarget.name = "BindTarget"
        pendingBindingDocument.profiles.append(bindTarget)
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        pendingBindingDocument.pendingBinding = PendingBinding(
            transactionID: UUID(),
            profileID: bindTarget.id,
            userID: "u9",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            tokenDigest: SessionTokenDigest.digest(of: "raw"),
            startedAt: transferFixedNow
        )
        expectRefusal(
            .competingPendingOperation, document: pendingBindingDocument,
            request: makeRequest(source: local, target: target, provenance: provenance)
        )
    }

    /// One seeded row of each schema entity refuses the transfer with
    /// zero mutation on either side.
    @Test func everyNonEmptyEntityRefusesWithZeroMutation() async throws {
        for entity in ProfileTransfer.inspectedEntityNames {
            try runNonEmptyEntityCase(entity)
        }
    }

    private func runNonEmptyEntityCase(_ entity: String) throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        do {
            let (local, target, provenance) = try establishTransferShape(fixture)
            let targetStoreURL = fixture.paths.storeURL(target.id)
            let container = try RecordingsStore.makeContainer(storeURL: targetStoreURL)
            try seedEntity(entity, into: ModelContext(container))
            let registryBytes = try Data(contentsOf: fixture.paths.registryURL)

            let dependencies = ProfileTransfer.Dependencies(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
            do {
                _ = try ProfileTransfer.begin(
                    request: .init(
                        sourceProfileID: local.id, targetProfileID: target.id,
                        mode: .move, creationTransactionID: provenance
                    ),
                    dependencies: dependencies
                )
                Issue.record("expected refusal for \(entity)")
            } catch ProfileTransfer.TransferError.preflight(
                .targetStoreNotEmpty(let hit, let count)
            ) {
                #expect(hit == entity)
                #expect(count == 1)
            } catch {
                Issue.record("expected non-empty refusal for \(entity), got \(error)")
            }
            #expect(try Data(contentsOf: fixture.paths.registryURL) == registryBytes)
            let counts = try #require(try LiveTransferStoreInspector(
                fileOperations: LiveFileOperations()
            ).entityCounts(at: targetStoreURL))
            #expect(counts[entity] == 1)
            let sourceCounts = try #require(try LiveTransferStoreInspector(
                fileOperations: LiveFileOperations()
            ).entityCounts(at: fixture.paths.storeURL(local.id)))
            #expect(sourceCounts["Recording"] == 1)
        }
    }

    /// The inspected-entity inventory is sealed against the real schema,
    /// and the live inspector reports exactly those entities.
    @Test func inspectorInventorySealsTheSchema() throws {
        let schemaNames = Set(RecordingsStore.schema.entities.map(\.name))
        #expect(Set(ProfileTransfer.inspectedEntityNames) == schemaNames)
        #expect(
            ProfileTransfer.inspectedEntityNames.count
                == Set(ProfileTransfer.inspectedEntityNames).count
        )

        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let storeURL = fixture.paths.storeURL(UUID())
        let inspector = LiveTransferStoreInspector(fileOperations: LiveFileOperations())
        #expect(try inspector.entityCounts(at: storeURL) == nil)
        _ = try RecordingsStore.makeContainer(storeURL: storeURL)
        let counts = try #require(try inspector.entityCounts(at: storeURL))
        #expect(Set(counts.keys) == schemaNames)
        #expect(counts.values.allSatisfy { $0 == 0 })
    }

    @Test func orphanTargetSidecarRefusesBeforeInitiation() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        let targetStoreURL = fixture.paths.storeURL(target.id)
        let orphanWAL = StoreTrioURL(base: targetStoreURL).wal
        try FileManager.default.createDirectory(
            at: orphanWAL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("foreign-wal".utf8).write(to: orphanWAL)
        let registryBytes = try Data(contentsOf: fixture.paths.registryURL)

        do {
            _ = try ProfileTransfer.begin(
                request: .init(
                    sourceProfileID: local.id,
                    targetProfileID: target.id,
                    mode: .copy,
                    creationTransactionID: provenance
                ),
                dependencies: .init(
                    registry: fixture.registry,
                    storeURL: { fixture.paths.storeURL($0) },
                    inspector: LiveTransferStoreInspector(
                        fileOperations: LiveFileOperations()
                    ),
                    fileOperations: LiveFileOperations(),
                    now: { transferFixedNow }
                )
            )
            Issue.record("expected refusal for an orphan target sidecar")
        } catch ProfileTransfer.TransferError.preflight(.targetStoreUnreadable(let detail)) {
            #expect(detail.contains("orphan target sidecar"))
        } catch {
            Issue.record("expected targetStoreUnreadable, got \(error)")
        }
        #expect(try Data(contentsOf: fixture.paths.registryURL) == registryBytes)
        #expect(try Data(contentsOf: orphanWAL) == Data("foreign-wal".utf8))
        #expect(!FileManager.default.fileExists(atPath: targetStoreURL.path))
    }

    @Test func beginClassifiedSaveMatrix() throws {
        let provenance = UUID()
        let local = makeSystemLocal()
        let target = try makeFreshTarget(provenance: provenance)
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id, profiles: [local, target]
        )
        let request = makeRequest(source: local, target: target, provenance: provenance)

        let happy = ScriptedRegistry(document: document)
        let pending = try ProfileTransfer.begin(
            request: request, dependencies: makeDependencies(registry: happy)
        )
        #expect(pending.state == .initiated)
        #expect(try happy.load().pendingTransfer == pending)
        #expect(pending.sourceEvidence.matches(local))
        #expect(pending.targetEvidence.matches(target))

        let persisted = ScriptedRegistry(document: document)
        persisted.configure { $0.persistThenThrowAt = [1] }
        let stillCommitted = try ProfileTransfer.begin(
            request: request, dependencies: makeDependencies(registry: persisted)
        )
        #expect(try persisted.load().pendingTransfer == stillCommitted)

        let failed = ScriptedRegistry(document: document)
        failed.configure { $0.failSaveAt = [1] }
        do {
            _ = try ProfileTransfer.begin(
                request: request, dependencies: makeDependencies(registry: failed)
            )
            Issue.record("expected throw")
        } catch ProfileTransfer.TransferError.saveNotCommitted {
            #expect(try failed.load().pendingTransfer == nil)
        } catch {
            Issue.record("expected saveNotCommitted, got \(error)")
        }

        let third = ScriptedRegistry(document: document)
        third.configure { $0.thirdShapeOnSaveAt = [1] }
        do {
            _ = try ProfileTransfer.begin(
                request: request, dependencies: makeDependencies(registry: third)
            )
            Issue.record("expected throw")
        } catch ProfileTransfer.TransferError.commitIndeterminate {
            // The caller halts; nothing to roll back here.
        } catch {
            Issue.record("expected commitIndeterminate, got \(error)")
        }
    }
}

// MARK: - Inspector audit notice

@MainActor
struct TransferInspectorAuditTests {
    /// The read-only preflight open is audited exactly once for a
    /// present store and never for an absent one.
    @Test func inspectorRecordsExactlyOneStoreOpenNotice() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let operations = InstrumentedFileOperations()
        let inspector = LiveTransferStoreInspector(fileOperations: operations)
        let storeURL = fixture.paths.storeURL(UUID())

        #expect(try inspector.entityCounts(at: storeURL) == nil)
        #expect(operations.recorded.storeOpenPaths.isEmpty)

        _ = try RecordingsStore.makeContainer(storeURL: storeURL)
        _ = try #require(try inspector.entityCounts(at: storeURL))
        #expect(operations.recorded.storeOpenPaths == [storeURL.path])
    }
}

// MARK: - Provenance windows in the core registry invariants

@MainActor
struct ProvenanceWindowValidationTests {
    /// Nonnil provenance is legal only on an unmaterialized standard
    /// profile inside its two windows: a matching created pending
    /// binding, or the post-creation bound window.
    @Test func provenanceOutsideItsWindowsIsRejectedOnLoadAndSave() throws {
        let registry = InMemoryProfileRegistry()
        let local = makeSystemLocal()

        let materialized = try makeFreshTarget(storeMaterialized: true)
        var document = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id, profiles: [local, materialized]
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(document) }

        // The same shape written straight to disk (bypassing the save
        // validation) must fail the load: the invariant is structural,
        // not merely a writer courtesy.
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        try ProfileRegistryCoding.makeEncoder().encode(document)
            .write(to: fixture.paths.registryURL)
        #expect(throws: ProfileRegistryError.self) { try fixture.registry.load() }

        let orphanUnbound = try makeFreshTarget(bound: false)
        document = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id, profiles: [local, orphanUnbound]
        )
        #expect(throws: ProfileRegistryError.self) { try registry.save(document) }

        // Mid-transaction window: unbound plus the matching created
        // pending binding is legal.
        let provenance = UUID()
        var midTransaction = try makeFreshTarget(provenance: provenance, bound: false)
        midTransaction.lockOnSignOut = true
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        document = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id,
            pendingBinding: PendingBinding(
                transactionID: provenance,
                profileID: midTransaction.id,
                userID: "user-t",
                originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: "https://cadenzapp.com/api/v1",
                tokenDigest: SessionTokenDigest.digest(of: "raw"),
                createdProfile: true,
                startedAt: transferFixedNow
            ),
            profiles: [local, midTransaction]
        )
        try registry.save(document)

        // Bound window: legal without any pending record.
        let bound = try makeFreshTarget()
        document = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id, profiles: [local, bound]
        )
        try registry.save(document)
        #expect(try registry.load().profiles.contains {
            $0.createdByBindingTransactionID != nil
        })
    }
}

// MARK: - Phase-authority seal

@MainActor
struct PhaseAuthoritySealTests {
    @Test func missingSealClassifiesAbsentAndSealsDurably() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        // Live operations regression: a missing seal is definite absence,
        // never unknown, and the first ensure writes it.
        #expect(fixture.sealStore.classify() == .absent)
        #expect(fixture.sealStore.ensureSealed(now: transferFixedNow) == .committed)
        #expect(fixture.sealStore.classify() == .sealed)
        #expect(fixture.sealStore.ensureSealed(now: transferFixedNow) == .committed)
    }

    @Test func malformedAndUnsupportedSealsClassifyUnknown() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.paths.migrationDirectory, withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fixture.sealStore.url)
        guard case .unknown = fixture.sealStore.classify() else {
            Issue.record("expected unknown for malformed seal")
            return
        }
        let future = PhaseAuthoritySealDocument(
            version: 9, phase: 2, sealedAt: transferFixedNow
        )
        try ProfileRegistryCoding.makeEncoder().encode(future)
            .write(to: fixture.sealStore.url)
        guard case .unknown = fixture.sealStore.classify() else {
            Issue.record("expected unknown for unsupported seal version")
            return
        }
        guard case .unknown = fixture.sealStore.ensureSealed(now: transferFixedNow) else {
            Issue.record("ensure must not overwrite an unknown seal")
            return
        }
    }

    @Test func symlinkedSealAndMigrationRootClassifyUnknown() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let outside = fixture.base.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createDirectory(
            at: fixture.paths.migrationDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.sealStore.url, withDestinationURL: outside
        )
        guard case .unknown = fixture.sealStore.classify() else {
            Issue.record("expected unknown for symlinked seal")
            return
        }

        let redirected = try makeBootFixture()
        defer { redirected.cleanUp() }
        let elsewhere = redirected.base.appendingPathComponent(
            "elsewhere", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: redirected.paths.migrationDirectory, withDestinationURL: elsewhere
        )
        guard case .unknown = redirected.sealStore.classify() else {
            Issue.record("expected unknown for symlinked migration root")
            return
        }
        guard case .unknown = redirected.sealStore.ensureSealed(now: transferFixedNow)
        else {
            Issue.record("ensure must not write through a redirected root")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: elsewhere.path
        ).isEmpty)
    }

    @Test func sealWriteFailuresClassifyExactly() throws {
        let persisted = try makeBootFixture(
            fileOperations: SealWriteOperations(behavior: .persistThenThrow)
        )
        defer { persisted.cleanUp() }
        #expect(persisted.sealStore.ensureSealed(now: transferFixedNow) == .committed)
        #expect(persisted.sealStore.classify() == .sealed)

        let failing = try makeBootFixture(
            fileOperations: SealWriteOperations(behavior: .failBeforeWrite)
        )
        defer { failing.cleanUp() }
        guard case .notCommitted = failing.sealStore.ensureSealed(now: transferFixedNow)
        else {
            Issue.record("expected notCommitted for a definite write failure")
            return
        }
        #expect(failing.sealStore.classify() == .absent)
    }
}

// MARK: - Boot interception

@MainActor
struct ProfileTransferBootTests {
    /// A valid pending transfer intercepts the boot before every normal
    /// step: the seal is backfilled first, no profile directories or
    /// containers are prepared, and the registry keeps the pending
    /// record.
    @Test func validPendingEntersTransferModeBeforeNormalSteps() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        let pending = try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id, targetProfileID: target.id,
                mode: .copy, creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
        )
        let registryBytes = try Data(contentsOf: fixture.paths.registryURL)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .transfer(let intercepted) = context.mode else {
            Issue.record("expected transfer mode, got \(context.mode)")
            return
        }
        #expect(intercepted == pending)
        #expect(context.storeURL == nil)
        #expect(context.profile == nil)
        // The seal was backfilled ahead of the transfer decision; nothing
        // else changed and no normal-boot directory exists.
        #expect(fixture.sealStore.classify() == .sealed)
        #expect(try Data(contentsOf: fixture.paths.registryURL) == registryBytes)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.chatHistoryDirectory(local.id).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.backupsDirectory(local.id).path
        ))
    }

    /// A seal that cannot be proven durable halts before any transfer or
    /// session-stage effect — even with a valid pending transfer.
    @Test func sealWriteFailureHaltsBeforeTransferAndSessionStages() throws {
        let fixture = try makeBootFixture(
            fileOperations: SealWriteOperations(behavior: .failBeforeWrite)
        )
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        _ = try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id, targetProfileID: target.id,
                mode: .copy, creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
        )
        let registryBytes = try Data(contentsOf: fixture.paths.registryURL)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .halted(let reason) = context.mode else {
            Issue.record("expected halted, got \(context.mode)")
            return
        }
        #expect(reason.contains("phase authority seal"))
        #expect(fixture.sealStore.classify() == .absent)
        #expect(try Data(contentsOf: fixture.paths.registryURL) == registryBytes)
    }

    /// Fresh-install and legacy-upgrade first boots share the same gate:
    /// a definite seal failure halts with no session-stage side effects.
    @Test func firstBootSealFailureHaltsWithoutSessionStages() throws {
        let fresh = try makeBootFixture(
            fileOperations: SealWriteOperations(behavior: .failBeforeWrite)
        )
        defer { fresh.cleanUp() }
        let freshContext = ProfileBootstrap.runPipeline(
            dependencies: fresh.m1, session: fresh.session
        )
        guard case .halted(let freshReason) = freshContext.mode else {
            Issue.record("expected halted, got \(freshContext.mode)")
            return
        }
        #expect(freshReason.contains("phase authority seal"))
        // No session stage ran: no Local promotion, no consent scope, no
        // profile row mutation beyond the M1 commit itself.
        let document = try fresh.registry.load()
        #expect(document.profiles.count == 1)
        #expect(document.profiles.first?.kind == .standard)
        #expect(document.profiles.first?.boundAccount == nil)

        let persisted = try makeBootFixture(
            fileOperations: SealWriteOperations(behavior: .persistThenThrow)
        )
        defer { persisted.cleanUp() }
        let persistedContext = ProfileBootstrap.runPipeline(
            dependencies: persisted.m1, session: persisted.session
        )
        // The throw was classified committed, so the session stages ran
        // and the boot proceeds normally.
        guard case .profile = persistedContext.mode else {
            Issue.record("expected profile boot, got \(persistedContext.mode)")
            return
        }
        #expect(persisted.sealStore.classify() == .sealed)
        #expect(try persisted.registry.load().profiles.contains {
            $0.kind == .system
        })
    }

    /// The seal is durably readable before the first session-stage side
    /// effect, and every normal pipeline boot backfills it idempotently.
    @Test func pipelineBackfillsSealBeforeSessionEffects() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let sealStates = OSAllocatedUnfairLock<[PhaseAuthoritySealStore.Classification]>(
            initialState: []
        )
        let sealStore = fixture.sealStore
        let probingSession = SessionMigrationDependencies(
            registry: fixture.session.registry,
            secretStore: fixture.session.secretStore,
            sessionUserStore: { id in
                sealStates.withLock { $0.append(sealStore.classify()) }
                return fixture.userStores.store(id)
            },
            marker: fixture.session.marker,
            storeURL: fixture.session.storeURL,
            storePresence: fixture.session.storePresence,
            profileDirectoryPresence: fixture.session.profileDirectoryPresence,
            defaults: fixture.session.defaults,
            backend: fixture.session.backend,
            newLocalAudioDirectory: fixture.session.newLocalAudioDirectory,
            now: fixture.session.now
        )
        // A legacy-style global session forces M2 to touch the session
        // user store, proving the seal precedes session effects.
        let user = CadenzaAuthService.SignedInUser(
            id: "user-1", email: "u@example.com", displayName: "U", pictureURL: nil
        )
        fixture.defaults.set(
            try JSONEncoder().encode(user), forKey: M2SessionMigration.globalUserKey
        )
        try fixture.secretStore.set("legacy-token", for: SessionTokenKey.legacyGlobalAccount)

        let legacyStore = try RecordingsStore.makeContainer(
            storeURL: fixture.paths.legacyStoreURL
        )
        let legacyContext = ModelContext(legacyStore)
        legacyContext.insert(Recording(title: "Legacy"))
        try legacyContext.save()

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: probingSession
        )
        guard case .profile = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        let observed = sealStates.withLock { $0 }
        #expect(!observed.isEmpty)
        #expect(observed.allSatisfy { $0 == .sealed })

        let second = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .profile = second.mode else {
            Issue.record("expected stable reboot, got \(second.mode)")
            return
        }
        #expect(fixture.sealStore.classify() == .sealed)
    }

    /// Only a target store that gained rows in the TOCTOU window refuses
    /// deterministically: the pending record and the one-shot provenance
    /// clear in one classified write and the normal boot continues.
    @Test func nonEmptyTargetAtBootClearsAndBootsNormally() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        _ = try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id, targetProfileID: target.id,
                mode: .move, creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
        )
        let container = try RecordingsStore.makeContainer(
            storeURL: fixture.paths.storeURL(target.id)
        )
        try seedEntity("Recording", into: ModelContext(container))

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(local.id))
        let document = try fixture.registry.load()
        #expect(document.pendingTransfer == nil)
        #expect(document.profiles.first { $0.id == target.id }?
            .createdByBindingTransactionID == nil)
        let counts = try #require(try LiveTransferStoreInspector(
            fileOperations: LiveFileOperations()
        ).entityCounts(at: fixture.paths.storeURL(target.id)))
        #expect(counts["Recording"] == 1)
        let sourceCounts = try #require(try LiveTransferStoreInspector(
            fileOperations: LiveFileOperations()
        ).entityCounts(at: fixture.paths.storeURL(local.id)))
        #expect(sourceCounts["Recording"] == 1)
    }

    /// Registry-level drift behind the pending record halts with zero
    /// writes: the active profile switched away, or the stored evidence
    /// lost its provenance.
    @Test func driftedAuthorityAtBootHaltsWithZeroWrites() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        _ = try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id, targetProfileID: target.id,
                mode: .copy, creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
        )
        // Flip the active profile behind the record, bypassing writer
        // validation via a direct file edit.
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.registryURL)
        ) as! [String: Any]
        raw["activeProfileID"] = target.id.uuidString
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: fixture.paths.registryURL)
        let driftedBytes = try Data(contentsOf: fixture.paths.registryURL)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .halted(let reason) = context.mode else {
            Issue.record("expected halted, got \(context.mode)")
            return
        }
        #expect(reason.contains("active profile is not the transfer source"))
        #expect(try Data(contentsOf: fixture.paths.registryURL) == driftedBytes)
    }

    /// A pending record whose evidence lost its creation provenance is
    /// corrupt authority: halt, zero writes.
    @Test func provenanceStrippedPendingHaltsWithZeroWrites() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        _ = try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id, targetProfileID: target.id,
                mode: .copy, creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
        )
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.registryURL)
        ) as! [String: Any]
        var pendingTransfer = raw["pendingTransfer"] as! [String: Any]
        var targetEvidence = pendingTransfer["targetEvidence"] as! [String: Any]
        var evidenceProfile = targetEvidence["profile"] as! [String: Any]
        evidenceProfile.removeValue(forKey: "createdByBindingTransactionID")
        targetEvidence["profile"] = evidenceProfile
        pendingTransfer["targetEvidence"] = targetEvidence
        raw["pendingTransfer"] = pendingTransfer
        var profiles = raw["profiles"] as! [[String: Any]]
        for index in profiles.indices
        where profiles[index]["id"] as? String == target.id.uuidString {
            profiles[index].removeValue(forKey: "createdByBindingTransactionID")
        }
        raw["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: fixture.paths.registryURL)
        let strippedBytes = try Data(contentsOf: fixture.paths.registryURL)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .halted(let reason) = context.mode else {
            Issue.record("expected halted, got \(context.mode)")
            return
        }
        #expect(reason.contains("creation provenance"))
        #expect(try Data(contentsOf: fixture.paths.registryURL) == strippedBytes)
    }

    /// An undecodable pending transfer makes the registry unreadable; the
    /// sealed phase authority then forbids the M1 journal rebuild, and
    /// every artifact keeps its exact bytes.
    @Test func corruptPendingStateWithSealedAuthorityHalts() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let (local, target, provenance) = try establishTransferShape(fixture)
        _ = try ProfileTransfer.begin(
            request: .init(
                sourceProfileID: local.id, targetProfileID: target.id,
                mode: .copy, creationTransactionID: provenance
            ),
            dependencies: .init(
                registry: fixture.registry,
                storeURL: { fixture.paths.storeURL($0) },
                inspector: LiveTransferStoreInspector(
                    fileOperations: LiveFileOperations()
                ),
                fileOperations: LiveFileOperations(),
                now: { transferFixedNow }
            )
        )
        #expect(fixture.sealStore.ensureSealed(now: transferFixedNow) == .committed)
        var raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.registryURL)
        ) as! [String: Any]
        var pendingTransfer = raw["pendingTransfer"] as! [String: Any]
        pendingTransfer["state"] = "bogus"
        raw["pendingTransfer"] = pendingTransfer
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: fixture.paths.registryURL)
        let corruptBytes = try Data(contentsOf: fixture.paths.registryURL)
        let storeBytes = try Data(contentsOf: fixture.paths.storeURL(local.id))

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .halted(let reason) = context.mode else {
            Issue.record("expected halted, got \(context.mode)")
            return
        }
        #expect(reason.contains("phase 2 authority sealed"))
        #expect(try Data(contentsOf: fixture.paths.registryURL) == corruptBytes)
        #expect(try Data(contentsOf: fixture.paths.storeURL(local.id)) == storeBytes)
    }

    /// The promoted-Local shape: a single system profile with customized
    /// name and audio authority, no session artifacts, no extra
    /// directories. A corrupt registry under the seal halts instead of
    /// resurrecting the M1 standard shape.
    @Test func promotedLocalCustomShapeNeverRebuildsFromJournal() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        // Real M1 journal from a genuine legacy migration.
        let legacyStore = try RecordingsStore.makeContainer(
            storeURL: fixture.paths.legacyStoreURL
        )
        let legacyContext = ModelContext(legacyStore)
        legacyContext.insert(Recording(title: "Legacy"))
        try legacyContext.save()
        let first = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .profile = first.mode else {
            Issue.record("expected migrated boot, got \(first.mode)")
            return
        }
        #expect(fixture.sealStore.classify() == .sealed)
        // Customize the promoted Local like a real user would.
        var document = try fixture.registry.load()
        let localIndex = try #require(document.profiles.firstIndex {
            $0.kind == .system
        })
        document.profiles[localIndex].colorHex = "#AABBCC"
        document.profiles[localIndex].audioDirectory.path =
            fixture.base.appendingPathComponent("CustomAudio").path
        document.profiles[localIndex].audioDirectory.kind = .userSelected
        try fixture.registry.save(document)
        let activeID = document.activeProfileID
        let storeBytes = try Data(contentsOf: fixture.paths.storeURL(activeID))
        let journalBytes = try Data(contentsOf: fixture.paths.journalURL)

        try Data("not json".utf8).write(to: fixture.paths.registryURL)
        let corruptBytes = try Data(contentsOf: fixture.paths.registryURL)

        let second = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .halted(let reason) = second.mode else {
            Issue.record("expected halted, got \(second.mode)")
            return
        }
        #expect(reason.contains("phase 2 authority sealed"))
        #expect(try Data(contentsOf: fixture.paths.registryURL) == corruptBytes)
        #expect(try Data(contentsOf: fixture.paths.storeURL(activeID)) == storeBytes)
        #expect(try Data(contentsOf: fixture.paths.journalURL) == journalBytes)
    }

    /// A sealed-absent installation (pre-session authority) keeps the
    /// established journal recovery for an unreadable registry.
    @Test func sealAbsentM1RecoveryStillRebuilds() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let legacyStore = try RecordingsStore.makeContainer(
            storeURL: fixture.paths.legacyStoreURL
        )
        let legacyContext = ModelContext(legacyStore)
        legacyContext.insert(Recording(title: "Legacy"))
        try legacyContext.save()
        // M1 only — the session stages (and the seal) never ran.
        let first = ProfileBootstrap.run(dependencies: fixture.m1)
        guard case .profile(let id) = first.mode else {
            Issue.record("expected M1 boot, got \(first.mode)")
            return
        }
        #expect(fixture.sealStore.classify() == .absent)

        try Data("not json".utf8).write(to: fixture.paths.registryURL)
        let recovered = ProfileBootstrap.run(dependencies: fixture.m1)
        #expect(recovered.mode == .profile(id))
        #expect(try fixture.registry.load().activeProfileID == id)
    }

    /// Boots without a pending transfer never enter transfer mode, and
    /// the ephemeral environment cannot reach the interception at all.
    @Test func normalAndEphemeralBootsNeverTransfer() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        _ = try establishTransferShape(fixture)
        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .profile = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        #expect(try fixture.registry.load().pendingTransfer == nil)

        guard case .ephemeral = ProfileEnvironment.current() else {
            Issue.record("test host must run in the ephemeral environment")
            return
        }
    }
}

// MARK: - Creation-provenance lifecycle

@MainActor
struct TransferProvenanceLifecycleTests {
    /// The binding transaction stamps the created profile with its own
    /// transaction ID — the durable freshness proof transfer relies on.
    @Test func bindingCreatedProfileCarriesCreationProvenance() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let local = makeSystemLocal()
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: local.id, profiles: [local]
        )
        try fixture.registry.save(document)
        let newID = UUID()
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        var request = ProfileBindingTransaction.Request(
            profileID: newID,
            userID: "user-t",
            origin: origin,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            user: SessionUser(
                userID: "user-t", email: "t@example.com", displayName: "T",
                pictureURL: nil
            ),
            tokenRaw: "token-raw"
        )
        request.create = ProfileBindingTransaction.NewProfileTemplate(
            name: "Account",
            audioDirectory: .init(
                bookmark: nil,
                path: fixture.base.appendingPathComponent("audio-new").path,
                kind: .appManaged
            )
        )
        let committed = try ProfileBindingTransaction.runSync(
            request: request,
            dependencies: .init(
                registry: fixture.registry,
                secretStore: fixture.secretStore,
                sessionUserStore: { fixture.userStores.store($0) },
                marker: SwiftDataHistoricalConsentMarker(),
                storeURL: { fixture.paths.storeURL($0) },
                storePresence: ProfileBindingTransaction.classifiedStorePresence(
                    fileOperations: LiveFileOperations()
                ),
                now: { transferFixedNow }
            )
        )
        let created = try #require(committed.profiles.first { $0.id == newID })
        let provenance = try #require(created.createdByBindingTransactionID)
        let sessionUser = try #require(try fixture.userStores.store(newID).load())
        #expect(sessionUser.bindingTransactionID == provenance)
    }

    /// First materialization flips the flag and consumes the provenance
    /// in one atomic registry write.
    @Test func materializationConsumesCreationProvenanceAtomically() throws {
        let fixture = try makeBootFixture()
        defer { fixture.cleanUp() }
        let local = makeSystemLocal()
        let target = try makeFreshTarget()
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: target.id, profiles: [local, target]
        )
        try fixture.registry.save(document)

        try ProfileBootstrap.recordStoreMaterialized(
            profileID: target.id, dependencies: fixture.m1
        )
        let after = try fixture.registry.load()
        let row = try #require(after.profiles.first { $0.id == target.id })
        #expect(row.storeMaterialized == true)
        #expect(row.createdByBindingTransactionID == nil)
    }
}
