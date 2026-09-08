import Foundation
import Testing
import os

@testable import Cadenza

/// Effect recorder for the coordinator's injected boundary: every call
/// is counted so refusal and cancel paths can assert zero writes.
@MainActor
private final class RelinkHarness {
    var identity: AudioRootRelinkCoordinator.RootIdentity?
    var probeResult = false
    var probeCalls = 0
    var pickResult: URL?
    var pickCalls = 0
    var madeBookmarks: [URL] = []
    var bookmarkToMake = Data([0xAB])
    var savedRelinks: [(bookmark: Data, path: String)] = []
    var saveError: Error?

    func makeCoordinator() -> AudioRootRelinkCoordinator {
        AudioRootRelinkCoordinator(dependencies: .init(
            rootIdentity: { self.identity },
            probeBookmark: { _, _ in
                self.probeCalls += 1
                return self.probeResult
            },
            pickFolder: { _ in
                self.pickCalls += 1
                return self.pickResult
            },
            makeBookmark: { url in
                self.madeBookmarks.append(url)
                return self.bookmarkToMake
            },
            saveRelinkedBookmark: { bookmark, path in
                if let error = self.saveError { throw error }
                self.savedRelinks.append((bookmark, path))
            }
        ))
    }

    func userSelectedIdentity(
        path: String = "/tmp/relink-root", bookmark: Data? = Data([0x01])
    ) {
        identity = .init(bookmark: bookmark, path: path, kind: .userSelected)
    }
}

@MainActor
struct AudioRootRelinkCoordinatorTests {
    @Test func staleBookmarkSurfacesOffer() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        harness.probeResult = false
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        #expect(coordinator.phase == .offered)
        #expect(coordinator.recordedPath == "/tmp/relink-root")
        #expect(harness.probeCalls == 1)
    }

    @Test func missingBookmarkOnUserSelectedRootSurfacesOfferWithoutProbing() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity(bookmark: nil)
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        #expect(coordinator.phase == .offered)
        #expect(harness.probeCalls == 0)
    }

    @Test func appManagedRootNeverOffers() {
        let harness = RelinkHarness()
        harness.identity = .init(
            bookmark: nil, path: "/tmp/managed", kind: .appManaged
        )
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        #expect(coordinator.phase == .unavailable)
        #expect(harness.probeCalls == 0)
    }

    @Test func healthyBookmarkStaysUnavailable() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        harness.probeResult = true
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        #expect(coordinator.phase == .unavailable)
    }

    @Test func missingAuthorityStaysUnavailable() {
        let harness = RelinkHarness()
        harness.identity = nil
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        #expect(coordinator.phase == .unavailable)
    }

    @Test func cancelKeepsOfferWithZeroWrites() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = nil
        coordinator.performRelink()
        #expect(coordinator.phase == .offered)
        #expect(harness.pickCalls == 1)
        #expect(harness.madeBookmarks.isEmpty)
        #expect(harness.savedRelinks.isEmpty)
    }

    @Test func differentFolderIsRefusedWithZeroWrites() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = URL(fileURLWithPath: "/tmp/other-folder", isDirectory: true)
        coordinator.performRelink()
        guard case .refused = coordinator.phase else {
            Issue.record("expected refused, got \(coordinator.phase)")
            return
        }
        #expect(harness.madeBookmarks.isEmpty)
        #expect(harness.savedRelinks.isEmpty)
        // The refusal message survives a re-probe of the same stale root.
        coordinator.refresh()
        guard case .refused = coordinator.phase else {
            Issue.record("expected refused after refresh, got \(coordinator.phase)")
            return
        }
    }

    @Test func exactFolderRepairsThroughTheSavePath() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity(path: "/tmp/relink root")
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = URL(fileURLWithPath: "/tmp/relink root", isDirectory: true)
        coordinator.performRelink()
        #expect(coordinator.phase == .repaired)
        #expect(harness.madeBookmarks.map(\.path) == ["/tmp/relink root"])
        #expect(harness.savedRelinks.count == 1)
        #expect(harness.savedRelinks.first?.bookmark == harness.bookmarkToMake)
        #expect(harness.savedRelinks.first?.path == "/tmp/relink root")
        // A repaired attempt is done; another pick requires a fresh offer.
        coordinator.performRelink()
        #expect(harness.pickCalls == 1)
        // With the bookmark now authorizing, the next probe clears the block.
        harness.probeResult = true
        coordinator.refresh()
        #expect(coordinator.phase == .unavailable)
    }

    @Test func saveNotCommittedIsRetryable() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = URL(fileURLWithPath: "/tmp/relink-root", isDirectory: true)
        harness.saveError = ProfileAudioRootWriter.RootWriteError.saveNotCommitted("scripted")
        coordinator.performRelink()
        guard case .saveFailed = coordinator.phase else {
            Issue.record("expected saveFailed, got \(coordinator.phase)")
            return
        }
        harness.saveError = nil
        coordinator.performRelink()
        #expect(coordinator.phase == .repaired)
        #expect(harness.savedRelinks.count == 1)
    }

    @Test func indeterminateSaveBlocksTheSession() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = URL(fileURLWithPath: "/tmp/relink-root", isDirectory: true)
        harness.saveError = ProfileAudioRootWriter.RootWriteError.commitIndeterminate("scripted")
        coordinator.performRelink()
        guard case .blocked = coordinator.phase else {
            Issue.record("expected blocked, got \(coordinator.phase)")
            return
        }
        // Blocked is terminal for the session: no further picks, and a
        // re-probe never downgrades it back to an offer.
        coordinator.performRelink()
        #expect(harness.pickCalls == 1)
        coordinator.refresh()
        guard case .blocked = coordinator.phase else {
            Issue.record("expected blocked after refresh, got \(coordinator.phase)")
            return
        }
    }

    @Test func rootChangedSinceOfferIsRefused() {
        let harness = RelinkHarness()
        harness.userSelectedIdentity()
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = URL(fileURLWithPath: "/tmp/relink-root", isDirectory: true)
        harness.saveError = ProfileAudioRootWriter.RootWriteError.rootChanged
        coordinator.performRelink()
        guard case .refused = coordinator.phase else {
            Issue.record("expected refused, got \(coordinator.phase)")
            return
        }
    }

    /// A security-scoped bookmark follows a moved directory; the recorded
    /// lexical path is the identity, so a resolution landing elsewhere is
    /// unhealthy even though the bookmark itself resolves.
    @Test func probeRefusesABookmarkResolvingToADifferentPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let bookmark = try StorageLocationManager.prepareCustomDirectoryBookmark(base)
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale
        )
        #expect(AudioRootRelinkCoordinator.bookmarkGrantsAccess(
            bookmark, expectedPath: resolved.path
        ))
        #expect(!AudioRootRelinkCoordinator.bookmarkGrantsAccess(
            bookmark, expectedPath: resolved.path + "-moved"
        ))
    }

    /// NFC and NFD spellings compare equal under Swift String equality but
    /// differ in bytes; the picker comparison must refuse before any
    /// bookmark is created or written.
    @Test func canonicallyEquivalentSelectionIsRefusedBeforeAnyWrite() {
        let nfc = "/tmp/relink-caf\u{E9}"
        let nfd = "/tmp/relink-cafe\u{301}"
        #expect(nfc == nfd)
        #expect(!LexicalPathIdentity.equals(nfc, nfd))
        let picked = URL(fileURLWithPath: nfd, isDirectory: true)
        #expect(Array(picked.path.utf8) == Array(nfd.utf8))

        let harness = RelinkHarness()
        harness.userSelectedIdentity(path: nfc)
        let coordinator = harness.makeCoordinator()
        coordinator.refresh()
        harness.pickResult = picked
        coordinator.performRelink()
        guard case .refused = coordinator.phase else {
            Issue.record("expected refused, got \(coordinator.phase)")
            return
        }
        #expect(harness.madeBookmarks.isEmpty)
        #expect(harness.savedRelinks.isEmpty)
    }
}

