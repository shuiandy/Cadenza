import Foundation
import Testing
@testable import Cadenza

@Suite("Web sync coordinator", .serialized)
struct WebSyncCoordinatorTests {
    @Test
    func unchangedCandidateSkipsPayloadWorkUntilContentOrAudioStateChanges() {
        let recordingID = UUID()
        let sourceRevision = Date(timeIntervalSince1970: 100)
        let syncedAt = Date(timeIntervalSince1970: 200)
        let candidate = WebSyncCandidate(
            recordingID: recordingID,
            contentRevision: sourceRevision,
            trashedDate: nil,
            awaitingHistoricalConsentBindingID: nil
        )
        func makeRecord(
            structuredState: String = WebStructuredSyncState.synced.rawValue,
            sourceRevision: Date? = sourceRevision,
            attemptRevision: Date? = sourceRevision,
            audioState: String = WebAudioSyncState.synced.rawValue,
            uploadSessionID: String? = nil,
            nextAttemptAt: Date? = nil,
            retryDomain: String? = nil
        ) -> WebSyncRecordDTO {
            WebSyncRecordDTO(
                syncKey: "user:\(recordingID)",
                userID: "user",
                recordingID: recordingID,
                remoteRecordingID: "remote",
                structuredState: structuredState,
                structuredHash: String(repeating: "a", count: 64),
                structuredSourceRevision: sourceRevision,
                structuredAttemptRevision: attemptRevision,
                audioState: audioState,
                audioFingerprint: "fingerprint",
                audioProbeRevision: nil,
                uploadSessionID: uploadSessionID,
                attemptCount: nextAttemptAt == nil ? 0 : 1,
                nextAttemptAt: nextAttemptAt,
                retryDomain: retryDomain,
                lastAttemptAt: syncedAt,
                syncedAt: syncedAt,
                isDeletionTombstone: false,
                lastErrorCode: nextAttemptAt == nil ? nil : "network(code:-1009)"
            )
        }
        let synced = makeRecord()
        let retryAt = syncedAt.addingTimeInterval(60)

        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: synced,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(WebSyncCoordinator.shouldProcessCandidate(
            .init(
                recordingID: recordingID,
                // The edit landed while the old request was in flight: its
                // revision predates the acknowledgement time but is newer than
                // the exact source revision captured by that payload.
                contentRevision: sourceRevision.addingTimeInterval(1),
                trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil
            ),
            record: synced,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(WebSyncCoordinator.shouldProcessCandidate(
            .init(
                recordingID: recordingID,
                contentRevision: sourceRevision.addingTimeInterval(-1),
                trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil
            ),
            record: synced,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: synced,
            audioUploadEnabled: true,
            forcePayloadRefresh: true,
            now: syncedAt
        ))
        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            .init(
                recordingID: recordingID,
                contentRevision: sourceRevision,
                trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil,
                hasAudioReference: true
            ),
            record: makeRecord(audioState: WebAudioSyncState.unavailable.rawValue),
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: makeRecord(audioState: WebAudioSyncState.unavailable.rawValue),
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: syncedAt
        ))

        let historicalCandidate = WebSyncCandidate(
            recordingID: recordingID,
            contentRevision: sourceRevision,
            trashedDate: nil,
            awaitingHistoricalConsentBindingID: UUID()
        )
        #expect(!WebSyncCoordinator.audioUploadEnabled(
            for: historicalCandidate,
            globalAudioEnabled: true,
            historicalConsent: .textOnly
        ))
        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            historicalCandidate,
            record: makeRecord(audioState: WebAudioSyncState.localOnly.rawValue),
            audioUploadEnabled: WebSyncCoordinator.audioUploadEnabled(
                for: historicalCandidate,
                globalAudioEnabled: true,
                historicalConsent: .textOnly
            ),
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(WebSyncCoordinator.audioUploadEnabled(
            for: historicalCandidate,
            globalAudioEnabled: true,
            historicalConsent: .withAudio
        ))
        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: makeRecord(audioState: WebAudioSyncState.pending.rawValue),
            audioUploadEnabled: true,
            mayOpenNewAudioSession: false,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: makeRecord(
                structuredState: WebStructuredSyncState.synced.rawValue,
                audioState: WebAudioSyncState.failed.rawValue,
                uploadSessionID: "resumable-session",
                nextAttemptAt: retryAt,
                retryDomain: WebSyncRetryDomain.structured.rawValue
            ),
            audioUploadEnabled: true,
            structuredSyncAllowed: false,
            mayOpenNewAudioSession: false,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: makeRecord(
                structuredState: WebStructuredSyncState.synced.rawValue,
                audioState: WebAudioSyncState.failed.rawValue,
                uploadSessionID: "audio-backoff-session",
                nextAttemptAt: retryAt,
                retryDomain: WebSyncRetryDomain.audio.rawValue
            ),
            audioUploadEnabled: true,
            structuredSyncAllowed: false,
            mayOpenNewAudioSession: false,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(!WebSyncCoordinator.shouldProcessCandidate(
            candidate,
            record: makeRecord(
                structuredState: WebStructuredSyncState.failed.rawValue,
                nextAttemptAt: retryAt
            ),
            audioUploadEnabled: false,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
        #expect(WebSyncCoordinator.shouldProcessCandidate(
            .init(
                recordingID: recordingID,
                contentRevision: sourceRevision.addingTimeInterval(1),
                trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil
            ),
            record: makeRecord(
                structuredState: WebStructuredSyncState.failed.rawValue,
                nextAttemptAt: retryAt
            ),
            audioUploadEnabled: false,
            forcePayloadRefresh: false,
            now: syncedAt
        ))
    }

    @Test
    func syncedAudioProbeRunsOnlyAfterItsMetadataInterval() {
        let recordingID = UUID()
        let revision = Date(timeIntervalSince1970: 100)
        let lastProbe = Date(timeIntervalSince1970: 1_000)
        let candidate = WebSyncCandidate(
            recordingID: recordingID,
            contentRevision: revision,
            trashedDate: nil,
            awaitingHistoricalConsentBindingID: nil,
            hasAudioReference: true
        )
        let record = WebSyncRecordDTO(
            syncKey: "user:\(recordingID)",
            userID: "user",
            recordingID: recordingID,
            remoteRecordingID: "remote",
            structuredState: WebStructuredSyncState.synced.rawValue,
            structuredHash: String(repeating: "a", count: 64),
            structuredSourceRevision: revision,
            structuredAttemptRevision: revision,
            audioState: WebAudioSyncState.synced.rawValue,
            audioFingerprint: "10:20",
            audioProbeRevision: nil,
            uploadSessionID: nil,
            attemptCount: 0,
            nextAttemptAt: nil,
            retryDomain: nil,
            lastAttemptAt: lastProbe,
            syncedAt: lastProbe,
            isDeletionTombstone: false,
            lastErrorCode: nil
        )

        #expect(!WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate,
            record: record,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: lastProbe.addingTimeInterval(WebSyncCoordinator.syncedAudioProbeInterval - 1)
        ))
        #expect(WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate,
            record: record,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: lastProbe.addingTimeInterval(WebSyncCoordinator.syncedAudioProbeInterval)
        ))
        #expect(!WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate,
            record: record,
            audioUploadEnabled: false,
            forcePayloadRefresh: false,
            now: .distantFuture
        ))
        let unavailable = WebSyncRecordDTO(
            syncKey: record.syncKey,
            userID: record.userID,
            recordingID: record.recordingID,
            remoteRecordingID: record.remoteRecordingID,
            structuredState: record.structuredState,
            structuredHash: record.structuredHash,
            structuredSourceRevision: record.structuredSourceRevision,
            structuredAttemptRevision: record.structuredAttemptRevision,
            audioState: WebAudioSyncState.unavailable.rawValue,
            audioFingerprint: nil,
            audioProbeRevision: nil,
            uploadSessionID: nil,
            attemptCount: 0,
            nextAttemptAt: nil,
            retryDomain: nil,
            lastAttemptAt: lastProbe,
            syncedAt: lastProbe,
            isDeletionTombstone: false,
            lastErrorCode: nil
        )
        #expect(WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate,
            record: unavailable,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: lastProbe.addingTimeInterval(WebSyncCoordinator.syncedAudioProbeInterval)
        ))
        #expect(!WebSyncCoordinator.shouldProbeSyncedAudio(
            .init(
                recordingID: recordingID,
                contentRevision: revision,
                trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil
            ),
            record: unavailable,
            audioUploadEnabled: true,
            forcePayloadRefresh: false,
            now: .distantFuture
        ))
        let touchedRevision = revision.addingTimeInterval(1)
        let touchedCandidate = WebSyncCandidate(
            recordingID: recordingID,
            contentRevision: touchedRevision,
            trashedDate: nil,
            awaitingHistoricalConsentBindingID: nil,
            hasAudioReference: true
        )
        #expect(WebSyncCoordinator.shouldProbeSyncedAudio(
            touchedCandidate,
            record: unavailable,
            audioUploadEnabled: true,
            structuredSyncAllowed: false,
            forcePayloadRefresh: false,
            now: lastProbe.addingTimeInterval(1)
        ))
        let touchedAlreadyProbed = WebSyncRecordDTO(
            syncKey: unavailable.syncKey,
            userID: unavailable.userID,
            recordingID: unavailable.recordingID,
            remoteRecordingID: unavailable.remoteRecordingID,
            structuredState: unavailable.structuredState,
            structuredHash: unavailable.structuredHash,
            structuredSourceRevision: unavailable.structuredSourceRevision,
            structuredAttemptRevision: unavailable.structuredAttemptRevision,
            audioState: unavailable.audioState,
            audioFingerprint: unavailable.audioFingerprint,
            audioProbeRevision: touchedRevision,
            uploadSessionID: nil,
            attemptCount: 0,
            nextAttemptAt: nil,
            retryDomain: nil,
            lastAttemptAt: lastProbe,
            syncedAt: lastProbe,
            isDeletionTombstone: false,
            lastErrorCode: nil
        )
        #expect(!WebSyncCoordinator.shouldProbeSyncedAudio(
            touchedCandidate,
            record: touchedAlreadyProbed,
            audioUploadEnabled: true,
            structuredSyncAllowed: false,
            forcePayloadRefresh: false,
            now: lastProbe.addingTimeInterval(1)
        ))
        #expect(WebSyncCoordinator.shouldProbeSyncedAudio(
            touchedCandidate,
            record: touchedAlreadyProbed,
            audioUploadEnabled: true,
            structuredSyncAllowed: false,
            forcePayloadRefresh: false,
            now: lastProbe.addingTimeInterval(WebSyncCoordinator.syncedAudioProbeInterval)
        ))
    }

    private func probeRecord(
        _ id: UUID, revision: Date, lastAttemptAt: Date?, audioProbeRevision: Date? = nil
    ) -> WebSyncRecordDTO {
        WebSyncRecordDTO(
            syncKey: "user:\(id)",
            userID: "user",
            recordingID: id,
            remoteRecordingID: "remote",
            structuredState: WebStructuredSyncState.synced.rawValue,
            structuredHash: String(repeating: "a", count: 64),
            structuredSourceRevision: revision,
            structuredAttemptRevision: revision,
            audioState: WebAudioSyncState.synced.rawValue,
            audioFingerprint: "10:20",
            audioProbeRevision: audioProbeRevision,
            uploadSessionID: nil,
            attemptCount: 0,
            nextAttemptAt: nil,
            retryDomain: nil,
            lastAttemptAt: lastAttemptAt,
            syncedAt: nil,
            isDeletionTombstone: false,
            lastErrorCode: nil
        )
    }

    @Test
    func inProcessProbeScheduleDefersAndOrdersCandidates() {
        let revision = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 100_000)
        let recent = UUID(), stale = UUID(), never = UUID()
        let candidates = [recent, stale, never].map {
            WebSyncCandidate(
                recordingID: $0, contentRevision: revision, trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil, hasAudioReference: true
            )
        }
        // Durable state says every row is overdue. The in-process schedule
        // knows `recent` was probed a minute ago and `stale` twenty minutes ago.
        let records = [
            recent: probeRecord(recent, revision: revision, lastAttemptAt: .distantPast),
            stale: probeRecord(stale, revision: revision, lastAttemptAt: .distantPast),
            never: probeRecord(never, revision: revision, lastAttemptAt: nil),
        ]
        let attempts: [UUID: Date] = [
            recent: now.addingTimeInterval(-60),
            stale: now.addingTimeInterval(-20 * 60),
        ]
        func select(budget: Int) -> Set<UUID> {
            WebSyncCoordinator.audioProbeCandidateIDs(
                candidates: candidates,
                recordsByRecordingID: records,
                globalAudioEnabled: true,
                historicalConsent: .undecided,
                forcePayloadRefresh: false,
                now: now,
                budget: budget,
                probeAttempts: attempts
            )
        }
        // Never probed sorts first, then the oldest in-process probe; the
        // row probed a minute ago is not due at all.
        #expect(select(budget: 1) == [never])
        #expect(select(budget: 2) == [never, stale])
        #expect(select(budget: 8) == [never, stale])

        // Without the schedule, durable state alone would re-probe everything.
        let durableOnly = WebSyncCoordinator.audioProbeCandidateIDs(
            candidates: candidates,
            recordsByRecordingID: records,
            globalAudioEnabled: true,
            historicalConsent: .undecided,
            forcePayloadRefresh: false,
            now: now
        )
        #expect(durableOnly == [recent, stale, never])
    }

    @Test
    func probeEligibilityUsesTheLaterOfDurableAndInProcessDates() {
        let revision = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 100_000)
        let id = UUID()
        let candidate = WebSyncCandidate(
            recordingID: id, contentRevision: revision, trashedDate: nil,
            awaitingHistoricalConsentBindingID: nil, hasAudioReference: true
        )
        let interval = WebSyncCoordinator.syncedAudioProbeInterval
        let overdue = probeRecord(id, revision: revision, lastAttemptAt: now.addingTimeInterval(-interval - 1))
        let fresh = probeRecord(id, revision: revision, lastAttemptAt: now.addingTimeInterval(-1))

        #expect(WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate, record: overdue, audioUploadEnabled: true,
            forcePayloadRefresh: false, now: now
        ))
        #expect(!WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate, record: overdue, audioUploadEnabled: true,
            forcePayloadRefresh: false, now: now, lastProbeAt: now.addingTimeInterval(-1)
        ))
        #expect(!WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate, record: fresh, audioUploadEnabled: true,
            forcePayloadRefresh: false, now: now, lastProbeAt: now.addingTimeInterval(-interval - 1)
        ))
        #expect(WebSyncCoordinator.shouldProbeSyncedAudio(
            candidate, record: overdue, audioUploadEnabled: true,
            forcePayloadRefresh: false, now: now, lastProbeAt: now.addingTimeInterval(-interval - 1)
        ))
    }

    @Test @MainActor
    func unchangedAudioProbeSchedulesInMemoryWithoutWritingTheStore() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "websync-probe-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent("probe.m4a")
        try Data(repeating: 7, count: 64 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID, title: "Probe", startDate: Date(), duration: 10,
            audioURL: audioURL, ownership: .appCreated
        ))
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let payload = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = payload.contentHash
        synced.structuredSourceRevision = snapshot.contentRevision
        synced.structuredAttemptRevision = snapshot.contentRevision
        synced.audioState = WebAudioSyncState.synced.rawValue
        synced.audioFingerprint = fingerprint.value
        _ = try await store.upsertWebSyncRecord(synced)
        // Durable state: last probed an hour ago at a stale revision, so the
        // row is due and the first probe legitimately moves the revision.
        let seededProbe = Date().addingTimeInterval(-3600)
        try await store.markWebSyncAudioProbe(
            userID: "user-1", recordingID: recordingID,
            contentRevision: Date(timeIntervalSince1970: 1), at: seededProbe
        )

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio"))
        defaults.set(true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledUploadAudio"))
        defaults.set(
            HistoricalSyncConsent.undecided.rawValue,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledHistoricalConsent")
        )
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults,
            startAutomatically: false, entitlementsRefreshPolicy: .never
        )
        let user = try #require(auth.currentUser)

        // Pass 1: the revision moved, so exactly one durable write happens.
        await coordinator.runOnePassForTesting(user: user, entitlementResolution: .selfHostOpen)
        let afterFirst = try #require(await store.fetchWebSyncRecord(
            userID: "user-1", recordingID: recordingID
        ))
        #expect(afterFirst.audioProbeRevision == snapshot.contentRevision)
        let persistedAt = try #require(afterFirst.lastAttemptAt)
        #expect(persistedAt > seededProbe)

        // Pass 2 and 3: nothing changed, the schedule lives in memory and the
        // row is not touched again (no save, no history transaction).
        for _ in 0..<2 {
            await coordinator.runOnePassForTesting(user: user, entitlementResolution: .selfHostOpen)
            let after = try #require(await store.fetchWebSyncRecord(
                userID: "user-1", recordingID: recordingID
            ))
            #expect(after.lastAttemptAt == persistedAt)
            #expect(after.audioProbeRevision == snapshot.contentRevision)
            #expect(after.audioState == WebAudioSyncState.synced.rawValue)
        }
        #expect(http.requests.isEmpty)
        coordinator.stop()
    }

    @Test
    func syncedAudioProbeSelectionIsBoundedAndOldestFirst() {
        let revision = Date(timeIntervalSince1970: 10)
        var candidates: [WebSyncCandidate] = []
        var records: [UUID: WebSyncRecordDTO] = [:]
        var orderedIDs: [UUID] = []
        for index in 0..<12 {
            let id = UUID()
            orderedIDs.append(id)
            candidates.append(.init(
                recordingID: id,
                contentRevision: revision,
                trashedDate: nil,
                awaitingHistoricalConsentBindingID: nil,
                hasAudioReference: true
            ))
            records[id] = WebSyncRecordDTO(
                syncKey: "user:\(id)",
                userID: "user",
                recordingID: id,
                remoteRecordingID: "remote-\(index)",
                structuredState: WebStructuredSyncState.synced.rawValue,
                structuredHash: String(repeating: "a", count: 64),
                structuredSourceRevision: revision,
                structuredAttemptRevision: revision,
                audioState: WebAudioSyncState.synced.rawValue,
                audioFingerprint: "10:20",
                audioProbeRevision: nil,
                uploadSessionID: nil,
                attemptCount: 0,
                nextAttemptAt: nil,
                retryDomain: nil,
                lastAttemptAt: Date(timeIntervalSince1970: TimeInterval(100 + index)),
                syncedAt: nil,
                isDeletionTombstone: false,
                lastErrorCode: nil
            )
        }

        let selected = WebSyncCoordinator.audioProbeCandidateIDs(
            candidates: candidates,
            recordsByRecordingID: records,
            globalAudioEnabled: true,
            historicalConsent: .undecided,
            forcePayloadRefresh: false,
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(selected.count == WebSyncCoordinator.syncedAudioProbeBudgetPerPass)
        #expect(selected == Set(orderedIDs.prefix(WebSyncCoordinator.syncedAudioProbeBudgetPerPass)))
    }

    @Test @MainActor
    func userRetryBypassesFutureBackoffAndClearsErrorAfterDurableSuccess() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Retry succeeds",
            startDate: Date(timeIntervalSince1970: 100),
            segmentsDirURL: nil
        ))
        let snapshot = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        let built = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .localOnly
        )
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            false,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledUploadAudio")
        )
        defaults.set(
            HistoricalSyncConsent.undecided.rawValue,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledHistoricalConsent")
        )
        http.enqueue(.success(data: Data(), response: response(status: 503)))
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
        let failed = try #require(
            await store.fetchWebSyncRecord(userID: user.id, recordingID: recordingID)
        )
        #expect(failed.structuredState == WebStructuredSyncState.failed.rawValue)
        #expect(try #require(failed.nextAttemptAt) > Date())
        #expect(coordinator.lastError != nil)
        #expect(http.requests.count == 1)

        http.enqueue(.success(
            data: Data(
                (#"{"recording_id":"remote-1","version":1,"content_hash":""#
                    + built.contentHash
                    + #"","audio_state":"local_only"}"#).utf8
            ),
            response: response(status: 201)
        ))
        await coordinator.runOnePassForTesting(
            user: user,
            userInitiatedRetry: true
        )

        let recovered = try #require(
            await store.fetchWebSyncRecord(userID: user.id, recordingID: recordingID)
        )
        #expect(http.requests.count == 2)
        #expect(recovered.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(recovered.attemptCount == 0)
        #expect(recovered.nextAttemptAt == nil)
        #expect(coordinator.lastError == nil)
        coordinator.stop()
    }

    @Test @MainActor
    func failedUserRetryKeepsTheFailureVisibleAndAdvancesBackoff() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Retry fails",
            startDate: Date(timeIntervalSince1970: 100),
            segmentsDirURL: nil
        ))
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            false,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledUploadAudio")
        )
        defaults.set(
            HistoricalSyncConsent.undecided.rawValue,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledHistoricalConsent")
        )
        http.enqueue(.success(data: Data(), response: response(status: 503)))
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
        let firstFailure = try #require(
            await store.fetchWebSyncRecord(userID: user.id, recordingID: recordingID)
        )
        let firstDeadline = try #require(firstFailure.nextAttemptAt)
        #expect(firstFailure.attemptCount == 1)
        #expect(coordinator.lastError != nil)

        http.enqueue(.success(data: Data(), response: response(status: 503)))
        await coordinator.runOnePassForTesting(
            user: user,
            userInitiatedRetry: true
        )

        let secondFailure = try #require(
            await store.fetchWebSyncRecord(userID: user.id, recordingID: recordingID)
        )
        #expect(http.requests.count == 2)
        #expect(secondFailure.structuredState == WebStructuredSyncState.failed.rawValue)
        #expect(secondFailure.attemptCount == 2)
        #expect(try #require(secondFailure.nextAttemptAt) > firstDeadline)
        #expect(coordinator.lastError != nil)
        coordinator.stop()
    }

    @Test @MainActor
    func sameHashDuringBackoffAdvancesAttemptRevisionWithoutNetworkWork() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Backoff",
            startDate: Date(timeIntervalSince1970: 100),
            segmentsDirURL: nil
        ))

        let original = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let originalPayload = try WebSyncPayloadBuilder.build(
            snapshot: original, audioSourceState: .localOnly
        )
        var failed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        failed.remoteRecordingID = "remote-1"
        failed.structuredState = WebStructuredSyncState.failed.rawValue
        failed.structuredHash = originalPayload.contentHash
        failed.structuredAttemptRevision = original.contentRevision
        failed.audioState = WebAudioSyncState.localOnly.rawValue
        failed.attemptCount = 1
        failed.nextAttemptAt = .distantFuture
        failed.retryDomain = WebSyncRetryDomain.structured.rawValue
        _ = try await store.upsertWebSyncRecord(failed)

        // Meeting type is local metadata that advances the recording revision
        // but is intentionally absent from the web payload.
        #expect(await store.updateMeetingType(
            recordingID: recordingID, meetingType: "interview"
        ))
        let updated = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let updatedPayload = try WebSyncPayloadBuilder.build(
            snapshot: updated, audioSourceState: .localOnly
        )
        #expect(updated.contentRevision != original.contentRevision)
        #expect(updatedPayload.contentHash == originalPayload.contentHash)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            false,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledUploadAudio")
        )
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

        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )

        let after = try #require(await store.fetchWebSyncRecord(
            userID: "user-1", recordingID: recordingID
        ))
        #expect(after.structuredAttemptRevision == updated.contentRevision)
        #expect(after.nextAttemptAt == .distantFuture)
        #expect(http.requests.isEmpty)
        coordinator.stop()
    }

    @Test @MainActor
    func replacementAudioRemainsPendingUntilAuthorityCanOpenANewSession() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "websync-replacement-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)

        let originalURL = audioRoot.appendingPathComponent("original.m4a")
        try Data(repeating: 1, count: 300 * 1_024).write(to: originalURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Replacement",
            startDate: Date(),
            duration: 10,
            audioURL: originalURL,
            ownership: .appCreated
        ))
        let original = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let originalPayload = try WebSyncPayloadBuilder.build(
            snapshot: original, audioSourceState: .eligible
        )
        let originalFingerprint = try await WebSyncFileReader().fingerprint(url: originalURL)
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = originalPayload.contentHash
        synced.structuredSourceRevision = original.contentRevision
        synced.structuredAttemptRevision = original.contentRevision
        synced.audioState = WebAudioSyncState.synced.rawValue
        synced.audioFingerprint = originalFingerprint.value
        _ = try await store.upsertWebSyncRecord(synced)

        let replacementURL = audioRoot.appendingPathComponent("replacement.m4a")
        try Data(repeating: 2, count: 320 * 1_024).write(to: replacementURL)
        #expect(await store.replaceAudioFile(
            recordingID: recordingID,
            newURL: replacementURL,
            ownership: .appCreated
        ))

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        let user = try #require(auth.currentUser)

        // No entitlement snapshot is not permission to open a new session.
        await coordinator.runOnePassForTesting(user: user)
        let pending = try #require(await store.fetchWebSyncRecord(
            userID: "user-1", recordingID: recordingID
        ))
        #expect(pending.audioState == WebAudioSyncState.pending.rawValue)
        #expect(http.requests.isEmpty)

        http.enqueue(.success(
            data: Data(
                #"{"session_id":"replacement-session","recording_id":"remote-1","expires_at":9999999999}"#.utf8
            ),
            response: response(status: 201)
        ))
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        #expect(http.requests.contains {
            $0.url?.path.contains("audio/sessions") == true
        })
        coordinator.stop()
    }

    @Test @MainActor
    func audioRelinkUploadsWhileStructuredEntitlementIsClosed() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "websync-closed-text-relink-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)

        let originalURL = audioRoot.appendingPathComponent("original.m4a")
        try Data(repeating: 1, count: 300 * 1_024).write(to: originalURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Closed text relink",
            startDate: Date(),
            duration: 10,
            audioURL: originalURL,
            ownership: .appCreated
        ))
        let original = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        let originalPayload = try WebSyncPayloadBuilder.build(
            snapshot: original, audioSourceState: .eligible
        )
        let originalFingerprint = try await WebSyncFileReader().fingerprint(url: originalURL)
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = originalPayload.contentHash
        synced.structuredSourceRevision = original.contentRevision
        synced.structuredAttemptRevision = original.contentRevision
        synced.audioState = WebAudioSyncState.synced.rawValue
        synced.audioFingerprint = originalFingerprint.value
        _ = try await store.upsertWebSyncRecord(synced)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
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
        #expect(http.requests.isEmpty)
        let authority = try #require(coordinator.entitlements.authority)
        coordinator.entitlements.note(.textQuotaExceeded, for: authority)

        let replacementURL = audioRoot.appendingPathComponent("replacement.m4a")
        try Data(repeating: 2, count: 320 * 1_024).write(to: replacementURL)
        #expect(await store.replaceAudioFile(
            recordingID: recordingID,
            newURL: replacementURL,
            ownership: .appCreated
        ))
        let replacement = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        #expect(replacement.contentRevision != original.contentRevision)

        http.enqueue(.success(
            data: Data(
                #"{"session_id":"closed-text-session","recording_id":"remote-1","expires_at":9999999999}"#.utf8
            ),
            response: response(status: 201)
        ))
        http.enqueue(.success(data: Data(), response: response(status: 200)))
        http.enqueue(.success(
            data: Data(#"{"recording_id":"remote-1","version":1,"ready":true}"#.utf8),
            response: response(status: 200)
        ))
        await coordinator.runOnePassForTesting(user: user)

        let after = try #require(
            await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        )
        #expect(after.audioState == WebAudioSyncState.synced.rawValue)
        #expect(after.audioProbeRevision == replacement.contentRevision)
        #expect(after.structuredSourceRevision == original.contentRevision)
        #expect(http.requests.contains {
            $0.httpMethod == "POST" && $0.url?.path.contains("audio/sessions") == true
        })
        #expect(http.requests.contains {
            $0.httpMethod == "PUT"
                && $0.url?.path.hasSuffix(recordingID.uuidString.lowercased()) == true
        } == false)
        coordinator.stop()
    }

    @Test @MainActor
    func inPlaceAudioReplacementIsDetectedByTheLightweightProbe() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "websync-in-place-probe-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent("meeting.m4a")
        try Data(repeating: 1, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Probe",
            startDate: Date(),
            duration: 10,
            audioURL: audioURL,
            ownership: .appCreated
        ))
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)
        let originalFingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = built.contentHash
        synced.structuredSourceRevision = snapshot.contentRevision
        synced.structuredAttemptRevision = snapshot.contentRevision
        synced.audioState = WebAudioSyncState.synced.rawValue
        synced.audioFingerprint = originalFingerprint.value
        _ = try await store.upsertWebSyncRecord(synced)
        try await store.markWebSyncAudioProbe(
            userID: "user-1",
            recordingID: recordingID,
            contentRevision: snapshot.contentRevision,
            at: .distantPast
        )

        // Replace bytes at the same sanctioned reference without touching the
        // model revision. The low-frequency metadata probe must still notice.
        try Data(repeating: 2, count: 320 * 1_024).write(to: audioURL)
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio"))
        defaults.set(
            true,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledUploadAudio")
        )
        defaults.set(
            HistoricalSyncConsent.undecided.rawValue,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledHistoricalConsent")
        )
        http.enqueue(.success(
            data: Data(
                #"{"session_id":"probe-session","recording_id":"remote-1","expires_at":9999999999}"#.utf8
            ),
            response: response(status: 201)
        ))
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        await coordinator.runOnePassForTesting(
            user: try #require(auth.currentUser), entitlementResolution: .selfHostOpen
        )

        #expect(http.requests.contains {
            $0.httpMethod == "POST" && $0.url?.path.contains("audio/sessions") == true
        })
        coordinator.stop()
    }

    @Test @MainActor
    func discoveryFailureDoesNotCommitPolicyReconciliationMarkers() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio"))
        await store.failNextWebSyncDiscoveryForTesting()
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )

        await coordinator.runOnePassForTesting(
            user: try #require(auth.currentUser), entitlementResolution: .selfHostOpen
        )

        #expect(defaults.object(forKey: AuthTestProfile.webSyncPreferenceKey(
            "webSync.reconciledUploadAudio"
        )) == nil)
        #expect(defaults.object(forKey: AuthTestProfile.webSyncPreferenceKey(
            "webSync.reconciledHistoricalConsent"
        )) == nil)
        #expect(coordinator.lastError == WebSyncPersistenceError.fetchFailed.localizedDescription)
        #expect(http.requests.isEmpty)

        await coordinator.runOnePassForTesting(user: try #require(auth.currentUser))
        #expect(coordinator.lastError == nil)
        #expect(http.requests.isEmpty)
        coordinator.stop()
    }

    @Test @MainActor
    func snapshotFailureDoesNotCommitPolicyReconciliationMarkers() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID,
            title: "Policy snapshot",
            startDate: Date(timeIntervalSince1970: 100),
            segmentsDirURL: nil
        ))
        let snapshot = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        let priorPayload = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .eligible
        )
        var synced = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        synced.remoteRecordingID = "remote-1"
        synced.structuredState = WebStructuredSyncState.synced.rawValue
        synced.structuredHash = priorPayload.contentHash
        synced.structuredSourceRevision = snapshot.contentRevision
        synced.structuredAttemptRevision = snapshot.contentRevision
        synced.audioState = WebAudioSyncState.synced.rawValue
        _ = try await store.upsertWebSyncRecord(synced)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        let reconciledAudioKey = AuthTestProfile.webSyncPreferenceKey(
            "webSync.reconciledUploadAudio"
        )
        defaults.set(true, forKey: reconciledAudioKey)
        defaults.set(
            HistoricalSyncConsent.undecided.rawValue,
            forKey: AuthTestProfile.webSyncPreferenceKey("webSync.reconciledHistoricalConsent")
        )
        await store.failNextWebSyncSnapshotForTesting()
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
        #expect(defaults.bool(forKey: reconciledAudioKey) == true)
        #expect(coordinator.lastError == WebSyncPersistenceError.fetchFailed.localizedDescription)
        #expect(http.requests.isEmpty)

        http.enqueue(.success(
            data: Data(
                (#"{"recording_id":"remote-1","version":1,"content_hash":""#
                    + String(repeating: "a", count: 64)
                    + #"","audio_state":"local_only"}"#).utf8
            ),
            response: response(status: 200)
        ))
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )

        #expect(defaults.bool(forKey: reconciledAudioKey) == false)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) }?
            .contains(#""audio_source_state":"local_only""#) == true)
        coordinator.stop()
    }

    @Test func diagnosticCodesAreBoundedAndDoNotPersistBackendMessages() {
        let secret = "secret transcript text"
        let error = CadenzaAPIError.backend(
            envelope: BackendErrorEnvelope(
                code: "unsafe code/\(String(repeating: "x", count: 100))",
                message: secret,
                integration: nil,
                upstreamStatus: nil,
                retryAfter: nil
            ),
            status: 500
        )

        let code = WebSyncCoordinator.diagnosticCode(for: error)

        #expect(code.hasPrefix("backend(status:500,code:unsafe_code_"))
        #expect(code.count <= 89)
        #expect(!code.contains(secret))
        #expect(!code.contains("/"))
    }

    @Test @MainActor
    func disclosedSignedInAccountAutomaticallyQueuesHistory() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(id: recordingID, title: "History", startDate: Date(), segmentsDirURL: nil))

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "a", count: 64) + #"","audio_state":"unavailable"}"#).utf8),
            response: response(status: 201)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        // Audio needs authority: this profile is bound to a self-hosted
        // issuer, so a missing endpoint there is the open state.
        coordinator.installEntitlementsForTesting(.selfHostOpen)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.remoteRecordingID != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sync = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(sync?.remoteRecordingID == "remote-1")
        #expect(sync?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(sync?.audioState == WebAudioSyncState.unavailable.rawValue)
        #expect(http.requests.count == 1)
        coordinator.stop()
    }

    @Test @MainActor
    func historicalRowsStayFullyLocalUntilConsent() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "History", startDate: Date(), segmentsDirURL: nil))
        // The binding stamped this row as pre-binding history (6.6).
        _ = try await store.markAllRecordingsAwaitingHistoricalConsent(transactionID: UUID())
        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        try await Task.sleep(for: .milliseconds(80))
        // Undecided consent: strictly zero requests for the marked row.
        #expect(http.requests.isEmpty)

        // Text-only consent queues the historical text immediately.
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "b", count: 64) + #"","audio_state":"local_only"}"#).utf8),
            response: response(status: 201)
        ))
        coordinator.updateHistoricalConsent(.textOnly)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(
                userID: "user-1", recordingID: recordingID
            )?.structuredState == WebStructuredSyncState.synced.rawValue {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sync = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(sync?.structuredState == WebStructuredSyncState.synced.rawValue)
        // Text-only: the structured upsert is the only traffic.
        #expect(http.requests.count == 1)
        coordinator.stop()
    }

    @Test @MainActor
    func syncDefersWhileMigrationClaimedAndUsesTheCurrentRootAfterwards() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-rootA-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-rootB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        await store.setAudioRootForTesting(rootA)
        let audioURL = rootA.appendingPathComponent("audio.m4a")
        try Data(repeating: 3, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID, title: "Root change", startDate: Date(),
            duration: 10, audioURL: audioURL, ownership: .appCreated))

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "c", count: 64) + #"","audio_state":"not_uploaded"}"#).utf8),
            response: response(status: 201)
        ))

        let migrationGate = StorageMigrationGate()
        #expect(migrationGate.claimMigration())
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth, defaults: defaults, migrationGate: migrationGate,
            entitlementsRefreshPolicy: .never
        )
        // Audio needs authority: this profile is bound to a self-hosted
        // issuer, so a missing endpoint there is the open state.
        coordinator.installEntitlementsForTesting(.selfHostOpen)
        try await Task.sleep(for: .milliseconds(300))
        // Every per-item sync deferred: no requests while the migration holds
        // the root.
        #expect(http.requests.isEmpty)

        // Migration completes: the file moves and the active root switches.
        try FileManager.default.moveItem(
            at: audioURL, to: rootB.appendingPathComponent("audio.m4a")
        )
        await store.setAudioRootForTesting(rootB)
        migrationGate.releaseMigration()

        coordinator.recordingDidChange(recordingID)
        for _ in 0..<50 {
            if http.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Structured create plus an audio-upload attempt: the re-fetched
        // snapshot resolved the file under the new root (the old root no
        // longer holds it).
        #expect(http.requests.count >= 2)
        coordinator.stop()
    }

    @Test @MainActor
    func audioFailureKeepsStructuredAcknowledgement() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 7, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "With audio",
            startDate: Date(),
            duration: 10,
            audioURL: audioURL, ownership: .appCreated))

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "b", count: 64) + #"","audio_state":"not_uploaded"}"#).utf8),
            response: response(status: 201)
        ))
        http.enqueue(.success(data: Data(), response: response(status: 500)))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        // Audio needs authority: this profile is bound to a self-hosted
        // issuer, so a missing endpoint there is the open state.
        coordinator.installEntitlementsForTesting(.selfHostOpen)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.audioState == WebAudioSyncState.failed.rawValue {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sync = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(sync?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(sync?.audioState == WebAudioSyncState.failed.rawValue)
        coordinator.stop()
    }

    @Test @MainActor
    func legacyCommittedSessionWithNilRetryDomainStillRecoversAcknowledgement() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 9, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Committed audio",
            startDate: Date(),
            duration: 10,
            audioURL: audioURL, ownership: .appCreated))
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .eligible)
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var seed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        seed.remoteRecordingID = "remote-1"
        seed.structuredState = WebStructuredSyncState.synced.rawValue
        seed.structuredHash = built.contentHash
        seed.structuredSourceRevision = snapshot.contentRevision
        seed.structuredAttemptRevision = snapshot.contentRevision
        seed.audioState = WebAudioSyncState.uploading.rawValue
        seed.audioFingerprint = fingerprint.value
        seed.uploadSessionID = "session-1"
        seed.nextAttemptAt = .distantFuture
        // Deployed rows predate retry-domain tracking. They get one resume
        // opportunity; any new failure persists an explicit audio domain.
        _ = try await store.upsertWebSyncRecord(seed)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data(#"{"session_id":"session-1","recording_id":"remote-1","state":"committed","total_size":307200,"chunk_size":307200,"parts_received":[1]}"#.utf8),
            response: response(status: 200)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        // Audio needs authority: this profile is bound to a self-hosted
        // issuer, so a missing endpoint there is the open state.
        coordinator.installEntitlementsForTesting(.selfHostOpen)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.audioState == WebAudioSyncState.synced.rawValue {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let sync = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(sync?.audioState == WebAudioSyncState.synced.rawValue)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.httpMethod == "GET")
        coordinator.stop()
    }

    @Test @MainActor
    func durableSessionHonorsItsOwnExponentialBackoff() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 4, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Audio backoff",
            startDate: Date(),
            duration: 10,
            audioURL: audioURL,
            ownership: .appCreated
        ))
        let snapshot = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        let built = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .eligible
        )
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var seed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        seed.remoteRecordingID = "remote-1"
        seed.structuredState = WebStructuredSyncState.synced.rawValue
        seed.structuredHash = built.contentHash
        seed.structuredSourceRevision = snapshot.contentRevision
        seed.structuredAttemptRevision = snapshot.contentRevision
        seed.audioState = WebAudioSyncState.uploading.rawValue
        seed.audioFingerprint = fingerprint.value
        seed.uploadSessionID = "session-backoff"
        seed.attemptCount = 1
        _ = try await store.upsertWebSyncRecord(seed)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(data: Data(), response: response(status: 503)))
        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            startAutomatically: false,
            entitlementsRefreshPolicy: .never
        )
        let user = try #require(auth.currentUser)
        let startedAt = Date()

        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        let failed = try #require(
            await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        )
        #expect(failed.uploadSessionID == "session-backoff")
        #expect(failed.retryDomain == WebSyncRetryDomain.audio.rawValue)
        #expect(failed.attemptCount == 2)
        #expect((failed.nextAttemptAt ?? .distantPast) > startedAt.addingTimeInterval(250))
        #expect(http.requests.count == 1)

        // A title edit must still reach structured sync, but that unrelated
        // success cannot erase the audio lane's 5-minute deadline.
        #expect(await store.updateTitle(recordingID: recordingID, title: "Edited during audio backoff"))
        http.enqueue(.success(
            data: Data(
                (#"{"recording_id":"remote-1","version":1,"content_hash":""#
                    + String(repeating: "d", count: 64)
                    + #"","audio_state":"not_uploaded"}"#).utf8
            ),
            response: response(status: 200)
        ))
        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        let afterEdit = try #require(
            await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        )
        #expect(http.requests.count == 2)
        #expect(http.requests.last?.url?.path.contains("sync/recordings") == true)
        #expect(afterEdit.uploadSessionID == "session-backoff")
        #expect(afterEdit.retryDomain == WebSyncRetryDomain.audio.rawValue)
        #expect(afterEdit.attemptCount == failed.attemptCount)
        #expect(afterEdit.nextAttemptAt == failed.nextAttemptAt)

        await coordinator.runOnePassForTesting(
            user: user, entitlementResolution: .selfHostOpen
        )
        #expect(http.requests.count == 2)
        coordinator.stop()
    }

    @Test @MainActor
    func durableSessionHonorsPermanentAudioEntitlementBackoff() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 6, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Audio quota",
            startDate: Date(),
            duration: 10,
            audioURL: audioURL,
            ownership: .appCreated
        ))
        let snapshot = try #require(
            try await store.fetchWebSyncSnapshot(recordingID: recordingID)
        )
        let built = try WebSyncPayloadBuilder.build(
            snapshot: snapshot, audioSourceState: .eligible
        )
        let fingerprint = try await WebSyncFileReader().fingerprint(url: audioURL)
        var seed = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        seed.remoteRecordingID = "remote-1"
        seed.structuredState = WebStructuredSyncState.synced.rawValue
        seed.structuredHash = built.contentHash
        seed.structuredSourceRevision = snapshot.contentRevision
        seed.structuredAttemptRevision = snapshot.contentRevision
        seed.audioState = WebAudioSyncState.uploading.rawValue
        seed.audioFingerprint = fingerprint.value
        seed.uploadSessionID = "session-quota"
        _ = try await store.upsertWebSyncRecord(seed)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(
            suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)"
        )!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data(
                #"{"session_id":"session-quota","recording_id":"remote-1","state":"uploading","total_size":307200,"chunk_size":307200,"parts_received":[1]}"#.utf8
            ),
            response: response(status: 200)
        ))
        http.enqueue(.success(
            data: Data(
                #"{"code":"storage_quota_exceeded","error":"storage_quota_exceeded","message":"quota"}"#.utf8
            ),
            response: response(status: 403)
        ))
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
        let refused = try #require(
            await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        )
        #expect(refused.uploadSessionID == "session-quota")
        #expect(refused.retryDomain == WebSyncRetryDomain.audio.rawValue)
        #expect(refused.nextAttemptAt == .distantFuture)
        #expect(refused.lastErrorCode == "entitlement:storage_quota_exceeded")
        #expect(http.requests.count == 2)

        await coordinator.runOnePassForTesting(
            user: user,
            userInitiatedRetry: true
        )
        #expect(http.requests.count == 2)
        coordinator.stop()
    }

    @Test @MainActor
    func activeRecordingGateDefersHistoricalAudioUpload() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("websync-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        let audioURL = audioRoot.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 5, count: 300 * 1_024).write(to: audioURL)
        #expect(await store.importAudioFile(
            id: recordingID,
            title: "Deferred audio",
            startDate: Date(),
            duration: 10,
            audioURL: audioURL, ownership: .appCreated))

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + String(repeating: "c", count: 64) + #"","audio_state":"not_uploaded"}"#).utf8),
            response: response(status: 201)
        ))

        let coordinator = WebSyncCoordinator(
            store: store,
            auth: auth,
            defaults: defaults,
            shouldPauseHistoricalAudio: { true },
            entitlementsRefreshPolicy: .never
        )
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.structuredState == WebStructuredSyncState.synced.rawValue {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let sync = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(sync?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(sync?.audioState != WebAudioSyncState.synced.rawValue)
        #expect(sync?.uploadSessionID == nil)
        #expect(http.requests.count == 1)
        coordinator.stop()
    }

    @Test @MainActor
    func parkedInitialNotFoundFailureRecoversAfterBackendRollout() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(id: recordingID, title: "Parked history", startDate: Date(), segmentsDirURL: nil))
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .unavailable)

        var parked = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        parked.structuredState = WebStructuredSyncState.failed.rawValue
        parked.structuredHash = built.contentHash
        parked.audioState = WebAudioSyncState.failed.rawValue
        parked.attemptCount = 1
        parked.nextAttemptAt = .distantFuture
        parked.retryDomain = WebSyncRetryDomain.structured.rawValue
        parked.lastErrorCode = "server(status: 404)"
        _ = try await store.upsertWebSyncRecord(parked)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + built.contentHash + #"","audio_state":"unavailable"}"#).utf8),
            response: response(status: 201)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.remoteRecordingID != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let recovered = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(recovered?.remoteRecordingID == "remote-1")
        #expect(recovered?.structuredState == WebStructuredSyncState.synced.rawValue)
        #expect(http.requests.count == 1)
        coordinator.stop()
    }

    @Test @MainActor
    func parkedInitialServerFailureGetsOneTimeRecovery() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(id: recordingID, title: "Storage rollout", startDate: Date(), segmentsDirURL: nil))
        let snapshot = try #require(try await store.fetchWebSyncSnapshot(recordingID: recordingID))
        let built = try WebSyncPayloadBuilder.build(snapshot: snapshot, audioSourceState: .unavailable)

        var parked = WebSyncMutation(userID: "user-1", recordingID: recordingID)
        parked.structuredState = WebStructuredSyncState.failed.rawValue
        parked.structuredHash = built.contentHash
        parked.audioState = WebAudioSyncState.failed.rawValue
        parked.attemptCount = 3
        parked.nextAttemptAt = Date().addingTimeInterval(1_800)
        parked.retryDomain = WebSyncRetryDomain.structured.rawValue
        parked.lastErrorCode = "server(status: 500)"
        _ = try await store.upsertWebSyncRecord(parked)

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data((#"{"recording_id":"remote-1","version":1,"content_hash":""# + built.contentHash + #"","audio_state":"unavailable"}"#).utf8),
            response: response(status: 201)
        ))

        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.remoteRecordingID != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let recovered = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        #expect(recovered?.remoteRecordingID == "remote-1")
        #expect(defaults.bool(forKey: AuthTestProfile.webSyncPreferenceKey(
            "webSync.initialServerRecovery"
        )))
        #expect(http.requests.count == 1)
        coordinator.stop()
    }

    @Test @MainActor
    func initialStructuredNotFoundUsesRetryDelayInsteadOfPermanentParking() async throws {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(id: recordingID, title: "Rollout race", startDate: Date(), segmentsDirURL: nil))

        let http = FakeAuthHTTP()
        let auth = signedIn(http: http)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(
            true, forKey: AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
        )
        http.enqueue(.success(
            data: Data(#"{"error":"not_found"}"#.utf8),
            response: response(status: 404)
        ))

        let startedAt = Date()
        let coordinator = WebSyncCoordinator(store: store, auth: auth, defaults: defaults, entitlementsRefreshPolicy: .never)
        for _ in 0..<50 {
            if await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)?.attemptCount == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let failed = await store.fetchWebSyncRecord(userID: "user-1", recordingID: recordingID)
        let nextAttemptAt = try #require(failed?.nextAttemptAt)
        #expect(nextAttemptAt < startedAt.addingTimeInterval(120))
        #expect(nextAttemptAt > startedAt)
        coordinator.stop()
    }

    /// Opaque server IDs are byte-exact throughout the sync chain:
    /// canonically equivalent NFC/NFD spellings are different accounts.
    @Test @MainActor
    func canonicallyEquivalentUserIDsNeverShareMappingsOrTasks() async throws {
        let nfc = "us\u{00E9}r-1"
        let nfd = "use\u{0301}r-1"
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        await store.clearAll()
        let recordingID = UUID()
        #expect(await store.createRecording(
            id: recordingID, title: "R", startDate: Date(), segmentsDirURL: nil
        ))

        // Mapping lookups never cross the byte boundary: an upsert under
        // the NFD spelling must not adopt or update the NFC row.
        var nfcMutation = WebSyncMutation(userID: nfc, recordingID: recordingID)
        nfcMutation.remoteRecordingID = "remote-nfc"
        _ = try await store.upsertWebSyncRecord(nfcMutation)
        var nfdMutation = WebSyncMutation(userID: nfd, recordingID: recordingID)
        nfdMutation.remoteRecordingID = "remote-nfd"
        _ = try await store.upsertWebSyncRecord(nfdMutation)
        let nfcRecord = await store.fetchWebSyncRecord(userID: nfc, recordingID: recordingID)
        let nfdRecord = await store.fetchWebSyncRecord(userID: nfd, recordingID: recordingID)
        #expect(nfcRecord?.remoteRecordingID == "remote-nfc")
        #expect(nfdRecord?.remoteRecordingID == "remote-nfd")

        // Ready-work ownership is byte-exact per account: exactly the
        // NFC row returns, proven in UTF-8 bytes (String comparison is
        // canonical and would conflate the two keys).
        let nfcWork = await store.fetchReadyWebSyncWork(userID: nfc, now: Date())
        let nfcKey = WebSyncRecord.key(userID: nfc, recordingID: recordingID)
        #expect(nfcWork.count == 1)
        #expect(nfcWork.first.map { Array($0.syncKey.utf8) == Array(nfcKey.utf8) } == true)

        // Active-account tombstone coverage does not accept the other
        // spelling as already covered.
        await store.setActiveWebSyncUserID(nfc)
        _ = await store.deleteRecording(recordingID: recordingID)
        _ = await store.permanentlyDelete(recordingID: recordingID)
        let nfcTombstone = await store.fetchWebSyncRecord(userID: nfc, recordingID: recordingID)
        let nfdTombstone = await store.fetchWebSyncRecord(userID: nfd, recordingID: recordingID)
        #expect(nfcTombstone?.isDeletionTombstone == true)
        #expect(nfdTombstone?.isDeletionTombstone == true)
        #expect(Array((nfcTombstone?.syncKey ?? "").utf8)
            != Array((nfdTombstone?.syncKey ?? "").utf8))
    }

    /// The coordinator's task-ownership guard refuses a canonically
    /// equivalent but byte-distinct user ID.
    @Test @MainActor
    func activeUserGuardIsByteExact() async throws {
        let nfc = "us\u{00E9}r-1"
        let nfd = "use\u{0301}r-1"
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let http = FakeAuthHTTP()
        // The profile is bound to the composed spelling, so only that exact
        // byte string is an active user.
        let auth = signedIn(http: http, userID: nfc)
        let coordinator = WebSyncCoordinator(
            store: store, auth: auth,
            defaults: UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!,
            startAutomatically: false
        )
        coordinator.sessionChanged(state: .signedIn, user: nil)
        #expect(!coordinator.isActiveUser(nfc))
        coordinator.stop()

        let enabled = WebSyncCoordinator(
            store: store, auth: auth,
            defaults: UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!,
            entitlementsRefreshPolicy: .never
        )
        enabled.sessionChanged(
            state: .signedIn,
            user: .init(id: nfc, email: "u@example.com", displayName: "U", pictureURL: nil)
        )
        #expect(enabled.isActiveUser(nfc))
        #expect(!enabled.isActiveUser(nfd))
        enabled.stop()
    }

    /// Preference identity covers profile, issuer and exact user-ID bytes.
    /// The ambiguous legacy value is claimed once and never copied to a
    /// second issuer that happens to issue the same ID.
    @Test @MainActor
    func audioPreferenceKeysAreByteExactAndIssuerScoped() async throws {
        let nfc = "us\u{00E9}r-1"
        let nfd = "use\u{0301}r-1"
        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let defaults = UserDefaults(suiteName: "WebSyncCoordinatorTests-\(UUID().uuidString)")!
        let exactIDCoordinator = WebSyncCoordinator(
            store: store,
            auth: signedIn(http: FakeAuthHTTP(), userID: nfc),
            defaults: defaults,
            startAutomatically: false
        )

        defaults.set(
            true,
            forKey: AuthTestProfile.webSyncPreferenceKey(
                "webSync.uploadAudio", userID: nfc
            )
        )
        #expect(exactIDCoordinator.audioUploadEnabled(userID: nfc))
        #expect(!exactIDCoordinator.audioUploadEnabled(userID: nfd))
        exactIDCoordinator.stop()

        let legacyKey = "webSync.uploadAudio.v1.user-1"
        defaults.set(true, forKey: legacyKey)
        let firstOrigin = WebSyncCoordinator(
            store: store,
            auth: signedIn(http: FakeAuthHTTP()),
            defaults: defaults,
            startAutomatically: false
        )
        #expect(firstOrigin.audioUploadEnabled(userID: "user-1"))
        #expect(defaults.object(forKey: legacyKey) == nil)
        firstOrigin.stop()

        let otherBaseURL = "https://other-sync.example.test/api/v1"
        let secondOrigin = WebSyncCoordinator(
            store: store,
            auth: signedIn(
                http: FakeAuthHTTP(), userID: "user-1", baseURL: otherBaseURL
            ),
            defaults: defaults,
            startAutomatically: false
        )
        #expect(!secondOrigin.audioUploadEnabled(userID: "user-1"))
        #expect(AuthTestProfile.webSyncPreferenceKey("webSync.uploadAudio")
            != AuthTestProfile.webSyncPreferenceKey(
                "webSync.uploadAudio", baseURL: otherBaseURL
            ))
        secondOrigin.stop()
    }

    @MainActor
    private func signedIn(
        http: FakeAuthHTTP,
        userID: String = "user-1",
        baseURL: String = AuthTestProfile.baseURLString
    ) -> CadenzaAuthService {
        let secrets = InMemoryAuthSecretStore()
        try! writeStoredToken(
            into: secrets,
            value: "token",
            expiresAt: Date().addingTimeInterval(3_600),
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
            registry: ScriptedRegistry(document: makeAuthRegistryDocument(
                userID: userID, baseURL: baseURL
            ))
        )
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://cadenzapp.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // The server's create fingerprint spans remote recording id, chunk size,
    // and source fingerprint. The idempotency key must move whenever any of
    // them moves, or the old session occupies the key with a fingerprint that
    // can never match again and every create answers 409 session_conflict.
    @Test
    func audioSessionIdempotencyKeyPinsEveryFingerprintDimension() {
        let recordingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        func key(
            remote: String = "remote-1",
            fingerprint: String = "fp-1",
            chunkSize: Int64 = 262_144
        ) -> String {
            WebSyncCoordinator.audioSessionIdempotencyKey(
                userID: "user-a",
                recordingID: recordingID,
                remoteRecordingID: remote,
                fingerprintValue: fingerprint,
                chunkSize: chunkSize
            )
        }

        #expect(key() == "user-a:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:audio:fp-1:262144:remote-1")
        #expect(key() == key())
        #expect(key(remote: "remote-2") != key())
        #expect(key(fingerprint: "fp-2") != key())
        #expect(key(chunkSize: 524_288) != key())
    }

    @Test
    func speakerIdentityReEnableForcesPayloadRefresh() {
        #expect(!WebSyncCoordinator.shouldForceSpeakerIdentityRefresh(
            enabled: false, generation: 1, lastEnabled: true, lastGeneration: 0
        ))
        #expect(WebSyncCoordinator.shouldForceSpeakerIdentityRefresh(
            enabled: true, generation: 1, lastEnabled: false, lastGeneration: 1
        ))
        #expect(WebSyncCoordinator.shouldForceSpeakerIdentityRefresh(
            enabled: true, generation: 1, lastEnabled: true, lastGeneration: 0
        ))
        #expect(!WebSyncCoordinator.shouldForceSpeakerIdentityRefresh(
            enabled: true, generation: 1, lastEnabled: true, lastGeneration: 1
        ))
        #expect(WebSyncCoordinator.shouldForceSpeakerIdentityRefresh(
            enabled: true, generation: 0, lastEnabled: nil, lastGeneration: nil
        ))
    }
}
