import Foundation
import SwiftData
import Testing
import os

@testable import Cadenza

// MARK: - Classified active-profile commits

@MainActor
struct ProfileSwitchCommitTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_785_700_000)

    private func makeDocument(
        activeID: UUID? = nil, extra: [Profile] = []
    ) -> (ProfileRegistryDocument, Profile) {
        let profile = Profile(
            id: UUID(),
            kind: .system,
            name: "Local",
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
        var profiles = [profile]
        profiles.append(contentsOf: extra)
        return (
            ProfileRegistryDocument(
                version: 1, activeProfileID: activeID ?? profile.id, profiles: profiles
            ),
            profile
        )
    }

    private func makeStandard(name: String = "P") -> Profile {
        Profile(
            id: UUID(),
            kind: .standard,
            name: name,
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
    }

    @Test func saveCommittedThenThrewClassifiesCommitted() {
        let target = makeStandard()
        let (document, _) = makeDocument(extra: [target])
        let registry = ScriptedRegistry(document: document)
        registry.configure { $0.persistThenThrowAt = [1] }

        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: target.id, registry: registry,
            precondition: { _ in nil },
            mutate: { doc in
                if let index = doc.profiles.firstIndex(where: { $0.id == target.id }) {
                    doc.profiles[index].lastActiveAt = self.fixedNow.addingTimeInterval(60)
                }
            }
        )
        #expect(outcome == .committed)
    }

    @Test func threwBeforeCommitClassifiesNotCommitted() throws {
        let target = makeStandard()
        let (document, local) = makeDocument(extra: [target])
        let registry = ScriptedRegistry(document: document)
        registry.configure { $0.failSaveAt = [1] }

        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: target.id, registry: registry,
            precondition: { _ in nil },
            mutate: { _ in }
        )
        guard case .notCommitted = outcome else {
            Issue.record("expected notCommitted, got \(outcome)")
            return
        }
        #expect(try registry.load().activeProfileID == local.id)
    }

    @Test func unreadableRereadClassifiesIndeterminate() {
        let target = makeStandard()
        let (document, _) = makeDocument(extra: [target])
        let registry = ScriptedRegistry(document: document)
        // Load 1 feeds the commit; load 2 is the classification re-read.
        registry.configure { $0.failSaveAt = [1]; $0.failLoadAt = [2] }

        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: target.id, registry: registry,
            precondition: { _ in nil },
            mutate: { _ in }
        )
        guard case .indeterminate = outcome else {
            Issue.record("expected indeterminate, got \(outcome)")
            return
        }
    }

    @Test func canonicalRespellingThirdShapeClassifiesIndeterminate() {
        // The concurrent drift changes only the Unicode normalization of a
        // name; synthesized String equality would call the shapes equal.
        // The scripted respelling targets profiles[0], so that profile
        // carries the composed name.
        let target = makeStandard()
        var (document, _) = makeDocument(extra: [target])
        document.profiles[0].name = "Caf\u{00E9}"
        let registry = ScriptedRegistry(document: document)
        registry.configure { $0.nfdShapeOnSaveAt = [1] }

        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: target.id, registry: registry,
            precondition: { _ in nil },
            mutate: { _ in }
        )
        guard case .indeterminate = outcome else {
            Issue.record("expected indeterminate, got \(outcome)")
            return
        }
    }

    @Test func thirdShapeAfterFailedSaveClassifiesIndeterminate() {
        let target = makeStandard()
        let (document, _) = makeDocument(extra: [target])
        let registry = ScriptedRegistry(document: document)
        registry.configure { $0.thirdShapeOnSaveAt = [1] }

        let outcome = ProfileSwitchCoordinator.commitActiveProfile(
            to: target.id, registry: registry,
            precondition: { _ in nil },
            mutate: { _ in }
        )
        guard case .indeterminate = outcome else {
            Issue.record("expected indeterminate, got \(outcome)")
            return
        }
    }

    /// Same-profile transitions (disposition, unlock, lastActiveAt) must
    /// classify by the full shape: the target being already active can
    /// never masquerade as proof of commitment.
    @Test func targetAlreadyActiveClassifiesByFullShape() throws {
        let (document, local) = makeDocument()
        let stamp = fixedNow.addingTimeInterval(120)

        let failing = ScriptedRegistry(document: document)
        failing.configure { $0.failSaveAt = [1] }
        let notCommitted = ProfileSwitchCoordinator.commitActiveProfile(
            to: local.id, registry: failing,
            precondition: { _ in nil },
            mutate: { doc in doc.profiles[0].lastActiveAt = stamp }
        )
        guard case .notCommitted = notCommitted else {
            Issue.record("expected notCommitted, got \(notCommitted)")
            return
        }
        #expect(try failing.load().profiles[0].lastActiveAt == fixedNow)

        let persisting = ScriptedRegistry(document: document)
        persisting.configure { $0.persistThenThrowAt = [1] }
        let committed = ProfileSwitchCoordinator.commitActiveProfile(
            to: local.id, registry: persisting,
            precondition: { _ in nil },
            mutate: { doc in doc.profiles[0].lastActiveAt = stamp }
        )
        #expect(committed == .committed)
        #expect(try persisting.load().profiles[0].lastActiveAt == stamp)
    }

    @Test func successfulSwitchStampsLastActiveAt() throws {
        let target = makeStandard()
        let (document, _) = makeDocument(extra: [target])
        let registry = ScriptedRegistry(document: document)
        let stamp = fixedNow.addingTimeInterval(300)

        let outcome = ProfileSwitchCoordinator.performSwitch(
            to: target.id, registry: registry,
            isRecording: false, isPostProcessing: false,
            isStorageMigrationActive: false,
            now: { stamp }
        )
        #expect(outcome == .committed)
        let saved = try registry.load()
        #expect(saved.activeProfileID == target.id)
        #expect(saved.profiles.first { $0.id == target.id }?.lastActiveAt == stamp)
    }

    @Test func refusalMatrixCoversEveryGuard() {
        let target = makeStandard()
        var (document, local) = makeDocument(extra: [target])

        func refusal(
            recording: Bool = false, postProcessing: Bool = false, migration: Bool = false,
            targetID: UUID? = nil, in doc: ProfileRegistryDocument? = nil
        ) -> ProfileSwitchCoordinator.Refusal? {
            ProfileSwitchCoordinator.refusal(
                document: doc ?? document,
                targetID: targetID ?? target.id,
                isRecording: recording,
                isPostProcessing: postProcessing,
                isStorageMigrationActive: migration
            )
        }

        #expect(refusal(recording: true) == .recordingActive)
        #expect(refusal(postProcessing: true) == .postProcessingActive)
        #expect(refusal(migration: true) == .storageMigrationActive)
        #expect(refusal(targetID: UUID()) == .targetMissing)
        #expect(refusal(targetID: local.id) == .alreadyActive)
        #expect(refusal() == nil)

        var locked = document
        if let index = locked.profiles.firstIndex(where: { $0.id == target.id }) {
            locked.profiles[index].isLocked = true
        }
        #expect(refusal(in: locked) == .targetLocked)

        document.pendingTransfer = makeTestPendingTransfer(
            source: local, target: target
        )
        #expect(refusal() == .operationInFlight)
    }
}

// MARK: - Transition halt runtime gate