@MainActor
struct AudioRootRelinkWriterTests {
    private func makeProfile(
        path: String,
        kind: Profile.AudioDirectory.Kind = .userSelected,
        bookmark: Data? = Data([0x01])
    ) -> Profile {
        let now = Date(timeIntervalSince1970: 1_785_900_000)
        return Profile(
            id: UUID(), kind: .standard, name: "Repairable", colorHex: nil,
            createdAt: now, lastActiveAt: now,
            audioDirectory: .init(bookmark: bookmark, path: path, kind: kind),
            boundAccount: nil, lockOnSignOut: false, isLocked: false,
            storeMaterialized: true, sessionDisposition: .active
        )
    }

    @Test func relinkRewritesOnlyTheBookmark() throws {
        let profile = makeProfile(path: "/tmp/relink-writer-root")
        let original = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        let registry = ScriptedRegistry(document: original)
        let newBookmark = Data([0xCA, 0xFE])

        try ProfileAudioRootWriter.applyRelinkedBookmark(
            newBookmark, expectedPath: "/tmp/relink-writer-root",
            profileID: profile.id, registry: registry
        )

        var expected = original
        expected.profiles[0].audioDirectory.bookmark = newBookmark
        let saved = try registry.load()
        #expect(saved == expected)
        // Path identity is byte-exact, not merely canonically equal.
        #expect(
            Array(saved.profiles[0].audioDirectory.path.utf8)
                == Array(original.profiles[0].audioDirectory.path.utf8)
        )
        #expect(registry.saveCount == 1)
    }

    @Test func differentRecordedPathRefusesWithZeroWrites() throws {
        let profile = makeProfile(path: "/tmp/relink-writer-root")
        let original = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        let registry = ScriptedRegistry(document: original)

        #expect(throws: ProfileAudioRootWriter.RootWriteError.rootChanged) {
            try ProfileAudioRootWriter.applyRelinkedBookmark(
                Data([0xCA]), expectedPath: "/tmp/somewhere-else",
                profileID: profile.id, registry: registry
            )
        }
        #expect(registry.saveCount == 0)
        #expect(try registry.load() == original)
    }

    @Test func appManagedRootRefusesWithZeroWrites() throws {
        let profile = makeProfile(path: "/tmp/relink-writer-root", kind: .appManaged, bookmark: nil)
        let original = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        let registry = ScriptedRegistry(document: original)

        #expect(throws: ProfileAudioRootWriter.RootWriteError.rootChanged) {
            try ProfileAudioRootWriter.applyRelinkedBookmark(
                Data([0xCA]), expectedPath: "/tmp/relink-writer-root",
                profileID: profile.id, registry: registry
            )
        }
        #expect(registry.saveCount == 0)
        #expect(try registry.load() == original)
    }

    @Test func inactiveProfileRefusesWithZeroWrites() throws {
        let inactive = makeProfile(path: "/tmp/relink-writer-root")
        let active = makeProfile(path: "/tmp/active-root")
        let original = ProfileRegistryDocument(
            version: 1, activeProfileID: active.id, profiles: [active, inactive]
        )
        let registry = ScriptedRegistry(document: original)

        #expect(throws: ProfileAudioRootWriter.RootWriteError.notActiveProfile) {
            try ProfileAudioRootWriter.applyRelinkedBookmark(
                Data([0xCA]), expectedPath: "/tmp/relink-writer-root",
                profileID: inactive.id, registry: registry
            )
        }
        #expect(registry.saveCount == 0)
        #expect(try registry.load() == original)
    }

    @Test func scriptedSaveFailureSurfacesAsNotCommitted() throws {
        let profile = makeProfile(path: "/tmp/relink-writer-root")
        let original = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        let registry = ScriptedRegistry(document: original)
        registry.configure { $0.failSaveAt = [1] }

        do {
            try ProfileAudioRootWriter.applyRelinkedBookmark(
                Data([0xCA]), expectedPath: "/tmp/relink-writer-root",
                profileID: profile.id, registry: registry
            )
            Issue.record("expected saveNotCommitted")
        } catch let error as ProfileAudioRootWriter.RootWriteError {
            guard case .saveNotCommitted = error else {
                Issue.record("expected saveNotCommitted, got \(error)")
                return
            }
        }
        #expect(try registry.load() == original)
    }

    /// A canonically equivalent (NFD) respelling of the recorded path must
    /// refuse at the writer with zero registry writes.
    @Test func canonicallyEquivalentPathRefusesWithZeroWrites() throws {
        let nfc = "/tmp/relink-caf\u{E9}"
        let nfd = "/tmp/relink-cafe\u{301}"
        #expect(nfc == nfd)
        let profile = makeProfile(path: nfc)
        let original = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        let registry = ScriptedRegistry(document: original)

        #expect(throws: ProfileAudioRootWriter.RootWriteError.rootChanged) {
            try ProfileAudioRootWriter.applyRelinkedBookmark(
                Data([0xCA]), expectedPath: nfd,
                profileID: profile.id, registry: registry
            )
        }
        #expect(registry.saveCount == 0)
        #expect(try registry.load() == original)
    }
}

