import Foundation
import SwiftData
import Testing
import os

@testable import Cadenza

@MainActor
struct SessionMigrationTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_785_700_000)

    private struct Fixture {
        let base: URL
        let paths: ProfilePaths
        let suiteName: String
        let defaults: UserDefaults
        let registry: DiskProfileRegistry
        let secretStore: ThrowingSecretStore
        let userStores: SharedSessionUserStores
        let m1: M1StorageMigration.Dependencies
        let session: SessionMigrationDependencies

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// Session-user stores keyed by profile, shared across stages like the
    /// live per-profile files are.
    final class SharedSessionUserStores {
        private var stores: [UUID: EphemeralSessionUserStore] = [:]

        @MainActor func store(_ id: UUID) -> EphemeralSessionUserStore {
            if let existing = stores[id] { return existing }
            let created = EphemeralSessionUserStore()
            stores[id] = created
            return created
        }
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-migrations-\(UUID().uuidString)", isDirectory: true)
        let audioRoot = base.appendingPathComponent("AudioRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let paths = ProfilePaths(root: base.appendingPathComponent("Cadenza", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let suiteName = "session-migrations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let operations = LiveFileOperations()
        let registry = DiskProfileRegistry(
            registryURL: paths.registryURL, fileOperations: operations
        )
        let secretStore = ThrowingSecretStore()
        let userStores = SharedSessionUserStores()
        let m1 = M1StorageMigration.Dependencies(
            paths: paths,
            registry: registry,
            fileOperations: operations,
            backupDriver: LiveSQLiteBackupDriver(),
            audioRoot: { audioRoot },
            audioDirectoryState: { .init(bookmark: nil, path: audioRoot.path, kind: .userSelected) },
            scopedDefaults: ProfileScopedDefaults(
                defaults: defaults, persistentDomainName: suiteName
            ),
            now: { self.fixedNow }
        )
        let session = SessionMigrationDependencies(
            registry: registry,
            secretStore: secretStore,
            sessionUserStore: { userStores.store($0) },
            marker: SwiftDataHistoricalConsentMarker(),
            storeURL: { paths.storeURL($0) },
            storePresence: ProfileBindingTransaction.classifiedStorePresence(
                fileOperations: operations
            ),
            profileDirectoryPresence: { id in
                do {
                    _ = try operations.attributesOfItem(at: paths.profileDirectory(id))
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
            now: { self.fixedNow }
        )
        return Fixture(
            base: base, paths: paths, suiteName: suiteName, defaults: defaults,
            registry: registry, secretStore: secretStore, userStores: userStores,
            m1: m1, session: session
        )
    }

    /// Registry in the committed M1 shape: one standard profile owning a
    /// real store with `rows` recordings.
    private func establishM1State(
        _ fixture: Fixture, rows: Int = 2, bound: Profile.BoundAccount? = nil
    ) throws -> Profile {
        let profile = Profile(
            id: UUID(),
            kind: .standard,
            name: "Cadenza",
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(
                bookmark: nil, path: fixture.m1.audioRoot().path, kind: .userSelected
            ),
            boundAccount: bound,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, profiles: [profile]
        )
        try fixture.registry.save(document)
        let storeURL = fixture.paths.storeURL(profile.id)
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        for index in 0..<rows {
            context.insert(Recording(title: "R\(index)"))
        }
        try context.save()
        // The M1 mapping marker: the migrated profile's copy is complete.
        fixture.defaults.set(
            true,
            forKey: ProfileScopedDefaults.scopedKey(
                ProfileScopedDefaults.mappingMarkerKey, profileID: profile.id
            )
        )
        return profile
    }

    private func seedGlobalSession(
        _ fixture: Fixture,
        userID: String = "user-1",
        token: String? = "legacy-token",
        disclosure: Bool? = nil,
        uploadAudio: Bool? = nil
    ) throws {
        let user = CadenzaAuthService.SignedInUser(
            id: userID, email: "u@example.com", displayName: "U", pictureURL: nil
        )
        fixture.defaults.set(try JSONEncoder().encode(user), forKey: M2SessionMigration.globalUserKey)
        if let token {
            try fixture.secretStore.set(token, for: SessionTokenKey.legacyGlobalAccount)
        }
        if let disclosure {
            fixture.defaults.set(disclosure, forKey: "webSync.historicalDisclosure.v1.\(userID)")
        }
        if let uploadAudio {
            fixture.defaults.set(uploadAudio, forKey: "webSync.uploadAudio.v1.\(userID)")
        }
    }

    private func readMarks(_ fixture: Fixture, profileID: UUID) throws -> [UUID?] {
        let container = try RecordingsStore.makeContainer(
            storeURL: fixture.paths.storeURL(profileID)
        )
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<Recording>())
            .map(\.awaitingHistoricalConsentBindingID)
    }

    // MARK: - M2

    @Test func m2NothingToDoWithoutGlobalUser() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)

        #expect(M2SessionMigration.run(session: fixture.session) == .nothingToDo)
        let document = try fixture.registry.load()
        #expect(document.profiles.first { $0.id == profile.id }?.boundAccount == nil)
    }

    @Test func m2BindsM1ProfileMigratesTokenAndMapsConsent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture, rows: 2)
        try seedGlobalSession(fixture, disclosure: true, uploadAudio: false)

        let outcome = M2SessionMigration.run(session: fixture.session)
        #expect(outcome == .completed(profileID: profile.id))

        let document = try fixture.registry.load()
        let bound = try #require(document.profiles.first?.boundAccount)
        #expect(bound.userID == "user-1")
        #expect(bound.issuerOrigin == "https://cadenzapp.com:443")
        #expect(bound.apiBaseURL == "https://cadenzapp.com/api/v1")
        #expect(document.profiles.first?.sessionDisposition == .active)
        #expect(document.pendingBinding == nil)

        // Token moved to the per-profile slot; global keys retired.
        let account = SessionTokenKey.account(
            profileID: profile.id, originKey: bound.originKey
        )
        #expect(fixture.secretStore.get(account) == "legacy-token")
        #expect(fixture.secretStore.get(SessionTokenKey.legacyGlobalAccount) == nil)
        #expect(fixture.defaults.data(forKey: M2SessionMigration.globalUserKey) == nil)

        // Session user migrated, historical rows stamped, consent mapped.
        let user = try #require(try fixture.userStores.store(profile.id).load())
        #expect(user.userID == "user-1")
        let marks = try readMarks(fixture, profileID: profile.id)
        #expect(marks.count == 2 && marks.allSatisfy { $0 != nil })
        let scope = ProfileDefaultsScope(defaults: fixture.defaults, profileID: profile.id)
        #expect(HistoricalSyncConsent.read(from: scope) == .textOnly)
    }

    @Test func m2TokenlessSessionBindsAndPresentsExpired() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        try seedGlobalSession(fixture, token: nil)

        let outcome = M2SessionMigration.run(session: fixture.session)
        #expect(outcome == .completed(profileID: profile.id))

        let document = try fixture.registry.load()
        let migrated = try #require(document.profiles.first)
        let bound = try #require(migrated.boundAccount)
        let account = SessionTokenKey.account(profileID: profile.id, originKey: bound.originKey)
        #expect(fixture.secretStore.get(account) == nil)
        let state = ProfileSessionDerivation.authState(
            boundAccount: bound,
            sessionDisposition: migrated.sessionDisposition,
            tokenPresent: false
        )
        #expect(state == .expired)
        // The real boot factory derives the same state end to end.
        let service = try CadenzaAuthService.bootstrapped(
            sessionProfile: .init(profile: migrated),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: fixture.secretStore,
            sessionUserStore: fixture.userStores.store(profile.id),
            registry: fixture.registry
        )
        #expect(service.sessionState == .expired)
    }

    @Test func m2AbsentDisclosureStaysUndecided() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        try seedGlobalSession(fixture)

        _ = M2SessionMigration.run(session: fixture.session)
        let scope = ProfileDefaultsScope(defaults: fixture.defaults, profileID: profile.id)
        #expect(HistoricalSyncConsent.read(from: scope) == .undecided)
    }

    @Test func m2DisclosureWithAbsentAudioPreferenceFailsClosedToTextOnly() throws {
        // Only an explicitly-true audio preference maps to with-audio; an
        // absent key is not affirmative intent.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        try seedGlobalSession(fixture, disclosure: true)

        _ = M2SessionMigration.run(session: fixture.session)
        let scope = ProfileDefaultsScope(defaults: fixture.defaults, profileID: profile.id)
        #expect(HistoricalSyncConsent.read(from: scope) == .textOnly)
    }

    @Test func m2DisclosureWithExplicitAudioTrueMapsToWithAudio() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        try seedGlobalSession(fixture, disclosure: true, uploadAudio: true)

        _ = M2SessionMigration.run(session: fixture.session)
        let scope = ProfileDefaultsScope(defaults: fixture.defaults, profileID: profile.id)
        #expect(HistoricalSyncConsent.read(from: scope) == .withAudio)
    }

    @Test func m2NeverOverwritesExistingScopedConsent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        try seedGlobalSession(fixture, disclosure: true, uploadAudio: true)
        let scope = ProfileDefaultsScope(defaults: fixture.defaults, profileID: profile.id)
        HistoricalSyncConsent.textOnly.write(to: scope)

        _ = M2SessionMigration.run(session: fixture.session)
        #expect(HistoricalSyncConsent.read(from: scope) == .textOnly)
    }

    @Test func m2ReentryAfterCommittedBindingOnlyCleansGlobals() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let origin = CadenzaBackendConfig.official().origin
        let profile = try establishM1State(
            fixture,
            bound: Profile.BoundAccount(
                userID: "user-1", originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: "https://cadenzapp.com/api/v1",
                displayEmail: "u@example.com", displayName: "U", boundAt: fixedNow
            )
        )
        try seedGlobalSession(fixture)

        let outcome = M2SessionMigration.run(session: fixture.session)
        #expect(outcome == .completed(profileID: profile.id))
        #expect(fixture.secretStore.get(SessionTokenKey.legacyGlobalAccount) == nil)
        #expect(fixture.defaults.data(forKey: M2SessionMigration.globalUserKey) == nil)
        #expect(try fixture.registry.load().profiles.count == 1)
    }

    @Test func m2MalformedGlobalUserHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try establishM1State(fixture)
        fixture.defaults.set(Data("junk".utf8), forKey: M2SessionMigration.globalUserKey)

        guard case .halted = M2SessionMigration.run(session: fixture.session) else {
            Issue.record("expected halted")
            return
        }
        // The undecodable record survives for inspection.
        #expect(fixture.defaults.data(forKey: M2SessionMigration.globalUserKey) != nil)
    }

    @Test func m2WrongTypeGlobalUserRecordHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try establishM1State(fixture)

        for wrongTyped: Any in ["user-1", ["id": "user-1"]] {
            fixture.defaults.set(wrongTyped, forKey: M2SessionMigration.globalUserKey)
            guard case .halted = M2SessionMigration.run(session: fixture.session) else {
                Issue.record("expected halted for wrong-typed record \(wrongTyped)")
                return
            }
            // The record survives for inspection; nothing was bound.
            #expect(fixture.defaults.object(forKey: M2SessionMigration.globalUserKey) != nil)
            #expect(try fixture.registry.load().profiles.allSatisfy { $0.boundAccount == nil })
        }
    }

    @Test func m2UnreadableGlobalTokenHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try establishM1State(fixture)
        try seedGlobalSession(fixture, token: nil)
        fixture.secretStore.failClassifiedReads = true

        guard case .halted = M2SessionMigration.run(session: fixture.session) else {
            Issue.record("expected halted")
            return
        }
    }

    @Test func m2UnexpectedRegistryShapeHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = try establishM1State(fixture)
        var document = try fixture.registry.load()
        var second = document.profiles[0]
        second.id = UUID()
        document.profiles.append(second)
        try fixture.registry.save(document)
        try seedGlobalSession(fixture)

        guard case .halted = M2SessionMigration.run(session: fixture.session) else {
            Issue.record("expected halted")
            return
        }
        // Nothing was bound or deleted.
        #expect(fixture.secretStore.get(SessionTokenKey.legacyGlobalAccount) == "legacy-token")
        #expect(try fixture.registry.load().profiles.allSatisfy { $0.boundAccount == nil })
        _ = first
    }

    // MARK: - M3

    @Test func m3PromotesUnboundM1ProfileInPlace() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)

        let outcome = M3LocalMigration.run(session: fixture.session)
        #expect(outcome == .promoted(profileID: profile.id))

        let document = try fixture.registry.load()
        #expect(document.profiles.count == 1)
        let local = try #require(document.profiles.first)
        #expect(local.id == profile.id)
        #expect(local.kind == .system)
        #expect(local.name == "Local")
        #expect(local.audioDirectory == profile.audioDirectory)
        #expect(local.storeMaterialized == true)
        #expect(document.activeProfileID == profile.id)
    }

    @Test func m3CreatesEmptyLocalBesideBoundProfile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let origin = CadenzaBackendConfig.official().origin
        let account = try establishM1State(
            fixture,
            bound: Profile.BoundAccount(
                userID: "user-1", originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: "https://cadenzapp.com/api/v1",
                displayEmail: "u@example.com", displayName: "U", boundAt: fixedNow
            )
        )

        let outcome = M3LocalMigration.run(session: fixture.session)
        guard case .created(let localID) = outcome else {
            Issue.record("expected created, got \(outcome)")
            return
        }

        let document = try fixture.registry.load()
        #expect(document.profiles.count == 2)
        #expect(document.activeProfileID == account.id)
        let local = try #require(document.profiles.first { $0.id == localID })
        #expect(local.kind == .system)
        #expect(local.name == "Local")
        #expect(local.boundAccount == nil)
        #expect(local.isLocked == false)
        #expect(local.storeMaterialized == false)
        #expect(local.audioDirectory.kind == .appManaged)
        // Empty by construction: no store file, no profile directory, and
        // the scoped-preferences mapping marker blocks any global copy.
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.storeURL(localID).path))
        #expect(
            !FileManager.default.fileExists(atPath: fixture.paths.profileDirectory(localID).path)
        )
        let marker = ProfileScopedDefaults.scopedKey(
            ProfileScopedDefaults.mappingMarkerKey, profileID: localID
        )
        #expect(fixture.defaults.object(forKey: marker) as? Bool == true)
    }

    @Test func m3IsIdempotentOnceSystemProfileExists() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try establishM1State(fixture)
        #expect(M3LocalMigration.run(session: fixture.session) != .alreadyEstablished)
        #expect(M3LocalMigration.run(session: fixture.session) == .alreadyEstablished)
    }

    @Test func m3RepairsARenamedSystemLocal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        #expect(M3LocalMigration.run(session: fixture.session) == .promoted(profileID: profile.id))

        // The fixed name is not user-mutable; a divergent registry value is
        // repaired on the next establishment pass.
        var document = try fixture.registry.load()
        document.profiles[0].name = "Renamed"
        try fixture.registry.save(document)

        #expect(M3LocalMigration.run(session: fixture.session) == .alreadyEstablished)
        #expect(try fixture.registry.load().profiles.first?.name == "Local")
    }

    @Test func m3UnexpectedShapeHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try establishM1State(fixture)
        var document = try fixture.registry.load()
        var second = document.profiles[0]
        second.id = UUID()
        document.profiles.append(second)
        try fixture.registry.save(document)

        guard case .halted = M3LocalMigration.run(session: fixture.session) else {
            Issue.record("expected halted")
            return
        }
    }

    // MARK: - Pipeline

    @Test func pipelineUpgradesSignedInLegacyUserEndToEnd() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture, rows: 3)
        try seedGlobalSession(fixture, disclosure: true, uploadAudio: true)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(profile.id))
        #expect(context.profile?.id == profile.id)
        #expect(context.storeURL == fixture.paths.storeURL(profile.id))

        let document = try fixture.registry.load()
        #expect(document.profiles.count == 2)
        let account = try #require(document.profiles.first { $0.id == profile.id })
        #expect(account.boundAccount?.userID == "user-1")
        #expect(document.profiles.contains { $0.kind == .system && $0.name == "Local" })
        #expect(document.activeProfileID == profile.id)
        #expect(fixture.secretStore.get(SessionTokenKey.legacyGlobalAccount) == nil)
        #expect(fixture.defaults.data(forKey: M2SessionMigration.globalUserKey) == nil)
        let marks = try readMarks(fixture, profileID: profile.id)
        #expect(marks.count == 3 && marks.allSatisfy { $0 != nil })
        let scope = ProfileDefaultsScope(defaults: fixture.defaults, profileID: profile.id)
        #expect(HistoricalSyncConsent.read(from: scope) == .withAudio)
    }

    @Test func pipelineUpgradesUnsignedLegacyUserToLocal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture, rows: 2)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(profile.id))
        #expect(context.profile?.kind == .system)
        #expect(context.profile?.name == "Local")

        let document = try fixture.registry.load()
        #expect(document.profiles.count == 1)
        // Zero data movement, no consent marks: nothing was bound.
        let marks = try readMarks(fixture, profileID: profile.id)
        #expect(marks.allSatisfy { $0 == nil })
    }

    @Test func pipelineRecoversCrashedM2BindingAndConverges() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture, rows: 2)
        try seedGlobalSession(fixture)

        // Crash state: phases A+B durable, B2/C never ran, globals intact.
        let origin = CadenzaBackendConfig.official().origin
        let pending = PendingBinding(
            transactionID: UUID(),
            profileID: profile.id,
            userID: "user-1",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            tokenDigest: SessionTokenDigest.digest(of: "legacy-token"),
            startedAt: fixedNow
        )
        var document = try fixture.registry.load()
        document.pendingBinding = pending
        try fixture.registry.save(document)
        try fixture.secretStore.set(
            "legacy-token",
            for: SessionTokenKey.account(profileID: profile.id, originKey: origin.originKey)
        )
        try fixture.userStores.store(profile.id).save(
            SessionUser(
                userID: "user-1", email: "u@example.com", displayName: "U",
                pictureURL: nil, bindingTransactionID: pending.transactionID
            )
        )

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(profile.id))

        let converged = try fixture.registry.load()
        #expect(converged.pendingBinding == nil)
        #expect(converged.profiles.first { $0.id == profile.id }?.boundAccount?.userID == "user-1")
        #expect(converged.profiles.contains { $0.kind == .system })
        #expect(fixture.secretStore.get(SessionTokenKey.legacyGlobalAccount) == nil)
        #expect(fixture.defaults.data(forKey: M2SessionMigration.globalUserKey) == nil)
        let marks = try readMarks(fixture, profileID: profile.id)
        #expect(marks.allSatisfy { $0 == pending.transactionID })
    }

    @Test func pipelineFallsBackToLocalWhenActiveProfileIsLocked() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let origin = CadenzaBackendConfig.official().origin
        let account = try establishM1State(
            fixture,
            bound: Profile.BoundAccount(
                userID: "user-1", originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: "https://cadenzapp.com/api/v1",
                displayEmail: "u@example.com", displayName: "U", boundAt: fixedNow
            )
        )
        // Establish Local, then lock the account profile.
        guard case .created(let localID) = M3LocalMigration.run(session: fixture.session) else {
            Issue.record("local establishment failed")
            return
        }
        var document = try fixture.registry.load()
        let index = try #require(document.profiles.firstIndex { $0.id == account.id })
        document.profiles[index].isLocked = true
        try fixture.registry.save(document)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(localID))
        #expect(context.profile?.kind == .system)
        // The fallback is durable: the registry now records Local active.
        #expect(try fixture.registry.load().activeProfileID == localID)
    }

    @Test func registryPresentBootNeverResolvesLegacyAudioGlobals() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try establishM1State(fixture)

        // The legacy audio-root discovery is lazy: a committed-registry
        // boot must never evaluate it — those closures are the only path
        // to the global storage keys.
        let audioReads = OSAllocatedUnfairLock<Int>(initialState: 0)
        let dependencies = M1StorageMigration.Dependencies(
            paths: fixture.paths,
            registry: fixture.registry,
            fileOperations: LiveFileOperations(),
            backupDriver: LiveSQLiteBackupDriver(),
            audioRoot: {
                audioReads.withLock { $0 += 1 }
                return fixture.m1.audioRoot()
            },
            audioDirectoryState: {
                audioReads.withLock { $0 += 1 }
                return fixture.m1.audioDirectoryState()
            },
            scopedDefaults: fixture.m1.scopedDefaults,
            now: { self.fixedNow }
        )
        let context = ProfileBootstrap.runPipeline(
            dependencies: dependencies, session: fixture.session
        )
        guard case .profile = context.mode else {
            Issue.record("expected profile boot, got \(context.mode)")
            return
        }
        #expect(audioReads.withLock { $0 } == 0)
    }

    @Test func pipelineHaltsWhenBindingRecoveryHalts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        let origin = CadenzaBackendConfig.official().origin
        let pending = PendingBinding(
            transactionID: UUID(),
            profileID: profile.id,
            userID: "user-1",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            tokenDigest: SessionTokenDigest.digest(of: "expected-token"),
            startedAt: fixedNow
        )
        var document = try fixture.registry.load()
        document.pendingBinding = pending
        try fixture.registry.save(document)
        // Foreign occupant in the transaction's slot.
        try fixture.secretStore.set(
            "some-other-token",
            for: SessionTokenKey.account(profileID: profile.id, originKey: origin.originKey)
        )

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .halted = context.mode else {
            Issue.record("expected halted, got \(context.mode)")
            return
        }
        #expect(try fixture.registry.load().pendingBinding == pending)
    }
}

