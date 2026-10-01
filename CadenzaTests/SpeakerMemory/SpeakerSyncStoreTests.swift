import Foundation
import SwiftData
import Testing
@testable import Cadenza

private let model = "test-model-v1"

@MainActor
private func makeStore(voiceConsent: Bool = true) async throws -> RecordingsStore {
    let store = RecordingsStore(modelContainer: try RecordingsStore.makeContainer(inMemory: true))
    await store.setSpeakerMemoryConsentForTesting(voiceConsent)
    return store
}

private func remoteProfile(_ id: UUID = UUID(), name: String = "Ada Example") -> SpeakerSyncProfile {
    SpeakerSyncProfile(
        profileID: id,
        displayName: name,
        aliases: ["Ada"],
        notes: "Fictional person",
        teamOrOrg: "Platform",
        createdAt: 1_789_000_000,
        lastSeenAt: 1_789_500_000
    )
}

private func remoteSample(
    profileID: UUID,
    recordingID: UUID = UUID(),
    label: String = "Speaker 1",
    quality: Float = 30
) -> SpeakerSyncSample {
    SpeakerSyncSample(
        key: SpeakerSyncSampleKey(recordingID: recordingID, rawLabel: label, modelVersion: model),
        profileID: profileID,
        embedding: SpeakerVoiceSample.serializeEmbedding([0.1, 0.2, 0.3, 0.4]),
        embeddingDimension: 4,
        sampleDuration: 40,
        nonOverlapRatio: 0.8,
        qualityScore: quality,
        createdAt: 1_789_000_100
    )
}

@Suite("RecordingsStore speaker sync", .serialized)
struct SpeakerSyncStoreTests {
    @Test @MainActor
    func remoteProfileIsCreatedUnderItsOwnID() async throws {
        let store = try await makeStore()
        let remote = remoteProfile()
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.profileWrites = [.init(profile: remote, expectedLocalFingerprint: nil)]

        let outcome = try #require(await store.applySpeakerSyncChanges(plan))
        let snapshot = try #require(await store.speakerSyncSnapshot(modelVersion: model))

        #expect(outcome.appliedProfiles == [remote.profileID: remote.fingerprint])
        #expect(snapshot.profiles[remote.profileID] == remote)
    }

    @Test @MainActor
    func writeIsSkippedWhenTheLocalCopyChangedAfterPlanning() async throws {
        let store = try await makeStore()
        let local = try #require(await store.createSpeakerProfile(displayName: "Ada"))
        let planned = try #require(await store.speakerSyncSnapshot(modelVersion: model)?.profiles[local.id])
        await store.updateSpeakerProfile(id: local.id, displayName: "Ada, edited here", notes: "", teamOrOrg: nil)
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.profileWrites = [.init(profile: remoteProfile(local.id, name: "Remote"), expectedLocalFingerprint: planned.fingerprint)]

        let outcome = try #require(await store.applySpeakerSyncChanges(plan))
        let names = await store.fetchSpeakerProfiles().map(\.displayName)

        #expect(outcome.appliedProfiles.isEmpty)
        #expect(names == ["Ada, edited here"])
    }