/// Serialized: these tests install a process-global root authority
/// through the test seam.
@MainActor
@Suite(.serialized)
struct AudioRootRelinkAdoptionTests {
    private func makeAuthority(
        path: String, kind: Profile.AudioDirectory.Kind = .userSelected
    ) -> StorageLocationManager.ProfileRootAuthority {
        StorageLocationManager.ProfileRootAuthority(
            bookmark: Data([0x01]),
            path: path,
            kind: kind,
            profileDefaultPath: "/tmp/relink-adopt-default",
            recordRefreshedBookmark: { _ in },
            recordRootChange: { _, _, _ in }
        )
    }

    @Test func adoptSwapsOnlyTheBookmarkWhenIdentityMatches() {
        StorageLocationManager.withProfileRootForTesting(
            makeAuthority(path: "/tmp/relink-adopt-root")
        ) {
            MainActor.assumeIsolated {
                #expect(StorageLocationManager.adoptRepairedBookmark(
                    Data([0x02]), expectedPath: "/tmp/relink-adopt-root"
                ))
                let identity = StorageLocationManager.profileRootIdentity
                #expect(identity?.bookmark == Data([0x02]))
                #expect(identity?.path == "/tmp/relink-adopt-root")
                #expect(identity?.kind == .userSelected)
            }
        }
    }

    @Test func adoptRefusesADifferentPath() {
        StorageLocationManager.withProfileRootForTesting(
            makeAuthority(path: "/tmp/relink-adopt-root")
        ) {
            MainActor.assumeIsolated {
                #expect(!StorageLocationManager.adoptRepairedBookmark(
                    Data([0x02]), expectedPath: "/tmp/other-root"
                ))
                #expect(
                    StorageLocationManager.profileRootIdentity?.bookmark == Data([0x01])
                )
            }
        }
    }

    @Test func adoptRefusesAppManagedRoots() {
        StorageLocationManager.withProfileRootForTesting(
            makeAuthority(path: "/tmp/relink-adopt-root", kind: .appManaged)
        ) {
            MainActor.assumeIsolated {
                #expect(!StorageLocationManager.adoptRepairedBookmark(
                    Data([0x02]), expectedPath: "/tmp/relink-adopt-root"
                ))
                #expect(
                    StorageLocationManager.profileRootIdentity?.bookmark == Data([0x01])
                )
            }
        }
    }

    /// The resolver never reads or writes through a bookmark whose
    /// resolution no longer byte-matches the frozen path: the frozen
    /// lexical path stands, and no refreshed bookmark is recorded.
    @Test func resolverFallsBackToTheFrozenPathWhenTheBookmarkMoved() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let bookmark = try StorageLocationManager.prepareCustomDirectoryBookmark(base)
        let refreshes = OSAllocatedUnfairLock(initialState: 0)
        let frozenPath = "/tmp/relink-frozen-\(UUID().uuidString)"
        let authority = StorageLocationManager.ProfileRootAuthority(
            bookmark: bookmark,
            path: frozenPath,
            kind: .userSelected,
            profileDefaultPath: "/tmp/relink-adopt-default",
            recordRefreshedBookmark: { _ in refreshes.withLock { $0 += 1 } },
            recordRootChange: { _, _, _ in }
        )
        StorageLocationManager.withProfileRootForTesting(authority) {
            #expect(StorageLocationManager.recordingsDirectory.path == frozenPath)
        }
        #expect(refreshes.withLock { $0 } == 0)
    }

    /// In-memory adoption must apply the same byte-exact identity rule as
    /// the registry write: an NFD respelling is a different identity.
    @Test func adoptRefusesCanonicallyEquivalentPath() {
        let nfc = "/tmp/relink-adopt-caf\u{E9}"
        let nfd = "/tmp/relink-adopt-cafe\u{301}"
        #expect(nfc == nfd)
        StorageLocationManager.withProfileRootForTesting(makeAuthority(path: nfc)) {
            MainActor.assumeIsolated {
                #expect(!StorageLocationManager.adoptRepairedBookmark(
                    Data([0x02]), expectedPath: nfd
                ))
                #expect(
                    StorageLocationManager.profileRootIdentity?.bookmark == Data([0x01])
                )
            }
        }
    }
}