// MARK: - Upgrade-path completion (INV-16) and backend resolution (INV-6)

extension SessionMigrationTests {
    /// Skip-version end to end: a pre-registry legacy store plus a global
    /// session goes through M1 (storage), M2 (binding), and M3 (Local) in
    /// one boot. The account profile owns the migrated store under its
    /// profile directory; Local exists empty beside it.
    @Test func pipelineUpgradesLegacyStoreWithSessionEndToEnd() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // Legacy store with two recordings at the pre-registry location;
        // scoped so the container releases before the migration freezes
        // the source.
        try {
            let container = try RecordingsStore.makeContainer(
                storeURL: fixture.paths.legacyStoreURL
            )
            let context = ModelContext(container)
            context.insert(Recording(title: "Legacy A"))
            context.insert(Recording(title: "Legacy B"))
            try context.save()
        }()
        try seedGlobalSession(fixture, disclosure: true, uploadAudio: true)

        let bootContext = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        guard case .profile(let accountID) = bootContext.mode else {
            Issue.record("expected profile boot, got \(bootContext.mode)")
            return
        }

        let document = try fixture.registry.load()
        #expect(document.profiles.count == 2)
        let account = try #require(document.profiles.first { $0.id == accountID })
        #expect(account.boundAccount?.userID == "user-1")
        #expect(account.lockOnSignOut)
        let local = try #require(document.profiles.first { $0.kind == .system })
        #expect(local.name == "Local")
        #expect(!local.storeMaterialized)
        // Store isolation: the migrated store lives under the account
        // profile's directory; Local has no store yet.
        #expect(bootContext.storeURL == fixture.paths.storeURL(accountID))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.storeURL(accountID).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.storeURL(local.id).path))
        let marks = try readMarks(fixture, profileID: accountID)
        #expect(marks.count == 2 && marks.allSatisfy { $0 != nil })
        #expect(fixture.secretStore.get(SessionTokenKey.legacyGlobalAccount) == nil)
    }

    /// Upgrade with a token that is present but expired: the binding
    /// migrates the value verbatim and the profile boots `.expired` —
    /// never signed out, never locked (INV-3).
    @Test func m2ExpiredTokenBindsAndBootsExpired() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        let expired = StoredToken(
            value: "old", expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        try seedGlobalSession(
            fixture, token: try CadenzaAuthService.encodeTokenValue(expired)
        )

        let outcome = M2SessionMigration.run(session: fixture.session)
        #expect(outcome == .completed(profileID: profile.id))
        let migrated = try #require(try fixture.registry.load().profiles.first)
        #expect(migrated.boundAccount != nil)
        #expect(migrated.isLocked == false)
        let snapshot = try CadenzaAuthService.loadSessionSnapshot(
            sessionProfile: .init(profile: migrated),
            secretStore: fixture.secretStore,
            sessionUserStore: fixture.userStores.store(profile.id)
        )
        guard case .expired = snapshot.token else {
            Issue.record("expected expired evidence, got \(snapshot.token)")
            return
        }
    }
}

