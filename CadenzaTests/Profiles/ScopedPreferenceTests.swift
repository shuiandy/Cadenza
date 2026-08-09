import Foundation
import SwiftData
import Testing
import os

@testable import Cadenza

// MARK: - Activation state machine

struct ActiveProfileDefaultsTests {
    @Test func resolutionFollowsModeAndUnresolvedAlwaysFailsClosed() {
        let id = UUID()
        let scoped = ProfileScopedDefaults.scopedKey("meetingPrepEnabled", profileID: id)
        #expect(ActiveProfileDefaults.resolvedKey(
            "meetingPrepEnabled", mode: .profile(id)) == scoped)
        #expect(ActiveProfileDefaults.resolvedKey(
            "meetingPrepEnabled", mode: .legacyFallback) == "meetingPrepEnabled")
        #expect(ActiveProfileDefaults.resolvedKey(
            "meetingPrepEnabled", mode: .ephemeral) == "meetingPrepEnabled")
        // Unresolved fails closed everywhere — there is no implicit
        // passthrough; TestHost and previews reach `.ephemeral` through an
        // explicit one-way activation.
        #expect(ActiveProfileDefaults.resolvedKey(
            "meetingPrepEnabled", mode: .unresolved) == nil)
    }

    @Test func activationIsAOneWayTransition() {
        let a = UUID()
        let b = UUID()
        #expect(ActiveProfileDefaults.transitionResult(
            from: .unresolved, to: .profile(a)) == .activated)
        #expect(ActiveProfileDefaults.transitionResult(
            from: .profile(a), to: .profile(a)) == .alreadyActive)
        #expect(ActiveProfileDefaults.transitionResult(
            from: .profile(a), to: .profile(b)) == .conflict(.profile(a)))
        #expect(ActiveProfileDefaults.transitionResult(
            from: .profile(a), to: .legacyFallback) == .conflict(.profile(a)))
        #expect(ActiveProfileDefaults.transitionResult(
            from: .legacyFallback, to: .profile(a)) == .conflict(.legacyFallback))
        #expect(ActiveProfileDefaults.transitionResult(
            from: .ephemeral, to: .ephemeral) == .alreadyActive)
        #expect(ActiveProfileDefaults.transitionResult(
            from: .unresolved, to: .legacyFallback) == .activated)
        #expect(ActiveProfileDefaults.transitionResult(
            from: .unresolved, to: .ephemeral) == .activated)
    }

    @Test func dynamicFolderSortKeysScopeAsAWhole() {
        let profileID = UUID()
        let folderID = UUID()
        let resolved = ActiveProfileDefaults.resolvedKey(
            "folderSort.\(folderID)", mode: .profile(profileID)
        )
        #expect(resolved == "folderSort.\(folderID).profile.\(profileID.uuidString)")
    }
}

// MARK: - Consumer seal (source inventory)

