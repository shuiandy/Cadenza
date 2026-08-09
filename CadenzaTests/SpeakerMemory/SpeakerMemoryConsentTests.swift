import Foundation
import Testing

@testable import Cadenza

@MainActor
@Suite("Speaker Memory Consent", .serialized)
struct SpeakerMemoryConsentTests {
    @Test func speakerMemoryIsOffUntilExplicitlyEnabled() {
        let defaults = isolatedDefaults()

        #expect(!SpeakerMemoryConsent.isEnabled(in: defaults))

        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)
        #expect(SpeakerMemoryConsent.isEnabled(in: defaults))
    }

    @Test func postProcessingDoesNotEnrollVoiceSamplesWithoutConsent() throws {
        let store = try makeStore()
        let coordinator = PostProcessingCoordinator(store: store)
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        let previousDiarization = SpeakerDiarizer.shared.isEnabled
        defer {
            restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults)
            SpeakerDiarizer.shared.isEnabled = previousDiarization
        }
        defaults.set(false, forKey: SpeakerMemoryConsent.defaultsKey)
        SpeakerDiarizer.shared.isEnabled = true

        var callCount = 0
        coordinator.speakerMemoryRunner = { _, _, _ in callCount += 1 }
        coordinator.runSpeakerMemoryIfNeeded(
            recordingID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            entries: [
                TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")
            ],
            speakerIdentityRevision: 0
        )

        #expect(callCount == 0)
    }

    @Test func explicitConsentAllowsSpeakerMemory() throws {
        let store = try makeStore()
        let coordinator = PostProcessingCoordinator(store: store)
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        let previousDiarization = SpeakerDiarizer.shared.isEnabled
        defer {
            restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults)
            SpeakerDiarizer.shared.isEnabled = previousDiarization
        }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)
        SpeakerDiarizer.shared.isEnabled = true

        var callCount = 0
        coordinator.speakerMemoryRunner = { _, _, _ in callCount += 1 }
        coordinator.runSpeakerMemoryIfNeeded(
            recordingID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            entries: [
                TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")
            ],
            speakerIdentityRevision: 0
        )

        #expect(callCount == 1)
    }

    @Test func deleteAllSpeakerMemoryRemovesEmbeddingsAndSuggestions() async throws {
        let store = try makeStore()
        let recordingID = UUID()
        await seedMemory(store: store, recordingID: recordingID)

        let deleted = await store.deleteAllSpeakerMemory()

        #expect(deleted)
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
        let detail = await store.fetchRecordingDetail(recordingID: recordingID)
        #expect(detail?.speakerSuggestions.isEmpty == true)
        #expect(detail?.speakerMappings.count == 1)
    }

    @Test func deleteAllSpeakerMemoryRollsBackWhenSaveFails() async throws {
        let store = try makeStore()
        let recordingID = UUID()
        await seedMemory(store: store, recordingID: recordingID)
        await store.failNextSaveForTesting()

        let deleted = await store.deleteAllSpeakerMemory()

        #expect(!deleted)
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).count == 1)
        #expect(await store.fetchRecordingDetail(recordingID: recordingID)?.speakerSuggestions.count == 1)

        #expect(await store.updateTitle(recordingID: recordingID, title: "Unrelated save"))
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).count == 1)
        #expect(await store.fetchRecordingDetail(recordingID: recordingID)?.speakerSuggestions.count == 1)
    }

    @Test func staleAnalysisCannotRestoreMemoryAfterDeletionAndReenable() async throws {
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        defer { restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults) }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        let store = try makeStore()
        let recordingID = UUID()
        await seedMemory(store: store, recordingID: recordingID)
        let staleSession = try #require(await store.beginSpeakerMemoryWriteSession())

        defaults.set(false, forKey: SpeakerMemoryConsent.defaultsKey)
        #expect(await store.deleteAllSpeakerMemory())
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([Float(1), 0, 0, 0]),
            embeddingDimension: 4,
            sampleDuration: 20,
            nonOverlapRatio: 0.9,
            qualityScore: 18,
            modelVersion: "test-v1",
            speakerMemorySession: staleSession
        )

        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
    }

    @Test func staleBatchCannotAttachSamplesThroughLaterUnrelatedSave() async throws {
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        defer { restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults) }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        let store = try makeStore()
        let recordingID = UUID()
        await seedUnmappedSample(store: store, recordingID: recordingID, rawLabel: "Speaker 1")
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Stale Person")
        )
        let staleSession = try #require(await store.beginSpeakerMemoryWriteSession())
        await store.invalidateSpeakerMemoryWriteSessions()

        let attached = await store.attachMappedVoiceSamplesToProfiles(
            recordingID: recordingID,
            mappings: [
                SpeakerLabelMappingDTO(
                    rawLabel: "Speaker 1",
                    profileID: profile.id,
                    profileName: profile.displayName
                )
            ],
            speakerMemorySession: staleSession
        )
        #expect(await store.updateTitle(recordingID: recordingID, title: "Unrelated save"))

        #expect(!attached)
        #expect(
            await store.fetchAllVoiceSamples(recordingID: recordingID)
                .allSatisfy { $0.profileID == nil }
        )
    }

    @Test func validBatchAttachesEveryMappedSample() async throws {
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        defer { restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults) }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        let store = try makeStore()
        let recordingID = UUID()
        await seedUnmappedSample(store: store, recordingID: recordingID, rawLabel: "Speaker 1")
        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 2",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([Float(0), 1, 0, 0]),
            embeddingDimension: 4,
            sampleDuration: 20,
            nonOverlapRatio: 0.9,
            qualityScore: 18,
            modelVersion: "test-v1"
        )
        let firstProfile = try #require(
            await store.createSpeakerProfile(displayName: "First Person")
        )
        let secondProfile = try #require(
            await store.createSpeakerProfile(displayName: "Second Person")
        )
        let session = try #require(await store.beginSpeakerMemoryWriteSession())

        let attached = await store.attachMappedVoiceSamplesToProfiles(
            recordingID: recordingID,
            mappings: [
                SpeakerLabelMappingDTO(
                    rawLabel: "Speaker 1",
                    profileID: firstProfile.id,
                    profileName: firstProfile.displayName
                ),
                SpeakerLabelMappingDTO(
                    rawLabel: "Speaker 2",
                    profileID: secondProfile.id,
                    profileName: secondProfile.displayName
                )
            ],
            speakerMemorySession: session
        )

        let samples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(attached)
        #expect(samples.first { $0.rawLabel == "Speaker 1" }?.profileID == firstProfile.id)
        #expect(samples.first { $0.rawLabel == "Speaker 2" }?.profileID == secondProfile.id)
    }

    @Test func batchRefusesToCommitOlderUnrelatedPendingChanges() async throws {
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        defer { restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults) }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        let container = try RecordingsStore.makeContainer(inMemory: true)
        let store = RecordingsStore(modelContainer: container)
        let recordingID = UUID()
        await seedUnmappedSample(store: store, recordingID: recordingID, rawLabel: "Speaker 1")
        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 2",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([Float(0), 1, 0, 0]),
            embeddingDimension: 4,
            sampleDuration: 20,
            nonOverlapRatio: 0.9,
            qualityScore: 18,
            modelVersion: "test-v1"
        )
        let batchProfile = try #require(
            await store.createSpeakerProfile(displayName: "Batch Person")
        )
        let unrelatedProfile = try #require(
            await store.createSpeakerProfile(displayName: "Pending Person")
        )
        await store.attachSampleToProfile(
            recordingID: recordingID,
            rawLabel: "Speaker 2",
            profileID: unrelatedProfile.id,
            persist: false
        )
        let session = try #require(await store.beginSpeakerMemoryWriteSession())

        let attached = await store.attachMappedVoiceSamplesToProfiles(
            recordingID: recordingID,
            mappings: [
                SpeakerLabelMappingDTO(
                    rawLabel: "Speaker 1",
                    profileID: batchProfile.id,
                    profileName: batchProfile.displayName
                )
            ],
            speakerMemorySession: session
        )
        let durableReader = RecordingsStore(modelContainer: container)
        let durableSamples = await durableReader.fetchAllVoiceSamples(recordingID: recordingID)

        #expect(!attached)
        #expect(durableSamples.allSatisfy { $0.profileID == nil })
        await store.flushPendingChanges()
    }

    @Test func failedBatchSaveRollsBackBeforeLaterUnrelatedSave() async throws {
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        defer { restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults) }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        let store = try makeStore()
        let recordingID = UUID()
        await seedUnmappedSample(store: store, recordingID: recordingID, rawLabel: "Speaker 1")
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Rollback Person")
        )
        let session = try #require(await store.beginSpeakerMemoryWriteSession())
        await store.failNextSaveForTesting()

        let attached = await store.attachMappedVoiceSamplesToProfiles(
            recordingID: recordingID,
            mappings: [
                SpeakerLabelMappingDTO(
                    rawLabel: "Speaker 1",
                    profileID: profile.id,
                    profileName: profile.displayName
                )
            ],
            speakerMemorySession: session
        )
        #expect(await store.updateTitle(recordingID: recordingID, title: "Later save"))

        #expect(!attached)
        #expect(
            await store.fetchAllVoiceSamples(recordingID: recordingID)
                .allSatisfy { $0.profileID == nil }
        )
    }

    @Test func manualMappingWhileConsentIsOffDoesNotConfirmVoiceSample() async throws {
        let defaults = UserDefaults.standard
        let previousConsent = defaults.object(forKey: SpeakerMemoryConsent.defaultsKey)
        defer { restore(previousConsent, key: SpeakerMemoryConsent.defaultsKey, defaults: defaults) }
        defaults.set(true, forKey: SpeakerMemoryConsent.defaultsKey)

        let store = try makeStore()
        let recordingID = UUID()
        await seedUnmappedSample(store: store, recordingID: recordingID, rawLabel: "Speaker 1")
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Explicit Person")
        )
        defaults.set(false, forKey: SpeakerMemoryConsent.defaultsKey)

        let mapped = await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        )

        #expect(mapped)
        #expect(await store.fetchRecordingDetail(recordingID: recordingID)?.speakerMappings.count == 1)
        #expect(await store.fetchConfirmedSamples(modelVersion: "test-v1").isEmpty)
    }

    @Test func settingsTogglePolicyAllowsOptOutAndBlocksDeletionRace() {
        #expect(
            !SpeakerMemoryConsent.isSettingsToggleDisabled(
                diarizationEnabled: false,
                memoryEnabled: true,
                isDeleting: false
            )
        )
        #expect(
            SpeakerMemoryConsent.isSettingsToggleDisabled(
                diarizationEnabled: false,
                memoryEnabled: false,
                isDeleting: false
            )
        )
        #expect(
            SpeakerMemoryConsent.isSettingsToggleDisabled(
                diarizationEnabled: true,
                memoryEnabled: true,
                isDeleting: true
            )
        )
    }

    private func makeStore() throws -> RecordingsStore {
        let container = try RecordingsStore.makeContainer(inMemory: true)
        return RecordingsStore(modelContainer: container)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "SpeakerMemoryConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func seedMemory(
        store: RecordingsStore,
        recordingID: UUID
    ) async {
        await store.createRecording(
            id: recordingID,
            title: "Remembered voice",
            startDate: Date(),
            segmentsDirURL: nil
        )
        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: SpeakerVoiceSample.serializeEmbedding([Float(1), 0, 0, 0]),
            embeddingDimension: 4,
            sampleDuration: 20,
            nonOverlapRatio: 0.9,
            qualityScore: 18,
            modelVersion: "test-v1"
        )
        let profile = await store.createSpeakerProfile(displayName: "Remembered Person")!
        _ = await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        )
        await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "Speaker 1",
                    profileID: profile.id,
                    score: 0.82,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ]
        )
    }

    private func seedUnmappedSample(
        store: RecordingsStore,
        recordingID: UUID,
        rawLabel: String
    ) async {
        await store.createRecording(
            id: recordingID,
            title: "Unmapped voice",
            startDate: Date(),
            segmentsDirURL: nil
        )
        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: rawLabel,
            embeddingData: SpeakerVoiceSample.serializeEmbedding([Float(1), 0, 0, 0]),
            embeddingDimension: 4,
            sampleDuration: 20,
            nonOverlapRatio: 0.9,
            qualityScore: 18,
            modelVersion: "test-v1"
        )
    }
}