struct CadenzaBackendConfigTests {
    @Test func officialBackendResolvesCanonically() {
        let official = CadenzaBackendConfig.official()
        #expect(official.origin.normalized == "https://cadenzapp.com:443")
        #expect(official.apiBaseURL.absoluteString == "https://cadenzapp.com/api/v1")
    }

    @Test func configuredOverrideAppliesOnlyToNewLogins() throws {
        let suite = "backend-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Absent override: the official backend.
        #expect(try CadenzaBackendConfig.resolveForNewLogin(defaults: defaults)
            == CadenzaBackendConfig.official())

        defaults.set("https://self.example:8443/custom/api", forKey: CadenzaBackendConfig.defaultsKey)
        let resolved = try CadenzaBackendConfig.resolveForNewLogin(defaults: defaults)
        #expect(resolved.origin.normalized == "https://self.example:8443")
        #expect(resolved.apiBaseURL.absoluteString == "https://self.example:8443/custom/api")

        // An invalid override refuses the login instead of silently
        // substituting the official backend.
        defaults.set("not a url", forKey: CadenzaBackendConfig.defaultsKey)
        #expect(throws: CadenzaBackendConfig.ConfigurationError.self) {
            _ = try CadenzaBackendConfig.resolveForNewLogin(defaults: defaults)
        }
    }
}

