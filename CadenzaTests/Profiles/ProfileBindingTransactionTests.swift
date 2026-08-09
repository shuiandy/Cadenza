import Foundation
import SwiftData
import Testing
import os

@testable import Cadenza

/// Registry double with scripted save failures, sharing the real coders
/// and validation so every persisted shape is invariant-checked.
final class ScriptedRegistry: ProfileRegistryProviding, Sendable {
    struct State: Sendable {
        var document: ProfileRegistryDocument?
        var saveCount = 0
        var loadCount = 0
        var failSaveAt: Set<Int> = []
        /// Save numbers that throw only after persisting — the
        /// "indeterminate persistence" shape of an atomic-write error.
        var persistThenThrowAt: Set<Int> = []
        /// Save numbers that persist a mutated document and throw — the
        /// "third shape" a concurrent writer could leave behind.
        var thirdShapeOnSaveAt: Set<Int> = []
        /// Same, but the drift is only a canonical-equivalence respelling
        /// (NFC to NFD) that synthesized String equality cannot see.
        var nfdShapeOnSaveAt: Set<Int> = []
        var failLoad = false
        var failLoadAt: Set<Int> = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(document: ProfileRegistryDocument? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(document: document))
    }

    func configure(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var saveCount: Int { state.withLock { $0.saveCount } }

    func presence() -> RegistryPresence {
        state.withLock { $0.document != nil } ? .present : .absent
    }

    func load() throws -> ProfileRegistryDocument {
        let (document, fail) = state.withLock { current in
            current.loadCount += 1
            let fail = current.failLoad || current.failLoadAt.contains(current.loadCount)
            return (current.document, fail)
        }
        if fail { throw ProfileRegistryError.malformedDocument("scripted load failure") }
        guard let document else {
            throw ProfileRegistryError.malformedDocument("no document")
        }
        try document.validate()
        return document
    }

    func save(_ document: ProfileRegistryDocument) throws {
        try document.validateForSave()
        let data = try ProfileRegistryCoding.makeEncoder().encode(document)
        let decoded = try ProfileRegistryCoding.makeDecoder().decode(
            ProfileRegistryDocument.self, from: data
        )
        try state.withLock { current in
            current.saveCount += 1
            if current.failSaveAt.contains(current.saveCount) {
                throw ProfileRegistryError.malformedDocument("scripted save failure")
            }
            if current.persistThenThrowAt.contains(current.saveCount) {
                current.document = decoded
                throw ProfileRegistryError.malformedDocument("scripted post-persist failure")
            }
            if current.thirdShapeOnSaveAt.contains(current.saveCount) {
                var third = decoded
                third.profiles[0].name += "-drifted"
                current.document = third
                throw ProfileRegistryError.malformedDocument("scripted third-shape failure")
            }
            if current.nfdShapeOnSaveAt.contains(current.saveCount) {
                var third = decoded
                third.profiles[0].name = third.profiles[0].name
                    .decomposedStringWithCanonicalMapping
                current.document = third
                throw ProfileRegistryError.malformedDocument("scripted nfd-shape failure")
            }
            current.document = decoded
        }
    }
}

@MainActor
final class ThrowingSecretStore: AuthSecretStore {
    struct ReadFailure: Error {}
    var values: [String: String] = [:]
    var failClassifiedReads = false
    /// Classified reads fail once this many have succeeded.
    var failClassifiedReadsAfter: Int?
    private var classifiedReads = 0
    /// Writes store a tampered value — the foreign-token shape.
    var corruptWrites = false

    func get(_ key: String) -> String? { values[key] }

    func getClassified(_ key: String) throws -> String? {
        if failClassifiedReads { throw ReadFailure() }
        if let threshold = failClassifiedReadsAfter {
            classifiedReads += 1
            if classifiedReads > threshold { throw ReadFailure() }
        }
        return values[key]
    }

    func set(_ value: String, for key: String) throws {
        values[key] = corruptWrites ? value + "-tampered" : value
    }

    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}

/// Marker double that must never be reached (proves the active-store route
/// is used) or that fails on demand (B2 crash windows).
struct ScriptedMarker: HistoricalConsentMarking {
    struct Unreachable: Error {}
    struct ScriptedFailure: Error {}
    var failMarking = false
    var forbidUse = false

    func markAll(storeURL: URL, transactionID: UUID) throws -> HistoricalMarkResult {
        if forbidUse { throw Unreachable() }
        if failMarking { throw ScriptedFailure() }
        return HistoricalMarkResult(newlyMarked: 0, previouslyMarked: 0, total: 0)
    }