struct ScopedConsumerSealTests {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    /// Every production occurrence of an inventoried key literal must
    /// resolve through the profile mapping (`ActiveProfileDefaults.key`,
    /// an injected `preferenceKey`, or `ProfileScopedDefaults.scopedKey`).
    /// The inventory definition itself and the migration copier are the
    /// authority files allowed to name raw keys.
    @Test func inventoriedKeysResolveThroughTheProfileMapping() throws {
        let root = Self.repoRoot().appendingPathComponent("Cadenza", isDirectory: true)
        let allowedFiles: Set<String> = [
            "ProfileScopedDefaults.swift",
            "ActiveProfileDefaults.swift",
        ]
        let resolverMarkers = [
            "ActiveProfileDefaults.key(", "preferenceKey(", "ProfileScopedDefaults.scopedKey(",
        ]
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var scanned = 0
        var checkedLines = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !allowedFiles.contains(url.lastPathComponent) else { continue }
            scanned += 1
            let contents = try String(contentsOf: url, encoding: .utf8)
            for line in contents.split(separator: "\n") {
                let hasKey = ProfileScopedDefaults.scopedKeys.contains {
                    line.contains("\"\($0)\"")
                } || line.contains("\"folderSort.\\(")
                guard hasKey else { continue }
                checkedLines += 1
                let resolved = resolverMarkers.contains { line.contains($0) }
                #expect(
                    resolved,
                    "\(url.lastPathComponent) names an inventoried key without the resolver: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
        #expect(scanned > 100)
        #expect(checkedLines > 10)
    }

    /// The startup path activates exactly one explicit mode; the TestHost
    /// branch activates ephemeral passthrough, never profile mode over the
    /// live defaults domain.
    @Test func startupActivatesAnExplicitMode() throws {
        let appFile = Self.repoRoot()
            .appendingPathComponent("Cadenza/App/CadenzaApp.swift")
        let contents = try String(contentsOf: appFile, encoding: .utf8)
        #expect(contents.contains("ActiveProfileDefaults.activate("))
        #expect(contents.contains("ActiveProfileDefaults.activateLegacyFallback()"))
        #expect(contents.contains("ActiveProfileDefaults.activateEphemeral()"))
    }

    /// TestHost lands exactly on the explicit ephemeral activation — never
    /// a live mode and never a lingering unresolved state.
    @MainActor
    @Test func testHostRunsInEphemeralMode() {
        #expect(ActiveProfileDefaults.mode == .ephemeral)
    }

    /// A leaked default-root consumer under TestHost resolves the boot's
    /// ephemeral audio root — never the real legacy directory — and the
    /// live default path stays untouched (INV-8).
    @MainActor
    @Test func testHostAudioRootIsEphemeral() {
        let resolved = StorageLocationManager.recordingsDirectory
        #expect(resolved.path != StorageLocationManager.defaultDirectory.path)
        #expect(!resolved.path.contains("/Documents/Cadenza"))
        #expect(resolved.path.contains("cadenza-ephemeral-"))
        #expect(!FileManager.default.fileExists(
            atPath: StorageLocationManager.defaultDirectory
                .appendingPathComponent(".testhost-canary").path
        ))
    }
}

// MARK: - Consent and audio matrix (spec 6.6)

