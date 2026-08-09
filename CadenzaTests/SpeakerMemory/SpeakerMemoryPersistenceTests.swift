import Foundation
import SwiftData
import Testing
@testable import Cadenza

@MainActor
private func makeIsolatedStore() async throws -> RecordingsStore {
    let container = try RecordingsStore.makeContainer(inMemory: true)
    return RecordingsStore(modelContainer: container)
}

private func makeSampleEmbedding(dimension: Int = 4) -> Data {
    let floats: [Float] = (0..<dimension).map { Float($0) * 0.1 }
    return SpeakerVoiceSample.serializeEmbedding(floats)
}

private func makeVoiceSampleWrite(
    rawLabel: String,
    sampleDuration: TimeInterval = 10,
    qualityScore: Float = 8
) -> RecordingsStore.VoiceSampleWrite {
    RecordingsStore.VoiceSampleWrite(
        rawLabel: rawLabel,
        embeddingData: makeSampleEmbedding(),
        embeddingDimension: 4,
        sampleDuration: sampleDuration,
        nonOverlapRatio: 0.8,
        qualityScore: qualityScore,
        modelVersion: "test-v1"
    )
}

// MARK: - Upsert Voice Sample

@Suite("RecordingsStore.upsertVoiceSample", .serialized)
struct UpsertVoiceSampleTests {

    @Test @MainActor
    func insertsNewSample() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)

        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 30,
            nonOverlapRatio: 0.8,
            qualityScore: 24,
            modelVersion: "test-v1"
        )

        let samples = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(samples.isEmpty)

        let allSamples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(allSamples.count == 1)
        #expect(allSamples[0].rawLabel == "Speaker 1")
    }

    @Test @MainActor
    func upsertReplacesSameRecordingAndLabel() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 50, nonOverlapRatio: 0.9, qualityScore: 45,
            modelVersion: "test-v1"
        )

        let allSamples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(allSamples.count == 1)
        #expect(allSamples[0].qualityScore == 45)
    }
}

// MARK: - Atomic Voice Sample Batch

@Suite("RecordingsStore.atomicVoiceSampleBatch", .serialized)
struct AtomicVoiceSampleBatchTests {
    @Test @MainActor
    func batchUpsertsEverySampleInOneGeneration() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let revision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        #expect(await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 5,
            nonOverlapRatio: 0.8,
            qualityScore: 4,
            modelVersion: "test-v1",
            expectedSpeakerIdentityRevision: revision
        ))

        let result = await store.upsertVoiceSamplesIfCurrent(
            recordingID: recordingID,
            samples: [
                makeVoiceSampleWrite(rawLabel: "Speaker 1", sampleDuration: 20, qualityScore: 16),
                makeVoiceSampleWrite(rawLabel: "Speaker 2", sampleDuration: 30, qualityScore: 24)
            ],
            expectedSpeakerIdentityRevision: revision
        )

        #expect(result == .applied)
        let samples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(samples.count == 2)
        #expect(samples.first { $0.rawLabel == "Speaker 1" }?.sampleDuration == 20)
        #expect(samples.first { $0.rawLabel == "Speaker 2" }?.sampleDuration == 30)
    }

    @Test @MainActor
    func batchAttachesNewSampleToExistingMappingInSameTransaction() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        _ = await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        ))
        let revision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        let result = await store.upsertVoiceSamplesIfCurrent(
            recordingID: recordingID,
            samples: [makeVoiceSampleWrite(rawLabel: "Speaker 1")],
            expectedSpeakerIdentityRevision: revision
        )

        #expect(result == .applied)
        let samples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(samples.count == 1)
        #expect(samples.first?.profileID == profile.id)
    }

    @Test @MainActor
    func staleBatchWritesNothing() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let staleRevision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        #expect(await store.clearSpeakerSuggestions(recordingID: recordingID))

        let result = await store.upsertVoiceSamplesIfCurrent(
            recordingID: recordingID,
            samples: [
                makeVoiceSampleWrite(rawLabel: "Speaker 1"),
                makeVoiceSampleWrite(rawLabel: "Speaker 2")
            ],
            expectedSpeakerIdentityRevision: staleRevision
        )

        #expect(result == .rejectedStaleRevision)
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
    }