@MainActor
struct ProfileTransitionHaltTests {
    @Test func haltBlocksRecordingAndProfileActions() async {
        let state = AppState()
        state.haltProfileTransition(reason: "test halt")

        await #expect(throws: AppState.ProfileTransitionHaltedError.self) {
            try await state.startRecording()
        }
        #expect(state.loadProfileDocument() == nil)
        #expect(state.makeProfileLoginCoordinator() == nil)
        // No error surfaced because the action never started.
        await state.switchProfile(to: UUID())
        #expect(state.profileActionError == nil)
    }

    /// The relaunching window itself refuses every old-store operation:
    /// from the proven commit until the replacement takes over (or a
    /// proven rollback returns to idle), the process serves nothing.
    @Test func delayedRelaunchWindowRefusesOldStoreOperations() async {
        let state = AppState()
        let captured = OSAllocatedUnfairLock<(@MainActor (String) -> Void)?>(initialState: nil)
        state.relaunchHandlerForTesting = { onFailure in
            captured.withLock { $0 = onFailure }
        }

        state.performProfileRelaunch()
        #expect(state.profileTransitionPhase == .relaunching)
        await #expect(throws: AppState.ProfileTransitionHaltedError.self) {
            try await state.startRecording()
        }
        #expect(state.loadProfileDocument() == nil)
        #expect(state.makeProfileLoginCoordinator() == nil)

        // Launch failure without a provable rollback (no live registry in
        // TestHost) stays blocked as halted — never a silent resume.
        let onFailure = captured.withLock { $0 }
        onFailure?("scripted launch failure")
        guard case .halted = state.profileTransitionPhase else {
            Issue.record("expected halted, got \(state.profileTransitionPhase)")
            return
        }
        await #expect(throws: AppState.ProfileTransitionHaltedError.self) {
            try await state.startRecording()
        }
    }
}

// MARK: - Login coordinator failure matrix