@MainActor
struct WebSyncConsentMatrixTests {
    private func makeCoordinator(
        consent: HistoricalSyncConsent,
        audioToggle: Bool?,
        marked: Bool,
        responses: [FakeAuthHTTP.Outcome] = []
    ) async throws -> (WebSyncCoordinator, RecordingsStore, FakeAuthHTTP, UUID) {
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(inMemory: true)
        )
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "R", startDate: Date(), segmentsDirURL: nil))
        if marked {
            _ = try await store.markAllRecordingsAwaitingHistoricalConsent(transactionID: UUID())
        }
        let http = FakeAuthHTTP()
        for response in responses { http.enqueue(response) }
        let auth = try makeWebSyncAuth(http: http)
        let defaults = UserDefaults(suiteName: "consent-matrix-\(UUID().uuidString)")!
        if let audioToggle {
            defaults.set(audioToggle, forKey: "webSync.uploadAudio.v1.user-1")
        }
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults,
            historicalConsent: { consent },
            entitlementsRefreshPolicy: .never
        )
        return (coordinator, store, http, recordingID)
    }

    private func makeWebSyncAuth(http: FakeAuthHTTP) throws -> CadenzaAuthService {
        let secrets = InMemoryAuthSecretStore()
        try writeStoredToken(into: secrets, value: "token",
                             expiresAt: Date().addingTimeInterval(3_600))
        let users = InMemoryUserStore()
        users.user = .init(id: "user-1", email: "u@example.com", displayName: "U", pictureURL: nil)
        return try CadenzaAuthService.bootstrapped(
            sessionProfile: AuthTestProfile.bound(userID: "user-1"),
            http: http,
            authorizer: FakeAuthorizationProvider(),
            secretStore: secrets,
            sessionUserStore: users,
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(userID: "user-1"))
        )
    }

    @Test func absentAudioToggleReadsOff() async throws {
        let (coordinator, _, _, _) = try await makeCoordinator(
            consent: .undecided, audioToggle: nil, marked: false
        )
        #expect(coordinator.audioUploadEnabled(userID: "user-1") == false)
    }

    @Test func undecidedConsentKeepsMarkedRowAtZeroRequests() async throws {
        let (coordinator, _, http, _) = try await makeCoordinator(
            consent: .undecided, audioToggle: true, marked: true
        )
        try await Task.sleep(for: .milliseconds(120))
        #expect(http.requests.isEmpty)
        coordinator.stop()
    }

    @Test func postBindingRowSyncsTextWhileAudioStaysOffByDefault() async throws {
        let (coordinator, store, http, recordingID) = try await makeCoordinator(
            consent: .undecided, audioToggle: nil, marked: false,
            responses: [.success(
                data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "d", count: 64) + #"","audio_state":"local_only"}"#).utf8),
                response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 201,
                                          httpVersion: nil, headerFields: nil)!
            )]
        )
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(
                userID: "user-1", recordingID: recordingID
            )?.structuredState == WebStructuredSyncState.synced.rawValue { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(record?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(record?.audioState == WebAudioSyncState.localOnly.rawValue)
        #expect(http.requests.count == 1)
        coordinator.stop()
    }

    /// Real-audio negative/positive matrix: the recording carries an
    /// actual audio file in an uploading state, so an absent audio request
    /// is evidence of the gate, not of having nothing to upload.
    private func makeAudioSeededCoordinator(
        consent: HistoricalSyncConsent,
        audioToggle: Bool?,
        seedAudioSourceState: WebSyncAudioSourceState,
        responses: [FakeAuthHTTP.Outcome]
    ) async throws -> (WebSyncCoordinator, RecordingsStore, FakeAuthHTTP, UUID, URL) {
        let store = RecordingsStore(
            modelContainer: try RecordingsStore.makeContainer(inMemory: true)
        )
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("consent-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 7, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID, title: "Historical audio", startDate: Date(),
            duration: 10, audioURL: audioURL, ownership: .appCreated))
        _ = try await store.markAllRecordingsAwaitingHistoricalConsent(transactionID: UUID())

        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: seedAudioSourceState
        )
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var seed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        seed.remoteRecordingID = "remote-1"
        seed.structuredState = WebStructuredSyncState.synced.rawValue
        seed.structuredHash = built.contentHash
        seed.audioState = WebAudioSyncState.uploading.rawValue
        seed.audioFingerprint = fingerprint.value
        seed.uploadSessionID = "session-1"
        _ = try await store.upsertWebSyncRecord(seed)

        let http = FakeAuthHTTP()
        for response in responses { http.enqueue(response) }
        let auth = try makeWebSyncAuth(http: http)
        let defaults = UserDefaults(suiteName: "consent-matrix-\(UUID().uuidString)")!
        if let audioToggle {
            defaults.set(audioToggle, forKey: "webSync.uploadAudio.v1.user-1")
        }
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults,
            historicalConsent: { consent },
            entitlementsRefreshPolicy: .never
        )
        return (coordinator, store, http, recordingID, audioRoot)
    }

    private func waitForAudioState(
        _ store: RecordingsStore, recordingID: UUID, target: String
    ) async throws {
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(
                userID: "user-1", recordingID: recordingID
            )?.audioState == target { break }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func textOnlyConsentBlocksTheRealAudioUpload() async throws {
        let (coordinator, store, http, recordingID, audioRoot) =
            try await makeAudioSeededCoordinator(
                consent: .textOnly, audioToggle: true,
                seedAudioSourceState: .localOnly, responses: []
            )
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        try await waitForAudioState(store, recordingID: recordingID,
                                    target: WebAudioSyncState.localOnly.rawValue)
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        // Text-only historical consent: the pending audio upload is
        // demoted to local-only and NO request of any kind fires.
        #expect(record?.audioState == WebAudioSyncState.localOnly.rawValue)
        #expect(http.requests.isEmpty)
        coordinator.stop()
    }

    @Test func withAudioConsentStillRequiresTheExplicitRuntimeToggle() async throws {
        let (coordinator, store, http, recordingID, audioRoot) =
            try await makeAudioSeededCoordinator(
                consent: .withAudio, audioToggle: nil,
                seedAudioSourceState: .localOnly, responses: []
            )
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        try await waitForAudioState(store, recordingID: recordingID,
                                    target: WebAudioSyncState.localOnly.rawValue)
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        // With-audio consent alone never uploads: the runtime toggle is
        // absent, which reads OFF.
        #expect(record?.audioState == WebAudioSyncState.localOnly.rawValue)
        #expect(http.requests.isEmpty)
        coordinator.stop()
    }

    @Test func withAudioConsentAndExplicitToggleReachesTheAudioPath() async throws {
        let (coordinator, store, http, recordingID, audioRoot) =
            try await makeAudioSeededCoordinator(
                consent: .withAudio, audioToggle: true,
                seedAudioSourceState: .eligible,
                responses: [.success(
                    data: Data(#"{"session_id":"session-1","recording_id":"remote-1","state":"committed","total_size":307200,"chunk_size":307200,"parts_received":[1]}"#.utf8),
                    response: HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!
                )]
            )
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        // Audio needs authority: this profile is bound to a self-hosted issuer,
        // so a missing endpoint there is the open state.
        coordinator.installEntitlementsForTesting(.selfHostOpen)
        try await waitForAudioState(store, recordingID: recordingID,
                                    target: WebAudioSyncState.synced.rawValue)
        let record = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(record?.audioState == WebAudioSyncState.synced.rawValue)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.httpMethod == "GET")
        #expect(http.requests.first?.url?.path.contains("uploads/sessions") == true)
        coordinator.stop()
    }
}