// MARK: - Per-recording legacy relink (spec 10.3)

@MainActor
struct LegacyAudioRelinkStoreTests {
    private struct Fixture {
        let store: RecordingsStore
        let root: URL
        let recordingID: UUID
        let legacyPath: String

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// In-memory store over a disk-backed scoped test root, seeded with
    /// the shape the M1 migration leaves for an un-rewritable row: the
    /// original absolute path string and no ownership column (which reads
    /// as `unknownLegacy`).
    private func makeFixture(
        legacyPath: String = "/upgraded/install/meeting.m4a"
    ) async throws -> Fixture {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-relink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(root)
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "Legacy Row",
            startDate: Date(timeIntervalSince1970: 1_785_900_000), segmentsDirURL: nil
        ))
        #expect(await store.setRawAudioReferencesForTesting(
            recordingID: recordingID, audioFilePath: legacyPath, segmentsDirectory: nil
        ))
        return Fixture(
            store: store, root: root, recordingID: recordingID, legacyPath: legacyPath
        )
    }

    private func writeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x01, 0x02, 0x03]).write(to: url)
    }

    /// Mutation scope, proven with typed whole-row snapshots: a second
    /// same-named legacy row and non-default segments/ownership sentinels
    /// on both rows; only the selected row's audio reference and content
    /// revision may change.
    @Test func relinkRewritesOnlyThisRowsAudioReference() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let otherID = UUID()
        #expect(await fixture.store.createRecording(
            id: otherID, title: "Other Legacy Row",
            startDate: Date(timeIntervalSince1970: 1_785_900_100), segmentsDirURL: nil
        ))
        #expect(await fixture.store.setRawAudioReferencesForTesting(
            recordingID: otherID,
            audioFilePath: "/upgraded/other/meeting.m4a",
            segmentsDirectory: "/upgraded/other/segments/other-row"
        ))
        #expect(await fixture.store.setRawAudioReferencesForTesting(
            recordingID: fixture.recordingID,
            audioFilePath: fixture.legacyPath,
            segmentsDirectory: "/upgraded/install/segments/target-row"
        ))
        #expect(await fixture.store.setOwnershipForTesting(
            recordingID: fixture.recordingID, .userOwned
        ))
        #expect(await fixture.store.setOwnershipForTesting(recordingID: otherID, .userOwned))
        let beforeTarget = try #require(
            await fixture.store.rowSnapshotForTesting(recordingID: fixture.recordingID)
        )
        let beforeOther = try #require(
            await fixture.store.rowSnapshotForTesting(recordingID: otherID)
        )
        #expect(beforeTarget.segments == .legacyAbsolute("/upgraded/install/segments/target-row"))
        let candidate = fixture.root.appendingPathComponent("meeting.m4a")
        try writeFile(candidate)
        try await Task.sleep(for: .milliseconds(2))

        let reference = try await fixture.store.relinkLegacyAudioReference(
            recordingID: fixture.recordingID, to: candidate
        )

        #expect(reference == .relative("meeting.m4a"))
        let afterTarget = try #require(
            await fixture.store.rowSnapshotForTesting(recordingID: fixture.recordingID)
        )
        #expect((afterTarget.updatedAt ?? .distantPast) > (beforeTarget.updatedAt ?? .distantPast))
        var expectedTarget = beforeTarget
        expectedTarget.audio = .relative("meeting.m4a")
        expectedTarget.updatedAt = afterTarget.updatedAt
        #expect(afterTarget == expectedTarget)
        let afterOther = try #require(
            await fixture.store.rowSnapshotForTesting(recordingID: otherID)
        )
        #expect(afterOther == beforeOther)
        #expect(await fixture.store.resolveURL(afterTarget.audio)?.path == candidate.path)
    }

    @Test func saveFailureRollsBackAndKeepsTheLegacyRow() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let candidate = fixture.root.appendingPathComponent("meeting.m4a")
        try writeFile(candidate)
        await fixture.store.failNextSaveForTesting()

        await #expect(throws: RecordingsStore.ReferenceRewriteError.saveFailed) {
            try await fixture.store.relinkLegacyAudioReference(
                recordingID: fixture.recordingID, to: candidate
            )
        }
        let detail = await fixture.store.fetchRecordingDetailUncached(recordingID: fixture.recordingID)
        #expect(detail?.audioFile == .legacyAbsolute(fixture.legacyPath))
    }

    @Test func unknownRecordingRefuses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let candidate = fixture.root.appendingPathComponent("meeting.m4a")
        try writeFile(candidate)

        await #expect(throws: RecordingsStore.LegacyRelinkError.recordingMissing) {
            try await fixture.store.relinkLegacyAudioReference(recordingID: UUID(), to: candidate)
        }
    }

    @Test func nonLegacyReferenceRefuses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        #expect(await fixture.store.setRawAudioReferencesForTesting(
            recordingID: fixture.recordingID,
            audioFilePath: "already-relative.m4a", segmentsDirectory: nil
        ))
        let candidate = fixture.root.appendingPathComponent("already-relative.m4a")
        try writeFile(candidate)

        await #expect(throws: RecordingsStore.LegacyRelinkError.referenceNotLegacy) {
            try await fixture.store.relinkLegacyAudioReference(
                recordingID: fixture.recordingID, to: candidate
            )
        }
        let detail = await fixture.store.fetchRecordingDetailUncached(recordingID: fixture.recordingID)
        #expect(detail?.audioFile == .relative("already-relative.m4a"))
    }

    @Test func differentFilenameRefusesIncludingCanonicalEquivalents() async throws {
        let fixture = try await makeFixture(legacyPath: "/upgraded/install/caf\u{E9}.m4a")
        defer { fixture.cleanUp() }
        let other = fixture.root.appendingPathComponent("other.m4a")
        try writeFile(other)
        await #expect(throws: RecordingsStore.LegacyRelinkError.nameMismatch("other.m4a")) {
            try await fixture.store.relinkLegacyAudioReference(
                recordingID: fixture.recordingID, to: other
            )
        }
        // NFD respelling of the same visible name is a different byte
        // identity and must refuse before any filesystem or store access.
        let nfd = fixture.root.appendingPathComponent("cafe\u{301}.m4a")
        await #expect(throws: RecordingsStore.LegacyRelinkError.nameMismatch("cafe\u{301}.m4a")) {
            try await fixture.store.relinkLegacyAudioReference(
                recordingID: fixture.recordingID, to: nfd
            )
        }
        let detail = await fixture.store.fetchRecordingDetailUncached(recordingID: fixture.recordingID)
        #expect(detail?.audioFile == .legacyAbsolute(fixture.legacyPath))
    }

    @Test func candidateOutsideTheRootRefuses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-relink-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outside = outsideDir.appendingPathComponent("meeting.m4a")
        try writeFile(outside)

        await #expect(throws: ProfileStorageResolver.ResolutionError.outsideRoot(outside.path)) {
            try await fixture.store.relinkLegacyAudioReference(
                recordingID: fixture.recordingID, to: outside
            )
        }
        let detail = await fixture.store.fetchRecordingDetailUncached(recordingID: fixture.recordingID)
        #expect(detail?.audioFile == .legacyAbsolute(fixture.legacyPath))
    }

    @Test func missingCandidateFileRefuses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let missing = fixture.root.appendingPathComponent("meeting.m4a")

        await #expect(throws: RecordingsStore.LegacyRelinkError.fileMissing(missing.path)) {
            try await fixture.store.relinkLegacyAudioReference(
                recordingID: fixture.recordingID, to: missing
            )
        }
    }

    /// End to end over the live coordinator wiring: an M1-shaped
    /// legacyAbsolute row, a same-named file in the current root, filename
    /// search, explicit adoption, and a converged relative row.
    @Test func m1ShapedRowRepairsEndToEnd() async throws {
        let fixture = try await makeFixture(legacyPath: "/old/mac/Recordings/standup.m4a")
        defer { fixture.cleanUp() }
        let candidate = fixture.root.appendingPathComponent("standup.m4a")
        try writeFile(candidate)

        let coordinator = LegacyAudioRelinkCoordinator.live(
            recordingID: fixture.recordingID, fileName: "standup.m4a", store: fixture.store
        )
        await coordinator.search()
        guard case .matches(let candidates) = coordinator.phase, candidates.count == 1 else {
            Issue.record("expected one match, got \(coordinator.phase)")
            return
        }
        await coordinator.adopt(candidates[0])
        #expect(coordinator.phase == .repaired)

        let detail = await fixture.store.fetchRecordingDetailUncached(recordingID: fixture.recordingID)
        #expect(detail?.audioFile == .relative("standup.m4a"))
        #expect(await fixture.store.resolveURL(detail?.audioFile)?.path == candidate.path)
        #expect(await fixture.store.audioOwnership(recordingID: fixture.recordingID) == .unknownLegacy)
    }

    /// Two same-named files force an explicit choice; adopting one rewrites
    /// to exactly that file's relative subpath.
    @Test func ambiguousMatchesRequireAnExplicitSelection() async throws {
        let fixture = try await makeFixture(legacyPath: "/old/mac/Recordings/standup.m4a")
        defer { fixture.cleanUp() }
        let topLevel = fixture.root.appendingPathComponent("standup.m4a")
        let nested = fixture.root.appendingPathComponent("imported/standup.m4a")
        try writeFile(topLevel)
        try writeFile(nested)

        let coordinator = LegacyAudioRelinkCoordinator.live(
            recordingID: fixture.recordingID, fileName: "standup.m4a", store: fixture.store
        )
        await coordinator.search()
        guard case .matches(let candidates) = coordinator.phase, candidates.count == 2 else {
            Issue.record("expected two matches, got \(coordinator.phase)")
            return
        }
        // Enumeration may spell the temp root through /private; select by
        // the unambiguous subpath — the relative rewrite below is the
        // actual identity proof.
        let chosen = try #require(candidates.first { $0.path.hasSuffix("/imported/standup.m4a") })
        await coordinator.adopt(chosen)
        #expect(coordinator.phase == .repaired)
        let detail = await fixture.store.fetchRecordingDetailUncached(recordingID: fixture.recordingID)
        #expect(detail?.audioFile == .relative("imported/standup.m4a"))
    }
}