@MainActor
struct ProfileLoginCoordinatorTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_785_700_000)

    private final class RelaunchProbe {
        var relaunched = false
        var transferRelaunched = false
        var halted: String?
        var refusal: String?
        var resumed = 0
        var transferRequests: [ProfileTransfer.Request] = []
    }

    private struct Fixture {
        let coordinator: ProfileLoginCoordinator
        let registry: ScriptedRegistry
        let secretStore: InMemoryAuthSecretStore
        let userStores: SessionMigrationTests.SharedSessionUserStores
        let store: RecordingsStore
        let probe: RelaunchProbe
        let http: FakeAuthHTTP
        let activeProfile: Profile
        let defaults: UserDefaults
    }

    private func makeActiveProfile(bound: Profile.BoundAccount? = nil) -> Profile {
        Profile(
            id: UUID(),
            kind: .standard,
            name: "Mine",
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: bound,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
    }

    private func exchangeOK(userID: String = "u1") -> FakeAuthHTTP.Outcome {
        let exchangeJSON = """
        {
          "token": "tok-123",
          "expires_at": \(Int(Date().addingTimeInterval(86400).timeIntervalSince1970)),
          "user": {
            "id": "\(userID)",
            "email": "andy@example.com",
            "display_name": "Andy",
            "picture": null
          }
        }
        """.data(using: .utf8)!
        return .success(
            data: exchangeJSON,
            response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!
        )
    }

    private func matchingCallback(authorizeURL: URL) -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "state" })!.value!
        return URL(string: "com.shuiandy.cadenza://auth/cadenza/callback?code=abc&state=\(state)")!
    }

    private func makeBoundProfile(
        userID: String,
        baseURL: String = AuthTestProfile.baseURLString,
        isLocked: Bool = false,
        name: String = "Owned"
    ) -> Profile {
        let origin = AuthTestProfile.origin(baseURL: baseURL)
        var profile = makeActiveProfile()
        profile.name = name
        profile.isLocked = isLocked
        profile.boundAccount = Profile.BoundAccount(
            userID: userID,
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: baseURL,
            displayEmail: "o@example.com",
            displayName: "Owner",
            boundAt: fixedNow
        )
        return profile
    }

    private func makeFixture(
        activeProfile: Profile,
        extraProfiles: [Profile] = [],
        userID: String = "u1",
        prepareTransitionOK: Bool = true,
        prepareTransitionHook: (@MainActor (ScriptedRegistry) async -> Bool)? = nil,
        beginTransferHook: ((ProfileTransfer.Request) throws -> PendingTransfer)? = nil,
        existingRegistry: ScriptedRegistry? = nil,
        existingSecretStore: InMemoryAuthSecretStore? = nil,
        existingUserStores: SessionMigrationTests.SharedSessionUserStores? = nil,
        onAuthorizeURL: (@Sendable (URL) -> Void)? = nil
    ) async throws -> Fixture {
        var profiles = [activeProfile]
        profiles.append(contentsOf: extraProfiles)
        let registry: ScriptedRegistry
        if let existingRegistry {
            registry = existingRegistry
        } else {
            let document = ProfileRegistryDocument(
                version: 1, activeProfileID: activeProfile.id, profiles: profiles
            )
            try document.validate()
            registry = ScriptedRegistry(document: document)
        }
        let secretStore = existingSecretStore ?? InMemoryAuthSecretStore()
        let userStores = existingUserStores ?? SessionMigrationTests.SharedSessionUserStores()
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(inMemory: true)
        )
        await store.clearAll()
        let http = FakeAuthHTTP()
        http.enqueue(exchangeOK(userID: userID))
        let authorizer = FakeAuthorizationProvider()
        authorizer.onAuthorize = { [self] url in
            onAuthorizeURL?(url)
            return matchingCallback(authorizeURL: url)
        }
        let auth = try CadenzaAuthService.bootstrapped(
            sessionProfile: .ephemeralUnbound(),
            http: http,
            authorizer: authorizer,
            secretStore: secretStore,
            sessionUserStore: EphemeralSessionUserStore(),
            newLoginBackend: {
                CadenzaBackendConfig.Resolved(
                    origin: AuthTestProfile.origin(),
                    apiBaseURL: URL(string: AuthTestProfile.baseURLString)!
                )
            }
        )
        let probe = RelaunchProbe()
        let defaults = UserDefaults(suiteName: "login-tests-\(UUID().uuidString)")!
        let coordinator = ProfileLoginCoordinator(dependencies: .init(
            auth: auth,
            registry: registry,
            secretStore: secretStore,
            sessionUserStore: { userStores.store($0) },
            marker: SwiftDataHistoricalConsentMarker(),
            storeURL: { _ in URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)") },
            storePresence: { _ in false },
            defaults: defaults,
            activeStore: .init(
                markAll: { txn in
                    try await store.markAllRecordingsAwaitingHistoricalConsent(transactionID: txn)
                },
                clearMarks: { txn in
                    try await store.clearHistoricalConsentMarks(transactionID: txn)
                }
            ),
            activeProfile: activeProfile,
            now: { self.fixedNow },
            relaunch: { probe.relaunched = true },
            transferRelaunch: { probe.transferRelaunched = true },
            haltTransition: { probe.halted = $0 },
            transitionRefusal: { probe.refusal },
            prepareTransition: {
                if let prepareTransitionHook {
                    return await prepareTransitionHook(registry)
                }
                return prepareTransitionOK
            },
            resumeAfterRefusedTransition: { probe.resumed += 1 },
            beginTransfer: { request in
                probe.transferRequests.append(request)
                if let result = beginTransferHook {
                    return try result(request)
                }
                throw ProfileTransfer.TransferError.preflight(.targetMissing)
            }
        ))
        return Fixture(
            coordinator: coordinator, registry: registry, secretStore: secretStore,
            userStores: userStores, store: store, probe: probe, http: http,
            activeProfile: activeProfile, defaults: defaults
        )
    }

    private func makeLocalSystemProfile() -> Profile {
        var profile = makeActiveProfile()
        profile.kind = .system
        profile.name = "Local"
        return profile
    }

    private func advanceToTransferChoice(
        _ fixture: Fixture
    ) async throws -> UUID {
        await fixture.coordinator.begin()
        guard case .chooseTarget(let canBind, _) = fixture.coordinator.step, !canBind else {
            Issue.record("expected create-only chooseTarget, got \(fixture.coordinator.step)")
            throw CancellationError()
        }
        await fixture.coordinator.createAccountProfile()
        guard case .consent(let profileID) = fixture.coordinator.step else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            throw CancellationError()
        }
        await fixture.coordinator.finishWithConsent(.textOnly)
        guard case .transferChoice(let choiceID) = fixture.coordinator.step,
              choiceID == profileID else {
            Issue.record("expected transferChoice, got \(fixture.coordinator.step)")
            throw CancellationError()
        }
        return profileID
    }

    /// The recovery branch proves the full frozen tuple against this
    /// login's authorization: a target that matches on origin and user
    /// but not on the API path never resumes into consent or transfer.
    @Test func recoveryRefusesSameOriginDifferentAPIPathTarget() async throws {
        let active = makeLocalSystemProfile()
        var target = makeBoundProfile(
            userID: "u1",
            baseURL: AuthTestProfile.baseURLString + "/other/api",
            name: "Half Set Up"
        )
        target.storeMaterialized = false
        target.isLocked = false
        target.createdByBindingTransactionID = UUID()
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [target]
        )

        await fixture.coordinator.begin()
        guard case .accountAlreadyBound(let matchedID, _) = fixture.coordinator.step,
              matchedID == target.id else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.transferRequests.isEmpty)
    }

    /// The transfer opportunity survives a process death after the
    /// binding commit: a fresh coordinator re-logging into the same
    /// account resumes the setup from the registry's durable facts —
    /// the unmaterialized store and the recorded creation transaction —
    /// instead of switching in and consuming the eligibility.
    @Test func reloginAfterCrashResumesTransferChoiceWithSameProvenance() async throws {
        let active = makeLocalSystemProfile()
        let fixture = try await makeFixture(activeProfile: active)
        await fixture.coordinator.begin()
        await fixture.coordinator.createAccountProfile()
        guard case .consent(let profileID) = fixture.coordinator.step else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            return
        }
        let committedRow = try #require(
            try fixture.registry.load().profiles.first { $0.id == profileID }
        )
        let provenance = try #require(committedRow.createdByBindingTransactionID)
        #expect(!committedRow.storeMaterialized)

        // The first coordinator dies here; a new process logs in again
        // over the same durable registry, secret, and session stores.
        let second = try await makeFixture(
            activeProfile: active,
            existingRegistry: fixture.registry,
            existingSecretStore: fixture.secretStore,
            existingUserStores: fixture.userStores
        )
        await second.coordinator.begin()
        guard case .consent(let resumedID) = second.coordinator.step,
              resumedID == profileID else {
            Issue.record("expected resumed consent, got \(second.coordinator.step)")
            return
        }
        await second.coordinator.finishWithConsent(nil)
        guard case .transferChoice(let choiceID) = second.coordinator.step,
              choiceID == profileID else {
            Issue.record("expected resumed transferChoice, got \(second.coordinator.step)")
            return
        }
        await second.coordinator.finishTransferChoice(.copy)
        let request = try #require(second.probe.transferRequests.first)
        #expect(request.creationTransactionID == provenance)
        #expect(request.sourceProfileID == active.id)
        #expect(request.targetProfileID == profileID)
    }

    /// A profile created from the system Local gets the Local-data step
    /// after consent; keep-separate then commits the plain switch and
    /// persists the stashed consent with it.
    @Test func createdFromLocalOffersChoiceAndKeepSeparateCommits() async throws {
        let active = makeLocalSystemProfile()
        let fixture = try await makeFixture(activeProfile: active)
        let profileID = try await advanceToTransferChoice(fixture)
        #expect(!fixture.probe.relaunched)
        #expect(try fixture.registry.load().activeProfileID == active.id)

        await fixture.coordinator.finishTransferChoice(.keepSeparate)
        #expect(fixture.coordinator.step == .relaunching)
        #expect(fixture.probe.relaunched)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == profileID)
        #expect(document.pendingTransfer == nil)
        let scope = ProfileDefaultsScope(
            defaults: fixture.defaults, profileID: profileID
        )
        #expect(HistoricalSyncConsent.read(from: scope) == .textOnly)
    }

    /// Copy hands the exact one-shot request to the injected transfer
    /// seam — source Local, created target, the committed creation
    /// transaction — and relaunches with the active profile unchanged:
    /// the executor owns the eventual switch.
    @Test func copyChoiceBeginsTransferAndRelaunchesWithActiveUnchanged() async throws {
        let active = makeLocalSystemProfile()
        final class RegistryBox { var registry: ScriptedRegistry? }
        let box = RegistryBox()
        var made: PendingTransfer?
        let fixture = try await makeFixture(
            activeProfile: active,
            beginTransferHook: { request in
                let document = try #require(box.registry).load()
                let source = try #require(document.profiles.first {
                    $0.id == request.sourceProfileID
                })
                let target = try #require(document.profiles.first {
                    $0.id == request.targetProfileID
                })
                let pending = makeTestPendingTransfer(
                    source: source, target: target, mode: request.mode
                )
                made = pending
                return pending
            }
        )
        box.registry = fixture.registry
        let profileID = try await advanceToTransferChoice(fixture)

        await fixture.coordinator.finishTransferChoice(.copy)
        #expect(fixture.coordinator.step == .relaunching)
        // The durable-intent relaunch path, never the switch-style one
        // whose failure handler rolls back and resumes source services.
        #expect(fixture.probe.transferRelaunched)
        #expect(!fixture.probe.relaunched)
        #expect(made != nil)
        let request = try #require(fixture.probe.transferRequests.first)
        #expect(request.sourceProfileID == active.id)
        #expect(request.targetProfileID == profileID)
        #expect(request.mode == .copy)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        let created = try #require(document.profiles.first { $0.id == profileID })
        #expect(request.creationTransactionID == created.createdByBindingTransactionID)
    }

    /// A refused or provably-uncommitted transfer start resumes services
    /// and keeps the choice open; nothing changed in the registry.
    @Test func refusedTransferBeginStaysOnChoicePage() async throws {
        let active = makeLocalSystemProfile()
        let fixture = try await makeFixture(activeProfile: active)
        let profileID = try await advanceToTransferChoice(fixture)

        await fixture.coordinator.finishTransferChoice(.move)
        guard case .transferChoice(let stillID) = fixture.coordinator.step,
              stillID == profileID else {
            Issue.record("expected to stay on transferChoice, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.coordinator.blockedReason != nil)
        #expect(fixture.probe.resumed == 1)
        #expect(!fixture.probe.relaunched)
        #expect(try fixture.registry.load().activeProfileID == active.id)
        // Nothing changed includes the consent: it persists only once
        // the durable transfer intent exists.
        let scope = ProfileDefaultsScope(
            defaults: fixture.defaults, profileID: profileID
        )
        #expect(HistoricalSyncConsent.read(from: scope) == .undecided)
    }

    /// An unclassifiable transfer save halts the transition like every
    /// other indeterminate authority write.
    @Test func indeterminateTransferBeginHalts() async throws {
        let active = makeLocalSystemProfile()
        let fixture = try await makeFixture(
            activeProfile: active,
            beginTransferHook: { _ in
                throw ProfileTransfer.TransferError.commitIndeterminate("scripted")
            }
        )
        _ = try await advanceToTransferChoice(fixture)

        await fixture.coordinator.finishTransferChoice(.copy)
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.halted != nil)
        #expect(!fixture.probe.relaunched)
    }

    @Test func happyPathBindsCurrentProfileAndFinishes() async throws {
        let active = makeActiveProfile()
        let fixture = try await makeFixture(activeProfile: active)
        _ = await fixture.store.createRecording(
            id: UUID(), title: "R", startDate: Date(), segmentsDirURL: nil
        )

        await fixture.coordinator.begin()
        guard case .chooseTarget(let canBind, _) = fixture.coordinator.step, canBind else {
            Issue.record("expected chooseTarget, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.bindCurrentProfile()
        guard case .consent(let profileID) = fixture.coordinator.step,
              profileID == active.id else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.finishWithConsent(.textOnly)
        #expect(fixture.coordinator.step == .relaunching)
        #expect(fixture.probe.relaunched)

        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        let bound = try #require(document.profiles.first?.boundAccount)
        #expect(bound.userID == "u1")
        // First binding arms lock-on-sign-out by default.
        #expect(document.profiles.first?.lockOnSignOut == true)
        #expect(document.pendingBinding == nil)
        let marks = await fixture.store.fetchWebSyncSnapshots(includeTrashed: true)
            .map(\.awaitingHistoricalConsentBindingID)
        #expect(marks.count == 1 && marks.allSatisfy { $0 != nil })
    }

    /// The authorized account is the active profile's own: the flow ends
    /// in a truthful already-active outcome and writes no registry or
    /// session artifact — seeded token and session-user sentinels stay
    /// byte-for-byte unchanged.
    @Test func sameActiveAccountAuthorizationDiscardsWithZeroWrites() async throws {
        let active = makeBoundProfile(userID: "u1", name: "Mine Bound")
        let fixture = try await makeFixture(activeProfile: active, userID: "u1")
        let tokenKey = SessionTokenKey.account(
            profileID: active.id, originKey: AuthTestProfile.origin().originKey
        )
        let sentinelToken = "sentinel-token-\(UUID().uuidString)"
        try fixture.secretStore.set(sentinelToken, for: tokenKey)
        let sentinelUser = SessionUser(
            userID: "u1", email: "o@example.com", displayName: "Owner", pictureURL: nil
        )
        try fixture.userStores.store(active.id).save(sentinelUser)

        await fixture.coordinator.begin()

        guard case .alreadyActiveAccount(let profileName) = fixture.coordinator.step else {
            Issue.record("expected alreadyActiveAccount, got \(fixture.coordinator.step)")
            return
        }
        #expect(profileName == "Mine Bound")
        #expect(fixture.registry.saveCount == 0)
        let storedToken = fixture.secretStore.get(tokenKey)
        #expect(storedToken.map { Array($0.utf8) } == Array(sentinelToken.utf8))
        #expect(try fixture.userStores.store(active.id).load() == sentinelUser)
        #expect(!fixture.probe.relaunched)
        #expect(fixture.probe.transferRequests.isEmpty)
    }

    /// Same origin and user but a different frozen API base path is not
    /// the same account tuple: the flow refuses instead of claiming
    /// nothing changed, and writes nothing.
    @Test func sameAccountDifferentAPIPathRefusesInsteadOfClaimingActive() async throws {
        let active = makeBoundProfile(
            userID: "u1", baseURL: AuthTestProfile.baseURLString + "/other",
            name: "Path Drift"
        )
        let fixture = try await makeFixture(activeProfile: active, userID: "u1")
        let tokenKey = SessionTokenKey.account(
            profileID: active.id, originKey: AuthTestProfile.origin().originKey
        )
        let sentinelToken = "sentinel-token-\(UUID().uuidString)"
        try fixture.secretStore.set(sentinelToken, for: tokenKey)

        await fixture.coordinator.begin()

        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.registry.saveCount == 0)
        let storedToken = fixture.secretStore.get(tokenKey)
        #expect(storedToken.map { Array($0.utf8) } == Array(sentinelToken.utf8))
        #expect(try fixture.userStores.store(active.id).load() == nil)
        #expect(!fixture.probe.relaunched)
    }

    /// A different account that already owns a profile keeps the
    /// existing switch offer when begun from a bound source.
    @Test func differentExistingAccountFromBoundSourceOffersSwitch() async throws {
        let active = makeBoundProfile(userID: "u1", name: "Mine Bound")
        let second = makeBoundProfile(userID: "u2", name: "Second Account")
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [second], userID: "u2"
        )

        await fixture.coordinator.begin()

        guard case .accountAlreadyBound(let profileID, let profileName)
            = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        #expect(profileID == second.id)
        #expect(profileName == "Second Account")
        #expect(fixture.registry.saveCount == 0)
    }

    /// A brand-new account begun from a bound source can only create its
    /// own profile — the bound current profile is not offered as a
    /// binding target. Creation binds the new row and reaches consent
    /// while the source profile stays active.
    @Test func newAccountFromBoundSourceOffersCreateOnly() async throws {
        let active = makeBoundProfile(userID: "u1", name: "Mine Bound")
        let fixture = try await makeFixture(activeProfile: active, userID: "u3")

        await fixture.coordinator.begin()

        guard case .chooseTarget(let canBindCurrent, _) = fixture.coordinator.step else {
            Issue.record("expected chooseTarget, got \(fixture.coordinator.step)")
            return
        }
        #expect(!canBindCurrent)
        #expect(fixture.registry.saveCount == 0)

        await fixture.coordinator.createAccountProfile()

        guard case .consent(let newProfileID) = fixture.coordinator.step else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            return
        }
        #expect(newProfileID != active.id)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        let newRow = try #require(document.profiles.first { $0.id == newProfileID })
        let newBound = try #require(newRow.boundAccount)
        #expect(AccountIdentity.matches(newBound.userID, "u3"))
        #expect(AccountIdentity.matches(
            newBound.originKey, AuthTestProfile.origin().originKey
        ))
        #expect(AccountIdentity.matches(
            newBound.issuerOrigin, AuthTestProfile.origin().normalized
        ))
        #expect(AccountIdentity.matches(newBound.apiBaseURL, AuthTestProfile.baseURLString))
        let activeRow = try #require(document.profiles.first { $0.id == active.id })
        #expect(activeRow.boundAccount?.userID == "u1")
    }

    @Test func beginFailsClosedWhenActiveProfileChangedBehindProcess() async throws {
        let active = makeActiveProfile()
        let other = makeActiveProfile()
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [other])
        var document = try fixture.registry.load()
        document.activeProfileID = other.id
        try fixture.registry.save(document)

        await fixture.coordinator.begin()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
    }

    @Test func switchToExistingRefusesIdentityDrift() async throws {
        let active = makeActiveProfile()
        let origin = AuthTestProfile.origin()
        var owner = makeActiveProfile()
        owner.name = "Owner"
        owner.boundAccount = Profile.BoundAccount(
            userID: "u1", originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: AuthTestProfile.baseURLString,
            displayEmail: "a@b.com", displayName: "A", boundAt: fixedNow
        )
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [owner])

        await fixture.coordinator.begin()
        guard case .accountAlreadyBound(let profileID, _) = fixture.coordinator.step,
              profileID == owner.id else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }

        // The owner's binding drifts to a different user before the switch.
        var drifted = try fixture.registry.load()
        if let index = drifted.profiles.firstIndex(where: { $0.id == owner.id }) {
            drifted.profiles[index].boundAccount?.userID = "someone-else"
        }
        try fixture.registry.save(drifted)

        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        // Zero writes into the owner's slot.
        let account = SessionTokenKey.account(
            profileID: owner.id, originKey: origin.originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(!fixture.probe.relaunched)
    }

    @Test func loginTransitionsRefuseWhileWorkIsActive() async throws {
        let active = makeActiveProfile()
        let fixture = try await makeFixture(activeProfile: active)

        await fixture.coordinator.begin()
        await fixture.coordinator.bindCurrentProfile()
        guard case .consent = fixture.coordinator.step else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            return
        }
        // INV-13: the final transition refuses while work is active, and
        // the step stays retryable.
        fixture.probe.refusal = "busy"
        await fixture.coordinator.finishWithConsent(nil)
        guard case .consent = fixture.coordinator.step else {
            Issue.record("expected consent retained, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.coordinator.blockedReason == "busy")
        #expect(!fixture.probe.relaunched)

        fixture.probe.refusal = nil
        await fixture.coordinator.finishWithConsent(nil)
        #expect(fixture.coordinator.step == .relaunching)
        #expect(fixture.probe.relaunched)
    }

    @Test func switchToExistingRefusesWhileWorkIsActive() async throws {
        let active = makeActiveProfile()
        let origin = AuthTestProfile.origin()
        var owner = makeActiveProfile()
        owner.name = "Owner"
        owner.boundAccount = Profile.BoundAccount(
            userID: "u1", originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: AuthTestProfile.baseURLString,
            displayEmail: "a@b.com", displayName: "A", boundAt: fixedNow
        )
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [owner])

        await fixture.coordinator.begin()
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        fixture.probe.refusal = "busy"
        await fixture.coordinator.switchToExistingProfile()
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected step retained, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.coordinator.blockedReason == "busy")
        let account = SessionTokenKey.account(
            profileID: owner.id, originKey: origin.originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(!fixture.probe.relaunched)
    }

    @Test func finishWithConsentFailsHardWhenProfileDisappeared() async throws {
        let active = makeActiveProfile()
        let fixture = try await makeFixture(activeProfile: active)

        await fixture.coordinator.begin()
        await fixture.coordinator.bindCurrentProfile()
        guard case .consent = fixture.coordinator.step else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            return
        }

        // The bound profile disappears before the switch commits.
        var document = try fixture.registry.load()
        let replacement = makeActiveProfile()
        document.profiles = [replacement]
        document.activeProfileID = replacement.id
        try? fixture.registry.save(document)

        await fixture.coordinator.finishWithConsent(.textOnly)
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(!fixture.probe.relaunched)
    }

    @Test func freshProfilePreCommitFailureRemovesTheInertProfile() async throws {
        let active = makeActiveProfile(bound: Profile.BoundAccount(
            userID: "other-user",
            originKey: AuthTestProfile.origin().originKey,
            issuerOrigin: AuthTestProfile.origin().normalized,
            apiBaseURL: AuthTestProfile.baseURLString,
            displayEmail: "o@b.com", displayName: "O", boundAt: fixedNow
        ))
        let fixture = try await makeFixture(activeProfile: active)

        await fixture.coordinator.begin()
        guard case .chooseTarget(let canBind, _) = fixture.coordinator.step, !canBind else {
            Issue.record("expected chooseTarget without bind, got \(fixture.coordinator.step)")
            return
        }
        // Phase B token write fails — a definite pre-commit failure.
        fixture.secretStore.failNextWriteWith = NSError(domain: "test", code: 1)
        await fixture.coordinator.createAccountProfile()

        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        let document = try fixture.registry.load()
        // The freshly-created profile was provably inert and removed.
        #expect(document.profiles.count == 1)
        #expect(document.profiles.first?.id == active.id)
        #expect(document.pendingBinding == nil)
    }
}