    @Test @MainActor
    func remoteRenameTouchesRecordingsThatShowTheName() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "Standup", startDate: Date(), segmentsDirURL: nil)
        let local = try #require(await store.createSpeakerProfile(displayName: "Ada"))
        #expect(await store.setSpeakerMapping(recordingID: recordingID, rawLabel: "Speaker 1", profileID: local.id))
        let before = try #require(await store.fetchRecordingDetail(recordingID: recordingID)?.updatedAt)
        let planned = try #require(await store.speakerSyncSnapshot(modelVersion: model)?.profiles[local.id])
        try await Task.sleep(for: .milliseconds(20))
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.profileWrites = [.init(profile: remoteProfile(local.id, name: "Ada Lovelace"), expectedLocalFingerprint: planned.fingerprint)]

        _ = try #require(await store.applySpeakerSyncChanges(plan))
        let after = try #require(await store.fetchRecordingDetail(recordingID: recordingID)?.updatedAt)
        let mappings = await store.speakerMappings(forRecordingID: recordingID)

        #expect(after > before)
        #expect(mappings.map(\.profileName) == ["Ada Lovelace"])
    }

    @Test @MainActor
    func remoteDeletionClearsTheMappingsLikeALocalDelete() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "Standup", startDate: Date(), segmentsDirURL: nil)
        let local = try #require(await store.createSpeakerProfile(displayName: "Ada"))
        #expect(await store.setSpeakerMapping(recordingID: recordingID, rawLabel: "Speaker 1", profileID: local.id))
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.profileDeletions = [local.id]

        _ = try #require(await store.applySpeakerSyncChanges(plan))

        #expect(await store.fetchSpeakerProfiles().isEmpty)
        #expect(await store.speakerMappings(forRecordingID: recordingID).isEmpty)
    }

    @Test @MainActor
    func remoteSamplesBecomeConfirmedSamplesCappedAtFive() async throws {
        let store = try await makeStore()
        let person = remoteProfile()
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.profileWrites = [.init(profile: person, expectedLocalFingerprint: nil)]
        plan.sampleWrites = (1...6).map { index in
            .init(
                sample: remoteSample(profileID: person.profileID, quality: Float(index)),
                expectedLocalFingerprint: nil
            )
        }

        let outcome = try #require(await store.applySpeakerSyncChanges(plan))
        let confirmed = await store.fetchConfirmedSamples(modelVersion: model)
        let snapshot = try #require(await store.speakerSyncSnapshot(modelVersion: model))

        #expect(outcome.appliedSamples.count == 6)
        #expect(confirmed.first?.sampleCount == 5)
        #expect(snapshot.samples.count == 5)
        #expect(!snapshot.samples.values.contains { $0.qualityScore == 1 })
    }

    @Test @MainActor
    func samplesNeitherLeaveNorEnterWithoutLocalConsent() async throws {
        let store = try await makeStore(voiceConsent: false)
        let person = remoteProfile()
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.profileWrites = [.init(profile: person, expectedLocalFingerprint: nil)]
        plan.sampleWrites = [.init(sample: remoteSample(profileID: person.profileID), expectedLocalFingerprint: nil)]

        let outcome = try #require(await store.applySpeakerSyncChanges(plan))
        let snapshot = try #require(await store.speakerSyncSnapshot(modelVersion: model))

        #expect(outcome.appliedProfiles.count == 1)
        #expect(outcome.appliedSamples.isEmpty)
        #expect(!snapshot.samplesConsented)
        #expect(snapshot.samples.isEmpty)
        #expect(await store.fetchConfirmedSamples(modelVersion: model).isEmpty)
    }

    @Test @MainActor
    func snapshotSharesOnlyConfirmedSamplesOfTheRequestedModel() async throws {
        let store = try await makeStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "Standup", startDate: Date(), segmentsDirURL: nil)
        let local = try #require(await store.createSpeakerProfile(displayName: "Ada"))
        for (label, version) in [("Speaker 1", model), ("Speaker 2", model), ("Speaker 3", "other-model")] {
            await store.upsertVoiceSample(
                recordingID: recordingID, rawLabel: label,
                embeddingData: SpeakerVoiceSample.serializeEmbedding([1, 0, 0, 0]),
                embeddingDimension: 4, sampleDuration: 30, nonOverlapRatio: 0.9,
                qualityScore: 20, modelVersion: version
            )
        }
        await store.attachSampleToProfile(recordingID: recordingID, rawLabel: "Speaker 1", profileID: local.id)
        await store.attachSampleToProfile(recordingID: recordingID, rawLabel: "Speaker 3", profileID: local.id)

        let snapshot = try #require(await store.speakerSyncSnapshot(modelVersion: model))

        #expect(snapshot.samples.keys.map(\.rawLabel) == ["Speaker 1"])
    }

    @Test @MainActor
    func sampleDeletionHonorsTheExpectedFingerprint() async throws {
        let store = try await makeStore()
        let person = remoteProfile()
        let kept = remoteSample(profileID: person.profileID, label: "Speaker 1")
        let removed = remoteSample(profileID: person.profileID, label: "Speaker 2")
        var seed = SpeakerProfileSyncPlanner.ApplyPlan()
        seed.profileWrites = [.init(profile: person, expectedLocalFingerprint: nil)]
        seed.sampleWrites = [kept, removed].map { .init(sample: $0, expectedLocalFingerprint: nil) }
        _ = try #require(await store.applySpeakerSyncChanges(seed))
        var plan = SpeakerProfileSyncPlanner.ApplyPlan()
        plan.sampleDeletions = [
            .init(key: kept.key, expectedLocalFingerprint: "not-what-is-stored"),
            .init(key: removed.key, expectedLocalFingerprint: removed.fingerprint),
        ]

        let outcome = try #require(await store.applySpeakerSyncChanges(plan))
        let remaining = try #require(await store.speakerSyncSnapshot(modelVersion: model)).samples.keys

        #expect(outcome.removedSamples == [removed.key])
        #expect(Array(remaining) == [kept.key])
    }
}