#if DEBUG
    @Test @MainActor
    func failedBatchRestoresEntirePreviousSampleSet() async throws {
        let store = try await makeIsolatedStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let initialRevision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        #expect(await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 5,
            nonOverlapRatio: 0.8,
            qualityScore: 4,
            modelVersion: "test-v1",
            expectedSpeakerIdentityRevision: initialRevision
        ))
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        ))
        let revision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        await store._test_failNextSave()
        let result = await store.upsertVoiceSamplesIfCurrent(
            recordingID: recordingID,
            samples: [
                makeVoiceSampleWrite(rawLabel: "Speaker 1", sampleDuration: 20, qualityScore: 16),
                makeVoiceSampleWrite(rawLabel: "Speaker 2", sampleDuration: 30, qualityScore: 24)
            ],
            expectedSpeakerIdentityRevision: revision
        )

        #expect(result == .saveFailed)
        let samples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(samples.count == 1)
        #expect(samples.first?.rawLabel == "Speaker 1")
        #expect(samples.first?.sampleDuration == 5)
        #expect(samples.first?.qualityScore == 4)
        #expect(samples.first?.profileID == profile.id)
    }
#endif
}

// MARK: - Attach / Detach Samples

@Suite("RecordingsStore.attachDetachSamples", .serialized)
struct AttachDetachSampleTests {

    @Test @MainActor
    func attachSampleToProfile() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )

        await store.attachSampleToProfile(recordingID: recordingID, rawLabel: "Speaker 1", profileID: profile.id)

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(confirmed.count == 1)
        #expect(confirmed[0].profileID == profile.id)
    }

    @Test @MainActor
    func detachSampleFromProfile() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )

        await store.attachSampleToProfile(recordingID: recordingID, rawLabel: "Speaker 1", profileID: profile.id)
        await store.detachSampleFromProfile(recordingID: recordingID, rawLabel: "Speaker 1")

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(confirmed.isEmpty)
    }

    @Test @MainActor
    func pendingAttachmentSurvivesFailedFinalizationRollback() async throws {
        let store = try await makeIsolatedStore()
        let sampleRecordingID = UUID()
        let interruptedRecordingID = UUID()
        await store.createRecording(
            id: sampleRecordingID,
            title: "Speaker sample",
            startDate: Date(),
            segmentsDirURL: nil
        )
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-memory-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        await store.setAudioRootForTesting(audioRoot)
        await store.createRecording(
            id: interruptedRecordingID,
            title: "Interrupted",
            startDate: Date(timeIntervalSinceReferenceDate: 100),
            segmentsDirURL: audioRoot.appendingPathComponent("pending-attachment-recovery", isDirectory: true)
        )
        let profile = try #require(
            await store.createSpeakerProfile(displayName: "Pending Alice")
        )
        await store.upsertVoiceSample(
            recordingID: sampleRecordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 30,
            nonOverlapRatio: 0.8,
            qualityScore: 24,
            modelVersion: "pending-v1"
        )
        await store.attachSampleToProfile(
            recordingID: sampleRecordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id,
            persist: false
        )

        await store.failNextSaveForTesting()
        let result = await store.finalizeRecording(
            id: interruptedRecordingID,
            duration: 120,
            endDate: Date(timeIntervalSinceReferenceDate: 220),
            audioFileURL: audioRoot.appendingPathComponent("pending-attachment.m4a")
        )
        await store.flushPendingChanges()

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "pending-v1")
        #expect(result == .failed)
        #expect(confirmed.contains { $0.profileID == profile.id })
    }
}

// MARK: - Model Version Filtering

@Suite("RecordingsStore.modelVersionFiltering", .serialized)
struct ModelVersionFilteringTests {

