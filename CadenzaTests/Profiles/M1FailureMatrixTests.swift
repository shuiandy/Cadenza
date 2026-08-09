import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Cadenza

/// §9.3 failure matrix for M1 plus the full-graph integrity gate and
/// the auth-untouched guarantee. Complements the happy-path and
/// boundary tests in `M1StorageMigrationTests`.
@Suite("M1 Failure Matrix", .serialized)
struct M1FailureMatrixTests {

    struct Fixture {
        let base: URL
        let paths: ProfilePaths
        let audioRoot: URL
        let defaults: UserDefaults
        let suiteName: String

        func dependencies(
            fileOperations: any FileOperations = LiveFileOperations(),
            backupDriver: any SQLiteBackupDriver = LiveSQLiteBackupDriver()
        ) -> M1StorageMigration.Dependencies {
            M1StorageMigration.Dependencies(
                paths: paths,
                registry: DiskProfileRegistry(
                    registryURL: paths.registryURL, fileOperations: fileOperations
                ),
                fileOperations: fileOperations,
                backupDriver: backupDriver,
                audioRoot: { audioRoot },
                audioDirectoryState: { .init(
                    bookmark: nil, path: audioRoot.path, kind: .userSelected
                ) },
                scopedDefaults: ProfileScopedDefaults(defaults: defaults, persistentDomainName: suiteName),
                now: { Date(timeIntervalSince1970: 1_785_628_800) }
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: paths.root.path
            )
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1-matrix-\(UUID().uuidString)", isDirectory: true)
        let audioRoot = base.appendingPathComponent("AudioRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let suiteName = "m1-matrix-\(UUID().uuidString)"
        return Fixture(
            base: base, paths: paths, audioRoot: audioRoot,
            defaults: UserDefaults(suiteName: suiteName)!, suiteName: suiteName
        )
    }

    @MainActor
    private func populateMinimalSource(_ fixture: Fixture) throws {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let context = ModelContext(container)
        let recording = Recording(id: UUID(), title: "minimal")
        recording.audioFilePath = fixture.audioRoot.appendingPathComponent("a.m4a").path
        context.insert(recording)
        try context.save()
    }

    // MARK: - Full-graph integrity

    /// Builds every entity type with full field coverage, migrates, and
    /// compares complete raw snapshots: the product must equal the source
    /// transformed by exactly the two declared normalizations. Also proves
    /// auth material sitting in the same defaults store is neither copied
    /// nor modified.
    @Test @MainActor
    func migrationPreservesTheFullGraphExactly() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let stamp = Date(timeIntervalSince1970: 1_785_000_000)
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let context = ModelContext(container)

        let parent = Folder(name: "Parent", icon: "folder", iconColor: "blue",
                            colorHex: "#00FF00", status: "active", sortOrder: 1)
        let child = Folder(name: "Child", icon: "building.2", iconColor: "purple",
                           colorHex: nil, status: "archived", sortOrder: 2)
        child.parentFolder = parent
        context.insert(parent)
        context.insert(child)

        let profile = SpeakerProfile(displayName: "Zoe", notes: "notes", teamOrOrg: "Acme")
        profile.aliases = ["Z"]
        profile.createdAt = stamp
        profile.lastSeenAt = stamp
        context.insert(profile)

        let full = Recording(id: UUID(), title: "full-graph", startDate: stamp,
                             language: "en", source: .captured)
        full.endDate = stamp.addingTimeInterval(600)
        full.duration = 600
        full.audioFilePath = fixture.audioRoot.appendingPathComponent("nested/full.m4a").path
        full.audioSegmentsDirectory = fixture.audioRoot
            .appendingPathComponent("nested/segments").path
        full.meetingApp = "Teams"
        full.meetingURL = "https://example.invalid/meet"
        full.meetingType = "standup"
        full.tags = ["tag1", "tag2"]
        full.lastAccessedDate = stamp
        full.linkedCalendarEventID = "evt-1"
        full.calendarAutoLinkState = "linked"
        full.calendarAutoLinkAttemptedAt = stamp
        full.speakerMappings = [SpeakerLabelMapping(rawLabel: "S1", profileID: profile.id)]
        full.speakerSuggestions = [SpeakerLabelSuggestion(
            rawLabel: "S1", profileID: profile.id, score: 0.5,
            strategy: "voice", modelVersion: "v1", generatedAt: stamp
        )]
        full.processingAttempts = 2
        full.postProcessingBackfillState = "pending"
        full.postProcessingBackfillRequestedAt = stamp
        full.postProcessingBackfillFailureCount = 1
        full.postProcessingBackfillLastError = "boom"
        full.folder = child
        full.transcript = Transcript(fullText: "line one", segments: [
            TranscriptEntry(startTime: 1, endTime: 2, text: "line one", speaker: "S1")
        ])
        full.transcript?.detectedLanguage = "en"
        full.transcript?.createdAt = stamp
        let summary = MeetingSummary(
            overview: "overview", keyPoints: ["kp"],
            actionItems: [ActionItem(assignee: "Zoe", task: "do", deadline: "Mon",
                                     isCompleted: false, priority: .high,
                                     createdAt: stamp, updatedAt: stamp)],
            decisions: ["d"], followUps: ["f"], yourTasks: ["y"],
            model: "m", language: "en"
        )
        summary.provider = "openai"
        summary.createdAt = stamp
        summary.chaptersJSON = "[{\"title\":\"c\"}]"
        full.summary = summary
        context.insert(full)

        let legacyOutside = Recording(id: UUID(), title: "outside", startDate: stamp)
        legacyOutside.audioFilePath = "/elsewhere/out.m4a"
        legacyOutside.trashedDate = stamp
        context.insert(legacyOutside)

        let sample = SpeakerVoiceSample(
            recordingID: full.id, rawLabel: "S1", profile: profile,
            embeddingData: Data([1, 2, 3]), embeddingDimension: 3,
            sampleDuration: 4.5, nonOverlapRatio: 0.8, qualityScore: 0.9,
            modelVersion: "v1"
        )
        sample.createdAt = stamp
        context.insert(sample)

        let external = ExternalRecordingImport(
            externalKey: "prov:1", provider: "prov", externalID: "1",
            sourceTitle: "ext", sourceStartDate: stamp, sourceDuration: 60,
            sourceCalendarEventID: "evt-x", sourceCreatedAt: stamp,
            sourceUpdatedAt: stamp, lastSeenAt: stamp, disposition: .imported
        )
        external.recording = full
        context.insert(external)

        let recap = Recap(
            id: UUID(), period: "weekly", startDate: stamp,
            endDate: stamp.addingTimeInterval(86_400), title: "Recap",
            overview: "ov", sections: [], stats: RecapStats(),
            recordingIDs: [full.id], allActionItems: ["a"], allDecisions: ["d"],
            provider: "openai"
        )
        recap.createdAt = stamp
        context.insert(recap)

        context.insert(AgentArtifact(
            id: UUID(), kind: "meetingPrep", targetType: "meeting", targetKey: "k",
            slotKey: "slot-1", bodyMarkdown: "body", provenanceSource: "builtin",
            provenanceDetail: "detail", status: "ready", generationID: nil,
            generatingStartedAt: nil, errorClass: nil, errorMessage: nil,
            lastAttemptedAt: nil, retryAfter: nil, targetStartDate: stamp,
            targetEndDate: stamp.addingTimeInterval(3600), targetFingerprint: "fp",
            contextBuiltAt: stamp, staleReason: nil, createdAt: stamp, updatedAt: stamp
        ))

        let webSync = WebSyncRecord(userID: "user-1", recordingID: full.id)
        webSync.remoteRecordingID = "remote-1"
        webSync.structuredState = "synced"
        webSync.structuredHash = "h"
        webSync.audioState = "uploaded"
        webSync.attemptCount = 3
        webSync.syncedAt = stamp
        context.insert(webSync)

        try context.save()
        let sourceSnapshot = try MigrationStoreSnapshot.capture(container: container)

        // Auth material in the same defaults store must survive untouched
        // and never be copied to a scoped key.
        fixture.defaults.set(Data("auth-sentinel".utf8), forKey: "cadenza.session.user.json")

        let bootContext = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = bootContext.mode else {
            Issue.record("expected profile boot, got \(bootContext.mode)")
            return
        }

        let product = try MigrationStoreSnapshot.capture(
            storeURL: fixture.paths.storeURL(id)
        )
        let expected = sourceSnapshot.expectedAfterM1(audioRootPath: fixture.audioRoot.path)
        #expect(product == expected)
        // The rewrite actually happened where provable and nowhere else.
        let byTitle = Dictionary(
            uniqueKeysWithValues: product.recordings.map { ($0.title.string, $0) }
        )
        #expect(byTitle["full-graph"]?.audioFilePath?.string == "nested/full.m4a")
        #expect(byTitle["full-graph"]?.audioSegmentsDirectory?.string == "nested/segments")
        #expect(byTitle["outside"]?.audioFilePath?.string == "/elsewhere/out.m4a")

        #expect(fixture.defaults.data(forKey: "cadenza.session.user.json")
            == Data("auth-sentinel".utf8))
        let scopedAuthKeys = fixture.defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("profile.") && $0.contains("cadenza.session") }
        #expect(scopedAuthKeys.isEmpty)
    }

    // MARK: - Disk space

    @Test @MainActor
    func preflightRejectsInsufficientDiskSpace() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let operations = InstrumentedFileOperations(capacityOverride: 1024)

        let context = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .legacyFallback = context.mode else {
            Issue.record("expected legacy fallback, got \(context.mode)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        #expect(DiskProfileRegistry(
            registryURL: fixture.paths.registryURL, fileOperations: LiveFileOperations()
        ).presence() == .absent)
    }

    @Test @MainActor
    func midOperationDiskFullRollsBackAndRetrySucceeds() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        // The staging copy of the snapshot artifact hits ENOSPC.
        let operations = InstrumentedFileOperations(failCopyNames: ["Cadenza.store"])

        let failed = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .legacyFallback = failed.mode else {
            Issue.record("expected legacy fallback, got \(failed.mode)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))

        let retried = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = retried.mode else {
            Issue.record("expected profile boot, got \(retried.mode)")
            return
        }
        let counts = try StoreSnapshotter.readEntityCounts(
            storeURL: fixture.paths.storeURL(id)
        )
        #expect(counts["Recording"] == 1)
    }

    // MARK: - Journal state boundaries

    /// Dying at each pre-commit journal transition (started,
    /// snapshotVerified, staged, targetVerified) leaves the source
    /// untouched and the registry unwritten; the next launch restarts from
    /// scratch and completes with the data intact.
    @Test @MainActor
    func interruptionAtEveryPreCommitJournalBoundaryResumes() throws {
        for boundary in 1...4 {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateMinimalSource(fixture)
            let operations = InstrumentedFileOperations(failJournalWriteAtCount: boundary)

            let failed = ProfileBootstrap.run(
                dependencies: fixture.dependencies(fileOperations: operations)
            )
            guard case .legacyFallback = failed.mode else {
                Issue.record("boundary \(boundary): expected legacy fallback, got \(failed.mode)")
                return
            }
            #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
            #expect(DiskProfileRegistry(
                registryURL: fixture.paths.registryURL, fileOperations: LiveFileOperations()
            ).presence() == .absent)

            let retried = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = retried.mode else {
                Issue.record("boundary \(boundary): expected profile boot, got \(retried.mode)")
                return
            }
            let counts = try StoreSnapshotter.readEntityCounts(
                storeURL: fixture.paths.storeURL(id)
            )
            #expect(counts["Recording"] == 1)
            let journal = try MigrationJournalStore(
                paths: fixture.paths, fileOperations: LiveFileOperations()
            ).load()
            #expect(journal?.m1?.state == .done)
            // Idempotency after the recovered boundary: a further launch
            // reproduces the same outcome exactly.
            let third = ProfileBootstrap.run(dependencies: fixture.dependencies())
            #expect(third == retried)
        }
    }

    /// A crash during the registry write itself is still pre-commit: no
    /// registry on disk, the retry completes.
    @Test @MainActor
    func commitWriteFailureStaysPreCommitAndRetries() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let operations = InstrumentedFileOperations(failWriteNames: ["profiles.json"])

        let failed = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .legacyFallback = failed.mode else {
            Issue.record("expected legacy fallback, got \(failed.mode)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))

        let retried = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = retried.mode else {
            Issue.record("expected profile boot, got \(retried.mode)")
            return
        }
    }

    /// A failed journal write AFTER the registry commit must not demote
    /// the boot to legacy: the profile is the authority and the retire
    /// converges on the next launch.
    @Test @MainActor
    func postCommitJournalFailureKeepsProfileAuthority() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        // Journal write #5 is the registryCommitted transition.
        let operations = InstrumentedFileOperations(failJournalWriteAtCount: 5)

        let first = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // Registry committed; source not yet retired.
        #expect(DiskProfileRegistry(
            registryURL: fixture.paths.registryURL, fileOperations: LiveFileOperations()
        ).presence() == .present)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        #expect(second.mode == .profile(id))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        let journal = try MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        ).load()
        #expect(journal?.m1?.state == .done)
    }

    // MARK: - Filesystem conditions

    @Test @MainActor
    func readOnlyMigrationRootFailsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: fixture.paths.root.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.paths.root.path
            )
        }

        let context = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .legacyFallback(let reason) = context.mode else {
            Issue.record("expected legacy fallback, got \(context.mode)")
            return
        }
        // The failure must actually stem from the read-only root, not from
        // an unrelated later step.
        #expect(reason.contains("migration directory"))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
    }

    @Test @MainActor
    func corruptedSourceStoreAbortsWithSourceIntact() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let garbage = Data("definitely not a sqlite database".utf8)
        try garbage.write(to: fixture.paths.legacyStoreURL)

        let context = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .legacyFallback = context.mode else {
            Issue.record("expected legacy fallback, got \(context.mode)")
            return
        }
        #expect(try Data(contentsOf: fixture.paths.legacyStoreURL) == garbage)
    }

    // MARK: - Skip-version upgrade (INV-16)

    /// A pre-Cadenza-directory install (`default.store` beside the Cadenza
    /// folder) migrates directly into the profile layout in one hop.
    @MainActor
    private func populateStore(at url: URL, titles: [String]) throws {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        for title in titles {
            context.insert(Recording(id: UUID(), title: title))
        }
        try context.save()
    }

    @Test @MainActor
    func skipVersionUpgradeMigratesDefaultStoreDirectly() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateStore(at: fixture.paths.preLegacyStoreURL, titles: ["ancient"])

        let bootContext = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = bootContext.mode else {
            Issue.record("expected profile boot, got \(bootContext.mode)")
            return
        }
        let counts = try StoreSnapshotter.readEntityCounts(
            storeURL: fixture.paths.storeURL(id)
        )
        #expect(counts["Recording"] == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.preLegacyStoreURL.path))
        let retained = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.preLegacyStoreURL.deletingLastPathComponent().path
        ).filter { $0.hasPrefix("default.store.migrated-") }
        #expect(retained.count == 1)
    }

    // MARK: - Untrusted journal and target validation

    /// A journal whose sourceStorePath points at an arbitrary SQLite file
    /// must never cause that file to be touched: the retire source is
    /// re-derived from the whitelist, so the foreign file stays byte-for-
    /// byte intact.
    @Test @MainActor
    func maliciousJournalPathCannotRetireForeignSQLite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }

        // A foreign SQLite database outside every whitelisted location.
        let foreign = fixture.base.appendingPathComponent("foreign.sqlite")
        let foreignContainer = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: foreign)
        )
        let foreignContext = ModelContext(foreignContainer)
        foreignContext.insert(Recording(id: UUID(), title: "foreign"))
        try foreignContext.save()
        let foreignHash = try LiveFileOperations().sha256(of: foreign)

        // Rewind the journal to registryCommitted with the malicious path.
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        var record = try #require(try journalStore.load()?.m1)
        record.state = .registryCommitted
        record.sourceStorePath = foreign.path
        try journalStore.save(MigrationJournalDocument(version: 1, m1: record))

        _ = ProfileBootstrap.run(dependencies: fixture.dependencies())
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(try LiveFileOperations().sha256(of: foreign) == foreignHash)
        _ = foreignContainer
    }

    /// Registry re-establishment from a committed journal requires a fully
    /// validated target: absent, tampered, and partial targets all fail
    /// closed with the source preserved and no registry written.
    @Test @MainActor
    func committedJournalWithoutValidTargetFailsClosed() throws {
        for sabotage in ["absent", "tampered", "partial"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateMinimalSource(fixture)
            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = first.mode else {
                Issue.record("\(sabotage): expected profile boot, got \(first.mode)")
                return
            }
            // Reconstruct the crash shape: registry gone, journal
            // committed, source back at its original name.
            try FileManager.default.removeItem(at: fixture.paths.registryURL)
            let retiredName = try #require(try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.root.path
            ).first { $0.hasPrefix("Cadenza.store.migrated-") })
            try FileManager.default.moveItem(
                at: fixture.paths.root.appendingPathComponent(retiredName),
                to: fixture.paths.legacyStoreURL
            )
            let journalStore = MigrationJournalStore(
                paths: fixture.paths, fileOperations: LiveFileOperations()
            )
            var record = try #require(try journalStore.load()?.m1)
            record.state = .registryCommitted
            try journalStore.save(MigrationJournalDocument(version: 1, m1: record))

            let storeURL = fixture.paths.storeURL(id)
            switch sabotage {
            case "absent":
                try FileManager.default.removeItem(at: fixture.paths.profileDirectory(id))
            case "tampered":
                // Extra row: entity counts diverge from the receipt.
                let container = try ModelContainer(
                    for: RecordingsStore.schema,
                    configurations: ModelConfiguration(url: storeURL)
                )
                let context = ModelContext(container)
                context.insert(Recording(id: UUID(), title: "injected"))
                try context.save()
            default:
                // Partial: store truncated to garbage.
                try Data("partial".utf8).write(to: storeURL)
            }

            let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted = second.mode else {
                Issue.record("\(sabotage): expected halted boot, got \(second.mode)")
                return
            }
            #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
            #expect(fixture.dependencies().registry.presence() == .absent)
        }
    }

    /// An unreadable registry never yields a legacy boot — even with
    /// multiple profile directories on disk. With a validated journal and
    /// target it recovers; without them it halts.
    @Test @MainActor
    func unreadableRegistryNeverBootsLegacy() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // Corrupt the registry: recovery via the journal + validated
        // target must re-establish the SAME profile.
        try Data("not json".utf8).write(to: fixture.paths.registryURL)
        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        #expect(second.mode == .profile(id))
        #expect(try fixture.dependencies().registry.load().activeProfileID == id)

        // A second (stray) profile directory is later-authority residue:
        // the journal cannot describe it, so an unreadable registry must
        // halt rather than rebuild the single-profile shape over it.
        let strayID = UUID()
        try FileManager.default.createDirectory(
            at: fixture.paths.profileDirectory(strayID), withIntermediateDirectories: true
        )
        try Data("stray".utf8).write(to: fixture.paths.storeURL(strayID))
        try Data("not json".utf8).write(to: fixture.paths.registryURL)
        let residueBlocked = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .halted(let residueReason) = residueBlocked.mode else {
            Issue.record("expected halted boot, got \(residueBlocked.mode)")
            return
        }
        #expect(residueReason.contains("later authority residue"))
        try FileManager.default.removeItem(at: fixture.paths.profileDirectory(strayID))
        let afterCleanup = ProfileBootstrap.run(dependencies: fixture.dependencies())
        #expect(afterCleanup.mode == .profile(id))

        // Corrupt the registry AND the journal: no recovery path — the
        // boot halts; it must not fall back to legacy.
        try Data("not json".utf8).write(to: fixture.paths.registryURL)
        try Data("not json".utf8).write(to: fixture.paths.journalURL)
        let third = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .halted = third.mode else {
            Issue.record("expected halted boot, got \(third.mode)")
            return
        }
        #expect(third.storeURL == nil)
    }

    // MARK: - Resumed retire evidence

    /// A logical write to the source between launches must keep the
    /// duplicate: the recorded content digest no longer matches, so the
    /// resumed retire refuses to rename.
    @Test @MainActor
    func resumedRetireKeepsDuplicateAfterLogicalSourceWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // Un-retire the source and rewind the journal, then perform a real
        // logical write to the source — the "old app instance wrote after
        // commit" scenario.
        let retiredName = try #require(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.root.path
        ).first { $0.hasPrefix("Cadenza.store.migrated-") })
        try FileManager.default.moveItem(
            at: fixture.paths.root.appendingPathComponent(retiredName),
            to: fixture.paths.legacyStoreURL
        )
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        var record = try #require(try journalStore.load()?.m1)
        record.state = .registryCommitted
        record.retireGeneration = nil
        try journalStore.save(MigrationJournalDocument(version: 1, m1: record))

        let writerContainer = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let writerContext = ModelContext(writerContainer)
        let fetched = try writerContext.fetch(FetchDescriptor<Recording>())
        fetched.first?.title = "modified-after-commit"
        try writerContext.save()

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        // Profile stays the authority; the modified source is preserved
        // under its original name and the journal stays short of done.
        #expect(second.mode == .profile(id))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        #expect(try journalStore.load()?.m1?.state != .done)
        _ = writerContainer
    }

    // MARK: - Retire rename protocol

    /// The retired artifact is a single self-contained database file under
    /// ONE recorded generation: the checkpoint folds the WAL into the base
    /// before the rename, the content-free source sidecars are removed,
    /// and the artifact converts to rollback-journal mode so a strictly
    /// read-only consumer can open it.
    @Test @MainActor
    func retiredArtifactIsSingleSelfContainedFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)

        let boot = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = boot.mode else {
            Issue.record("expected profile boot, got \(boot.mode)")
            return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.root.path)
            .filter { $0.contains(".migrated-") }.sorted()
        #expect(names.count == 1)
        let baseName = try #require(names.first)
        #expect(baseName.range(
            of: #"^Cadenza\.store\.migrated-\d+$"#, options: .regularExpression
        ) != nil)
        // Source sidecars are gone along with the base.
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.legacyStoreURL.path + "-wal"
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.paths.legacyStoreURL.path + "-shm"
        ))
        let generation = Int(baseName.replacingOccurrences(
            of: "Cadenza.store.migrated-", with: ""
        ))
        let journal = try MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        ).load()
        #expect(journal?.m1?.retireGeneration == generation)

        // The retired artifact carries the full content on its own: its
        // logical digest equals the one recorded under the freeze lease at
        // migration time.
        let digest = try SQLiteLogicalDigest.digest(
            of: fixture.paths.root.appendingPathComponent(baseName)
        )
        #expect(digest == journal?.m1?.sourceContentDigest)
    }

    /// Injected failure at the base-rename boundary keeps state
    /// recoverable: the next launch reuses the recorded generation and
    /// converges.
    @Test @MainActor
    func retireRenameBoundaryFailureRecovers() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)

        let operations = FailingRenameFileOperations(failSourceNames: ["Cadenza.store"])
        let first = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        #expect(try journalStore.load()?.m1?.state == .registryCommitted)
        let recordedGeneration = try journalStore.load()?.m1?.retireGeneration
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        #expect(second.mode == .profile(id))
        #expect(try journalStore.load()?.m1?.state == .done)
        #expect(try journalStore.load()?.m1?.retireGeneration == recordedGeneration)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
    }

    /// Same-second collision: occupied target names push the CHOSEN
    /// generation forward before anything is renamed — never a mixed
    /// generation, never an overwrite.
    @Test @MainActor
    func retireGenerationSkipsOccupiedNames() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // Resume shape with the generation not yet chosen, and a foreign
        // occupant sitting on the first candidate name (fixed `now` makes
        // it known). The retired base from the first run IS that occupant
        // once moved aside; use a fresh foreign file to prove exclusivity.
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        var record = try #require(try journalStore.load()?.m1)
        let retiredName = try #require(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.root.path
        ).first { $0.hasPrefix("Cadenza.store.migrated-") })
        try FileManager.default.moveItem(
            at: fixture.paths.root.appendingPathComponent(retiredName),
            to: fixture.paths.legacyStoreURL
        )
        record.state = .registryCommitted
        record.retireGeneration = nil
        try journalStore.save(MigrationJournalDocument(version: 1, m1: record))
        let occupied = fixture.paths.root
            .appendingPathComponent("Cadenza.store.migrated-1785628800")
        try Data("occupant".utf8).write(to: occupied)

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = second.mode else {
            Issue.record("expected profile boot, got \(second.mode)")
            return
        }
        #expect(try Data(contentsOf: occupied) == Data("occupant".utf8))
        let journal = try journalStore.load()
        #expect(journal?.m1?.state == .done)
        #expect(journal?.m1?.retireGeneration == 1_785_628_801)
    }

    /// SQLite has released the source vnode before the filesystem rename;
    /// the retired-content digest remains the post-rename proof.
    @Test @MainActor
    func retireRenameClosesSQLiteLeaseBeforeFilesystemMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let probe = WriterProbeFileOperations(probePath: fixture.paths.legacyStoreURL.path)

        let boot = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: probe)
        )
        guard case .profile = boot.mode else {
            Issue.record("expected profile boot, got \(boot.mode)")
            return
        }
        #expect(probe.probeResults.contains(.acquired))
        #expect(!probe.probeResults.contains(.busy))
    }

    // MARK: - Journal integrity at bootstrap

    /// Malformed and symlinked journals are corruption, not absence: the
    /// migration refuses to run over them (source untouched, journal file
    /// preserved for diagnosis).
    @Test @MainActor
    func malformedJournalFailsClosedWithoutOverwriting() throws {
        for shape in ["garbage", "symlink"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateMinimalSource(fixture)
            try FileManager.default.createDirectory(
                at: fixture.paths.migrationDirectory, withIntermediateDirectories: true
            )
            let original: Data
            if shape == "garbage" {
                original = Data("{{{not json".utf8)
                try original.write(to: fixture.paths.journalURL)
            } else {
                let elsewhere = fixture.base.appendingPathComponent("elsewhere.json")
                original = Data("{\"version\":1}".utf8)
                try original.write(to: elsewhere)
                try FileManager.default.createSymbolicLink(
                    at: fixture.paths.journalURL, withDestinationURL: elsewhere
                )
            }

            let boot = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted(let reason) = boot.mode else {
                Issue.record("\(shape): expected halted boot, got \(boot.mode)")
                return
            }
            #expect(reason.contains("journal"))
            #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
            #expect(fixture.dependencies().registry.presence() == .absent)
            if shape == "garbage" {
                #expect(try Data(contentsOf: fixture.paths.journalURL) == original)
            }
        }
    }

    /// A real external SQLite writer transaction (raw connection, BEGIN
    /// IMMEDIATE) blocks the migration fail-closed.
    @Test @MainActor
    func externalSQLiteWriterLockFailsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)

        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(
            fixture.paths.legacyStoreURL.path, &writer, SQLITE_OPEN_READWRITE, nil
        ) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        // The fixture container may still be inside its asynchronous
        // close-time checkpoint; wait it out before taking the lock.
        sqlite3_busy_timeout(writer, 5000)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { _ = sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let boot = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .legacyFallback = boot.mode else {
            Issue.record("expected legacy fallback, got \(boot.mode)")
            return
        }
        #expect(fixture.dependencies().registry.presence() == .absent)
    }

    // MARK: - Source probe classification

    /// A source whose metadata cannot be read is NOT a missing source: the
    /// migration must fail closed instead of committing a fresh empty
    /// profile over data it merely could not see.
    @Test @MainActor
    func unreadableSourceMetadataNeverBecomesFreshInstall() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let operations = InstrumentedFileOperations(failAttributeNames: ["Cadenza.store"])

        let boot = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .legacyFallback = boot.mode else {
            Issue.record("expected legacy fallback, got \(boot.mode)")
            return
        }
        #expect(fixture.dependencies().registry.presence() == .absent)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.profilesDirectory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
    }

    /// The sidecar sweep runs only on a DEFINITE base not-found: a base
    /// whose probe errors may be a live database, and its WAL must stay.
    @Test @MainActor
    func sidecarSweepKeepsWALWhenBaseProbeFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // Shape a pending retire whose base probe errors while a WAL
        // exists beside the (retired) base path.
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        var record = try #require(try journalStore.load()?.m1)
        record.state = .registryCommitted
        try journalStore.save(MigrationJournalDocument(version: 1, m1: record))
        let wal = URL(fileURLWithPath: fixture.paths.legacyStoreURL.path + "-wal")
        try Data("wal-bytes".utf8).write(to: wal)

        let operations = InstrumentedFileOperations(failAttributeNames: ["Cadenza.store"])
        _ = ProfileBootstrap.run(dependencies: fixture.dependencies(fileOperations: operations))
        #expect(FileManager.default.fileExists(atPath: wal.path))
        #expect(try Data(contentsOf: wal) == Data("wal-bytes".utf8))
    }

    // MARK: - Target content digest

    /// Source with a recording and a Recap (Recap is outside the counted
    /// entity set). Scoped so the container releases before any bootstrap
    /// takes the source lease.
    @MainActor
    private func populateRecapSource(_ fixture: Fixture) throws {
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let context = ModelContext(container)
        context.insert(Recording(id: UUID(), title: "kept"))
        let recap = Recap(
            id: UUID(), period: "weekly",
            startDate: Date(timeIntervalSince1970: 1), endDate: Date(timeIntervalSince1970: 2),
            title: "recap", overview: "o", sections: [], stats: RecapStats(),
            recordingIDs: [], allActionItems: [], allDecisions: [], provider: "p"
        )
        context.insert(recap)
        try context.save()
    }

    /// Sabotage helper, scoped for the same reason.
    @MainActor
    private func sabotageTarget(at storeURL: URL, sabotage: String) throws {
        let target = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: storeURL)
        )
        let targetContext = ModelContext(target)
        if sabotage == "uncounted-entity" {
            let recaps = try targetContext.fetch(FetchDescriptor<Recap>())
            for found in recaps { targetContext.delete(found) }
        } else {
            let recordings = try targetContext.fetch(FetchDescriptor<Recording>())
            recordings.first?.title = "tampered"
        }
        try targetContext.save()
    }

    /// The target digest binds entities the count check never sees and
    /// fields that leave counts unchanged: registry re-establishment must
    /// refuse both sabotages.
    @Test @MainActor
    func targetDigestBindsUncountedEntitiesAndFields() throws {
        for sabotage in ["uncounted-entity", "same-count-field"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateRecapSource(fixture)

            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = first.mode else {
                Issue.record("\(sabotage): expected profile boot, got \(first.mode)")
                return
            }
            // Registry lost, journal committed, source back in place.
            try FileManager.default.removeItem(at: fixture.paths.registryURL)
            let retiredName = try #require(try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.root.path
            ).first { $0.hasPrefix("Cadenza.store.migrated-") })
            try FileManager.default.moveItem(
                at: fixture.paths.root.appendingPathComponent(retiredName),
                to: fixture.paths.legacyStoreURL
            )
            let journalStore = MigrationJournalStore(
                paths: fixture.paths, fileOperations: LiveFileOperations()
            )
            var record = try #require(try journalStore.load()?.m1)
            record.state = .registryCommitted
            try journalStore.save(MigrationJournalDocument(version: 1, m1: record))

            // Sabotage the target while keeping every counted total intact.
            try sabotageTarget(at: fixture.paths.storeURL(id), sabotage: sabotage)

            let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted = second.mode else {
                Issue.record("\(sabotage): expected halted boot, got \(second.mode)")
                return
            }
            #expect(fixture.dependencies().registry.presence() == .absent)
            #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        }
    }

    // MARK: - Resume-source strictness

    /// When the recorded source is gone, the resume must not switch to a
    /// different whitelisted file — even one with identical content.
    @Test @MainActor
    func resumeNeverSwitchesToAnotherWhitelistedFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // The recorded source is retired (gone from its original name);
        // plant an identical-content file at the OTHER whitelisted path.
        let retiredName = try #require(try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.root.path
        ).first { $0.hasPrefix("Cadenza.store.migrated-") })
        try FileManager.default.copyItem(
            at: fixture.paths.root.appendingPathComponent(retiredName),
            to: fixture.paths.preLegacyStoreURL
        )
        let decoyBytes = try Data(contentsOf: fixture.paths.preLegacyStoreURL)
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        var record = try #require(try journalStore.load()?.m1)
        record.state = .registryCommitted
        try journalStore.save(MigrationJournalDocument(version: 1, m1: record))

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = second.mode else {
            Issue.record("expected profile boot, got \(second.mode)")
            return
        }
        // The decoy stayed byte-for-byte in place and was never renamed.
        #expect(FileManager.default.fileExists(atPath: fixture.paths.preLegacyStoreURL.path))
        #expect(try Data(contentsOf: fixture.paths.preLegacyStoreURL) == decoyBytes)
        #expect(try journalStore.load()?.m1?.state == .done)
    }

    // MARK: - Artifact permissions

    /// The snapshot artifact is owner-only from birth to receipt.
    @Test @MainActor
    func snapshotArtifactIsOwnerOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let boot = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = boot.mode else {
            Issue.record("expected profile boot, got \(boot.mode)")
            return
        }
        let artifact = fixture.paths.migrationDirectory
            .appendingPathComponent("snapshots/m1/Cadenza.store")
        let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    // MARK: - Boot-target validation

    /// A committed registry whose migrated store is missing or unreadable
    /// must halt before any container opens — SwiftData would otherwise
    /// materialize an empty database and present the data as gone. A
    /// fresh-install profile stays free to materialize.
    @Test @MainActor
    func bootHaltsWhenMigratedStoreIsMissingOrTampered() throws {
        for sabotage in ["missing", "tampered"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateMinimalSource(fixture)
            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = first.mode else {
                Issue.record("\(sabotage): expected profile boot, got \(first.mode)")
                return
            }
            let storeURL = fixture.paths.storeURL(id)
            if sabotage == "missing" {
                try FileManager.default.removeItem(at: storeURL)
            } else {
                try Data("garbage".utf8).write(to: storeURL)
            }
            let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted = second.mode else {
                Issue.record("\(sabotage): expected halted boot, got \(second.mode)")
                return
            }
            #expect(second.storeURL == nil)
        }

        // Fresh install: the missing store may materialize only until the
        // registry records the first materialization.
        let fresh = try makeFixture()
        defer { fresh.cleanup() }
        let first = ProfileBootstrap.run(dependencies: fresh.dependencies())
        let second = ProfileBootstrap.run(dependencies: fresh.dependencies())
        guard case .profile = second.mode else {
            Issue.record("fresh: expected profile boot, got \(second.mode)")
            return
        }
        #expect(first == second)
    }

    /// The materialization boundary is one-time and durable: after the
    /// container exists, the flag flips, and user data lands, a lost store
    /// — or the loss of the whole profile directory — halts the boot
    /// instead of silently recreating an empty database. A failed flag
    /// write surfaces as an error so the caller can halt before anything
    /// becomes writable.
    @Test @MainActor
    func freshMaterializationBoundaryIsOneTimeAndDurable() throws {
        for loss in ["store-only", "whole-directory"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = first.mode, let storeURL = first.storeURL else {
                Issue.record("\(loss): expected profile boot, got \(first.mode)")
                return
            }
            // Materialize the store the way startup does: container first,
            // flag immediately after, data only then.
            try populateStore(at: storeURL, titles: ["first-note"])
            try ProfileBootstrap.recordStoreMaterialized(
                profileID: id, dependencies: fixture.dependencies()
            )
            #expect(try fixture.dependencies().registry.load()
                .profiles.first?.storeMaterialized == true)

            if loss == "store-only" {
                try FileManager.default.removeItem(at: storeURL)
            } else {
                try FileManager.default.removeItem(at: fixture.paths.profileDirectory(id))
            }
            let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted = second.mode else {
                Issue.record("\(loss): expected halted boot, got \(second.mode)")
                return
            }
            #expect(second.storeURL == nil)
        }

        // A failed flag write throws; the startup wiring halts on it and
        // never proceeds to a writable state.
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let boot = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = boot.mode else {
            Issue.record("expected profile boot, got \(boot.mode)")
            return
        }
        let failing = fixture.dependencies(
            fileOperations: InstrumentedFileOperations(failWriteNames: ["profiles.json"])
        )
        #expect(throws: (any Error).self) {
            try ProfileBootstrap.recordStoreMaterialized(profileID: id, dependencies: failing)
        }
        #expect(try fixture.dependencies().registry.load()
            .profiles.first?.storeMaterialized == false)
    }

    /// Without a readable registry the materialization state is unknown:
    /// a fresh-install journal must not permit re-creating a missing
    /// store, and a valid target re-establishes the registry as a durable
    /// artifact.
    @Test @MainActor
    func registryLossNeverRelicensesFreshMaterialization() throws {
        // Fresh journal + lost registry + absent store: halted.
        let fresh = try makeFixture()
        defer { fresh.cleanup() }
        let boot = ProfileBootstrap.run(dependencies: fresh.dependencies())
        guard case .profile = boot.mode else {
            Issue.record("expected profile boot, got \(boot.mode)")
            return
        }
        try FileManager.default.removeItem(at: fresh.paths.registryURL)
        let relost = ProfileBootstrap.run(dependencies: fresh.dependencies())
        guard case .halted = relost.mode else {
            Issue.record("expected halted boot, got \(relost.mode)")
            return
        }

        // Migrated profile + lost registry + valid target: the registry is
        // rebuilt durably and the boot proceeds.
        let migrated = try makeFixture()
        defer { migrated.cleanup() }
        try populateMinimalSource(migrated)
        let first = ProfileBootstrap.run(dependencies: migrated.dependencies())
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        try FileManager.default.removeItem(at: migrated.paths.registryURL)
        let second = ProfileBootstrap.run(dependencies: migrated.dependencies())
        #expect(second.mode == .profile(id))
        let rebuilt = try migrated.dependencies().registry.load()
        #expect(rebuilt.activeProfileID == id)
        #expect(rebuilt.profiles.first?.storeMaterialized == true)

        // Migrated profile + lost registry + missing target: halted, and
        // the registry is NOT rebuilt.
        try FileManager.default.removeItem(at: migrated.paths.registryURL)
        try FileManager.default.removeItem(at: migrated.paths.storeURL(id))
        let third = ProfileBootstrap.run(dependencies: migrated.dependencies())
        guard case .halted = third.mode else {
            Issue.record("expected halted boot, got \(third.mode)")
            return
        }
        #expect(migrated.dependencies().registry.presence() == .absent)
    }

    /// Registry re-establishment must produce the durable artifact: a
    /// failing registry write halts instead of proceeding for one session.
    @Test @MainActor
    func registryReestablishmentWriteFailureHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        try FileManager.default.removeItem(at: fixture.paths.registryURL)
        let failing = fixture.dependencies(
            fileOperations: InstrumentedFileOperations(failWriteNames: ["profiles.json"])
        )
        let second = ProfileBootstrap.run(dependencies: failing)
        guard case .halted = second.mode else {
            Issue.record("expected halted boot, got \(second.mode)")
            return
        }
    }

    /// An unprobeable registry is routed to the unreadable-registry
    /// recovery, never to a fresh migration: with a complete journal and a
    /// valid target the boot recovers the same profile.
    @Test @MainActor
    func unprobeableRegistryNeverStartsFreshMigration() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        let unprobeable = fixture.dependencies(
            fileOperations: InstrumentedFileOperations(failAttributeNames: ["profiles.json"])
        )
        let second = ProfileBootstrap.run(dependencies: unprobeable)
        #expect(second.mode == .profile(id))
        // The journal stayed at done — no migration restarted.
        let journal = try MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        ).load()
        #expect(journal?.m1?.state == .done)
        #expect(journal?.m1?.profileID == id)
    }

    /// A fresh-install journal for a DIFFERENT profile never licenses the
    /// active profile's missing store: the materialization boundary is
    /// bound to the registry's own per-profile state.
    @Test @MainActor
    func foreignFreshJournalNeverExemptsActiveProfile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = first.mode else {
            Issue.record("expected profile boot, got \(first.mode)")
            return
        }
        // Replace the journal with a fresh-install-shaped record for a
        // different profile and remove the active store.
        let journalStore = MigrationJournalStore(
            paths: fixture.paths, fileOperations: LiveFileOperations()
        )
        let foreign = MigrationJournalDocument.M1Record(
            state: .done, profileID: UUID(), sourceStorePath: "",
            receipt: nil, sourceEvidence: nil,
            rewrittenReferenceCount: 0, retainedLegacyCount: 0,
            sourceContentDigest: nil, targetContentDigest: nil,
            retireGeneration: nil
        )
        try journalStore.save(MigrationJournalDocument(version: 1, m1: foreign))
        try FileManager.default.removeItem(at: fixture.paths.storeURL(id))

        let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .halted = second.mode else {
            Issue.record("expected halted boot, got \(second.mode)")
            return
        }
    }

    /// Present-but-unprobeable chat history must abort the migration
    /// before commit — skipping it would lose the data silently.
    @Test @MainActor
    func unprobeableChatHistoryAbortsPreCommit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try populateMinimalSource(fixture)
        try FileManager.default.createDirectory(
            at: fixture.paths.legacyChatHistoryDirectory, withIntermediateDirectories: true
        )
        let sessionFile = fixture.paths.legacyChatHistoryDirectory
            .appendingPathComponent("s1.json")
        try Data("{\"id\":1}".utf8).write(to: sessionFile)

        let operations = InstrumentedFileOperations(failAttributeNames: ["ChatHistory"])
        let boot = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .legacyFallback = boot.mode else {
            Issue.record("expected legacy fallback, got \(boot.mode)")
            return
        }
        #expect(fixture.dependencies().registry.presence() == .absent)
        #expect(try Data(contentsOf: sessionFile) == Data("{\"id\":1}".utf8))
    }

    /// An unprobeable WAL sidecar must fail evidence capture instead of
    /// silently dropping the node from the evidence.
    @Test @MainActor
    func unprobeableWALFailsEvidenceCapture() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // Keep the container open so the WAL exists during capture.
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let context = ModelContext(container)
        context.insert(Recording(id: UUID(), title: "wal-holder"))
        try context.save()

        let operations = InstrumentedFileOperations(
            failAttributeNames: ["Cadenza.store-wal"]
        )
        let boot = ProfileBootstrap.run(
            dependencies: fixture.dependencies(fileOperations: operations)
        )
        guard case .legacyFallback = boot.mode else {
            Issue.record("expected legacy fallback, got \(boot.mode)")
            return
        }
        #expect(fixture.dependencies().registry.presence() == .absent)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
        _ = container
    }

    // MARK: - Commit evidence without a registry

    /// Byte fingerprints of every authority artifact a broken boot must
    /// leave untouched.
    private func authorityFingerprints(
        _ fixture: Fixture, profileID: UUID
    ) throws -> (target: String, retired: String?) {
        let live = LiveFileOperations()
        let target = try live.sha256(of: fixture.paths.storeURL(profileID))
        let retiredName = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.root.path
        ).first { $0.hasPrefix("Cadenza.store.migrated-") }
        let retired = try retiredName.map {
            try live.sha256(of: fixture.paths.root.appendingPathComponent($0))
        }
        return (target, retired)
    }

    /// With the registry definitively absent, an UNREADABLE journal, an
    /// unprobeable migration directory, or a held migration lock is
    /// unknown commit evidence: the boot halts, and neither a legacy store
    /// nor a new registry may appear while the committed target and the
    /// retired source stay byte-identical.
    @Test @MainActor
    func unknownCommitEvidenceWithoutRegistryHalts() throws {
        for obstacle in ["journal-unprobeable", "migration-dir-unprobeable", "lock-held"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateMinimalSource(fixture)
            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = first.mode else {
                Issue.record("\(obstacle): expected profile boot, got \(first.mode)")
                return
            }
            let before = try authorityFingerprints(fixture, profileID: id)
            try FileManager.default.removeItem(at: fixture.paths.registryURL)

            let dependencies: M1StorageMigration.Dependencies
            var externalLock: Int32 = -1
            switch obstacle {
            case "journal-unprobeable":
                dependencies = fixture.dependencies(
                    fileOperations: InstrumentedFileOperations(
                        failAttributeNames: ["journal.json"]
                    )
                )
            case "migration-dir-unprobeable":
                dependencies = fixture.dependencies(
                    fileOperations: InstrumentedFileOperations(
                        failAttributeNames: ["Migration"]
                    )
                )
            default:
                let lockPath = fixture.paths.migrationDirectory
                    .appendingPathComponent("lock").path
                externalLock = open(lockPath, O_CREAT | O_RDWR, 0o600)
                #expect(externalLock >= 0)
                #expect(flock(externalLock, LOCK_EX | LOCK_NB) == 0)
                dependencies = fixture.dependencies()
            }
            defer {
                if externalLock >= 0 {
                    flock(externalLock, LOCK_UN)
                    close(externalLock)
                }
            }

            let second = ProfileBootstrap.run(dependencies: dependencies)
            guard case .halted = second.mode else {
                Issue.record("\(obstacle): expected halted boot, got \(second.mode)")
                return
            }
            #expect(fixture.dependencies().registry.presence() == .absent)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.legacyStoreURL.path))
            let after = try authorityFingerprints(fixture, profileID: id)
            #expect(after.target == before.target)
            #expect(after.retired == before.retired)
        }
    }

    /// Registry and journal both definitively missing is still not proof
    /// of never-committed: profile-directory residue or a retired source
    /// artifact halts the boot — no fresh profile, no new registry, no
    /// orphaned data.
    @Test @MainActor
    func committedResidueWithoutRegistryOrJournalHalts() throws {
        for wipe in ["journal-only", "whole-migration-dir"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try populateMinimalSource(fixture)
            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile(let id) = first.mode else {
                Issue.record("\(wipe): expected profile boot, got \(first.mode)")
                return
            }
            let before = try authorityFingerprints(fixture, profileID: id)
            try FileManager.default.removeItem(at: fixture.paths.registryURL)
            if wipe == "journal-only" {
                try FileManager.default.removeItem(at: fixture.paths.journalURL)
            } else {
                try FileManager.default.removeItem(at: fixture.paths.migrationDirectory)
            }

            let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted = second.mode else {
                Issue.record("\(wipe): expected halted boot, got \(second.mode)")
                return
            }
            #expect(fixture.dependencies().registry.presence() == .absent)
            let children = try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.profilesDirectory.path
            )
            #expect(children == [id.uuidString])
            let after = try authorityFingerprints(fixture, profileID: id)
            #expect(after.target == before.target)
            #expect(after.retired == before.retired)
        }
    }

    /// A retired source artifact alone — target and profiles directory
    /// gone too — still proves a past commit and halts, for both
    /// whitelisted source spellings.
    @Test @MainActor
    func retiredArtifactAloneHaltsFreshMigration() throws {
        for spelling in ["legacy", "pre-legacy"] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            if spelling == "legacy" {
                try populateMinimalSource(fixture)
            } else {
                try populateStore(at: fixture.paths.preLegacyStoreURL, titles: ["ancient"])
            }
            let first = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .profile = first.mode else {
                Issue.record("\(spelling): expected profile boot, got \(first.mode)")
                return
            }
            try FileManager.default.removeItem(at: fixture.paths.registryURL)
            try FileManager.default.removeItem(at: fixture.paths.migrationDirectory)
            try FileManager.default.removeItem(at: fixture.paths.profilesDirectory)

            let second = ProfileBootstrap.run(dependencies: fixture.dependencies())
            guard case .halted = second.mode else {
                Issue.record("\(spelling): expected halted boot, got \(second.mode)")
                return
            }
            #expect(fixture.dependencies().registry.presence() == .absent)
            #expect(!FileManager.default.fileExists(atPath: fixture.paths.profilesDirectory.path))
        }
    }

    /// Materialization is bound to the ACTIVE profile: a foreign or stale
    /// identifier throws and leaves the registry unchanged.
    @Test @MainActor
    func materializationRejectsNonActiveProfiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let boot = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile = boot.mode else {
            Issue.record("expected profile boot, got \(boot.mode)")
            return
        }
        let before = try fixture.dependencies().registry.load()
        #expect(throws: ProfileRegistryError.self) {
            try ProfileBootstrap.recordStoreMaterialized(
                profileID: UUID(), dependencies: fixture.dependencies()
            )
        }
        #expect(try fixture.dependencies().registry.load() == before)
    }

    /// Pending WAL content from a container that stays OPEN through the
    /// whole migration is captured (backup API, not file copy).
    @Test @MainActor
    func openSourceContainerWithPendingWALMigratesCompletely() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let container = try ModelContainer(
            for: RecordingsStore.schema,
            configurations: ModelConfiguration(url: fixture.paths.legacyStoreURL)
        )
        let context = ModelContext(container)
        for index in 0..<5 {
            context.insert(Recording(id: UUID(), title: "wal-\(index)"))
        }
        try context.save()

        let bootContext = ProfileBootstrap.run(dependencies: fixture.dependencies())
        guard case .profile(let id) = bootContext.mode else {
            Issue.record("expected profile boot, got \(bootContext.mode)")
            return
        }
        let counts = try StoreSnapshotter.readEntityCounts(
            storeURL: fixture.paths.storeURL(id)
        )
        #expect(counts["Recording"] == 5)
        _ = container
    }
}