// MARK: - Drain primitives

struct TaskDrainTests {
    @Test func emptyAndCompletedTasksDrainTrue() async {
        #expect(await TaskDrain.awaitAll([], timeout: .milliseconds(50)))
        let done = Task<Void, Never> { }
        #expect(await TaskDrain.awaitAll([done], timeout: .seconds(1)))
    }

    @Test func hungTaskTimesOutFalseWithinTheBound() async {
        let gate = AsyncStream<Void>.makeStream()
        let hung = Task<Void, Never> {
            for await _ in gate.stream { }
        }
        let start = ContinuousClock.now
        let drained = await TaskDrain.awaitAll([hung], timeout: .milliseconds(150))
        let elapsed = ContinuousClock.now - start
        #expect(!drained)
        #expect(elapsed < .seconds(2))
        gate.continuation.finish()
        _ = await hung.value
    }
}

// MARK: - WebSync suspension during transitions

@MainActor
struct WebSyncSuspensionTests {
    @Test func suspendedCoordinatorSpawnsNoStoreTasksUntilResumed() async throws {
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(inMemory: true)
        )
        let http = FakeAuthHTTP()
        let secrets = InMemoryAuthSecretStore()
        try writeStoredToken(into: secrets, value: "token",
                             expiresAt: Date().addingTimeInterval(3_600))
        let users = InMemoryUserStore()
        users.user = .init(id: "user-1", email: "u@example.com", displayName: "U", pictureURL: nil)
        let auth = try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "user-1"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: secrets,
            sessionUserStore: users,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "user-1"))
        )
        let defaults = UserDefaults(suiteName: "websync-suspend-\(UUID().uuidString)")!
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults,
            historicalConsent: { .undecided }
        )
        // The signed-in session publishes its user ID into the store.
        var published: String?
        for _ in 0..<200 {
            published = await store.debugActiveWebSyncUserID()
            if published == "user-1" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(published == "user-1")

        #expect(await coordinator.stopAndWait())
        #expect(coordinator.isSuspended)

        // A session change published mid-transition updates cached state
        // only; no worker or store task may spawn behind the drain — the
        // store still shows the pre-suspension value.
        coordinator.sessionChanged(state: .signedOut, user: nil)
        coordinator.reconcile()
        #expect(!coordinator.isSyncing)
        #expect(coordinator.isSuspended)
        #expect(await store.debugActiveWebSyncUserID() == "user-1")

        // Resume must republish the cached session even though it is now
        // signed out: the stale ID would otherwise keep the old account's
        // rows treated as active after a refused transition.
        coordinator.resume()
        #expect(!coordinator.isSuspended)
        var cleared: String? = "sentinel"
        for _ in 0..<200 {
            cleared = await store.debugActiveWebSyncUserID()
            if cleared == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cleared == nil)
        coordinator.stop()
    }
}

