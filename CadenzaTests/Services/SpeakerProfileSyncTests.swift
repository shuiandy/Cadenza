import Foundation
import Testing
@testable import Cadenza

private let model = "test-model-v1"
private let ledgerKey = "webSync.speakerProfileSync.test"

/// Scripted pulls; pushes are recorded and answered as fully applied.
@MainActor
private final class FakeSpeakerTransport: SpeakerProfileSyncTransport {
    var pulls: [Result<SpeakerSyncPullResponse, Error>] = []
    private(set) var pullCursors: [Int64] = []
    private(set) var pushes: [SpeakerSyncPushRequest] = []
    var pushError: Error?

    func pullSpeakerChanges(since cursor: Int64, limit: Int, modelVersions: [String]) async throws -> SpeakerSyncPullResponse {
        pullCursors.append(cursor)
        guard !pulls.isEmpty else { throw URLError(.badServerResponse) }
        return try pulls.removeFirst().get()
    }

    func pushSpeakerChanges(_ request: SpeakerSyncPushRequest) async throws -> SpeakerSyncPushResponse {
        pushes.append(request)
        if let pushError { throw pushError }
        return SpeakerSyncPushResponse(
            appliedProfiles: request.profiles.count, appliedSamples: request.samples.count,
            skippedProfileIDs: [], skippedSamples: []
        )
    }
}

private func page(
    identity: Bool = true,
    identityGeneration: Int64 = 1,
    voice: Bool = true,
    voiceGeneration: Int64 = 0,
    profiles: String = "[]",
    samples: String = "[]",
    cursor: Int64 = 0,
    hasMore: Bool = false
) -> SpeakerSyncPullResponse {
    let json = """
    {"identity_enabled":\(identity),"identity_generation":\(identityGeneration),\
    "voice_enabled":\(voice),"voice_generation":\(voiceGeneration),\
    "profiles":\(profiles),"samples":\(samples),"cursor":\(cursor),"has_more":\(hasMore)}
    """
    return try! JSONDecoder().decode(SpeakerSyncPullResponse.self, from: Data(json.utf8))
}

private func profileJSON(_ id: UUID, name: String, seq: Int64) -> String {
    #"{"profile_id":"\#(id.uuidString.lowercased())","seq":\#(seq),"deleted":false,"display_name":"\#(name)","aliases":[],"notes":"","team_or_org":null,"created_at":1789000000,"last_seen_at":null,"updated_at":1789000000}"#
}

@MainActor
private func makeHarness(
    voiceConsent: Bool = true,
    now: @escaping () -> Date = Date.init
) async throws -> (RecordingsStore, FakeSpeakerTransport, SpeakerProfileSync, UserDefaults) {
    let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
    await store.setSpeakerMemoryConsentForTesting(voiceConsent)
    let transport = FakeSpeakerTransport()
    let defaults = UserDefaults(suiteName: "SpeakerProfileSyncTests.\(UUID().uuidString)")!
    let sync = SpeakerProfileSync(
        store: store, transport: transport, defaults: defaults, modelVersion: model, now: now
    )
    return (store, transport, sync, defaults)
}

@Suite("Speaker profile sync pass", .serialized)
struct SpeakerProfileSyncTests {
    @Test @MainActor
    func identityOffSendsNothing() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        _ = await store.createSpeakerProfile(displayName: "Ada")
        transport.pulls = [.success(page(identity: false))]

        let result = await sync.runPass(ledgerKey: ledgerKey) { true }