// MARK: - Audio-root authority (registry per-profile)

@MainActor
@Suite(.serialized)
struct ProfileAudioRootTests {
    private func makeAuthority(
        path: String,
        kind: Profile.AudioDirectory.Kind = .userSelected,
        profileDefaultPath: String,
        recordRootChange: @escaping @MainActor (Data?, String, Profile.AudioDirectory.Kind) throws -> Void
    ) -> StorageLocationManager.ProfileRootAuthority {
        StorageLocationManager.ProfileRootAuthority(
            bookmark: nil,
            path: path,
            kind: kind,
            profileDefaultPath: profileDefaultPath,
            recordRefreshedBookmark: { _ in },
            recordRootChange: recordRootChange
        )
    }

    @Test func appManagedDefaultPathsAreDistinctPerProfile() {
        let a = UUID()
        let b = UUID()
        let pathA = ProfileAudioRootWriter.appManagedDefaultPath(profileID: a)
        let pathB = ProfileAudioRootWriter.appManagedDefaultPath(profileID: b)
        #expect(pathA != pathB)
        #expect(pathA.contains(a.uuidString))
        #expect(pathA != StorageLocationManager.defaultDirectory.path)
    }

    @Test func resetCommitsTheProfileOwnAppManagedRootNeverAShared() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ownDefault = dir.appendingPathComponent("own-default").path