// MARK: - Existing-user boot shapes and post-sign-out isolation

extension SessionMigrationTests {
    /// Valid-token existing user: the full pipeline plus the real boot
    /// factory land in a signed-in bound profile.
    @Test func pipelineWithValidTokenBootsSignedIn() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let profile = try establishM1State(fixture)
        let valid = StoredToken(value: "tok", expiresAt: Date().addingTimeInterval(86_400))
        try seedGlobalSession(
            fixture, token: try CadenzaAuthService.encodeTokenValue(valid)
        )

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(profile.id))
        let migrated = try #require(context.profile)
        #expect(migrated.boundAccount?.userID == "user-1")
        let service = try CadenzaAuthService.bootstrapped(
            sessionProfile: .init(profile: migrated),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: fixture.secretStore,
            sessionUserStore: fixture.userStores.store(profile.id),
            registry: fixture.registry
        )
        #expect(service.sessionState == .signedIn)
        #expect(service.currentUser?.id == "user-1")
    }

    /// Post-sign-out shape: the locked, explicitly signed-out account
    /// profile stays untouched while the system Local boots, records,
    /// and sees none of the account's data, session, or preferences.
    @Test func signedOutAccountBootsLocalRecordsAndKeepsAccountDataInvisible() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        let bound = Profile.BoundAccount(
            userID: "user-9",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "a@b.com",
            displayName: "A",
            boundAt: fixedNow
        )
        let account = try establishM1State(fixture, rows: 2, bound: bound)
        let accountTokenSlot = SessionTokenKey.account(
            profileID: account.id, originKey: bound.originKey
        )
        try fixture.secretStore.set("acct-token", for: accountTokenSlot)
        let accountScope = ProfileDefaultsScope(
            defaults: fixture.defaults, profileID: account.id
        )
        HistoricalSyncConsent.withAudio.write(to: accountScope)

        var document = try fixture.registry.load()
        document.profiles[0].sessionDisposition = .explicitlySignedOut
        document.profiles[0].isLocked = true
        let local = Profile(
            id: UUID(),
            kind: .system,
            name: "Local",
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(
                bookmark: nil,
                path: fixture.m1.audioRoot().appendingPathComponent("local").path,
                kind: .appManaged
            ),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: false,
            sessionDisposition: .active
        )
        document.profiles.append(local)
        document.activeProfileID = local.id
        try fixture.registry.save(document)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(local.id))
        #expect(context.profile?.kind == .system)
        let localStoreURL = try #require(context.storeURL)
        #expect(localStoreURL == fixture.paths.storeURL(local.id))

        // First materialization follows the production ordering:
        // container creation, then the durable flag, and only then any
        // user-data write. A failed flag save must stop the test here.
        let localContainer = try RecordingsStore.makeContainer(storeURL: localStoreURL)
        try ProfileBootstrap.recordStoreMaterialized(
            profileID: local.id, dependencies: fixture.m1
        )
        #expect(try fixture.registry.load()
            .profiles.first(where: { $0.id == local.id })?.storeMaterialized == true)
        let localContext = ModelContext(localContainer)
        localContext.insert(Recording(title: "Local A"))
        try localContext.save()
        let localRows = try localContext.fetch(FetchDescriptor<Recording>())
        #expect(localRows.count == 1)
        #expect(localRows.allSatisfy { $0.title == "Local A" })

        // The account's rows, token slot, and scoped consent survive
        // untouched and stay invisible from the Local side.
        let accountContext = ModelContext(
            try RecordingsStore.makeContainer(storeURL: fixture.paths.storeURL(account.id))
        )
        let accountRows = try accountContext.fetch(FetchDescriptor<Recording>())
        #expect(accountRows.count == 2)
        #expect(fixture.secretStore.get(accountTokenSlot) == "acct-token")
        let localScope = ProfileDefaultsScope(
            defaults: fixture.defaults, profileID: local.id
        )
        #expect(HistoricalSyncConsent.read(from: localScope) == .undecided)

        // Local's own session surface is unbound and signed out.
        let service = try CadenzaAuthService.bootstrapped(
            sessionProfile: .init(profile: try #require(context.profile)),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: fixture.secretStore,
            sessionUserStore: fixture.userStores.store(local.id),
            registry: fixture.registry
        )
        #expect(service.sessionState == .signedOut)
        #expect(service.currentUser == nil)
    }
}