    func clearMarks(storeURL: URL, transactionID: UUID) throws -> Int {
        if forbidUse { throw Unreachable() }
        return 0
    }
}

@MainActor
struct ProfileBindingTransactionTests {
    // MARK: - Fixtures

    private let fixedNow = Date(timeIntervalSince1970: 1_785_700_000)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeProfile(
        id: UUID = UUID(),
        kind: Profile.Kind = .standard,
        storeMaterialized: Bool = true,
        bound: Profile.BoundAccount? = nil,
        isLocked: Bool = false
    ) -> Profile {
        Profile(
            id: id,
            kind: kind,
            name: kind == .system ? "Local" : "P",
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: bound,
            lockOnSignOut: false,
            isLocked: isLocked,
            storeMaterialized: storeMaterialized,
            sessionDisposition: .active
        )
    }

    private func officialOrigin() throws -> IssuerOrigin {
        try IssuerOrigin(validating: "https://cadenzapp.com:443")
    }

    private func makeRequest(
        profileID: UUID,
        userID: String = "user-1",
        requestUserID: String? = nil,
        tokenRaw: String = "token-raw-1"
    ) throws -> ProfileBindingTransaction.Request {
        ProfileBindingTransaction.Request(
            profileID: profileID,
            userID: userID,
            origin: try officialOrigin(),
            apiBaseURL: "https://cadenzapp.com/api/v1",
            user: SessionUser(
                userID: requestUserID ?? userID,
                email: "u@example.com",
                displayName: "U",
                pictureURL: nil
            ),
            tokenRaw: tokenRaw
        )
    }

    private struct Fixture {
        let registry: ScriptedRegistry
        let secretStore: ThrowingSecretStore
        let userStore: EphemeralSessionUserStore
        let storeURL: URL
        let dependencies: ProfileBindingTransaction.Dependencies
        let profileID: UUID
    }

    private func makeFixture(
        profile: Profile,
        extraProfiles: [Profile] = [],
        storeURL: URL,
        marker: HistoricalConsentMarking = SwiftDataHistoricalConsentMarker(),
        pending: PendingBinding? = nil,
        storeURLByProfile: ((UUID) -> URL)? = nil
    ) throws -> Fixture {
        var profiles = [profile]
        profiles.append(contentsOf: extraProfiles)
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, pendingBinding: pending,
            profiles: profiles
        )
        try document.validate()
        let registry = ScriptedRegistry(document: document)
        let secretStore = ThrowingSecretStore()
        let userStore = EphemeralSessionUserStore()
        let dependencies = ProfileBindingTransaction.Dependencies(
            registry: registry,
            secretStore: secretStore,
            sessionUserStore: { _ in userStore },
            marker: marker,
            storeURL: { id in storeURLByProfile?(id) ?? storeURL },
            storePresence: ProfileBindingTransaction.classifiedStorePresence(
                fileOperations: LiveFileOperations()
            ),
            now: { self.fixedNow }
        )
        return Fixture(
            registry: registry, secretStore: secretStore, userStore: userStore,
            storeURL: storeURL, dependencies: dependencies, profileID: profile.id
        )
    }

    /// Creates a real store with `rows` recordings and releases the
    /// container before returning.
    private func populateStore(at storeURL: URL, rows: Int, markedWith: UUID? = nil) throws {
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        for index in 0..<rows {
            let recording = Recording(title: "R\(index)")
            recording.awaitingHistoricalConsentBindingID = markedWith
            context.insert(recording)
        }
        try context.save()
    }