    @Test @MainActor
    func fetchConfirmedSamplesFiltersVersion() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "old-v0"
        )
        await store.attachSampleToProfile(recordingID: recordingID, rawLabel: "Speaker 1", profileID: profile.id)

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(confirmed.isEmpty)

        let oldConfirmed = await store.fetchConfirmedSamples(modelVersion: "old-v0")
        #expect(oldConfirmed.count == 1)
    }

    @Test @MainActor
    func fetchConfirmedSamplesFiltersEmbeddingDimension() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        let firstRecordingID = UUID()
        await store.createRecording(id: firstRecordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.upsertVoiceSample(
            recordingID: firstRecordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(dimension: 4), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )
        await store.attachSampleToProfile(recordingID: firstRecordingID, rawLabel: "Speaker 1", profileID: profile.id)

        let secondRecordingID = UUID()
        await store.createRecording(id: secondRecordingID, title: "R2", startDate: Date(), segmentsDirURL: nil)
        await store.upsertVoiceSample(
            recordingID: secondRecordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(dimension: 6), embeddingDimension: 6,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )
        await store.attachSampleToProfile(recordingID: secondRecordingID, rawLabel: "Speaker 1", profileID: profile.id)

        let allConfirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(allConfirmed.count == 2)

        let dim4Confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1", embeddingDimension: 4)
        #expect(dim4Confirmed.count == 1)
        #expect(dim4Confirmed[0].embeddingDimension == 4)
        #expect(dim4Confirmed[0].embedding.count == 4)
        #expect(dim4Confirmed[0].sampleCount == 1)

        let dim6Confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1", embeddingDimension: 6)
        #expect(dim6Confirmed.count == 1)
        #expect(dim6Confirmed[0].embeddingDimension == 6)
        #expect(dim6Confirmed[0].embedding.count == 6)
        #expect(dim6Confirmed[0].sampleCount == 1)
    }
}

// MARK: - Retention Cap

@Suite("RecordingsStore.retentionCap", .serialized)
struct RetentionCapTests {

    @Test @MainActor
    func evictsLowestQualityWhenOverCap() async throws {
        let store = try await makeIsolatedStore()
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        for i in 0..<6 {
            let rid = UUID()
            await store.createRecording(id: rid, title: "R\(i)", startDate: Date(), segmentsDirURL: nil)
            await store.upsertVoiceSample(
                recordingID: rid, rawLabel: "Speaker 1",
                embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
                sampleDuration: Float64(10 + i * 5), nonOverlapRatio: 0.8,
                qualityScore: Float(10 + i * 5),
                modelVersion: "test-v1"
            )
            await store.attachSampleToProfile(recordingID: rid, rawLabel: "Speaker 1", profileID: profile.id)
            await store.enforceRetentionCap(profileID: profile.id, modelVersion: "test-v1", maxSamples: 5)
        }

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        let aliceSamples = confirmed.filter { $0.profileID == profile.id }
        #expect(aliceSamples.count == 1)  // grouped by profile, returns 1 entry
        #expect(aliceSamples[0].sampleCount == 5)
    }
}

// MARK: - Speaker Suggestions

@Suite("RecordingsStore.speakerSuggestions", .serialized)
struct SpeakerSuggestionsTests {

    @Test @MainActor
    func saveSuggestions() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        let suggestions = [
            SpeakerLabelSuggestion(
                rawLabel: "Speaker 1", profileID: profile.id,
                score: 0.85, strategy: "voice", modelVersion: "test-v1", generatedAt: Date()
            )
        ]

        await store.saveSpeakerSuggestions(recordingID: recordingID, suggestions: suggestions)