        #expect(result == .identityOff)
        #expect(transport.pushes.isEmpty)
    }

    @Test @MainActor
    func localProfilesArePushedOnceAndNotAgain() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        let local = try #require(await store.createSpeakerProfile(displayName: "Ada"))
        transport.pulls = [.success(page()), .success(page())]

        let first = await sync.runPass(ledgerKey: ledgerKey) { true }
        let second = await sync.runPass(ledgerKey: ledgerKey) { true }

        #expect(first == .completed && second == .completed)
        #expect(transport.pushes.count == 1)
        #expect(transport.pushes.first?.profiles.map(\.profileID) == [local.id])
        #expect(transport.pushes.first?.identityGeneration == 1)
    }

    @Test @MainActor
    func appliedRemoteProfileIsNotEchoedBack() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        let remoteID = UUID()
        transport.pulls = [.success(page(profiles: "[\(profileJSON(remoteID, name: "Grace Example", seq: 3))]", cursor: 3))]

        let result = await sync.runPass(ledgerKey: ledgerKey) { true }

        #expect(result == .completed)
        #expect(await store.fetchSpeakerProfiles().map(\.id) == [remoteID])
        #expect(transport.pushes.isEmpty)
    }

    @Test @MainActor
    func generationChangeRestartsFromZeroAndResendsEverything() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        _ = await store.createSpeakerProfile(displayName: "Ada")
        transport.pulls = [.success(page(identityGeneration: 1, cursor: 7))]
        _ = await sync.runPass(ledgerKey: ledgerKey) { true }
        transport.pulls = [
            .success(page(identityGeneration: 2, cursor: 9)),
            .success(page(identityGeneration: 2, cursor: 9)),
        ]

        let result = await sync.runPass(ledgerKey: ledgerKey) { true }

        #expect(result == .completed)
        #expect(transport.pullCursors == [0, 7, 0])
        #expect(transport.pushes.count == 2)
        #expect(transport.pushes.last?.identityGeneration == 2)
    }

    @Test @MainActor
    func pagesArePulledUntilCaughtUp() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        let first = UUID()
        let second = UUID()
        transport.pulls = [
            .success(page(profiles: "[\(profileJSON(first, name: "One", seq: 1))]", cursor: 1, hasMore: true)),
            .success(page(profiles: "[\(profileJSON(second, name: "Two", seq: 2))]", cursor: 2)),
        ]

        _ = await sync.runPass(ledgerKey: ledgerKey) { true }

        #expect(transport.pullCursors == [0, 1])
        #expect(Set(await store.fetchSpeakerProfiles().map(\.id)) == [first, second])
    }

    @Test @MainActor
    func missingBackendBacksOffWithoutFurtherRequests() async throws {
        let (_, transport, sync, _) = try await makeHarness()
        transport.pulls = [.failure(AuthError.server(status: 404))]

        let first = await sync.runPassIfDue(ledgerKey: ledgerKey) { true }
        let second = await sync.runPassIfDue(ledgerKey: ledgerKey) { true }

        #expect(first == .unavailable && second == .unavailable)
        #expect(transport.pullCursors.count == 1)
    }

    @Test @MainActor
    func passesAreThrottled() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let (_, transport, sync, _) = try await makeHarness(now: { clock })
        transport.pulls = [.success(page()), .success(page())]

        let first = await sync.runPassIfDue(ledgerKey: ledgerKey) { true }
        let throttled = await sync.runPassIfDue(ledgerKey: ledgerKey) { true }
        clock = clock.addingTimeInterval(SpeakerProfileSync.minimumInterval)
        let due = await sync.runPassIfDue(ledgerKey: ledgerKey) { true }

        #expect([first, throttled, due] == [.completed, .notDue, .completed])
        #expect(transport.pullCursors.count == 2)
    }

    @Test @MainActor
    func sessionChangeMidPassStopsBeforePushing() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        _ = await store.createSpeakerProfile(displayName: "Ada")
        transport.pulls = [.success(page())]

        let result = await sync.runPass(ledgerKey: ledgerKey) { false }

        #expect(result == .abandoned)
        #expect(transport.pushes.isEmpty)
    }

    @Test @MainActor
    func voiceSamplesTravelOnlyWithBothSwitchesOn() async throws {
        let (store, transport, sync, _) = try await makeHarness()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "Standup", startDate: Date(), segmentsDirURL: nil)
        let local = try #require(await store.createSpeakerProfile(displayName: "Ada"))
        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([1, 0, 0, 0]),
            embeddingDimension: 4, sampleDuration: 30, nonOverlapRatio: 0.9,
            qualityScore: 20, modelVersion: model
        )
        await store.attachSampleToProfile(recordingID: recordingID, rawLabel: "Speaker 1", profileID: local.id)
        transport.pulls = [.success(page(voice: false)), .success(page(voice: true, voiceGeneration: 0))]

        _ = await sync.runPass(ledgerKey: ledgerKey) { true }
        let samplesWhileVoiceOff = transport.pushes.flatMap(\.samples)
        _ = await sync.runPass(ledgerKey: ledgerKey) { true }
        let sampleRequest = try #require(transport.pushes.last)

        #expect(samplesWhileVoiceOff.isEmpty)
        #expect(sampleRequest.samples.map(\.key.rawLabel) == ["Speaker 1"])
        #expect(sampleRequest.voiceGeneration == 0)
    }
}