    private func readMarks(at storeURL: URL) throws -> [UUID?] {
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Recording>())
        return rows.map(\.awaitingHistoricalConsentBindingID)
    }

    private func tokenAccount(_ fixture: Fixture) throws -> String {
        SessionTokenKey.account(
            profileID: fixture.profileID, originKey: try officialOrigin().originKey
        )
    }

    /// Writes the durable artifacts of a mid-flight transaction exactly as
    /// the phases would, so recovery sees a real crash state.
    private func seedPhaseArtifacts(
        _ fixture: Fixture,
        pending: PendingBinding,
        token: String? = nil,
        user: SessionUser? = nil
    ) throws {
        if let token {
            try fixture.secretStore.set(
                token,
                for: SessionTokenKey.account(
                    profileID: pending.profileID, originKey: pending.originKey
                )
            )
        }
        if let user {
            try fixture.userStore.save(user)
        }
    }

    private func makePending(
        profileID: UUID,
        userID: String = "user-1",
        tokenRaw: String = "token-raw-1"
    ) throws -> PendingBinding {
        let origin = try officialOrigin()
        return PendingBinding(
            transactionID: UUID(),
            profileID: profileID,
            userID: userID,
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            tokenDigest: SessionTokenDigest.digest(of: tokenRaw),
            startedAt: fixedNow
        )
    }

    private func sessionUser(
        userID: String = "user-1", transactionID: UUID?
    ) -> SessionUser {
        SessionUser(
            userID: userID, email: "u@example.com", displayName: "U",
            pictureURL: nil, bindingTransactionID: transactionID
        )
    }

    // MARK: - Forward path

    @Test func runSyncBindsMaterializedProfileAndMarksAllRows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 3)
        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)

        let committed = try ProfileBindingTransaction.runSync(
            request: makeRequest(profileID: fixture.profileID),
            dependencies: fixture.dependencies
        )

        let profile = try #require(committed.profiles.first { $0.id == fixture.profileID })
        let bound = try #require(profile.boundAccount)
        #expect(bound.userID == "user-1")
        #expect(bound.issuerOrigin == "https://cadenzapp.com:443")
        #expect(bound.apiBaseURL == "https://cadenzapp.com/api/v1")
        #expect(bound.originKey == (try officialOrigin().originKey))
        #expect(profile.isLocked == false)
        #expect(profile.sessionDisposition == .active)
        #expect(committed.pendingBinding == nil)

        let marks = try readMarks(at: storeURL)
        #expect(marks.count == 3)
        let distinct = Set(marks.compactMap { $0 })
        #expect(distinct.count == 1)
        #expect(marks.allSatisfy { $0 != nil })

        let token = fixture.secretStore.get(try tokenAccount(fixture))
        #expect(token == "token-raw-1")
        let user = try #require(try fixture.userStore.load())
        #expect(user.userID == "user-1")
        #expect(user.bindingTransactionID == distinct.first)
    }

    @Test func runSyncOnFreshProfileBindsWithoutCreatingAStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        let fixture = try makeFixture(
            profile: makeProfile(storeMaterialized: false), storeURL: storeURL
        )

        let committed = try ProfileBindingTransaction.runSync(
            request: makeRequest(profileID: fixture.profileID),
            dependencies: fixture.dependencies
        )

        #expect(committed.profiles.first?.boundAccount != nil)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func runRoutesMarkingThroughActiveStoreOnly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 2)
        // The direct marker is forbidden: the open-container route must be
        // the only marking path the async entry point uses.
        let fixture = try makeFixture(
            profile: makeProfile(), storeURL: storeURL,
            marker: ScriptedMarker(forbidUse: true)
        )
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(storeURL: storeURL)
        )

        let committed = try await ProfileBindingTransaction.run(
            request: makeRequest(profileID: fixture.profileID),
            dependencies: fixture.dependencies,
            activeStore: .init(
                markAll: { txn in
                    try await store.markAllRecordingsAwaitingHistoricalConsent(
                        transactionID: txn
                    )
                },
                clearMarks: { txn in
                    try await store.clearHistoricalConsentMarks(transactionID: txn)
                }
            )
        )

        #expect(committed.profiles.first?.boundAccount?.userID == "user-1")
        let txn = try #require(try fixture.userStore.load()?.bindingTransactionID)
        let result = try await store.markAllRecordingsAwaitingHistoricalConsent(
            transactionID: txn
        )
        #expect(result == HistoricalMarkResult(newlyMarked: 0, previouslyMarked: 2, total: 2))
    }

    // MARK: - Preconditions

    @Test func systemProfileRefusesBinding() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeFixture(
            profile: makeProfile(kind: .system),
            storeURL: dir.appendingPathComponent("Cadenza.store")
        )
        #expect(throws: ProfileBindingTransaction.BindingError.systemProfileCannotBind) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }
        #expect(try fixture.registry.load().pendingBinding == nil)
    }

    @Test func alreadyBoundAccountIsRedirectedNotRebound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try officialOrigin()
        let boundProfile = makeProfile(
            bound: Profile.BoundAccount(
                userID: "user-1", originKey: origin.originKey,
                issuerOrigin: origin.normalized,
                apiBaseURL: "https://cadenzapp.com/api/v1",
                displayEmail: "u@example.com", displayName: "U", boundAt: fixedNow
            )
        )
        let target = makeProfile(storeMaterialized: false)
        let fixture = try makeFixture(
            profile: target, extraProfiles: [boundProfile],
            storeURL: dir.appendingPathComponent("Cadenza.store")
        )

        #expect(throws: ProfileBindingTransaction.BindingError
            .accountAlreadyBoundElsewhere(boundProfile.id)) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }
        #expect(try fixture.registry.load().pendingBinding == nil)
    }

    @Test func identityMismatchIsRefusedBeforeAnyWrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeFixture(
            profile: makeProfile(storeMaterialized: false),
            storeURL: dir.appendingPathComponent("Cadenza.store")
        )
        #expect(throws: ProfileBindingTransaction.BindingError.identityMismatch) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(
                    profileID: fixture.profileID, userID: "user-1",
                    requestUserID: "user-2"
                ),
                dependencies: fixture.dependencies
            )
        }
        #expect(fixture.registry.saveCount == 0)
    }

    @Test func foreignTokenSlotRefusesBindingBeforePhaseA() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeFixture(
            profile: makeProfile(storeMaterialized: false),
            storeURL: dir.appendingPathComponent("Cadenza.store")
        )
        try fixture.secretStore.set("someone-elses-token", for: try tokenAccount(fixture))

        #expect(throws: ProfileBindingTransaction.BindingError
            .foreignSessionArtifact("token slot occupied")) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }
        // Zero writes: no pending, foreign token untouched.
        #expect(fixture.registry.saveCount == 0)
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == "someone-elses-token")
    }

    @Test func foreignSessionUserRefusesBindingBeforePhaseA() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try makeFixture(
            profile: makeProfile(storeMaterialized: false),
            storeURL: dir.appendingPathComponent("Cadenza.store")
        )
        try fixture.userStore.save(sessionUser(transactionID: UUID()))

        #expect(throws: ProfileBindingTransaction.BindingError
            .foreignSessionArtifact("session-user file exists")) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }
        #expect(fixture.registry.saveCount == 0)
        #expect(try fixture.userStore.load() != nil)
    }

    @Test func orphanStoreOnUnmaterializedProfileFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let fixture = try makeFixture(
            profile: makeProfile(storeMaterialized: false), storeURL: storeURL
        )

        #expect(throws: (any Error).self) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }
        // Rolled back: no pending, artifacts removed, row untouched.
        let document = try fixture.registry.load()
        #expect(document.pendingBinding == nil)
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == nil)
        #expect(try fixture.userStore.load() == nil)
        #expect(try readMarks(at: storeURL) == [nil])
    }

    // MARK: - B2 semantics

    @Test func foreignMarkAbortsAndRollsBackOwnEffectsOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        let foreign = UUID()
        try populateStore(at: storeURL, rows: 2, markedWith: nil)
        // One row pre-marked by a foreign transaction.
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Recording>())
        rows[0].awaitingHistoricalConsentBindingID = foreign
        try context.save()

        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)
        #expect(throws: (any Error).self) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }

        let document = try fixture.registry.load()
        #expect(document.pendingBinding == nil)
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == nil)
        #expect(try fixture.userStore.load() == nil)
        // The foreign mark survives; no row carries a second transaction.
        let marks = try readMarks(at: storeURL)
        #expect(marks.contains(foreign))
        #expect(marks.compactMap { $0 }.allSatisfy { $0 == foreign })
    }

    /// Post-phase-A contract: unreadable or foreign token evidence must
    /// exit as commit-indeterminate with the pending record retained —
    /// never an ordinary error that lets the runtime keep serving.
    @Test func unreadableTokenEvidenceAfterPhaseBEscalates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)
        // Read 1 is the begin-time precheck; the pre-commit proof fails.
        fixture.secretStore.failClassifiedReadsAfter = 1

        // The first exit itself must already be commit-indeterminate —
        // not an ordinary error that only the retry reveals.
        do {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.commitIndeterminate {
            // Pending retained; the runtime must halt.
        } catch {
            Issue.record("expected commitIndeterminate first, got \(error)")
        }
        do {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.anotherOperationInFlight {
            // Pending retained from the first attempt: recovery is owed.
        } catch {
            Issue.record("expected pending retained, got \(error)")
        }
        #expect(try fixture.registry.load().pendingBinding != nil)
    }

    @Test func foreignTokenEvidenceAfterPhaseBEscalates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)
        fixture.secretStore.corruptWrites = true

        do {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.commitIndeterminate {
            // The foreign slot deliberately retains the pending record.
        } catch {
            Issue.record("expected commitIndeterminate, got \(error)")
        }
        #expect(try fixture.registry.load().pendingBinding != nil)
    }

    // MARK: - Crash-window recovery

    @Test func recoverAfterPhaseAOnlyRollsBack() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        #expect(outcome == .rolledBack(profileID: profile.id))
        let document = try fixture.registry.load()
        #expect(document.pendingBinding == nil)
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(try readMarks(at: storeURL) == [nil])
    }

    @Test func recoverWithTokenButNoUserRollsBackAndRemovesOwnedToken() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        try seedPhaseArtifacts(fixture, pending: pending, token: "token-raw-1")

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        #expect(outcome == .rolledBack(profileID: profile.id))
        let account = SessionTokenKey.account(
            profileID: pending.profileID, originKey: pending.originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.registry.load().pendingBinding == nil)
    }

    @Test func recoverWithCompleteArtifactsFinishesB2AndCommits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 2)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        try seedPhaseArtifacts(
            fixture, pending: pending, token: "token-raw-1",
            user: sessionUser(transactionID: pending.transactionID)
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        #expect(outcome == .completed(profileID: profile.id))
        let document = try fixture.registry.load()
        let committed = try #require(document.profiles.first)
        #expect(committed.boundAccount?.userID == "user-1")
        #expect(committed.boundAccount?.issuerOrigin == "https://cadenzapp.com:443")
        #expect(committed.sessionDisposition == .active)
        #expect(committed.isLocked == false)
        #expect(document.pendingBinding == nil)
        let marks = try readMarks(at: storeURL)
        #expect(marks.allSatisfy { $0 == pending.transactionID })
    }

    @Test func recoverAfterB2IsIdempotentAndCommits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        try populateStore(at: storeURL, rows: 2, markedWith: pending.transactionID)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        try seedPhaseArtifacts(
            fixture, pending: pending, token: "token-raw-1",
            user: sessionUser(transactionID: pending.transactionID)
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        #expect(outcome == .completed(profileID: profile.id))
        let marks = try readMarks(at: storeURL)
        #expect(marks.allSatisfy { $0 == pending.transactionID })
    }

    @Test func recoverForeignTokenHaltsWithZeroDeletions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        try seedPhaseArtifacts(
            fixture, pending: pending, token: "a-different-token",
            user: sessionUser(transactionID: pending.transactionID)
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        guard case .halted = outcome else {
            Issue.record("expected halted, got \(outcome)")
            return
        }
        let account = SessionTokenKey.account(
            profileID: pending.profileID, originKey: pending.originKey
        )
        #expect(fixture.secretStore.get(account) == "a-different-token")
        #expect(try fixture.userStore.load() != nil)
        #expect(try fixture.registry.load().pendingBinding == pending)
    }

    @Test func recoverUnreadableKeychainHalts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        fixture.secretStore.failClassifiedReads = true

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        guard case .halted = outcome else {
            Issue.record("expected halted, got \(outcome)")
            return
        }
        #expect(try fixture.registry.load().pendingBinding == pending)
    }

    @Test func recoverForeignSessionUserHaltsWithZeroDeletions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        // Incomplete (no token) plus a session-user owned by a different
        // transaction: the rollback must refuse to delete it.
        try seedPhaseArtifacts(
            fixture, pending: pending, user: sessionUser(transactionID: UUID())
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        guard case .halted = outcome else {
            Issue.record("expected halted, got \(outcome)")
            return
        }
        #expect(try fixture.userStore.load() != nil)
        #expect(try fixture.registry.load().pendingBinding == pending)
    }

    @Test func recoverMalformedSessionUserFileHalts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)

        let userFile = dir.appendingPathComponent("session-user.json")
        try Data("not json".utf8).write(to: userFile)
        let fileStore = FileSessionUserStore(
            url: userFile, fileOperations: LiveFileOperations()
        )
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: profile.id, pendingBinding: pending,
            profiles: [profile]
        )
        let registry = ScriptedRegistry(document: document)
        let secretStore = ThrowingSecretStore()
        let dependencies = ProfileBindingTransaction.Dependencies(
            registry: registry,
            secretStore: secretStore,
            sessionUserStore: { _ in fileStore },
            marker: SwiftDataHistoricalConsentMarker(),
            storeURL: { _ in storeURL },
            storePresence: ProfileBindingTransaction.classifiedStorePresence(
                fileOperations: LiveFileOperations()
            ),
            now: { self.fixedNow }
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try registry.load(), dependencies: dependencies
        )
        guard case .halted = outcome else {
            Issue.record("expected halted, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }

    @Test func recoverUserIdentityMismatchRollsBackOwnedArtifacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1, markedWith: nil)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        // Owned by this transaction but recording a different identity:
        // completeness fails, ownership holds — rolled back, not halted.
        try seedPhaseArtifacts(
            fixture, pending: pending, token: "token-raw-1",
            user: sessionUser(userID: "user-9", transactionID: pending.transactionID)
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        #expect(outcome == .rolledBack(profileID: profile.id))
        #expect(try fixture.userStore.load() == nil)
        let account = SessionTokenKey.account(
            profileID: pending.profileID, originKey: pending.originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.registry.load().pendingBinding == nil)
    }

    @Test func recoverCommitFailureHaltsWithArtifactsIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id)
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        try seedPhaseArtifacts(
            fixture, pending: pending, token: "token-raw-1",
            user: sessionUser(transactionID: pending.transactionID)
        )
        fixture.registry.configure { $0.failSaveAt = [1] }

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        guard case .halted = outcome else {
            Issue.record("expected halted, got \(outcome)")
            return
        }
        let account = SessionTokenKey.account(
            profileID: pending.profileID, originKey: pending.originKey
        )
        #expect(fixture.secretStore.get(account) == "token-raw-1")
        #expect(try fixture.userStore.load() != nil)
        #expect(try fixture.registry.load().pendingBinding == pending)
    }

    // MARK: - Stale registry during async B2

    @Test func commitRefusesWhenPendingChangedDuringAwait() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let fixture = try makeFixture(
            profile: makeProfile(), storeURL: storeURL,
            marker: ScriptedMarker(forbidUse: true)
        )
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(storeURL: storeURL)
        )
        let registry = fixture.registry

        await #expect(throws: (any Error).self) {
            _ = try await ProfileBindingTransaction.run(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies,
                activeStore: .init(
                    markAll: { txn in
                        // Concurrent actor resolves the pending record
                        // while B2 is off the main actor.
                        var document = try registry.load()
                        document.pendingBinding = nil
                        try registry.save(document)
                        return try await store.markAllRecordingsAwaitingHistoricalConsent(
                            transactionID: txn
                        )
                    },
                    clearMarks: { txn in
                        try await store.clearHistoricalConsentMarks(transactionID: txn)
                    }
                )
            )
        }
        // The commit must not have manufactured a bound account from the
        // stale snapshot.
        let document = try registry.load()
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(document.pendingBinding == nil)
    }

    // MARK: - Commit-failure classification

    @Test func commitSaveFailureWithPendingIntactRollsBack() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 2)
        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)
        // Save 1 = phase A, save 2 = commit (fails), save 3 = rollback.
        fixture.registry.configure { $0.failSaveAt = [2] }

        #expect(throws: (any Error).self) {
            _ = try ProfileBindingTransaction.runSync(
                request: self.makeRequest(profileID: fixture.profileID),
                dependencies: fixture.dependencies
            )
        }
        let document = try fixture.registry.load()
        #expect(document.pendingBinding == nil)
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == nil)
        #expect(try fixture.userStore.load() == nil)
        #expect(try readMarks(at: storeURL) == [nil, nil])
    }

    @Test func commitSaveErrorThatActuallyPersistedCountsAsSuccess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)
        fixture.registry.configure { $0.persistThenThrowAt = [2] }

        let committed = try ProfileBindingTransaction.runSync(
            request: self.makeRequest(profileID: fixture.profileID),
            dependencies: fixture.dependencies
        )
        #expect(committed.profiles.first?.boundAccount?.userID == "user-1")
        #expect(committed.pendingBinding == nil)
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == "token-raw-1")
    }

    // MARK: - Consent tri-state

    @Test func consentReadsFailClosedAndRoundTrips() {
        let suiteName = "consent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scope = ProfileDefaultsScope(defaults: defaults, profileID: UUID())

        #expect(HistoricalSyncConsent.read(from: scope) == .undecided)
        scope.set("garbage", forKey: HistoricalSyncConsent.scopedKeyBase)
        #expect(HistoricalSyncConsent.read(from: scope) == .undecided)

        HistoricalSyncConsent.textOnly.write(to: scope)
        #expect(HistoricalSyncConsent.read(from: scope) == .textOnly)
        HistoricalSyncConsent.withAudio.write(to: scope)
        #expect(HistoricalSyncConsent.read(from: scope) == .withAudio)

        #expect(!HistoricalSyncConsent.undecided.allowsHistoricalSync)
        #expect(HistoricalSyncConsent.textOnly.allowsHistoricalSync)
        #expect(!HistoricalSyncConsent.textOnly.allowsHistoricalAudio)
        #expect(HistoricalSyncConsent.withAudio.allowsHistoricalAudio)
    }

    // MARK: - Store actor marking

    @Test func actorMarkingStampsCountsAndRefusesForeignMarks() async throws {
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(inMemory: true)
        )
        _ = await store.createRecording(
            id: UUID(), title: "A", startDate: Date(), segmentsDirURL: nil
        )
        _ = await store.createRecording(
            id: UUID(), title: "B", startDate: Date(), segmentsDirURL: nil
        )
        let txn = UUID()

        let result = try await store.markAllRecordingsAwaitingHistoricalConsent(
            transactionID: txn
        )
        #expect(result == HistoricalMarkResult(newlyMarked: 2, previouslyMarked: 0, total: 2))

        let again = try await store.markAllRecordingsAwaitingHistoricalConsent(
            transactionID: txn
        )
        #expect(again == HistoricalMarkResult(newlyMarked: 0, previouslyMarked: 2, total: 2))

        await #expect(throws: HistoricalMarkingError.self) {
            _ = try await store.markAllRecordingsAwaitingHistoricalConsent(
                transactionID: UUID()
            )
        }

        let cleared = try await store.clearHistoricalConsentMarks(transactionID: txn)
        #expect(cleared == 2)
    }
}