        let recorded = OSAllocatedUnfairLock<(Data?, String, Profile.AudioDirectory.Kind)?>(
            initialState: nil
        )
        try StorageLocationManager.withProfileRootForTesting(
            makeAuthority(
                path: dir.path,
                profileDefaultPath: ownDefault,
                recordRootChange: { bookmark, path, kind in
                    recorded.withLock { $0 = (bookmark, path, kind) }
                }
            )
        ) {
            #expect(StorageLocationManager.recordingsDirectory.path == dir.path)
            #expect(StorageLocationManager.isCustomDirectorySet)
            #expect(StorageLocationManager.resetTargetDirectory.path == ownDefault)
            try StorageLocationManager.resetToDefault()
            // Reset targets the profile's own app-managed root and derives
            // isCustom from the authority, not the global defaults.
            #expect(!StorageLocationManager.isCustomDirectorySet)
            #expect(StorageLocationManager.recordingsDirectory.path == ownDefault)
        }
        let change = recorded.withLock { $0 }
        #expect(change?.0 == nil)
        #expect(change?.1 == ownDefault)
        #expect(change?.2 == .appManaged)
    }

    @Test func customCommitRecordsUserSelected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorded = OSAllocatedUnfairLock<(Data?, String, Profile.AudioDirectory.Kind)?>(
            initialState: nil
        )
        try StorageLocationManager.withProfileRootForTesting(
            makeAuthority(
                path: dir.path,
                kind: .appManaged,
                profileDefaultPath: dir.path,
                recordRootChange: { bookmark, path, kind in
                    recorded.withLock { $0 = (bookmark, path, kind) }
                }
            )
        ) {
            try StorageLocationManager.commitCustomDirectory(
                bookmarkData: Data([0x02]), path: "/custom/root"
            )
        }
        let change = recorded.withLock { $0 }
        #expect(change?.0 == Data([0x02]))
        #expect(change?.1 == "/custom/root")
        #expect(change?.2 == .userSelected)
    }

    @Test func failingRegistryRecorderAbortsTheRootCommit() throws {
        struct RecorderFailure: Error {}
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        StorageLocationManager.withProfileRootForTesting(
            makeAuthority(
                path: dir.path,
                profileDefaultPath: dir.path + "-default",
                recordRootChange: { _, _, _ in throw RecorderFailure() }
            )
        ) {
            #expect(throws: RecorderFailure.self) {
                try StorageLocationManager.resetToDefault()
            }
            // The failed commit left the resolved root and the derived UI
            // state unchanged.
            #expect(StorageLocationManager.recordingsDirectory.path == dir.path)
            #expect(StorageLocationManager.isCustomDirectorySet)
        }
    }
}

// MARK: - Registry root writer guards

@MainActor
struct ProfileAudioRootWriterTests {
    private func makeDocument(
        activeID: UUID, profileID: UUID, isLocked: Bool = false
    ) -> ProfileRegistryDocument {
        var profiles = [Profile(
            id: profileID,
            kind: .system,
            name: "Local",
            colorHex: nil,
            createdAt: Date(timeIntervalSince1970: 1_785_628_800),
            lastActiveAt: Date(timeIntervalSince1970: 1_785_628_800),
            audioDirectory: .init(bookmark: Data([0xAA]), path: "/root/a", kind: .userSelected),
            boundAccount: nil,
            lockOnSignOut: false,
            isLocked: false,
            storeMaterialized: true,
            sessionDisposition: .active
        )]
        if activeID != profileID || isLocked {
            var other = profiles[0]
            other.id = activeID == profileID ? UUID() : activeID
            other.kind = .standard
            other.name = "Other"
            other.isLocked = false
            profiles.append(other)
        }
        if isLocked {
            profiles[0].kind = .standard
            profiles[0].name = "Locked"
            profiles[0].isLocked = true
        }
        return ProfileRegistryDocument(
            version: 1,
            activeProfileID: activeID == profileID && isLocked ? profiles[1].id : activeID,
            profiles: profiles
        )
    }