// MARK: - Post-sign-out isolation across production surfaces

extension SessionMigrationTests {
    /// Spec 13 isolation regression, driven through the production entry
    /// points on the resolved stores: after sign-out the account's
    /// recordings appear in no list, search, MCP, mirror, or archive
    /// surface of the Local profile; Local records and its transcript
    /// persists through the production store sink (the coordinator's
    /// transcription flow over an injected store is covered by the
    /// post-processing suite); the real target-scoped unlock flow
    /// restores the account's data intact.
    @Test func postSignOutIsolationAcrossProductionSurfaces() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let origin = try IssuerOrigin(validating: "https://cadenzapp.com:443")
        let bound = Profile.BoundAccount(
            userID: "user-9",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "a@b.com",
            displayName: "A",
            boundAt: fixedNow
        )
        let account = try establishM1State(fixture, rows: 0, bound: bound)

        // Account data through the production store path, including a
        // transcript that search must never surface from Local.
        let accountRecordingID = UUID()
        do {
            let accountStore = RecordingsStore(
                modelContainer: try RecordingsStore.makeContainer(
                    storeURL: fixture.paths.storeURL(account.id)
                )
            )
            #expect(await accountStore.createRecording(
                id: accountRecordingID, title: "Account offsite",
                startDate: Date(), segmentsDirURL: nil
            ))
            #expect(await accountStore.saveTranscript(
                recordingID: accountRecordingID,
                fullText: "Confidential budget offsite discussion.",
                segments: [TranscriptEntry(
                    startTime: 0, endTime: 5,
                    text: "Confidential budget offsite discussion.", speaker: nil
                )],
                language: "en",
                tags: []
            ))
        }

        var document = try fixture.registry.load()
        document.profiles[0].sessionDisposition = .explicitlySignedOut
        document.profiles[0].isLocked = true
        let local = Profile(
            id: UUID(),
            kind: .system,
            name: "Local",
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(
                bookmark: nil,
                path: fixture.m1.audioRoot().appendingPathComponent("local").path,
                kind: .appManaged
            ),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: false,
            sessionDisposition: .active
        )
        document.profiles.append(local)
        document.activeProfileID = local.id
        try fixture.registry.save(document)

        let context = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(context.mode == .profile(local.id))
        let localStoreURL = try #require(context.storeURL)

        // Local records through the production store path, after the
        // first-materialization ordering; the transcript lands through
        // the same store sink the post-processing coordinator uses.
        let localStore = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(storeURL: localStoreURL)
        )
        try ProfileBootstrap.recordStoreMaterialized(
            profileID: local.id, dependencies: fixture.m1
        )
        let localRecordingID = UUID()
        #expect(await localStore.createRecording(
            id: localRecordingID, title: "Local sync",
            startDate: Date(), segmentsDirURL: nil
        ))
        #expect(await localStore.saveTranscript(
            recordingID: localRecordingID,
            fullText: "Weekly local sync notes.",
            segments: [TranscriptEntry(
                startTime: 0, endTime: 4, text: "Weekly local sync notes.", speaker: nil
            )],
            language: "en",
            tags: []
        ))

        // List: only Local rows.
        let list = await localStore.fetchRecordingDTOs(
            sortKey: "date", folderID: nil, tagFilter: nil
        )
        #expect(list.map(\.title) == ["Local sync"])

        // Search: account content is unreachable, Local content is found.
        let accountHits = await localStore.searchRecordingDTOs(
            query: "offsite", sortKey: "date", folderID: nil, tagFilter: nil
        )
        #expect(accountHits.isEmpty)
        let localHits = await localStore.searchRecordingDTOs(
            query: "local sync", sortKey: "date", folderID: nil, tagFilter: nil
        )
        #expect(localHits.map(\.id) == [localRecordingID])

        // MCP list and search over the resolved store.
        let mcp = MCPToolRegistry(store: localStore, writesEnabled: { false })
        let mcpList = await mcp.call(name: "list_recordings", arguments: [:])
        #expect(!mcpList.isError)
        #expect(mcpList.text.contains("Local sync"))
        #expect(!mcpList.text.contains("Account offsite"))
        let mcpSearch = await mcp.call(
            name: "search_transcripts", arguments: ["query": "offsite"]
        )
        #expect(!mcpSearch.isError)
        #expect(!mcpSearch.text.contains("Confidential"))

        // The real mirror service, rebuilt into a scratch directory.
        let mirrorDir = fixture.base.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mirrorDir, withIntermediateDirectories: true
        )
        let mirror = MarkdownMirrorService(
            store: localStore,
            defaultsSuiteName: fixture.suiteName,
            ledgerKey: "mirror-ledger-probe",
            directoryProvider: { mirrorDir }
        )
        _ = await mirror.rebuildAll(includeTranscript: true)
        let mirrorFiles = try FileManager.default.contentsOfDirectory(atPath: mirrorDir.path)
            .filter { $0.hasSuffix(".md") }
        #expect(mirrorFiles.count == 1)
        #expect(mirrorFiles.allSatisfy { $0.contains(localRecordingID.uuidString) })
        let mirrorContent = try String(
            contentsOf: mirrorDir.appendingPathComponent(try #require(mirrorFiles.first)),
            encoding: .utf8
        )
        #expect(mirrorContent.contains("Weekly local sync notes."))
        #expect(!mirrorContent.contains("Confidential"))

        // The real archive writer, fed by the exact production source
        // closure AppState installs — resolved store plus the resolved
        // profile's own chat directory.
        let localChatDir = try #require(context.chatHistoryDirectory)
        try Data("local chat payload".utf8).write(
            to: localChatDir.appendingPathComponent("local-chat.json")
        )
        let accountChatDir = fixture.paths.chatHistoryDirectory(account.id)
        try FileManager.default.createDirectory(
            at: accountChatDir, withIntermediateDirectories: true
        )
        try Data("account secret chat".utf8).write(
            to: accountChatDir.appendingPathComponent("account-chat.json")
        )
        let appState = AppState()
        appState.store = localStore
        appState.profileBootContext = context
        let makeSource = try #require(appState.exportService.archiveExporter.makeSource)
        let archiveParent = fixture.base.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: archiveParent, withIntermediateDirectories: true
        )
        let archiveResult = try await PortableArchiveWriter.write(
            toParent: archiveParent, source: makeSource()
        )
        #expect(archiveResult.recordingCount == 1)
        var archiveText = ""
        let enumerator = try #require(FileManager.default.enumerator(
            at: archiveResult.archiveURL, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            archiveText += (try? String(contentsOf: item, encoding: .utf8)) ?? ""
        }
        #expect(archiveText.contains("Weekly local sync notes."))
        #expect(archiveText.contains("local chat payload"))
        #expect(!archiveText.contains("Confidential"))
        #expect(!archiveText.contains("account secret chat"))
        #expect(!archiveText.contains(accountRecordingID.uuidString))

        // Correct re-login through the real target-scoped unlock flow:
        // authorization against the account's frozen backend, byte-exact
        // identity, then the unlock commit and artifact writes.
        let http = FakeAuthHTTP()
        let exchangeJSON = """
        {
          "token": "tok-2",
          "expires_at": \(Int(Date().addingTimeInterval(86_400).timeIntervalSince1970)),
          "user": { "id": "user-9", "email": "a@b.com", "display_name": "A", "picture": null }
        }
        """
        http.enqueue(.success(
            data: Data(exchangeJSON.utf8),
            response: HTTPURLResponse(
                url: URL(string: "https://cadenzapp.com")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
        ))
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.first(where: { $0.name == "state" })!.value!
            return URL(
                string: "com.shuiandy.cadenza://auth/cadenza/callback?code=abc&state=\(state)"
            )!
        }
        let auth = try CadenzaAuthService.bootstrapped(
            sessionProfile: .ephemeralUnbound(),
            http: http,
            authorizer: authorizer,
            secretStore: InMemoryAuthSecretStore(),
            sessionUserStore: EphemeralSessionUserStore()
        )
        let relaunched = OSAllocatedUnfairLock(initialState: false)
        let coordinator = ProfileLoginCoordinator(dependencies: .init(
            auth: auth,
            registry: fixture.registry,
            secretStore: fixture.secretStore,
            sessionUserStore: { fixture.userStores.store($0) },
            marker: SwiftDataHistoricalConsentMarker(),
            storeURL: { fixture.paths.storeURL($0) },
            storePresence: ProfileBindingTransaction.classifiedStorePresence(
                fileOperations: LiveFileOperations()
            ),
            defaults: fixture.defaults,
            activeStore: .init(
                markAll: { _ in
                    HistoricalMarkResult(newlyMarked: 0, previouslyMarked: 0, total: 0)
                },
                clearMarks: { _ in 0 }
            ),
            activeProfile: try #require(context.profile),
            now: { self.fixedNow },
            relaunch: { relaunched.withLock { $0 = true } },
            transferRelaunch: { relaunched.withLock { $0 = true } },
            haltTransition: { _ in },
            transitionRefusal: { nil },
            prepareTransition: { true },
            resumeAfterRefusedTransition: { },
            beginTransfer: { _ in
                throw ProfileTransfer.TransferError.preflight(.targetMissing)
            }
        ))
        await coordinator.beginUnlock(of: account.id)
        guard case .accountAlreadyBound(let targetID, _) = coordinator.step,
              targetID == account.id else {
            Issue.record("expected accountAlreadyBound, got \(coordinator.step)")
            return
        }
        await coordinator.switchToExistingProfile()
        #expect(coordinator.step == .relaunching)
        #expect(relaunched.withLock { $0 })

        let restored = ProfileBootstrap.runPipeline(
            dependencies: fixture.m1, session: fixture.session
        )
        #expect(restored.mode == .profile(account.id))
        let restoredStore = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(
                storeURL: try #require(restored.storeURL)
            )
        )
        let restoredList = await restoredStore.fetchRecordingDTOs(
            sortKey: "date", folderID: nil, tagFilter: nil
        )
        #expect(restoredList.map(\.title) == ["Account offsite"])
        let restoredHits = await restoredStore.searchRecordingDTOs(
            query: "offsite", sortKey: "date", folderID: nil, tagFilter: nil
        )
        #expect(restoredHits.map(\.id) == [accountRecordingID])
        let service = try CadenzaAuthService.bootstrapped(
            sessionProfile: .init(profile: try #require(restored.profile)),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: fixture.secretStore,
            sessionUserStore: fixture.userStores.store(account.id),
            registry: fixture.registry
        )
        #expect(service.sessionState == .signedIn)
    }
}