/// State machine over injected effects; every refusal path asserts the
/// store was never called.
@MainActor
private final class LegacyRelinkHarness {
    var candidates: [URL] = []
    var searchCalls = 0
    var relinked: [(id: UUID, url: URL)] = []
    var relinkError: Error?
    /// Deterministic suspension gates: a held effect parks on a
    /// continuation until the test releases it, so in-flight phases are
    /// observable without timing races.
    var holdSearch = false
    var holdRelink = false
    /// Spins cooperatively until the surrounding task is cancelled,
    /// proving the coordinator cancels the traversal itself.
    var spinUntilCancelled = false
    var sawCancellation = false
    private var pendingSearch: CheckedContinuation<Void, Never>?
    private var pendingRelink: CheckedContinuation<Void, Never>?

    /// The held search has actually parked; releasing before this point
    /// would resume nothing and leave the continuation waiting forever.
    var hasParkedSearch: Bool { pendingSearch != nil }

    func releaseSearch() {
        pendingSearch?.resume()
        pendingSearch = nil
    }

    func releaseRelink() {
        pendingRelink?.resume()
        pendingRelink = nil
    }

    func makeCoordinator(
        recordingID: UUID = UUID(), fileName: String = "meeting.m4a"
    ) -> LegacyAudioRelinkCoordinator {
        LegacyAudioRelinkCoordinator(
            recordingID: recordingID,
            fileName: fileName,
            dependencies: .init(
                searchCandidates: { _ in
                    self.searchCalls += 1
                    if self.spinUntilCancelled {
                        while !Task.isCancelled { await Task.yield() }
                        self.sawCancellation = true
                        return []
                    }
                    if self.holdSearch {
                        await withCheckedContinuation { self.pendingSearch = $0 }
                    }
                    return self.candidates
                },
                relink: { id, url in
                    if self.holdRelink {
                        await withCheckedContinuation { self.pendingRelink = $0 }
                    }
                    if let error = self.relinkError { throw error }
                    self.relinked.append((id, url))
                }
            )
        )
    }
}