        let detail = await store.fetchRecordingDetail(recordingID: recordingID)
        #expect(detail?.speakerSuggestions.count == 1)
        #expect(detail?.speakerSuggestions.first?.rawLabel == "Speaker 1")
        #expect(detail?.speakerSuggestions.first?.profileName == "Alice")
    }

    @Test @MainActor
    func clearSuggestions() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        let suggestions = [
            SpeakerLabelSuggestion(
                rawLabel: "Speaker 1", profileID: profile.id,
                score: 0.85, strategy: "voice", modelVersion: "test-v1", generatedAt: Date()
            )
        ]
        await store.saveSpeakerSuggestions(recordingID: recordingID, suggestions: suggestions)
        await store.clearSpeakerSuggestions(recordingID: recordingID)

        let detail = await store.fetchRecordingDetail(recordingID: recordingID)
        #expect(detail?.speakerSuggestions.isEmpty == true)
    }
}

// MARK: - Mapping Integration

@Suite("RecordingsStore.mappingIntegration", .serialized)
struct MappingIntegrationTests {

    @Test @MainActor
    func setSpeakerMappingAttachesSample() async throws {
        let store = try await makeIsolatedStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )

        await store.setSpeakerMapping(recordingID: recordingID, rawLabel: "Speaker 1", profileID: profile.id)

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(confirmed.count == 1)
    }

    @Test @MainActor
    func removeSpeakerMappingDetachesSample() async throws {
        let store = try await makeIsolatedStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = await store.createSpeakerProfile(displayName: "Alice")!

        await store.upsertVoiceSample(
            recordingID: recordingID, rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(), embeddingDimension: 4,
            sampleDuration: 30, nonOverlapRatio: 0.8, qualityScore: 24,
            modelVersion: "test-v1"
        )

        await store.setSpeakerMapping(recordingID: recordingID, rawLabel: "Speaker 1", profileID: profile.id)
        await store.removeSpeakerMapping(recordingID: recordingID, rawLabel: "Speaker 1")

        let confirmed = await store.fetchConfirmedSamples(modelVersion: "test-v1")
        #expect(confirmed.isEmpty)
    }
}

// MARK: - Delete Speaker Profile Integrity