// MARK: - Frozen-tuple, byte-identity, and unlock coverage

extension ProfileLoginCoordinatorTests {
    /// Same origin, same user, different API path: the switch must
    /// refuse before any artifact write — a token minted against the
    /// configured backend must never land in a slot whose frozen base
    /// differs, where the runtime would send it to the old base.
    @Test func sameOriginDifferentAPIPathRefusesSwitchWithZeroWrites() async throws {
        let active = makeActiveProfile()
        let owned = makeBoundProfile(
            userID: "u1", baseURL: "https://cadenzapp.test/other/api", isLocked: true
        )
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [owned])

        await fixture.coordinator.begin()
        guard case .accountAlreadyBound(let id, _) = fixture.coordinator.step, id == owned.id else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        let account = SessionTokenKey.account(
            profileID: owned.id,
            originKey: AuthTestProfile.origin(baseURL: "https://cadenzapp.test/other/api").originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.userStores.store(owned.id).load() == nil)
        let document = try fixture.registry.load()
        #expect(document.profiles.first(where: { $0.id == owned.id })?.isLocked == true)
        #expect(document.activeProfileID == active.id)
        #expect(!fixture.probe.relaunched)
    }

    /// INV-2 lookup is byte-exact: a canonically equivalent but
    /// byte-distinct user ID must not select the bound profile.
    @Test func canonicallyEquivalentUserIDDoesNotMatchBoundProfile() async throws {
        let active = makeActiveProfile()
        let owned = makeBoundProfile(userID: "us\u{00E9}r-1")
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [owned], userID: "use\u{0301}r-1"
        )
        await fixture.coordinator.begin()
        guard case .chooseTarget = fixture.coordinator.step else {
            Issue.record("expected chooseTarget, got \(fixture.coordinator.step)")
            return
        }
    }

    /// Two origins: the unlock dance must run against the locked row's
    /// frozen backend, not the configured new-login backend, and unlock
    /// exactly that row.
    @Test func unlockAuthorizesAgainstTargetFrozenBackendAndUnlocks() async throws {
        let selfHostBase = "https://self.example:8443/custom/api"
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", baseURL: selfHostBase, isLocked: true)
        let seenHosts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked],
            onAuthorizeURL: { url in
                seenHosts.withLock { $0.append(url.host() ?? "") }
            }
        )

        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound(let id, _) = fixture.coordinator.step, id == locked.id else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        #expect(seenHosts.withLock { $0 } == ["self.example"])

        await fixture.coordinator.switchToExistingProfile()
        #expect(fixture.coordinator.step == .relaunching)
        #expect(fixture.probe.relaunched)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == locked.id)
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == false)
        let account = SessionTokenKey.account(
            profileID: locked.id,
            originKey: AuthTestProfile.origin(baseURL: selfHostBase).originKey
        )
        #expect(fixture.secretStore.get(account) != nil)
        #expect(try fixture.userStores.store(locked.id).load()?.userID == "u1")
    }

    /// The wrong account cannot unlock: nothing is written, the target
    /// stays locked, and the rejected authorization is not retained for
    /// a later switch.
    @Test func unlockWrongAccountWritesNothingAndStaysLocked() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked], userID: "intruder"
        )

        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .failed(let message) = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(message == AuthError.accountMismatch.localizedMessage())
        let account = SessionTokenKey.account(
            profileID: locked.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.userStores.store(locked.id).load() == nil)
        let document = try fixture.registry.load()
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
        #expect(document.activeProfileID == active.id)

        await fixture.coordinator.switchToExistingProfile()
        #expect(!fixture.probe.relaunched)
    }

    /// Byte-distinct spelling of the bound identity is a wrong account
    /// for unlock purposes as well.
    @Test func unlockRefusesCanonicallyEquivalentByteDistinctAccount() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "us\u{00E9}r-1", isLocked: true)
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked], userID: "use\u{0301}r-1"
        )
        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        let account = SessionTokenKey.account(
            profileID: locked.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.registry.load()
            .profiles.first(where: { $0.id == locked.id })?.isLocked == true)
    }

    /// The commit precondition re-proves the frozen tuple in exact
    /// bytes: a canonically equivalent respelling during the quiescence
    /// drain must refuse at the commit boundary, with no unlock and no
    /// active-ID change.
    @Test func targetRespelledDuringDrainRefusesBeforeArtifactWrites() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "us\u{00E9}r-1", isLocked: true)
        let lockedID = locked.id
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked], userID: "us\u{00E9}r-1",
            prepareTransitionHook: { registry in
                do {
                    var document = try registry.load()
                    if let index = document.profiles.firstIndex(where: { $0.id == lockedID }) {
                        document.profiles[index].boundAccount?.userID = "use\u{0301}r-1"
                    }
                    try registry.save(document)
                } catch {
                    Issue.record("hook mutation failed: \(error)")
                }
                return true
            }
        )

        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(!fixture.probe.relaunched)
        // Source proven still owned: a safe refusal that resumes.
        #expect(fixture.probe.resumed > 0)
        #expect(fixture.probe.halted == nil)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
        // The post-drain reproof refused before any artifact write.
        let account = SessionTokenKey.account(
            profileID: locked.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.userStores.store(locked.id).load() == nil)
    }

    /// A refused quiescence never commits: the registry keeps the old
    /// active profile and the locked target untouched.
    @Test func refusedQuiescenceLeavesRegistryUncommitted() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked], prepareTransitionOK: false
        )
        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.switchToExistingProfile()
        #expect(fixture.coordinator.blockedReason != nil)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
        #expect(!fixture.probe.relaunched)
    }
}