@MainActor
struct LegacyAudioRelinkCoordinatorTests {
    @Test func noMatchSurfacesWithoutStoreAccess() async {
        let harness = LegacyRelinkHarness()
        let coordinator = harness.makeCoordinator()
        await coordinator.search()
        #expect(coordinator.phase == .noMatch)
        #expect(harness.relinked.isEmpty)
    }

    @Test func singleMatchStillRequiresExplicitAdoption() async {
        let harness = LegacyRelinkHarness()
        let match = URL(fileURLWithPath: "/tmp/root/meeting.m4a")
        harness.candidates = [match]
        let recordingID = UUID()
        let coordinator = harness.makeCoordinator(recordingID: recordingID)
        await coordinator.search()
        #expect(coordinator.phase == .matches([match]))
        #expect(harness.relinked.isEmpty)
        await coordinator.adopt(match)
        #expect(coordinator.phase == .repaired)
        #expect(harness.relinked.count == 1)
        #expect(harness.relinked.first?.id == recordingID)
        #expect(harness.relinked.first?.url == match)
    }

    @Test func adoptingAnUnlistedURLIsRefusedWithoutStoreAccess() async {
        let harness = LegacyRelinkHarness()
        let match = URL(fileURLWithPath: "/tmp/root/meeting.m4a")
        harness.candidates = [match]
        let coordinator = harness.makeCoordinator()
        await coordinator.search()
        await coordinator.adopt(URL(fileURLWithPath: "/tmp/elsewhere/meeting.m4a"))
        #expect(coordinator.phase == .matches([match]))
        #expect(harness.relinked.isEmpty)
    }