// MARK: - Phase A classified save and byte-exact identity

extension ProfileBindingTransactionTests {
    private func makeCreateRequest(
        newProfileID: UUID
    ) throws -> ProfileBindingTransaction.Request {
        var request = try makeRequest(profileID: newProfileID)
        request.create = ProfileBindingTransaction.NewProfileTemplate(
            name: "Account",
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio-new", kind: .appManaged)
        )
        return request
    }

    /// Phase A's save landed the created profile and pending record
    /// before throwing: classification proves the intended bytes and the
    /// transaction continues to a full commit.
    @Test func createdProfilePhaseASavePersistedThenThrewContinues() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let newID = UUID()
        let fixture = try makeFixture(
            profile: makeProfile(), storeURL: storeURL,
            storeURLByProfile: { id in
                id == newID ? dir.appendingPathComponent("absent.store") : storeURL
            }
        )
        fixture.registry.configure { $0.persistThenThrowAt = [1] }
        let committed = try ProfileBindingTransaction.runSync(
            request: makeCreateRequest(newProfileID: newID),
            dependencies: fixture.dependencies
        )
        #expect(committed.profiles.count == 2)
        let created = committed.profiles.first(where: { $0.id == newID })
        #expect(created?.boundAccount?.userID == "user-1")
        #expect(committed.pendingBinding == nil)
    }

    /// Phase A's save provably did not land: the original error
    /// surfaces and neither the pending record, the created profile,
    /// nor any artifact exists afterwards.
    @Test func createdProfilePhaseAFailedSaveLeavesNoTrace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let newID = UUID()
        let fixture = try makeFixture(
            profile: makeProfile(), storeURL: storeURL,
            storeURLByProfile: { id in
                id == newID ? dir.appendingPathComponent("absent.store") : storeURL
            }
        )
        fixture.registry.configure { $0.failSaveAt = [1] }
        do {
            _ = try ProfileBindingTransaction.runSync(
                request: makeCreateRequest(newProfileID: newID),
                dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.commitIndeterminate {
            Issue.record("a proven-old save must not escalate")
        } catch {
            // Original save error: retryable.
        }
        let document = try fixture.registry.load()
        #expect(document.pendingBinding == nil)
        #expect(!document.profiles.contains(where: { $0.id == newID }))
        let account = SessionTokenKey.account(
            profileID: newID, originKey: try officialOrigin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try readMarks(at: storeURL) == [nil])
    }

    /// Phase A's save left a third shape: the first error is already
    /// commit-indeterminate and the persisted pending record awaits
    /// recovery.
    @Test func createdProfilePhaseAThirdShapeEscalatesIndeterminate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let newID = UUID()
        let fixture = try makeFixture(
            profile: makeProfile(), storeURL: storeURL,
            storeURLByProfile: { id in
                id == newID ? dir.appendingPathComponent("absent.store") : storeURL
            }
        )
        fixture.registry.configure { $0.thirdShapeOnSaveAt = [1] }

        do {
            _ = try ProfileBindingTransaction.runSync(
                request: makeCreateRequest(newProfileID: newID),
                dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.commitIndeterminate {
            // Runtime halt and recovery are owed.
        } catch {
            Issue.record("expected commitIndeterminate, got \(error)")
        }
        #expect(try fixture.registry.load().pendingBinding != nil)
    }

    /// The request's own identity pair must match in exact UTF-8 bytes:
    /// canonically equivalent spellings are different accounts.
    @Test func canonicallyEquivalentRequestIdentityIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let fixture = try makeFixture(profile: makeProfile(), storeURL: storeURL)

        do {
            _ = try ProfileBindingTransaction.runSync(
                request: makeRequest(
                    profileID: fixture.profileID,
                    userID: "us\u{00E9}r-1",
                    requestUserID: "use\u{0301}r-1"
                ),
                dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.identityMismatch {
            // Byte-distinct identity refused before any write.
        } catch {
            Issue.record("expected identityMismatch, got \(error)")
        }
        let document = try fixture.registry.load()
        #expect(document.pendingBinding == nil)
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == nil)
    }

    /// Recovery's completion proof compares user IDs in exact bytes: a
    /// canonically equivalent session-user record is wrong-identity
    /// evidence and must roll back, never complete the binding.
    @Test func recoverRefusesCanonicallyEquivalentOwnershipEvidence() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let pending = try makePending(profileID: profile.id, userID: "us\u{00E9}r-1")
        let fixture = try makeFixture(profile: profile, storeURL: storeURL, pending: pending)
        try seedPhaseArtifacts(
            fixture, pending: pending, token: "token-raw-1",
            user: sessionUser(userID: "use\u{0301}r-1", transactionID: pending.transactionID)
        )

        let outcome = ProfileBindingTransaction.recover(
            document: try fixture.registry.load(), dependencies: fixture.dependencies
        )
        #expect(outcome == .rolledBack(profileID: profile.id))
        let document = try fixture.registry.load()
        #expect(document.profiles.first?.boundAccount == nil)
        #expect(document.pendingBinding == nil)
    }
}