// MARK: - Phase A source authority

extension ProfileLoginCoordinatorTests {
    /// The active profile switches between authorization and phase A:
    /// bind-current must refuse inside phase A's fresh load with zero
    /// pending, artifact, or mark writes.
    @Test func bindCurrentRefusesWhenActiveProfileSwitchedAfterAuthorization() async throws {
        let active = makeActiveProfile()
        let other = makeActiveProfile()
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [other])
        _ = await fixture.store.createRecording(
            id: UUID(), title: "R", startDate: Date(), segmentsDirURL: nil
        )

        await fixture.coordinator.begin()
        guard case .chooseTarget = fixture.coordinator.step else {
            Issue.record("expected chooseTarget, got \(fixture.coordinator.step)")
            return
        }
        var document = try fixture.registry.load()
        document.activeProfileID = other.id
        try fixture.registry.save(document)

        await fixture.coordinator.bindCurrentProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        // Lost source authority: halt, never a resumed refusal.
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        let after = try fixture.registry.load()
        #expect(after.pendingBinding == nil)
        #expect(after.profiles.allSatisfy { $0.boundAccount == nil })
        let account = SessionTokenKey.account(
            profileID: active.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        #expect(try fixture.userStores.store(active.id).load() == nil)
        let marks = await fixture.store.fetchWebSyncSnapshots(includeTrashed: true)
            .map(\.awaitingHistoricalConsentBindingID)
        #expect(marks.allSatisfy { $0 == nil })
    }

    /// The same race against create: no profile row, pending record, or
    /// artifact may exist after the refusal.
    @Test func createRefusesWhenActiveProfileSwitchedAfterAuthorization() async throws {
        let active = makeActiveProfile()
        let other = makeActiveProfile()
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [other])

        await fixture.coordinator.begin()
        guard case .chooseTarget = fixture.coordinator.step else {
            Issue.record("expected chooseTarget, got \(fixture.coordinator.step)")
            return
        }
        var document = try fixture.registry.load()
        document.activeProfileID = other.id
        try fixture.registry.save(document)

        await fixture.coordinator.createAccountProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        let after = try fixture.registry.load()
        #expect(after.pendingBinding == nil)
        #expect(after.profiles.count == 2)
        #expect(after.profiles.allSatisfy { $0.boundAccount == nil })
    }
}

// MARK: - Source drift around the switch commits

extension ProfileLoginCoordinatorTests {
    /// Active-ID drift after authorization, before the switch: refused
    /// ahead of any artifact write; the other instance's active ID is
    /// never overwritten.
    @Test func switchRefusesWhenSourceLostActiveSlotAfterAuthorization() async throws {
        let active = makeActiveProfile()
        let other = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [other, locked]
        )
        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        var document = try fixture.registry.load()
        document.activeProfileID = other.id
        try fixture.registry.save(document)

        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        // Lost source slot is unknown authority: halt, never resume the
        // old services against the new owner.
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        let account = SessionTokenKey.account(
            profileID: locked.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        let after = try fixture.registry.load()
        #expect(after.activeProfileID == other.id)
        #expect(after.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
        #expect(!fixture.probe.relaunched)
    }