    @Test func multipleMatchesAdoptTheSelectedOne() async {
        let harness = LegacyRelinkHarness()
        let first = URL(fileURLWithPath: "/tmp/root/a/meeting.m4a")
        let second = URL(fileURLWithPath: "/tmp/root/b/meeting.m4a")
        harness.candidates = [first, second]
        let coordinator = harness.makeCoordinator()
        await coordinator.search()
        await coordinator.adopt(second)
        #expect(coordinator.phase == .repaired)
        #expect(harness.relinked.map(\.url) == [second])
    }

    @Test func cancelReturnsToIdleWithoutStoreAccess() async {
        let harness = LegacyRelinkHarness()
        harness.candidates = [URL(fileURLWithPath: "/tmp/root/meeting.m4a")]
        let coordinator = harness.makeCoordinator()
        await coordinator.search()
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        #expect(harness.relinked.isEmpty)
    }

    @Test func rewriteFailureIsRetryable() async {
        struct ScriptedFailure: Error {}
        let harness = LegacyRelinkHarness()
        let match = URL(fileURLWithPath: "/tmp/root/meeting.m4a")
        harness.candidates = [match]
        harness.relinkError = ScriptedFailure()
        let coordinator = harness.makeCoordinator()
        await coordinator.search()
        await coordinator.adopt(match)
        guard case .saveFailed = coordinator.phase else {
            Issue.record("expected saveFailed, got \(coordinator.phase)")
            return
        }
        #expect(harness.relinked.isEmpty)
        harness.relinkError = nil
        await coordinator.search()
        await coordinator.adopt(match)
        #expect(coordinator.phase == .repaired)
        #expect(harness.relinked.count == 1)
    }

    /// The searching phase is visible while the walk runs, and a cancel
    /// during it drops the stale result instead of resurfacing it.
    @Test func searchShowsProgressAndCancelDropsTheStaleResult() async {
        let harness = LegacyRelinkHarness()
        harness.candidates = [URL(fileURLWithPath: "/tmp/root/meeting.m4a")]
        harness.holdSearch = true
        let coordinator = harness.makeCoordinator()
        let task = Task { await coordinator.search() }
        // Wait for the injected search to have actually started and
        // parked: releasing before the continuation is installed would
        // resume nothing and the child would wait forever.
        while !(harness.searchCalls == 1 && harness.hasParkedSearch) {
            await Task.yield()
        }
        #expect(coordinator.phase == .searching)
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        harness.releaseSearch()
        await task.value
        #expect(coordinator.phase == .idle)
        #expect(harness.relinked.isEmpty)
    }

    /// The rewrite shows a truthful in-flight phase; cancel is refused
    /// while it runs and the outcome still lands.
    @Test func relinkingPhaseIsVisibleWhileTheRewriteRuns() async {
        let harness = LegacyRelinkHarness()
        let match = URL(fileURLWithPath: "/tmp/root/meeting.m4a")
        harness.candidates = [match]
        harness.holdRelink = true
        let coordinator = harness.makeCoordinator()
        await coordinator.search()
        let task = Task { await coordinator.adopt(match) }
        while coordinator.phase != .relinking { await Task.yield() }
        coordinator.cancel()
        #expect(coordinator.phase == .relinking)
        harness.releaseRelink()
        await task.value
        #expect(coordinator.phase == .repaired)
        #expect(harness.relinked.count == 1)
    }