@Suite("RecordingsStore.deleteSpeakerProfileIntegrity", .serialized)
struct DeleteSpeakerProfileIntegrityTests {
    @Test @MainActor
    func deletionClearsReferencesAndAdvancesEveryAffectedRecording() async throws {
        let store = try await makeIsolatedStore()
        let deletedProfile = try #require(await store.createSpeakerProfile(displayName: "Delete me"))
        let retainedProfile = try #require(await store.createSpeakerProfile(displayName: "Keep me"))

        let mappedRecordingID = UUID()
        await store.createRecording(
            id: mappedRecordingID,
            title: "Mapped",
            startDate: Date(),
            segmentsDirURL: nil
        )
        _ = await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: mappedRecordingID,
            fullText: "Mapped",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Mapped", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        #expect(await store.upsertVoiceSample(
            recordingID: mappedRecordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 5,
            nonOverlapRatio: 0.8,
            qualityScore: 4,
            modelVersion: "test-v1"
        ))
        #expect(await store.setSpeakerMapping(
            recordingID: mappedRecordingID,
            rawLabel: "Speaker 1",
            profileID: deletedProfile.id
        ))

        let suggestedRecordingID = UUID()
        await store.createRecording(
            id: suggestedRecordingID,
            title: "Suggested",
            startDate: Date(),
            segmentsDirURL: nil
        )
        #expect(await store.saveSpeakerSuggestions(
            recordingID: suggestedRecordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "Speaker 1",
                    profileID: deletedProfile.id,
                    score: 0.9,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                ),
                SpeakerLabelSuggestion(
                    rawLabel: "Speaker 2",
                    profileID: retainedProfile.id,
                    score: 0.8,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ]
        ))

        let sampleOnlyRecordingID = UUID()
        await store.createRecording(
            id: sampleOnlyRecordingID,
            title: "Sample only",
            startDate: Date(),
            segmentsDirURL: nil
        )
        #expect(await store.upsertVoiceSample(
            recordingID: sampleOnlyRecordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 5,
            nonOverlapRatio: 0.8,
            qualityScore: 4,
            modelVersion: "test-v1"
        ))
        #expect(await store.attachSampleToProfile(
            recordingID: sampleOnlyRecordingID,
            rawLabel: "Speaker 1",
            profileID: deletedProfile.id
        ))

        let unaffectedRecordingID = UUID()
        await store.createRecording(
            id: unaffectedRecordingID,
            title: "Unaffected",
            startDate: Date(),
            segmentsDirURL: nil
        )
        #expect(await store.setSpeakerMapping(
            recordingID: unaffectedRecordingID,
            rawLabel: "Speaker 1",
            profileID: retainedProfile.id
        ))

        let mappedRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: mappedRecordingID)
        ).speakerIdentityRevision
        let suggestedRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: suggestedRecordingID)
        ).speakerIdentityRevision
        let sampleOnlyRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: sampleOnlyRecordingID)
        ).speakerIdentityRevision
        let unaffectedRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: unaffectedRecordingID)
        ).speakerIdentityRevision

        #expect(await store.deleteSpeakerProfile(id: deletedProfile.id))

        let mapped = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: mappedRecordingID))
        let suggested = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: suggestedRecordingID))
        let sampleOnly = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: sampleOnlyRecordingID))
        let unaffected = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: unaffectedRecordingID))
        #expect(mapped.speakerIdentityRevision != mappedRevision)
        #expect(suggested.speakerIdentityRevision != suggestedRevision)
        #expect(sampleOnly.speakerIdentityRevision != sampleOnlyRevision)
        #expect(unaffected.speakerIdentityRevision == unaffectedRevision)
        #expect(mapped.detail.speakerMappings.isEmpty)
        #expect(suggested.detail.speakerSuggestions.count == 1)
        #expect(suggested.detail.speakerSuggestions.first?.profileID == retainedProfile.id)
        #expect(unaffected.detail.speakerMappings.first?.profileID == retainedProfile.id)
        #expect(
            await store.fetchAllVoiceSamples(recordingID: sampleOnlyRecordingID).first?.profileID == nil
        )
        #expect(!(await store.fetchSpeakerProfiles()).contains { $0.id == deletedProfile.id })
    }

    @Test @MainActor
    func deletingProfileInvalidatesAnOlderSpeakerMemoryTask() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        _ = await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        let deletedProfile = try #require(await store.createSpeakerProfile(displayName: "Delete me"))
        let automaticProfile = try #require(await store.createSpeakerProfile(displayName: "Automatic guess"))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: deletedProfile.id
        ))
        let staleRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        #expect(await store.deleteSpeakerProfile(id: deletedProfile.id))
        let batchResult = await store.upsertVoiceSamplesIfCurrent(
            recordingID: recordingID,
            samples: [makeVoiceSampleWrite(rawLabel: "Speaker 1")],
            expectedSpeakerIdentityRevision: staleRevision
        )
        let mappingResult = await store.applySpeakerMappingIfCurrent(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: automaticProfile.id,
            expectedSpeakerIdentityRevision: staleRevision
        )
        let suggestionSaved = await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "Speaker 1",
                    profileID: automaticProfile.id,
                    score: 0.9,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ],
            expectedSpeakerIdentityRevision: staleRevision
        )

        #expect(batchResult == .rejectedStaleRevision)
        #expect(mappingResult == .rejectedStaleRevision)
        #expect(!suggestionSaved)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detail.speakerMappings.isEmpty)
        #expect(detail.speakerSuggestions.isEmpty)
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
    }

    @Test @MainActor
    func suggestionWriteRejectsProfileDeletedAfterAnalysisReadIt() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let revision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        let deletedProfile = try #require(await store.createSpeakerProfile(displayName: "Delete me"))

        // This recording does not reference the profile yet, so deletion does
        // not need to invalidate its revision. The suggestion write itself must
        // still reject the profile ID captured by an in-flight analysis.
        #expect(await store.deleteSpeakerProfile(id: deletedProfile.id))
        #expect(await store.isSpeakerIdentityRevisionCurrent(
            recordingID: recordingID,
            revision: revision
        ))
        let saved = await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "Speaker 1",
                    profileID: deletedProfile.id,
                    score: 0.8,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ],
            expectedSpeakerIdentityRevision: revision
        )

        #expect(!saved)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detail.speakerSuggestions.isEmpty)
    }