    /// Active-ID drift during the quiescence drain: refused at the
    /// commit precondition; the concurrent instance's active ID stands.
    @Test func switchRefusesWhenSourceLostActiveSlotDuringDrain() async throws {
        let active = makeActiveProfile()
        let other = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        let otherID = other.id
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [other, locked],
            prepareTransitionHook: { registry in
                do {
                    var document = try registry.load()
                    document.activeProfileID = otherID
                    try registry.save(document)
                } catch {
                    Issue.record("hook mutation failed: \(error)")
                }
                return true
            }
        )
        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        let after = try fixture.registry.load()
        #expect(after.activeProfileID == other.id)
        #expect(after.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
        #expect(!fixture.probe.relaunched)
    }

    /// Consent-step drain drift: the bind committed, but the final
    /// switch must not overwrite an active ID another instance took
    /// during quiescence.
    @Test func consentSwitchRefusesWhenActiveSlotTakenDuringDrain() async throws {
        let active = makeActiveProfile()
        let other = makeActiveProfile()
        let otherID = other.id
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [other],
            prepareTransitionHook: { registry in
                do {
                    var document = try registry.load()
                    document.activeProfileID = otherID
                    try registry.save(document)
                } catch {
                    Issue.record("hook mutation failed: \(error)")
                }
                return true
            }
        )
        await fixture.coordinator.begin()
        guard case .chooseTarget(let canBind, _) = fixture.coordinator.step, canBind else {
            Issue.record("expected chooseTarget, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.bindCurrentProfile()
        guard case .consent = fixture.coordinator.step else {
            Issue.record("expected consent, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.finishWithConsent(.textOnly)
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(try fixture.registry.load().activeProfileID == other.id)
        #expect(!fixture.probe.relaunched)
        // Lost source slot: halt without resuming, and the consent was
        // never written.
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        let scope = ProfileDefaultsScope(
            defaults: fixture.defaults, profileID: fixture.activeProfile.id
        )
        #expect(HistoricalSyncConsent.read(from: scope) == .undecided)
    }
}

// MARK: - Post-drain artifact-write failure

extension ProfileLoginCoordinatorTests {
    /// A target artifact write failing after the drain resumes the old
    /// profile's services and leaves the registry's active and lock
    /// state unchanged.
    @Test func artifactWriteFailureAfterDrainResumesWithRegistryUnchanged() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        let fixture = try await makeFixture(activeProfile: active, extraProfiles: [locked])

        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        fixture.secretStore.failNextWriteWith = NSError(domain: "test", code: 7)
        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.resumed > 0)
        #expect(fixture.probe.halted == nil)
        #expect(!fixture.probe.relaunched)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
        #expect(try fixture.userStores.store(locked.id).load() == nil)
    }
}

// MARK: - Post-drain halt branches

extension ProfileLoginCoordinatorTests {
    /// An unreadable registry after the drain is unknown authority:
    /// halt, no resume, zero artifact writes.
    @Test func registryUnreadableAfterDrainHalts() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked],
            prepareTransitionHook: { registry in
                registry.configure { $0.failLoad = true }
                return true
            }
        )
        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        #expect(!fixture.probe.relaunched)
        let account = SessionTokenKey.account(
            profileID: locked.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        // Readable again only to inspect: nothing changed.
        fixture.registry.configure { $0.failLoad = false }
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == active.id)
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
    }

    /// A pending operation appearing during the drain is another
    /// instance's transaction: halt, no resume, zero artifact writes.
    @Test func pendingOperationAfterDrainHalts() async throws {
        let active = makeActiveProfile()
        let locked = makeBoundProfile(userID: "u1", isLocked: true)
        var bindTarget = makeActiveProfile()
        bindTarget.name = "T"
        bindTarget.storeMaterialized = false
        let targetID = bindTarget.id
        let fixture = try await makeFixture(
            activeProfile: active, extraProfiles: [locked, bindTarget],
            prepareTransitionHook: { registry in
                do {
                    var document = try registry.load()
                    let origin = AuthTestProfile.origin()
                    document.pendingBinding = PendingBinding(
                        transactionID: UUID(),
                        profileID: targetID,
                        userID: "u9",
                        originKey: origin.originKey,
                        issuerOrigin: origin.normalized,
                        apiBaseURL: AuthTestProfile.baseURLString,
                        tokenDigest: SessionTokenDigest.digest(of: "raw"),
                        createdProfile: false,
                        startedAt: Date(timeIntervalSince1970: 1_785_700_000)
                    )
                    try registry.save(document)
                } catch {
                    Issue.record("hook mutation failed: \(error)")
                }
                return true
            }
        )
        await fixture.coordinator.beginUnlock(of: locked.id)
        guard case .accountAlreadyBound = fixture.coordinator.step else {
            Issue.record("expected accountAlreadyBound, got \(fixture.coordinator.step)")
            return
        }
        await fixture.coordinator.switchToExistingProfile()
        guard case .failed = fixture.coordinator.step else {
            Issue.record("expected failed, got \(fixture.coordinator.step)")
            return
        }
        #expect(fixture.probe.halted != nil)
        #expect(fixture.probe.resumed == 0)
        let account = SessionTokenKey.account(
            profileID: locked.id, originKey: AuthTestProfile.origin().originKey
        )
        #expect(fixture.secretStore.get(account) == nil)
        let document = try fixture.registry.load()
        #expect(document.profiles.first(where: { $0.id == locked.id })?.isLocked == true)
    }
}

// MARK: - Sign-out lock tri-state through AppState