    @Test func staleProcessCannotUpdateANonActiveProfile() throws {
        let profileID = UUID()
        let otherID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: otherID, profileID: profileID)
        )
        #expect(throws: ProfileAudioRootWriter.RootWriteError.notActiveProfile) {
            try ProfileAudioRootWriter.update(profileID: profileID, registry: registry) { _ in
                true
            }
        }
    }

    @Test func pendingOperationRejectsRootMutation() throws {
        let profileID = UUID()
        var document = makeDocument(activeID: profileID, profileID: profileID)
        var standard = document.profiles[0]
        standard.id = UUID()
        standard.kind = .standard
        standard.name = "P"
        document.profiles.append(standard)
        document.pendingBinding = PendingBinding(
            transactionID: UUID(),
            profileID: standard.id,
            userID: "u",
            originKey: CadenzaBackendConfig.official().origin.originKey,
            issuerOrigin: CadenzaBackendConfig.official().origin.normalized,
            apiBaseURL: CadenzaBackendConfig.officialAPIBaseURLString,
            tokenDigest: nil,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let registry = ScriptedRegistry(document: document)
        #expect(throws: ProfileAudioRootWriter.RootWriteError.operationInFlight) {
            try ProfileAudioRootWriter.update(profileID: profileID, registry: registry) { _ in
                true
            }
        }
    }

    @Test func delayedBookmarkRefreshNeverOverwritesANewerRoot() throws {
        let profileID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        // A newer root commits while the refresh task is still queued.
        try ProfileAudioRootWriter.update(profileID: profileID, registry: registry) { directory in
            directory.bookmark = Data([0xBB])
            directory.path = "/root/b"
            directory.kind = .userSelected
            return true
        }
        // The delayed refresh carries the OLD directory identity.
        try ProfileAudioRootWriter.applyRefreshedBookmark(
            StorageLocationManager.RefreshedBookmark(
                refreshed: Data([0xA1]),
                expectedBookmark: Data([0xAA]),
                expectedPath: "/root/a",
                expectedKind: .userSelected
            ),
            profileID: profileID,
            registry: registry
        )
        let directory = try #require(try registry.load().profiles.first?.audioDirectory)
        #expect(directory.bookmark == Data([0xBB]))
        #expect(directory.path == "/root/b")
    }

    @Test func matchingBookmarkRefreshAppliesAndPreservesConcurrentMutations() throws {
        let profileID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        // An unrelated registry mutation lands between resolution and the
        // refresh write; the fresh load-modify-save must preserve it.
        var document = try registry.load()
        document.profiles[0].name = "Renamed by another writer"
        try registry.save(document)

        try ProfileAudioRootWriter.applyRefreshedBookmark(
            StorageLocationManager.RefreshedBookmark(
                refreshed: Data([0xA1]),
                expectedBookmark: Data([0xAA]),
                expectedPath: "/root/a",
                expectedKind: .userSelected
            ),
            profileID: profileID,
            registry: registry
        )
        let loaded = try registry.load()
        #expect(loaded.profiles[0].audioDirectory.bookmark == Data([0xA1]))
        #expect(loaded.profiles[0].name == "Renamed by another writer")
    }
}

// MARK: - Classified root writes

extension ProfileAudioRootWriterTests {
    @Test func rootSaveThatActuallyPersistedReturnsSuccess() throws {
        let profileID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        registry.configure { $0.persistThenThrowAt = [1] }
        try ProfileAudioRootWriter.update(profileID: profileID, registry: registry) { directory in
            directory.path = "/root/new"
            directory.kind = .userSelected
            return true
        }
        #expect(try registry.load().profiles.first?.audioDirectory.path == "/root/new")
    }

    @Test func rootSaveProvenOldThrowsRetryable() throws {
        let profileID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        registry.configure { $0.failSaveAt = [1] }
        do {
            try ProfileAudioRootWriter.update(profileID: profileID, registry: registry) { directory in
                directory.path = "/root/new"
                return true
            }
            Issue.record("expected throw")
        } catch ProfileAudioRootWriter.RootWriteError.saveNotCommitted {
            // Retryable; nothing changed.
        } catch {
            Issue.record("expected saveNotCommitted, got \(error)")
        }
        #expect(try registry.load().profiles.first?.audioDirectory.path == "/root/a")
        #expect(!StorageMigrationGate.shared.isPoisonedUntilRestart)
    }

    @Test func rootSaveThirdShapePoisonsTheGateUntilRestart() throws {
        defer { StorageMigrationGate.shared.resetPoisonForTesting() }
        let profileID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        registry.configure { $0.thirdShapeOnSaveAt = [1] }
        do {
            try ProfileAudioRootWriter.update(profileID: profileID, registry: registry) { directory in
                directory.path = "/root/new"
                return true
            }
            Issue.record("expected throw")
        } catch ProfileAudioRootWriter.RootWriteError.commitIndeterminate {
            // Terminal until restart.
        } catch {
            Issue.record("expected commitIndeterminate, got \(error)")
        }
        #expect(StorageMigrationGate.shared.isPoisonedUntilRestart)
        #expect(StorageMigrationGate.shared.isMigrationClaimed)
        #expect(StorageMigrationGate.shared.claimActivity() == nil)
        StorageMigrationGate.shared.releaseMigration()
        #expect(StorageMigrationGate.shared.isMigrationClaimed)
        #expect(!StorageMigrationGate.shared.claimMigration())
    }