    /// Structural seal over the live search: the resolver root is awaited
    /// first, the filename walk runs only inside the detached task —
    /// never synchronously on the main actor — and the caller's
    /// cancellation is bridged into that task explicitly.
    @Test func liveSearchWalksInsideADetachedTaskWithCancellationBridged() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Cadenza/Services/Profiles/AudioRootRelink.swift"),
            encoding: .utf8
        )
        let function = try #require(source.range(of: "static func performLiveSearch"))
        let resolverAwait = try #require(source.range(
            of: "await store.resolver", range: function.upperBound..<source.endIndex
        ))
        let detached = try #require(source.range(
            of: "Task.detached", range: resolverAwait.upperBound..<source.endIndex
        ))
        let walk = try #require(source.range(
            of: "findFilesNamed(name, under: root)",
            range: detached.upperBound..<source.endIndex
        ))
        let bridge = try #require(source.range(
            of: "withTaskCancellationHandler",
            range: walk.upperBound..<source.endIndex
        ))
        _ = try #require(source.range(
            of: "walk.cancel()", range: bridge.upperBound..<source.endIndex
        ))
        #expect(detached.lowerBound < walk.lowerBound)
        // No synchronous walk in the live path outside the detached closure.
        #expect(!source.contains("return findFilesNamed"))
    }

    /// Cancelling stops the traversal itself, not merely its result: the
    /// injected walk exits only when it observes task cancellation.
    @Test func cancelStopsTheInFlightSearchTask() async {
        let harness = LegacyRelinkHarness()
        harness.spinUntilCancelled = true
        let coordinator = harness.makeCoordinator()
        let task = Task { await coordinator.search() }
        // The injected walk must be running before the cancel, so the
        // exit below can only come from observed cancellation.
        while harness.searchCalls == 0 { await Task.yield() }
        coordinator.cancel()
        await task.value
        #expect(harness.sawCancellation)
        #expect(coordinator.phase == .idle)
        #expect(harness.relinked.isEmpty)
    }

    /// The walker checks cancellation during traversal and exits
    /// promptly: under a cancelled task it returns nothing even though a
    /// matching file exists, while an uncancelled walk finds it.
    @Test func walkerExitsPromptlyOnceCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relink-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0x01]).write(to: root.appendingPathComponent("meeting.m4a"))

        let cancelled = await Task { () -> [URL] in
            withUnsafeCurrentTask { $0?.cancel() }
            return LegacyAudioRelinkCoordinator.findFilesNamed("meeting.m4a", under: root)
        }.value
        #expect(cancelled.isEmpty)
        #expect(
            LegacyAudioRelinkCoordinator.findFilesNamed("meeting.m4a", under: root).count == 1
        )
    }

    /// NFC and NFD spellings tie under String comparison; the byte order
    /// is total, so candidate presentation is deterministic either way.
    @Test func canonicallyEquivalentCandidatePathsSortInDeterministicByteOrder() {
        let nfc = "/tmp/root/caf\u{E9}.m4a"
        let nfd = "/tmp/root/cafe\u{301}.m4a"
        #expect(nfc == nfd)
        #expect(!LexicalPathIdentity.equals(nfc, nfd))
        let forward = [nfc, nfd].sorted { LexicalPathIdentity.isOrderedBefore($0, $1) }
        let backward = [nfd, nfc].sorted { LexicalPathIdentity.isOrderedBefore($0, $1) }
        #expect(forward.map { Array($0.utf8) } == backward.map { Array($0.utf8) })
        #expect(Array(forward[0].utf8) == Array(nfd.utf8))
        #expect(Array(forward[1].utf8) == Array(nfc.utf8))
    }

    /// Source gates over the detail surface: the repair is offered for
    /// playable and missing legacy files alike (never for relative rows),
    /// match copy uses literal catalog constructors, and candidate rows
    /// use byte-distinct identities.
    @Test func detailSurfaceGatesLegacyRepairAndCatalogSafety() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Cadenza/Views/Recordings/RecordingDetailView.swift"),
            encoding: .utf8
        )
        let player = try #require(source.range(of: "audioPlayerSection(detail)\n"))
        let residual = try #require(
            source.range(of: "legacyRelinkSection(audioFile, style: .residualLocation)")
        )
        #expect(player.lowerBound < residual.lowerBound)
        #expect(source.contains("legacyRelinkSection(audioFile, style: .missingFile)"))
        #expect(source.components(separatedBy: "if audioFile.isLegacy {").count - 1 == 2)
        #expect(!source.contains("Text(candidates.count"))
        #expect(source.contains("Text(\"Found a matching file:\")"))
        #expect(source.contains("Text(\"Several files share this name. Choose the exact one:\")"))
        #expect(source.contains("ForEach(Array(candidates.enumerated()), id: \\.offset)"))
        #expect(!source.contains("id: \\.path"))
    }
}