@MainActor
struct AppStateSignOutTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_785_700_000)

    private func makeProfile(
        id: UUID = UUID(),
        kind: Profile.Kind = .standard,
        name: String = "Mine",
        bound: Profile.BoundAccount? = nil,
        lockOnSignOut: Bool = false
    ) -> Profile {
        Profile(
            id: id,
            kind: kind,
            name: name,
            colorHex: nil,
            createdAt: fixedNow,
            lastActiveAt: fixedNow,
            audioDirectory: .init(bookmark: nil, path: "/tmp/audio", kind: .appManaged),
            boundAccount: bound,
            lockOnSignOut: lockOnSignOut,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )
    }

    private struct SignOutFixture {
        let state: AppState
        let registry: ScriptedRegistry
        let account: Profile
        let local: Profile
        let secrets: InMemoryAuthSecretStore
        let users: InMemoryUserStore
        let tokenSlot: String
    }

    /// Registry, boot context, and the injected auth service are all
    /// derived from the one bound account profile, so the fixture cannot
    /// describe a session the registry does not.
    private func makeSignOutFixture(lockOnSignOut: Bool) throws -> SignOutFixture {
        let origin = AuthTestProfile.origin()
        let bound = Profile.BoundAccount(
            userID: "u1",
            originKey: origin.originKey,
            issuerOrigin: origin.normalized,
            apiBaseURL: AuthTestProfile.baseURLString,
            displayEmail: "a@b.com",
            displayName: "Andy",
            boundAt: fixedNow
        )
        let account = makeProfile(bound: bound, lockOnSignOut: lockOnSignOut)
        let local = makeProfile(kind: .system, name: "Local")
        let document = ProfileRegistryDocument(
            version: 1, activeProfileID: account.id, profiles: [account, local]
        )
        try document.validate()
        let registry = ScriptedRegistry(document: document)
        let secrets = InMemoryAuthSecretStore()
        let users = InMemoryUserStore()
        users.user = .init(id: "u1", email: "a@b.com", displayName: "Andy", pictureURL: nil)
        let tokenSlot = SessionTokenKey.account(
            profileID: account.id, originKey: origin.originKey
        )
        try writeStoredToken(
            into: secrets, value: "tok",
            expiresAt: Date().addingTimeInterval(3_600), account: tokenSlot
        )
        let auth = try CadenzaAuthService.bootstrapped(
            sessionProfile: .init(profile: account),
            http: FakeAuthHTTP(),
            authorizer: FakeAuthorizationProvider(),
            secretStore: secrets,
            sessionUserStore: users,
            registry: registry
        )
        let state = AppState(cadenzaAuth: auth)
        state.profileRegistryForTesting = registry
        state.profileBootContext = ProfileBootContext(
            mode: .profile(account.id),
            storeURL: nil,
            chatHistoryDirectory: nil,
            backupsDirectory: nil,
            profile: account
        )
        return SignOutFixture(
            state: state, registry: registry, account: account, local: local,
            secrets: secrets, users: users, tokenSlot: tokenSlot
        )
    }

    /// Explicit sign-out with the lock armed: disposition flips, the
    /// profile locks, and the registry switches to Local before the
    /// relaunch.
    @Test func signOutArmsLockSwitchesToLocalAndRelaunches() async throws {
        let fixture = try makeSignOutFixture(lockOnSignOut: true)
        #expect(fixture.state.cadenzaAuth.sessionState == .signedIn)
        let relaunched = OSAllocatedUnfairLock(initialState: false)
        fixture.state.relaunchHandlerForTesting = { _ in
            relaunched.withLock { $0 = true }
        }

        await fixture.state.signOutFromProfile()

        #expect(fixture.state.profileActionError == nil)
        #expect(relaunched.withLock { $0 })
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == fixture.local.id)
        let account = document.profiles.first { $0.id == fixture.account.id }
        #expect(account?.sessionDisposition == .explicitlySignedOut)
        #expect(account?.isLocked == true)
        // The binding itself survives sign-out (INV-3: sign-out is a
        // disposition, not an unbind), the credential is durably gone,
        // and the session-user record stays by design.
        #expect(account?.boundAccount != nil)
        #expect(fixture.secrets.get(fixture.tokenSlot) == nil)
        #expect(fixture.users.user != nil)
        #expect(fixture.state.cadenzaAuth.sessionState == .signedOut)
    }

    /// Sign-out with the lock disarmed leaves the profile enterable.
    @Test func signOutWithoutLockLeavesProfileUnlocked() async throws {
        let fixture = try makeSignOutFixture(lockOnSignOut: false)
        fixture.state.relaunchHandlerForTesting = { _ in }

        await fixture.state.signOutFromProfile()

        #expect(fixture.state.profileActionError == nil)
        let document = try fixture.registry.load()
        #expect(document.activeProfileID == fixture.local.id)
        let account = document.profiles.first { $0.id == fixture.account.id }
        #expect(account?.sessionDisposition == .explicitlySignedOut)
        #expect(account?.isLocked == false)
        #expect(fixture.secrets.get(fixture.tokenSlot) == nil)
        #expect(fixture.users.user != nil)
    }

    /// A durable pendingTransfer makes the switch-style rollback wrong:
    /// activeProfileID never moved, so the only safe response to a spawn
    /// failure is halting with the intent preserved and nothing resumed.
    @Test func transferRelaunchFailureHaltsAndPreservesThePendingIntent() async throws {
        let fixture = try makeSignOutFixture(lockOnSignOut: false)
        var document = try fixture.registry.load()
        // Real transfer shape: the system Local is the active source and
        // the bound account profile is a fresh, not-yet-materialized
        // target.
        document.activeProfileID = fixture.local.id
        let accountIndex = try #require(
            document.profiles.firstIndex { $0.id == fixture.account.id }
        )
        document.profiles[accountIndex].storeMaterialized = false
        document.profiles[accountIndex].createdByBindingTransactionID = UUID()
        document.pendingTransfer = makeTestPendingTransfer(
            source: fixture.local, target: document.profiles[accountIndex]
        )
        try fixture.registry.save(document)
        let savesBefore = fixture.registry.saveCount
        let handlerRan = OSAllocatedUnfairLock(initialState: false)
        fixture.state.relaunchHandlerForTesting = { onFailure in
            handlerRan.withLock { $0 = true }
            onFailure("scripted spawn failure")
        }

        fixture.state.performTransferRelaunch()

        #expect(handlerRan.withLock { $0 })
        guard case .halted(let reason) = fixture.state.profileTransitionPhase else {
            Issue.record("expected halted, got \(fixture.state.profileTransitionPhase)")
            return
        }
        #expect(reason.contains("pending transfer"))
        // No rollback save; the durable intent stays untouched.
        #expect(fixture.registry.saveCount == savesBefore)
        #expect(try fixture.registry.load().pendingTransfer != nil)
        // Every ordinary surface stays refused: recording throws, and
        // the profile document and login entry points are unavailable.
        #expect(fixture.state.profileTransitionBlockReason != nil)
        await #expect(throws: AppState.ProfileTransitionHaltedError.self) {
            try await fixture.state.startRecording()
        }
        #expect(fixture.state.loadProfileDocument() == nil)
        #expect(fixture.state.makeProfileLoginCoordinator() == nil)
    }

    /// The distinction is real: the same spawn failure on the normal
    /// switch path rolls the registry back and resumes with an error.
    @Test func normalRelaunchFailureRollsBackAndResumesUnlikeTransfer() async throws {
        let fixture = try makeSignOutFixture(lockOnSignOut: false)
        let savesBefore = fixture.registry.saveCount
        fixture.state.relaunchHandlerForTesting = { onFailure in
            onFailure("scripted spawn failure")
        }

        fixture.state.performProfileRelaunch()

        #expect(fixture.state.profileTransitionPhase == .idle)
        #expect(fixture.registry.saveCount == savesBefore + 1)
        #expect(fixture.state.profileActionError != nil)
    }
}

// MARK: - Archive chat source follows the boot policy

@MainActor
struct AppStateArchiveSourceTests {
    private func makeContext(
        mode: ProfileBootContext.Mode, chatDirectory: URL?
    ) -> ProfileBootContext {
        ProfileBootContext(
            mode: mode,
            storeURL: nil,
            chatHistoryDirectory: chatDirectory,
            backupsDirectory: nil,
            profile: nil
        )
    }

    /// The archive's chat directory is the resolved profile's own — a
    /// Local archive can never include an account profile's history.
    @Test func archiveChatDirectoryIsTheResolvedProfilesOwn() throws {
        let state = AppState()
        let localChat = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-chat-\(UUID().uuidString)", isDirectory: true)
        state.profileBootContext = makeContext(
            mode: .profile(UUID()), chatDirectory: localChat
        )
        let makeSource = try #require(state.exportService.archiveExporter.makeSource)
        #expect(makeSource().chatHistoryDirectory == localChat)
    }

    /// Profile boots without a usable chat directory, halted boots, and
    /// TestHost (no boot context) omit chat entirely instead of falling
    /// back to a global path.
    @Test func archiveChatIsOmittedWithoutAResolvedDirectory() throws {
        let state = AppState()
        let makeSource = try #require(state.exportService.archiveExporter.makeSource)
        #expect(makeSource().chatHistoryDirectory == nil)

        state.profileBootContext = makeContext(mode: .profile(UUID()), chatDirectory: nil)
        #expect(makeSource().chatHistoryDirectory == nil)

        state.profileBootContext = makeContext(
            mode: .halted(reason: "probe"), chatDirectory: nil
        )
        #expect(makeSource().chatHistoryDirectory == nil)
    }

    /// The pre-commit legacy fallback keeps exporting the legacy chat
    /// location.
    @Test func archiveChatUsesLegacyDirectoryOnlyInLegacyFallback() throws {
        let state = AppState()
        state.profileBootContext = makeContext(
            mode: .legacyFallback(reason: "probe"), chatDirectory: nil
        )
        let makeSource = try #require(state.exportService.archiveExporter.makeSource)
        #expect(makeSource().chatHistoryDirectory == ChatHistoryManager.legacyDirectory)
    }
}