    @Test func refreshPathIndeterminateAlsoPoisonsTheGate() throws {
        defer { StorageMigrationGate.shared.resetPoisonForTesting() }
        let profileID = UUID()
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        registry.configure { $0.thirdShapeOnSaveAt = [1] }
        let payload = StorageLocationManager.RefreshedBookmark(
            refreshed: Data([0xBB]),
            expectedBookmark: Data([0xAA]),
            expectedPath: "/root/a",
            expectedKind: .userSelected
        )
        do {
            try ProfileAudioRootWriter.applyRefreshedBookmark(
                payload, profileID: profileID, registry: registry
            )
            Issue.record("expected throw")
        } catch ProfileAudioRootWriter.RootWriteError.commitIndeterminate {
            // Same terminal state as the root-change path.
        } catch {
            Issue.record("expected commitIndeterminate, got \(error)")
        }
        #expect(StorageMigrationGate.shared.isPoisonedUntilRestart)
    }

    /// A registry save that landed despite throwing advances the
    /// in-process root authority and resolved directory.
    @Test func provenCommittedRootChangeAdvancesTheResolvedRoot() throws {
        let profileID = UUID()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaultPath = dir.appendingPathComponent("own-default").path
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        registry.configure { $0.persistThenThrowAt = [1] }

        try StorageLocationManager.withProfileRootForTesting(
            StorageLocationManager.ProfileRootAuthority(
                bookmark: Data([0xAA]),
                path: dir.path,
                kind: .userSelected,
                profileDefaultPath: defaultPath,
                recordRefreshedBookmark: { _ in },
                recordRootChange: { bookmark, path, kind in
                    try ProfileAudioRootWriter.update(
                        profileID: profileID, registry: registry
                    ) { directory in
                        directory.bookmark = bookmark
                        directory.path = path
                        directory.kind = kind
                        return true
                    }
                }
            )
        ) {
            try StorageLocationManager.resetToDefault()
            #expect(StorageLocationManager.recordingsDirectory.path == defaultPath)
            #expect(!StorageLocationManager.isCustomDirectorySet)
        }
        #expect(try registry.load().profiles.first?.audioDirectory.path == defaultPath)
    }

    /// A proven-uncommitted registry save leaves the in-process root
    /// untouched.
    @Test func provenOldRootChangeKeepsTheResolvedRoot() throws {
        let profileID = UUID()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = ScriptedRegistry(
            document: makeDocument(activeID: profileID, profileID: profileID)
        )
        registry.configure { $0.failSaveAt = [1] }

        StorageLocationManager.withProfileRootForTesting(
            StorageLocationManager.ProfileRootAuthority(
                bookmark: Data([0xAA]),
                path: dir.path,
                kind: .userSelected,
                profileDefaultPath: dir.path + "-default",
                recordRefreshedBookmark: { _ in },
                recordRootChange: { bookmark, path, kind in
                    try ProfileAudioRootWriter.update(
                        profileID: profileID, registry: registry
                    ) { directory in
                        directory.bookmark = bookmark
                        directory.path = path
                        directory.kind = kind
                        return true
                    }
                }
            )
        ) {
            #expect(throws: ProfileAudioRootWriter.RootWriteError.self) {
                try StorageLocationManager.resetToDefault()
            }
            #expect(StorageLocationManager.recordingsDirectory.path == dir.path)
            #expect(StorageLocationManager.isCustomDirectorySet)
        }
        #expect(try registry.load().profiles.first?.audioDirectory.path == "/root/a")
    }
}
