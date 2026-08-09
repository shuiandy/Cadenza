import Foundation
import Testing
@testable import Cadenza

/// Drives the real coordinator, auth service and store so the entitlement
/// gates are exercised where they actually run rather than in isolation.
@Suite("Web sync entitlement gates", .serialized)
struct WebSyncEntitlementGateTests {
    // MARK: - Fixtures

    private static let upsertBody = Data(
        (#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "a", count: 64)
            + #"","audio_state":"unavailable"}"#).utf8
    )

    private static func entitlementsBody(
        audioUpload: Bool, textQuota: Int64? = nil, textUsed: Int64 = 0
    ) -> Data {
        var body: [String: Any] = [
            "contract_version": 1,
            "plan": "free",
            "subscription_status": "active",
            "text_sync_used": textUsed,
            "text_sync_unit": "recordings",
            "text_sync_period": "none",
            "audio_upload": audioUpload,
            "storage_quota_bytes": NSNull(),
            "used_bytes": 0,
            "storage_reserved_bytes": 0,
        ]
        body["text_sync_quota"] = textQuota as Any? ?? NSNull()
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func rejection(code: String) -> Data {
        Data(#"{"code":"\#(code)","error":"\#(code)","message":"server prose"}"#.utf8)
    }

    /// The decoded contract behind `entitlementsBody`, for tests that install
    /// knowledge instead of fetching it.
    private static func contract(audioUpload: Bool) -> EntitlementsContract {
        guard case .entitled(let contract) = EntitlementsResolution.classify(
            status: 200, body: entitlementsBody(audioUpload: audioUpload), service: .official
        ) else {
            fatalError("fixture must decode")
        }
        return contract
    }

    @MainActor
    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://cadenzapp.test")!, statusCode: status,
            httpVersion: nil, headerFields: nil
        )!
    }

    @MainActor
    private func signedIn(
        http: FakeAuthHTTP, userID: String = "user-1", baseURL: String = AuthTestProfile.baseURLString
    ) -> CadenzaAuthService {
        let secrets = InMemoryAuthSecretStore()
        try! writeStoredToken(
            into: secrets, value: "token", expiresAt: Date().addingTimeInterval(3_600),
            account: AuthTestProfile.tokenAccount(baseURL: baseURL)
        )
        let users = InMemoryUserStore()
        users.user = .init(id: userID, email: "u@example.com", displayName: "User", pictureURL: nil)
        return try! CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: userID, baseURL: baseURL),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: secrets,
            sessionUserStore: users,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: userID))
        )
    }

    /// Seeds a recording with committed audio on an isolated root.
    @MainActor
    private func seedAudioRecording(
        _ store: RecordingsStore, recordingID: UUID
    ) async throws -> URL {
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("entitlement-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 7, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID, title: "One", startDate: Date(),
            duration: 10, audioURL: audioURL, ownership: .appCreated
        ))
        return audioRoot
    }

    /// A bound service whose token slot is empty, so it boots without an
    /// installed session and the coordinator sees only what a test publishes.
    @MainActor
    private func signedOut(http: FakeAuthHTTP) throws -> CadenzaAuthService {
        let users = InMemoryUserStore()
        users.user = .init(id: "user-1", email: "u@example.com", displayName: "User", pictureURL: nil)
        return try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "user-1"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: InMemoryAuthSecretStore(),
            sessionUserStore: users,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "user-1"))
        )
    }

    @MainActor
    private func makeStore() async throws -> RecordingsStore {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        return store
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WebSyncEntitlementGateTests-\(UUID().uuidString)")!
    }

    // MARK: - Fetch identity

    @Test @MainActor
    func aMissingEndpointOnTheOfficialIssuerNeverOpensTheGate() async throws {
        // AuthTestProfile binds a non-official issuer, so the official case is
        // asserted through the frozen classification the client actually uses.
        let official = Profile.BoundAccount(
            userID: "user-1",
            originKey: CadenzaBackendConfig.official().origin.originKey,
            issuerOrigin: CadenzaBackendConfig.official().origin.normalized,
            apiBaseURL: CadenzaBackendConfig.officialAPIBaseURLString,
            displayEmail: "a@b.com", displayName: "Andy",
            boundAt: Date(timeIntervalSince1970: 1_785_628_800)
        )
        let authority = EntitlementsAuthority(profileID: UUID(), bound: official)
        #expect(authority?.service == .official)

        let gate = EntitlementsGate()
        gate.bind(to: authority)
        gate.apply(
            EntitlementsResolution.classify(status: 404, body: Data(), service: .official),
            for: authority!
        )
        #expect(gate.knowledge == nil)
    }

    @Test @MainActor
    func aFrozenSelfHostBindingOpensOnAMissingEndpoint() async throws {
        let store = try await makeStore()
        let http = FakeAuthHTTP()
        // The test profile's issuer is not the official one, which is exactly
        // the caller-proven self-host shape.
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 404)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()

        #expect(coordinator.entitlements.authority?.service == .selfHost)
        #expect(coordinator.entitlements.knowledge == .selfHostOpen)
        coordinator.stop()
    }

    @Test @MainActor
    func aSupportedResponseBecomesAuthorityForTheBoundAccount() async throws {
        let store = try await makeStore()
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: false), response: response(status: 200)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()

        guard case .contract(let contract)? = coordinator.entitlements.knowledge else {
            Issue.record("expected a contract")
            return
        }
        #expect(contract.audioUpload == false)
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)
        coordinator.stop()
    }

    @Test @MainActor
    func anUnreadableResponseRetainsOnlyTheSameAccountsPreviousState() async throws {
        let store = try await makeStore()
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: false), response: response(status: 200)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)

        // A newer contract and then a server failure: neither replaces what the
        // account already proved.
        http.enqueue(.success(
            data: Data(#"{"contract_version":99,"plan":"pro"}"#.utf8), response: response(status: 200)
        ))
        coordinator.refreshEntitlements()
        try await settle()
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)

        http.enqueue(.success(data: Data(), response: response(status: 503)))
        coordinator.refreshEntitlements()
        try await settle()
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)
        coordinator.stop()
    }

    @Test @MainActor
    func anAccountSwitchCannotBorrowThePreviousAccountsSnapshot() async throws {
        let store = try await makeStore()
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: false), response: response(status: 200)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        #expect(coordinator.entitlements.knowledge != nil)

        // A different account on the same profile binding: the session user is
        // no longer the bound one, so there is no authority at all.
        coordinator.sessionChanged(
            state: .signedIn,
            user: .init(id: "user-2", email: "b@example.com", displayName: "Other", pictureURL: nil)
        )
        #expect(coordinator.entitlements.authority == nil)
        #expect(coordinator.entitlements.knowledge == nil)
        // No authority for this account is no grant.
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-2") == false)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-2") == true)
        coordinator.stop()
    }

    @Test @MainActor
    func signingOutDropsTheAccountsEntitlementState() async throws {
        let store = try await makeStore()
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: false), response: response(status: 200)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        #expect(coordinator.entitlements.knowledge != nil)

        coordinator.sessionChanged(state: .signedOut, user: nil)
        #expect(coordinator.entitlements.authority == nil)
        #expect(coordinator.entitlements.knowledge == nil)
        coordinator.stop()
    }

    @Test @MainActor
    func aSuspendedCoordinatorStartsNoEntitlementFetch() async throws {
        let store = try await makeStore()
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)

        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true), response: response(status: 200)
        ))
        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        #expect(await coordinator.stopAndWait())
        let before = http.requests.count

        // A session change published during a profile transition binds the gate
        // but starts nothing behind the drain.
        coordinator.sessionChanged(state: .signedIn, user: auth.currentUser)
        try await settle()
        #expect(coordinator.entitlements.authority != nil)
        #expect(http.requests.count == before)
        coordinator.stop()
    }

    // MARK: - Gates

    @Test @MainActor
    func knownAudioFalseKeepsStructuredSyncAndSkipsAudio() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: false), response: response(status: 200)
        ))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults)
        try await settle()

        let record = await waitForRecord(store, recordingID: recordingID) {
            $0.structuredState == WebStructuredSyncState.synced.rawValue
        }
        #expect(record?.structuredState == WebStructuredSyncState.synced.rawValue)
        // This row has no readable audio file, so it is unavailable rather than
        // withheld; either way no audio endpoint is reached.
        #expect(record?.audioState == WebAudioSyncState.unavailable.rawValue)
        #expect(http.requests.contains { $0.url?.path.contains("audio/sessions") == true } == false)
        coordinator.stop()
    }

    // MARK: - Rejections

    @Test @MainActor
    func aTextQuotaRejectionStopsFurtherStructuredAttemptsWithoutRetrying() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"), response: response(status: 403)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()

        let record = await waitForRecord(store, recordingID: recordingID) {
            $0.lastErrorCode != nil
        }
        #expect(record?.lastErrorCode == "entitlement:text_quota_exceeded")
        // Refused, not deferred: the row leaves the retry loop entirely.
        #expect(record?.nextAttemptAt == .distantFuture)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)

        // A further pass makes no request at all for this account.
        let before = http.requests.count
        await coordinator.runOnePassForTesting(user: auth.currentUser!)
        #expect(http.requests.count == before)
        coordinator.stop()
    }

    @Test @MainActor
    func anAudioRejectionBlocksAudioButNotStructuredSync() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(
            data: Self.rejection(code: "audio_upload_not_entitled"), response: response(status: 403)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        _ = await waitForGate { coordinator.entitlements.pause.isAudioPaused }

        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == true)

        // Structured sync still runs on the next pass.
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))
        await coordinator.runOnePassForTesting(user: auth.currentUser!)
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(record?.structuredState == WebStructuredSyncState.synced.rawValue)
        coordinator.stop()
    }

    @Test @MainActor
    func anUnknownRejectionCodeKeepsTheExistingRetryBehavior() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(
            data: Self.rejection(code: "some_future_code"), response: response(status: 429)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()

        let record = await waitForRecord(store, recordingID: recordingID) { $0.lastErrorCode != nil }
        // The generic backoff, not a permanent refusal.
        #expect(record?.nextAttemptAt != .distantFuture)
        #expect(record?.lastErrorCode?.hasPrefix("backend(status:429") == true)
        #expect(coordinator.entitlements.pause == .none)
        coordinator.stop()
    }

    @Test @MainActor
    func aRejectionLeavesAlreadySyncedStateUntouched() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        let synced = await waitForRecord(store, recordingID: recordingID) {
            $0.structuredState == WebStructuredSyncState.synced.rawValue
        }
        #expect(synced?.structuredState == WebStructuredSyncState.synced.rawValue)
        let remoteID = synced?.remoteRecordingID

        // A later edit is refused for quota.
        #expect(await store.updateTitle(recordingID: recordingID, title: "Two"))
        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"), response: response(status: 403)
        ))
        await coordinator.runOnePassForTesting(user: auth.currentUser!)

        let after = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        // The accepted work is not undone by a refused new attempt.
        #expect(after?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(after?.remoteRecordingID == remoteID)
        #expect(after?.lastErrorCode == "entitlement:text_quota_exceeded")
        coordinator.stop()
    }

    // MARK: - Reopening

    @Test @MainActor
    func provenCapacityClearsThePauseAndLetsSyncResume() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"), response: response(status: 403)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        _ = await waitForGate { coordinator.entitlements.pause.isStructuredPaused }
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)

        // An unavailable refresh proves nothing and must not reopen.
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        coordinator.refreshEntitlements()
        try await settle()
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)

        // An authoritative refresh showing room does.
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true, textQuota: 100, textUsed: 2),
            response: response(status: 200)
        ))
        coordinator.refreshEntitlements()
        try await settle()
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == true)
        coordinator.stop()
    }

    @Test @MainActor
    func anAuthoritativeReopenMakesRefusedStructuredRowsSyncAgain() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"), response: response(status: 403)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        let refused = await waitForRecord(store, recordingID: recordingID) { $0.lastErrorCode != nil }
        #expect(refused?.nextAttemptAt == .distantFuture)

        // An unreadable refresh must not revive the row.
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        coordinator.refreshEntitlements()
        try await settle()
        let stillParked = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(stillParked?.nextAttemptAt == .distantFuture)
        #expect(stillParked?.lastErrorCode == "entitlement:text_quota_exceeded")

        // Authority showing room requeues the row and the worker syncs it.
        let before = http.requests.count
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true, textQuota: 100, textUsed: 2),
            response: response(status: 200)
        ))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))
        coordinator.refreshEntitlements()

        let synced = await waitForRecord(store, recordingID: recordingID) {
            $0.structuredState == WebStructuredSyncState.synced.rawValue
        }
        #expect(synced?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(synced?.remoteRecordingID == "remote-1")
        #expect(synced?.nextAttemptAt != .distantFuture)
        // A new structured request was actually issued.
        #expect(http.requests.count > before + 1)
        #expect(http.requests.last?.url?.path.contains("sync/recordings") == true)
        coordinator.stop()
    }

    @Test @MainActor
    func anAuthoritativeReopenMakesRefusedAudioAttemptAgain() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("entitlement-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 7, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID, title: "One", startDate: Date(),
            duration: 10, audioURL: audioURL, ownership: .appCreated
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        // Entitled to upload, then the audio session is refused for storage.
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true), response: response(status: 200)
        ))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))
        http.enqueue(.success(
            data: Self.rejection(code: "storage_quota_exceeded"), response: response(status: 403)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults)
        try await settle()
        let refused = await waitForRecord(store, recordingID: recordingID) {
            $0.lastErrorCode == "entitlement:storage_quota_exceeded"
        }
        #expect(refused?.nextAttemptAt == .distantFuture)
        // Structured work already accepted is untouched by the audio refusal.
        #expect(refused?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)

        // Authority showing storage room requeues and the audio path runs.
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true), response: response(status: 200)
        ))
        http.enqueue(.success(
            data: Data(#"{"session_id":"s-1","recording_id":"remote-1","expires_at":9999999999}"#.utf8),
            response: response(status: 201)
        ))
        coordinator.refreshEntitlements()

        _ = await waitForRequest(http) { $0.url?.path.contains("audio/sessions") == true }
        #expect(http.requests.contains { $0.url?.path.contains("audio/sessions") == true })
        coordinator.stop()
    }

    @Test @MainActor
    func aClosedStructuredGateStopsAFailedRowThatAlreadyHasARemoteID() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        _ = await waitForRecord(store, recordingID: recordingID) {
            $0.structuredState == WebStructuredSyncState.synced.rawValue
        }

        // The row now has a remote id and a failed structured state, and the
        // account is refused for text.
        var mutation = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        mutation.structuredState = WebStructuredSyncState.failed.rawValue
        mutation.nextAttemptAt = Date().addingTimeInterval(-60)
        _ = try await store.upsertWebSyncRecord(mutation)
        #expect(await store.updateTitle(recordingID: recordingID, title: "Two"))
        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"), response: response(status: 403)
        ))
        await coordinator.runOnePassForTesting(user: auth.currentUser!)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)

        // A further pass makes no request: the closed gate covers a failed row
        // that already has a remote id.
        let before = http.requests.count
        await coordinator.runOnePassForTesting(user: auth.currentUser!)
        #expect(http.requests.count == before)
        coordinator.stop()
    }

    @Test @MainActor
    func editedTextQuotaRowStaysColdWithoutRepeatedPayloadWork() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"),
            response: response(status: 403)
        ))
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: isolatedDefaults(),
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        let user = try #require(auth.currentUser)

        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        let refused = try #require(await store.fetchWebSyncRecord(
            userID: "user-1", recordingID: recordingID
        ))
        #expect(refused.nextAttemptAt == .distantFuture)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)
        let refusedRevision = refused.structuredAttemptRevision

        #expect(await store.updateTitle(recordingID: recordingID, title: "Two"))
        let editedRevision = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)?.contentRevision
        )
        let requestCount = http.requests.count

        // The closed gate is known before detail materialization. Both passes
        // stay cold and retain the last attempted revision until a fresh
        // entitlement snapshot explicitly reopens structured sync.
        await coordinator.runOnePassForTesting(user: user)
        let parked = try #require(await store.fetchWebSyncRecord(
            userID: "user-1", recordingID: recordingID
        ))
        #expect(parked.structuredAttemptRevision == refusedRevision)
        #expect(parked.structuredAttemptRevision != editedRevision)
        #expect(parked.nextAttemptAt == .distantFuture)
        #expect(http.requests.count == requestCount)

        await coordinator.runOnePassForTesting(user: user)
        #expect(http.requests.count == requestCount)
        coordinator.stop()
    }

    @Test @MainActor
    func closedStructuredGateCannotAcknowledgeAnAudioPolicyDowngrade() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "Policy", startDate: Date(), segmentsDirURL: nil
        ))
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let priorPayload = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .unavailable
        )
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = priorPayload.contentHash
        synced.structuredSourceRevision = snapshot.contentRevision
        synced.structuredAttemptRevision = snapshot.contentRevision
        synced.audioState = WebAudioSyncState.unavailable.rawValue
        _ = try await store.upsertWebSyncRecord(synced)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        let audioKey = AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        let reconciledAudioKey = AuthTestProfile.webSyncPreferenceKey(
            "webSync.reconciledUploadAudio"
        )
        let reconciledConsentKey = AuthTestProfile.webSyncPreferenceKey(
            "webSync.reconciledHistoricalConsent"
        )
        defaults.set(true, forKey: audioKey)
        defaults.set(true, forKey: reconciledAudioKey)
        defaults.set(HistoricalSyncConsent.undecided.rawValue, forKey: reconciledConsentKey)
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        let user = try #require(auth.currentUser)
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        let authority = try #require(coordinator.entitlements.authority)
        coordinator.entitlements.note(.textQuotaExceeded, for: authority)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)

        // User policy changed, but the text gate cannot accept the updated
        // local-only payload. The old marker must remain until a real PUT wins.
        defaults.set(false, forKey: audioKey)
        let before = http.requests.count
        await coordinator.runOnePassForTesting(user: user)
        #expect(defaults.bool(forKey: reconciledAudioKey) == true)
        #expect(http.requests.count == before)

        http.enqueue(.success(data: Self.upsertBody, response: response(status: 200)))
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        #expect(defaults.bool(forKey: reconciledAudioKey) == false)
        let policyRequest = http.requests.last
        #expect(policyRequest?.url?.path.contains("sync/recordings") == true)
        #expect(policyRequest?.httpBody.flatMap { String(data: $0, encoding: .utf8) }?
            .contains(#""audio_source_state":"local_only""#) == true)
        coordinator.stop()
    }

    @Test @MainActor
    func rejectedAudioPolicyDowngradeRemainsPendingUntilRemoteAcknowledgement() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "Rejected policy", startDate: Date(), segmentsDirURL: nil
        ))
        let snapshot = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        let priorPayload = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .unavailable
        )
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = priorPayload.contentHash
        synced.structuredSourceRevision = snapshot.contentRevision
        synced.structuredAttemptRevision = snapshot.contentRevision
        synced.audioState = WebAudioSyncState.unavailable.rawValue
        _ = try await store.upsertWebSyncRecord(synced)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        let audioKey = AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        let reconciledAudioKey = AuthTestProfile.webSyncPreferenceKey(
            "webSync.reconciledUploadAudio"
        )
        defaults.set(false, forKey: audioKey)
        defaults.set(true, forKey: reconciledAudioKey)
        defaults.set(
            HistoricalSyncConsent.undecided.rawValue,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledHistoricalConsent")
        )
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        let user = try #require(auth.currentUser)

        http.enqueue(.success(
            data: Self.rejection(code: "text_quota_exceeded"),
            response: response(status: 403)
        ))
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )

        #expect(defaults.bool(forKey: reconciledAudioKey) == true)
        #expect(coordinator.entitlements.allowsStructuredSync(for: "user-1") == false)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) }?
            .contains(#""audio_source_state":"local_only""#) == true)

        http.enqueue(.success(data: Self.upsertBody, response: response(status: 200)))
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )

        #expect(defaults.bool(forKey: reconciledAudioKey) == false)
        #expect(http.requests.count == 2)
        #expect(http.requests.last?.httpBody.flatMap { String(data: $0, encoding: .utf8) }?
            .contains(#""audio_source_state":"local_only""#) == true)
        coordinator.stop()
    }

    @MainActor
    private func waitForRequest(
        _ http: FakeAuthHTTP, until: (URLRequest) -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if http.requests.contains(where: until) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return http.requests.contains(where: until)
    }

    @Test @MainActor
    func aSessionNamingAnotherAccountActivatesNothing() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "One", startDate: Date(), segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        // An enabled coordinator whose session has not been installed yet, so
        // the only session it sees is the mismatched one below. The profile is
        // frozen to user-1.
        let auth = try signedOut(http: http)
        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: isolatedDefaults())
        try await settle()
        #expect(http.requests.isEmpty)

        coordinator.sessionChanged(
            state: .signedIn,
            user: .init(id: "user-2", email: "b@example.com", displayName: "Other", pictureURL: nil)
        )
        try await settle()

        #expect(coordinator.entitlements.authority == nil)
        #expect(coordinator.isActiveUser("user-2") == false)
        #expect(coordinator.isActiveUser("user-1") == false)
        // Nothing reached the network and no row was claimed for either id.
        #expect(http.requests.isEmpty)
        #expect(await store.fetchWebSyncRecord(userID: "user-2", recordingID: recordingID) == nil)
        #expect(await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID) == nil)
        coordinator.stop()
    }

    @Test @MainActor
    func withoutASnapshotStructuredSyncsAndAudioSendsNothing() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("entitlement-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 7, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID, title: "One", startDate: Date(),
            duration: 10, audioURL: audioURL, ownership: .appCreated
        ))
        defer { try? FileManager.default.removeItem(at: audioRoot) }

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))

        // No automatic fetch, so the account has a valid authority and no
        // knowledge. Structured sync proceeds; audio has no evidence to go on.
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never
        )
        try await settle()

        #expect(coordinator.entitlements.authority != nil)
        #expect(coordinator.entitlements.knowledge == nil)
        let record = await waitForRecord(store, recordingID: recordingID) {
            $0.structuredState == WebStructuredSyncState.synced.rawValue
        }
        #expect(record?.structuredState == WebStructuredSyncState.synced.rawValue)
        // No session is opened and none is claimed, so the audio never leaves
        // the device.
        #expect(record?.audioState != WebAudioSyncState.synced.rawValue)
        #expect(record?.uploadSessionID == nil)
        #expect(http.requests.contains { $0.url?.path.contains("audio/sessions") == true } == false)
        #expect(http.requests.contains { $0.url?.path.contains("uploads/sessions") == true } == false)
        coordinator.stop()
    }

    @Test @MainActor
    func freshlyLearnedAuthorityStartsAudioWithoutWaitingForTheTimer() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        let audioRoot = try await seedAudioRecording(store, recordingID: recordingID)
        defer { try? FileManager.default.removeItem(at: audioRoot) }

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        // The first pass runs with no knowledge, so it records audio as local
        // only and sleeps. Nothing here waits out that timer.
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults)
        _ = await waitForRecord(store, recordingID: recordingID) {
            $0.audioState == WebAudioSyncState.localOnly.rawValue
        }
        #expect(coordinator.entitlements.knowledge == nil)

        // Authority arrives saying audio is entitled: the audio path runs now.
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true), response: response(status: 200)
        ))
        http.enqueue(.success(
            data: Data(#"{"session_id":"s-1","recording_id":"remote-1","expires_at":9999999999}"#.utf8),
            response: response(status: 201)
        ))
        coordinator.refreshEntitlements()

        #expect(await waitForRequest(http) { $0.url?.path.contains("audio/sessions") == true })
        coordinator.stop()
    }

    @Test @MainActor
    func anAudioFalseToTrueRefreshStartsAudioWithoutWaitingForTheTimer() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        let audioRoot = try await seedAudioRecording(store, recordingID: recordingID)
        defer { try? FileManager.default.removeItem(at: audioRoot) }

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: false), response: response(status: 200)
        ))
        http.enqueue(.success(data: Self.upsertBody, response: response(status: 201)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults)
        _ = await waitForRecord(store, recordingID: recordingID) {
            $0.audioState == WebAudioSyncState.localOnly.rawValue
        }
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)
        #expect(http.requests.contains { $0.url?.path.contains("audio/sessions") == true } == false)

        http.enqueue(.success(
            data: Self.entitlementsBody(audioUpload: true), response: response(status: 200)
        ))
        http.enqueue(.success(
            data: Data(#"{"session_id":"s-1","recording_id":"remote-1","expires_at":9999999999}"#.utf8),
            response: response(status: 201)
        ))
        coordinator.refreshEntitlements()

        #expect(await waitForRequest(http) { $0.url?.path.contains("audio/sessions") == true })
        coordinator.stop()
    }

    @Test @MainActor
    func anUploadAlreadyInFlightFinishesEvenWhenAudioIsNoLongerEntitled() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        let audioRoot = try await seedAudioRecording(store, recordingID: recordingID)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)
        let audioURL = try #require(snapshot.audioFileURL)
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        // A durable session already exists for this exact file.
        var seed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        seed.remoteRecordingID = "remote-1"
        seed.structuredState = WebStructuredSyncState.synced.rawValue
        seed.structuredHash = built.contentHash
        seed.audioState = WebAudioSyncState.uploading.rawValue
        seed.audioFingerprint = fingerprint.value
        seed.uploadSessionID = "session-1"
        _ = try await store.upsertWebSyncRecord(seed)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        // Audio is no longer entitled, yet the session in flight is answered
        // from its own durable state: status, the missing part, then commit.
        // The knowledge is installed rather than fetched so the queue holds
        // only the upload exchange and its order is fixed.
        http.enqueue(.success(
            data: Data(
                #"{"session_id":"session-1","recording_id":"remote-1","state":"uploading","total_size":307200,"chunk_size":307200,"parts_received":[]}"#.utf8
            ),
            response: response(status: 200)
        ))
        http.enqueue(.success(data: Data(), response: response(status: 200)))
        http.enqueue(.success(
            data: Data(#"{"recording_id":"remote-1","version":1,"ready":true}"#.utf8),
            response: response(status: 200)
        ))

        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults, startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        await coordinator.runOnePassForTesting(
            user: auth.currentUser!,
            entitlementResolution: .entitled(Self.contract(audioUpload: false))
        )
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(record?.audioState == WebAudioSyncState.synced.rawValue)
        #expect(coordinator.entitlements.allowsAudioTransfer(for: "user-1") == false)
        // The in-flight upload used its own session and opened no new one.
        #expect(http.requests.contains { $0.url?.path.contains("uploads/sessions/session-1") == true })
        #expect(http.requests.contains {
            $0.httpMethod == "PUT" && $0.url?.path.contains("parts/1") == true
        })
        #expect(http.requests.contains { $0.url?.path.contains("commit") == true })
        #expect(http.requests.contains { $0.url?.path.contains("audio/sessions") == true } == false)
        coordinator.stop()
    }

    @Test @MainActor
    func aSavedSessionTheServerNoLongerHasIsNotReplacedWithoutEntitlement() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        let audioRoot = try await seedAudioRecording(store, recordingID: recordingID)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)
        let audioURL = try #require(snapshot.audioFileURL)
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var seed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        seed.remoteRecordingID = "remote-1"
        seed.structuredState = WebStructuredSyncState.synced.rawValue
        seed.structuredHash = built.contentHash
        seed.audioState = WebAudioSyncState.uploading.rawValue
        seed.audioFingerprint = fingerprint.value
        seed.uploadSessionID = "session-gone"
        _ = try await store.upsertWebSyncRecord(seed)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "webSync.uploadAudio.v1.user-1")
        // The saved session is gone, so there is nothing to resume.
        http.enqueue(.success(
            data: Data(#"{"code":"not_found","error":"not_found"}"#.utf8),
            response: response(status: 404)
        ))

        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults, startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        await coordinator.runOnePassForTesting(
            user: auth.currentUser!,
            entitlementResolution: .entitled(Self.contract(audioUpload: false))
        )

        // Opening a replacement is a new upload, which entitlement forbids.
        #expect(http.requests.contains {
            $0.url?.path.contains("uploads/sessions/session-gone") == true
        })
        #expect(http.requests.contains { $0.url?.path.contains("audio/sessions") == true } == false)
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(record?.audioState != WebAudioSyncState.synced.rawValue)
        #expect(record?.uploadSessionID == nil)

        // The confirmed-dead session is no longer a durable-work bypass. A
        // second pass under the same closed audio gate stays cold instead of
        // issuing the same status GET every minute.
        let requestCount = http.requests.count
        await coordinator.runOnePassForTesting(
            user: auth.currentUser!,
            entitlementResolution: .entitled(Self.contract(audioUpload: false))
        )
        #expect(http.requests.count == requestCount)
        coordinator.stop()
    }

    /// Lets the coordinator's tracked tasks reach a quiescent point without
    /// depending on wall-clock timing for correctness.
    private func settle() async throws {
        for _ in 0..<40 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private func waitForRecord(
        _ store: RecordingsStore, recordingID: UUID, until: (WebSyncRecordDTO) -> Bool
    ) async -> WebSyncRecordDTO? {
        for _ in 0..<100 {
            if let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID),
               until(record) {
                return record
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
    }

    @MainActor
    private func waitForGate(_ until: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if until() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return until()
    }
}