#if DEBUG
    @Test @MainActor
    func failedDeletionRestoresProfileReferencesAndRevisions() async throws {
        let store = try await makeIsolatedStore()
        await store.setSpeakerMemoryConsentForTesting(true)
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        #expect(await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 5,
            nonOverlapRatio: 0.8,
            qualityScore: 4,
            modelVersion: "test-v1"
        ))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        ))
        #expect(await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "Speaker 1",
                    profileID: profile.id,
                    score: 0.9,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ]
        ))
        let revision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        await store._test_failNextSave()
        #expect(!(await store.deleteSpeakerProfile(id: profile.id)))

        let snapshot = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID))
        #expect(snapshot.speakerIdentityRevision == revision)
        #expect(snapshot.detail.speakerMappings.first?.profileID == profile.id)
        #expect(snapshot.detail.speakerSuggestions.first?.profileID == profile.id)
        #expect((await store.fetchSpeakerProfiles()).contains { $0.id == profile.id })
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).first?.profileID == profile.id)
    }
#endif
}

// MARK: - Retranscription Reset

@Suite("RecordingsStore.retranscriptionSpeakerReset", .serialized)
struct RetranscriptionSpeakerResetTests {
    @Test @MainActor
    func replacingTranscriptClearsStaleMappingsSuggestionsAndVoiceSamples() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        await store.saveTranscript(
            recordingID: recordingID,
            fullText: "Old transcript",
            segments: [TranscriptEntry(startTime: 0, endTime: 10, text: "Old", speaker: "A")],
            language: "en",
            tags: []
        )
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "A",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 10,
            nonOverlapRatio: 0.9,
            qualityScore: 9,
            modelVersion: "test-v1"
        )
        await store.setSpeakerMapping(recordingID: recordingID, rawLabel: "A", profileID: profile.id)
        await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "B",
                    profileID: profile.id,
                    score: 0.8,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ]
        )

        let saved = await store.saveTranscript(
            recordingID: recordingID,
            fullText: "New transcript",
            segments: [TranscriptEntry(startTime: 0, endTime: 10, text: "New", speaker: "Speaker 1")],
            language: "en",
            tags: [],
            resetSpeakerIdentity: true
        )

        #expect(saved)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detail.speakerMappings.isEmpty)
        #expect(detail.speakerSuggestions.isEmpty)
        #expect(detail.transcript?.segments.first?.speaker == "Speaker 1")
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
    }

    @Test @MainActor
    func staleSpeakerAnalysisCannotWriteAfterRetranscription() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let staleRevision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "First",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "First", speaker: "A")],
            language: "en",
            tags: []
        ))

        let currentRevision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Second",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Second", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        #expect(currentRevision != staleRevision)

        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        let sampleSaved = await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "A",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 5,
            nonOverlapRatio: 0.9,
            qualityScore: 4.5,
            modelVersion: "test-v1",
            expectedSpeakerIdentityRevision: staleRevision
        )
        let mappingSaved = await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "A",
            profileID: profile.id,
            expectedSpeakerIdentityRevision: staleRevision
        )
        let suggestionsSaved = await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [
                SpeakerLabelSuggestion(
                    rawLabel: "A",
                    profileID: profile.id,
                    score: 0.9,
                    strategy: "voice",
                    modelVersion: "test-v1",
                    generatedAt: Date()
                )
            ],
            expectedSpeakerIdentityRevision: staleRevision
        )

        #expect(!sampleSaved)
        #expect(!mappingSaved)
        #expect(!suggestionsSaved)
        #expect(await store.fetchAllVoiceSamples(recordingID: recordingID).isEmpty)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detail.speakerMappings.isEmpty)
        #expect(detail.speakerSuggestions.isEmpty)
        #expect(detail.transcript?.segments.first?.speaker == "Speaker 1")
    }
}