// MARK: - Source authority inside phase A

extension ProfileBindingTransactionTests {
    /// The precondition is proven against phase A's own fresh document:
    /// a source snapshot the registry no longer matches refuses before
    /// any write.
    @Test func staleSourceAuthorityRefusesWithZeroWrites() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let fixture = try makeFixture(profile: profile, storeURL: storeURL)

        var staleSnapshot = profile
        staleSnapshot.isLocked = false
        var request = try makeRequest(profileID: fixture.profileID)
        request.sourceAuthority = .init(profile: staleSnapshot)
        // The registry moves to a different active profile behind the
        // snapshot.
        var document = try fixture.registry.load()
        var other = profile
        other.id = UUID()
        other.name = "Other"
        document.profiles.append(other)
        document.activeProfileID = other.id
        try fixture.registry.save(document)
        let savesBefore = fixture.registry.saveCount

        do {
            _ = try ProfileBindingTransaction.runSync(
                request: request, dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.sourceAuthorityLost {
            // Typed lost-authority refusal at the fresh load; nothing
            // written.
        } catch {
            Issue.record("expected sourceAuthorityLost, got \(error)")
        }
        #expect(fixture.registry.saveCount == savesBefore)
        let after = try fixture.registry.load()
        #expect(after.pendingBinding == nil)
        #expect(after.profiles.allSatisfy { $0.boundAccount == nil })
        #expect(fixture.secretStore.get(try tokenAccount(fixture)) == nil)
        #expect(try readMarks(at: storeURL) == [nil])
    }

    /// A rebound source (byte-distinct account tuple) is also stale
    /// authority, even when the active ID still matches.
    @Test func reboundSourceAuthorityRefuses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Cadenza.store")
        try populateStore(at: storeURL, rows: 1)
        let profile = makeProfile()
        let fixture = try makeFixture(profile: profile, storeURL: storeURL)

        var snapshot = profile
        let origin = try officialOrigin()
        snapshot.boundAccount = Profile.BoundAccount(
            userID: "us\u{00E9}r-9",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: "https://cadenzapp.com/api/v1",
            displayEmail: "x@example.com",
            displayName: "X",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
        var document = try fixture.registry.load()
        var bound = snapshot.boundAccount
        bound?.userID = "use\u{0301}r-9"
        document.profiles[0].boundAccount = bound
        try fixture.registry.save(document)

        var request = try makeRequest(profileID: UUID())
        request.create = ProfileBindingTransaction.NewProfileTemplate(
            name: "Account",
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio-new", kind: .appManaged)
        )
        request.sourceAuthority = .init(profile: snapshot)

        do {
            _ = try ProfileBindingTransaction.runSync(
                request: request, dependencies: fixture.dependencies
            )
            Issue.record("expected throw")
        } catch ProfileBindingTransaction.BindingError.sourceAuthorityLost {
            // Byte-distinct tuple is lost authority.
        } catch {
            Issue.record("expected sourceAuthorityLost, got \(error)")
        }
        #expect(try fixture.registry.load().pendingBinding == nil)
    }
}