// MARK: - Manual Identity Edit Guards

@Suite("RecordingsStore.manualSpeakerIdentityEditGuards", .serialized)
struct ManualSpeakerIdentityEditGuardTests {
    @Test @MainActor
    func manualSelectionInvalidatesOlderAnalysisAndPreservesUserMapping() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let staleRevision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        let userProfile = try #require(await store.createSpeakerProfile(displayName: "User choice"))
        let automaticProfile = try #require(await store.createSpeakerProfile(displayName: "Automatic guess"))

        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: userProfile.id
        ))

        let result = await store.applySpeakerMappingIfCurrent(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: automaticProfile.id,
            expectedSpeakerIdentityRevision: staleRevision
        )

        #expect(result == .rejectedStaleRevision)
        let mappings = await store.speakerMappings(forRecordingID: recordingID)
        #expect(mappings.count == 1)
        #expect(mappings.first?.profileID == userProfile.id)
    }

    @Test @MainActor
    func currentAnalysisStillCannotOverwriteExistingManualMapping() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        _ = await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        let userProfile = try #require(await store.createSpeakerProfile(displayName: "User choice"))
        let automaticProfile = try #require(await store.createSpeakerProfile(displayName: "Automatic guess"))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: userProfile.id
        ))
        let currentRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        let result = await store.applySpeakerMappingIfCurrent(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: automaticProfile.id,
            expectedSpeakerIdentityRevision: currentRevision
        )

        #expect(result == .preservedExistingMapping)
        let mappings = await store.speakerMappings(forRecordingID: recordingID)
        #expect(mappings.count == 1)
        #expect(mappings.first?.profileID == userProfile.id)
    }

    @Test @MainActor
    func manualRemovalInvalidatesAnalysisSoMappingCannotReappear() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        _ = await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        )
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        ))
        let staleRevision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        #expect(await store.removeSpeakerMapping(recordingID: recordingID, rawLabel: "Speaker 1"))
        let result = await store.applySpeakerMappingIfCurrent(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id,
            expectedSpeakerIdentityRevision: staleRevision
        )

        #expect(result == .rejectedStaleRevision)
        #expect(await store.speakerMappings(forRecordingID: recordingID).isEmpty)
    }

    @Test @MainActor
    func manualSuggestionClearInvalidatesAnalysisSoSuggestionsStayCleared() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let staleRevision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        let originalSuggestion = SpeakerLabelSuggestion(
            rawLabel: "Speaker 1",
            profileID: profile.id,
            score: 0.8,
            strategy: "voice",
            modelVersion: "test-v1",
            generatedAt: Date()
        )
        #expect(await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [originalSuggestion],
            expectedSpeakerIdentityRevision: staleRevision
        ))

        #expect(await store.clearSpeakerSuggestions(recordingID: recordingID))
        let staleWriteSucceeded = await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [originalSuggestion],
            expectedSpeakerIdentityRevision: staleRevision
        )

        #expect(!staleWriteSucceeded)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detail.speakerSuggestions.isEmpty)
    }

}

#if DEBUG
// MARK: - Speaker Identity Save Rollback

@Suite("RecordingsStore.speakerIdentitySaveRollback", .serialized)
struct SpeakerIdentitySaveRollbackTests {
    @Test @MainActor
    func failedVoiceSampleReplacementRestoresPreviousSample() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        #expect(await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 10,
            nonOverlapRatio: 0.8,
            qualityScore: 8,
            modelVersion: "test-v1"
        ))

        await store._test_failNextSave()
        let saved = await store.upsertVoiceSample(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            embeddingData: makeSampleEmbedding(),
            embeddingDimension: 4,
            sampleDuration: 40,
            nonOverlapRatio: 0.9,
            qualityScore: 36,
            modelVersion: "test-v1"
        )

        #expect(!saved)
        let samples = await store.fetchAllVoiceSamples(recordingID: recordingID)
        #expect(samples.count == 1)
        #expect(samples.first?.sampleDuration == 10)
        #expect(samples.first?.qualityScore == 8)
    }

    @Test @MainActor
    func failedManualMappingRestoresRevisionAndMappingState() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let revision = try #require(await store.replaceTranscriptForSpeakerAnalysis(
            recordingID: recordingID,
            fullText: "Hello",
            segments: [TranscriptEntry(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1")],
            language: "en",
            tags: []
        ))
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))

        await store._test_failNextSave()
        let saved = await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        )

        #expect(!saved)
        #expect(await store.speakerMappings(forRecordingID: recordingID).isEmpty)
        let snapshot = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID))
        #expect(snapshot.speakerIdentityRevision == revision)

        let automaticResult = await store.applySpeakerMappingIfCurrent(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id,
            expectedSpeakerIdentityRevision: revision
        )
        #expect(automaticResult == .applied)
    }

    @Test @MainActor
    func failedSuggestionSaveRestoresPreviousSuggestions() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        let original = SpeakerLabelSuggestion(
            rawLabel: "Speaker 1",
            profileID: profile.id,
            score: 0.75,
            strategy: "voice",
            modelVersion: "test-v1",
            generatedAt: Date()
        )
        #expect(await store.saveSpeakerSuggestions(recordingID: recordingID, suggestions: [original]))

        let replacement = SpeakerLabelSuggestion(
            rawLabel: "Speaker 2",
            profileID: profile.id,
            score: 0.95,
            strategy: "voice",
            modelVersion: "test-v1",
            generatedAt: Date()
        )
        await store._test_failNextSave()
        let saved = await store.saveSpeakerSuggestions(
            recordingID: recordingID,
            suggestions: [replacement]
        )

        #expect(!saved)
        let detail = try #require(await store.fetchRecordingDetail(recordingID: recordingID))
        #expect(detail.speakerSuggestions.count == 1)
        #expect(detail.speakerSuggestions.first?.rawLabel == "Speaker 1")
    }

    @Test @MainActor
    func failedManualRemovalRestoresRevisionAndMapping() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        #expect(await store.setSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1",
            profileID: profile.id
        ))
        let revision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        await store._test_failNextSave()
        let removed = await store.removeSpeakerMapping(
            recordingID: recordingID,
            rawLabel: "Speaker 1"
        )

        #expect(!removed)
        let snapshot = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID))
        #expect(snapshot.speakerIdentityRevision == revision)
        #expect(snapshot.detail.speakerMappings.first?.profileID == profile.id)
    }

    @Test @MainActor
    func failedManualSuggestionClearRestoresRevisionAndSuggestions() async throws {
        let store = try await makeIsolatedStore()
        let recordingID = UUID()
        await store.createRecording(id: recordingID, title: "R1", startDate: Date(), segmentsDirURL: nil)
        let profile = try #require(await store.createSpeakerProfile(displayName: "Alice"))
        let suggestion = SpeakerLabelSuggestion(
            rawLabel: "Speaker 1",
            profileID: profile.id,
            score: 0.8,
            strategy: "voice",
            modelVersion: "test-v1",
            generatedAt: Date()
        )
        #expect(await store.saveSpeakerSuggestions(recordingID: recordingID, suggestions: [suggestion]))
        let revision = try #require(
            await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID)
        ).speakerIdentityRevision

        await store._test_failNextSave()
        let cleared = await store.clearSpeakerSuggestions(recordingID: recordingID)

        #expect(!cleared)
        let snapshot = try #require(await store.fetchSpeakerAnalysisSnapshot(recordingID: recordingID))
        #expect(snapshot.speakerIdentityRevision == revision)
        #expect(snapshot.detail.speakerSuggestions.count == 1)
        #expect(snapshot.detail.speakerSuggestions.first?.rawLabel == "Speaker 1")
    }

}
#endif
